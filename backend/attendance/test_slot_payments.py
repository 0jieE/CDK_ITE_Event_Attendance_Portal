"""Marking a fine paid slot by slot (partial payments)."""

import datetime
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from attendance import services
from attendance.models import AttendanceLog, EventDayFine, Fine, FineSlotPayment

from .tests import make_event, make_student

User = get_user_model()
PW = "pw-12345-Xy"
D = datetime.timedelta


def noon(day):
    return timezone.make_aware(datetime.datetime.combine(day, datetime.time(12, 0)))


class SlotPaymentTests(TestCase):
    def setUp(self):
        cache.clear()
        today = timezone.localdate()
        self.d0, self.d1, self.d2 = today - D(days=2), today - D(days=1), today
        # 3 days, 2 required slots, closed windows, default 10 and day 1 costs 50
        self.event = make_event(
            start_date=self.d0, end_date=self.d2, fine_rate=Decimal("10.00"),
            required_types=["AM_IN", "PM_OUT"],
            am_in_start=datetime.time(0, 0), am_in_end=datetime.time(0, 1),
            pm_in_start=None, pm_in_end=None,
            pm_out_start=datetime.time(0, 2), pm_out_end=datetime.time(0, 3),
        )
        EventDayFine.objects.create(event=self.event, date=self.d1, fine_rate=Decimal("50.00"))
        self.student = make_student("s1", "S-1")
        self.now = noon(self.d2)
        services.compute_fines_for_event(self.event, now=self.now)
        self.fine = Fine.objects.get(student=self.student)          # 6 slots: 10+10 + 50+50 + 10+10 = 140
        self.adviser = User.objects.create_user("adviser", password=PW, is_admin=True)

    def test_setup_numbers(self):
        self.assertEqual((self.fine.missed_slots, self.fine.amount), (6, Decimal("140.00")))
        self.assertEqual(self.fine.amount_paid, 0)

    def test_pay_one_slot_makes_the_fine_part_paid(self):
        services.pay_slots(self.fine, slots=[(self.d1, "AM_IN")], recorded_by=self.adviser, now=self.now)
        self.fine.refresh_from_db()
        self.assertEqual(self.fine.amount_paid, Decimal("50.00"))
        self.assertEqual(self.fine.balance, Decimal("90.00"))
        self.assertEqual(self.fine.status, Fine.Status.UNPAID)
        self.assertTrue(self.fine.is_partially_paid)
        self.assertEqual(FineSlotPayment.objects.get().amount, Decimal("50.00"))

    def test_paying_every_slot_one_by_one_marks_the_fine_paid(self):
        for day, slot, _ in services.missed_slot_details(self.student, self.event, self.now):
            services.pay_slots(self.fine, slots=[(day, slot)], recorded_by=self.adviser, now=self.now)
        self.fine.refresh_from_db()
        self.assertEqual((self.fine.status, self.fine.amount_paid), (Fine.Status.PAID, Decimal("140.00")))
        self.assertIsNotNone(self.fine.paid_at)
        self.assertEqual(self.fine.recorded_by, self.adviser)

    def test_mark_paid_pays_only_the_remaining_slots(self):
        services.pay_slots(self.fine, slots=[(self.d1, "AM_IN")], now=self.now)
        self.fine.mark_paid(recorded_by=self.adviser)
        self.fine.refresh_from_db()
        self.assertEqual(self.fine.status, Fine.Status.PAID)
        self.assertEqual(self.fine.slot_payments.count(), 6)
        self.assertEqual(self.fine.amount_paid, Decimal("140.00"))

    def test_only_missed_slots_can_be_paid_and_paying_twice_is_a_noop(self):
        with self.assertRaises(ValueError):
            services.pay_slots(self.fine, slots=[(self.d0, "AM_OUT")], now=self.now)     # not required
        self.assertEqual(services.pay_slots(self.fine, slots=[(self.d0, "AM_IN")], now=self.now), 1)
        self.assertEqual(services.pay_slots(self.fine, slots=[(self.d0, "AM_IN")], now=self.now), 0)
        self.assertEqual(FineSlotPayment.objects.count(), 1)

    def test_undo_a_slot_payment(self):
        services.pay_slots(self.fine, now=self.now)
        self.fine.refresh_from_db()
        self.assertEqual(self.fine.status, Fine.Status.PAID)
        self.assertTrue(services.unpay_slot(self.fine, self.d1, "AM_IN"))
        self.fine.refresh_from_db()
        self.assertEqual((self.fine.status, self.fine.amount_paid, self.fine.paid_at),
                         (Fine.Status.UNPAID, Decimal("90.00"), None))
        self.assertFalse(services.unpay_slot(self.fine, self.d1, "AM_IN"))

    def test_recompute_keeps_payments_and_a_new_miss_reopens_a_paid_fine(self):
        # pay everything as of "yesterday noon", then a later day is missed too
        yesterday_noon = noon(self.d1)
        services.compute_fines_for_event(self.event, now=yesterday_noon)
        fine = Fine.objects.get(student=self.student)
        services.pay_slots(fine, now=yesterday_noon)
        fine.refresh_from_db()
        self.assertEqual((fine.status, fine.amount), (Fine.Status.PAID, Decimal("120.00")))
        services.compute_fines_for_event(self.event, now=self.now)       # today's two slots now missed
        fine.refresh_from_db()
        self.assertEqual(fine.amount, Decimal("140.00"))
        self.assertEqual((fine.status, fine.amount_paid), (Fine.Status.UNPAID, Decimal("120.00")))
        self.assertEqual(fine.balance, Decimal("20.00"))
        self.assertFalse(fine.needs_review)

    def test_fine_paid_in_full_before_slot_payments_stays_protected(self):
        legacy = Fine.objects.get(student=self.student)
        Fine.objects.filter(pk=legacy.pk).update(status=Fine.Status.PAID, amount_paid=legacy.amount)
        self.assertEqual(services.pay_slots(Fine.objects.get(pk=legacy.pk), now=self.now), 0)
        EventDayFine.objects.filter(event=self.event).update(fine_rate=Decimal("60.00"))
        services.compute_fines_for_event(self.event, now=self.now)
        fine = Fine.objects.get(pk=legacy.pk)
        self.assertEqual((fine.status, fine.amount), (Fine.Status.PAID, Decimal("140.00")))
        self.assertTrue(fine.needs_review)

    def test_totals_use_the_amount_actually_paid(self):
        services.pay_slots(self.fine, slots=[(self.d1, "AM_IN"), (self.d1, "PM_OUT")], now=self.now)
        dash = services.build_dashboard()
        self.assertEqual(dash["total_fines_issued"], Decimal("140.00"))
        self.assertEqual(dash["total_collected"], Decimal("100.00"))
        self.assertEqual(dash["total_outstanding"], Decimal("40.00"))
        row = services.financial_report()[0]
        self.assertEqual((row["collected"], row["outstanding"]), (Decimal("100.00"), Decimal("40.00")))

    def test_student_api_shows_paid_and_balance(self):
        services.pay_slots(self.fine, slots=[(self.d1, "AM_IN")], now=self.now)
        api = APIClient()
        api.force_authenticate(self.student.user)
        fine = api.get(reverse("student-fines")).json()
        fine = fine["results"][0] if isinstance(fine, dict) else fine[0]
        self.assertEqual((fine["amount_paid"], fine["balance"], fine["status"]), ("50.00", "90.00", "UNPAID"))
        bal = api.get(reverse("student-balance")).json()
        self.assertEqual((bal["total_fines"], bal["total_paid"], bal["outstanding"]), ("140.00", "50.00", "90.00"))

    def test_admin_api_status_patch_pays_and_unpays_slots(self):
        api = APIClient()
        api.force_authenticate(self.adviser)
        url = reverse("fine-detail", args=[self.fine.pk])
        res = api.patch(url, {"status": "PAID"}, format="json")
        self.assertEqual(res.status_code, 200, res.content)
        self.fine.refresh_from_db()
        self.assertEqual((self.fine.status, self.fine.slot_payments.count()), (Fine.Status.PAID, 6))
        api.patch(url, {"status": "UNPAID"}, format="json")
        self.fine.refresh_from_db()
        self.assertEqual((self.fine.status, self.fine.amount_paid, self.fine.slot_payments.count()),
                         (Fine.Status.UNPAID, 0, 0))


class PortalSlotPaymentTests(TestCase):
    def setUp(self):
        cache.clear()
        today = timezone.localdate()
        self.event = make_event(
            start_date=today - D(days=1), end_date=today - D(days=1), fine_rate=Decimal("15.00"),
            required_types=["AM_IN", "PM_OUT"],
            am_in_start=datetime.time(0, 0), am_in_end=datetime.time(0, 1),
            pm_out_start=datetime.time(0, 2), pm_out_end=datetime.time(0, 3),
        )
        self.day = self.event.start_date
        self.student = make_student("s1", "S-1")
        services.compute_fines_for_event(self.event)
        self.fine = Fine.objects.get(student=self.student)
        User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.login(username="adviser", password=PW)

    def grid(self):
        return self.client.get(reverse("portal:fines-list"), {
            "view": "student", "student": self.student.pk, "event": self.event.pk}).content.decode()

    def post(self, name, **data):
        return self.client.post(reverse(name, args=[self.fine.pk]), data, HTTP_HX_REQUEST="true")

    def test_grid_offers_a_pay_button_per_missed_slot(self):
        html = self.grid()
        self.assertEqual(html.count("Pay ₱15.00"), 2)
        self.assertIn("Mark all paid", html)

    def test_pay_a_single_slot_then_undo_it(self):
        r = self.post("portal:fines-pay-slot", date=self.day.isoformat(), slot="AM_IN")
        self.assertEqual(r.status_code, 204)
        self.fine.refresh_from_db()
        self.assertEqual((self.fine.amount_paid, self.fine.status), (Decimal("15.00"), Fine.Status.UNPAID))
        html = self.grid()
        self.assertEqual(html.count("Pay ₱15.00"), 1)               # the other slot is still payable
        self.assertIn("Part-paid", html)
        self.assertIn("Pay balance", html)
        self.post("portal:fines-unpay-slot", date=self.day.isoformat(), slot="AM_IN")
        self.fine.refresh_from_db()
        self.assertEqual(self.fine.amount_paid, 0)

    def test_paying_both_slots_completes_the_fine(self):
        for slot in ("AM_IN", "PM_OUT"):
            self.post("portal:fines-pay-slot", date=self.day.isoformat(), slot=slot)
        self.fine.refresh_from_db()
        self.assertEqual(self.fine.status, Fine.Status.PAID)
        html = self.grid()
        self.assertEqual(html.count("Pay ₱15.00"), 0)
        self.assertEqual(html.count('class="badge text-bg-success" title="₱15.00 paid"'), 2)

    def test_bad_input_is_rejected_without_side_effects(self):
        for data in ({"date": "nope", "slot": "AM_IN"}, {"date": self.day.isoformat(), "slot": "AM_OUT"}):
            r = self.post("portal:fines-pay-slot", **data)
            self.assertEqual(r.status_code, 204)
            self.assertIn("error", r["HX-Trigger"])
        self.assertEqual(FineSlotPayment.objects.count(), 0)
        self.assertEqual(self.client.get(reverse("portal:fines-pay-slot", args=[self.fine.pk])).status_code, 405)

    def test_mark_paid_button_still_pays_everything_and_the_ledger_shows_it(self):
        r = self.post("portal:fines-mark-paid")
        self.assertEqual(r.status_code, 204)
        self.fine.refresh_from_db()
        self.assertEqual((self.fine.status, self.fine.amount_paid), (Fine.Status.PAID, Decimal("30.00")))
        self.assertContains(self.client.get(reverse("portal:fines-list")), "Paid")

    def test_non_admins_cannot_pay_slots(self):
        self.client.logout()
        User.objects.create_user("stu", password=PW, is_student=True)
        self.client.login(username="stu", password=PW)
        r = self.client.post(reverse("portal:fines-pay-slot", args=[self.fine.pk]),
                             {"date": self.day.isoformat(), "slot": "AM_IN"})
        self.assertEqual(r.status_code, 403)
        self.assertEqual(FineSlotPayment.objects.count(), 0)
