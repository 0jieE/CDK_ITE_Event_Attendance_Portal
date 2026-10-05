"""Fines are per *required attendance slot* and update automatically."""

import datetime
from decimal import Decimal

from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Student, User

from . import services
from .models import AttendanceLog, Event, Fine, SchoolYear, Semester

T = datetime.time


def aware(day, hh, mm=0):
    return timezone.make_aware(datetime.datetime.combine(day, T(hh, mm)))


def make_student(name="stu", number="S-1"):
    user = User.objects.create_user(username=name, password="x", is_student=True)
    return Student.objects.create(user=user, student_number=number)


def make_event(start, end=None, required=("AM_IN", "PM_OUT"), rate="50.00"):
    sy = SchoolYear.objects.get_or_create(sy="2025-2026")[0]
    sem = Semester.objects.get_or_create(school_year=sy, name="1st")[0]
    return Event.objects.create(
        name="Entrams", semester=sem, start_date=start, end_date=end or start,
        fine_rate=Decimal(rate), required_types=list(required),
        am_in_start=T(6, 0), am_in_end=T(7, 30),
        pm_out_start=T(16, 30), pm_out_end=T(17, 30),
    )


def scan(student, event, day, slot):
    AttendanceLog.objects.create(
        student=student, event=event, date=day, attendance_type=slot,
        status=AttendanceLog.Status.PRESENT, scanned_at=timezone.now())


class SlotAwareCalculationTests(TestCase):
    def setUp(self):
        self.today = timezone.localdate()
        self.student = make_student()
        self.event = make_event(self.today)

    def fine(self):
        return Fine.objects.filter(student=self.student, event=self.event).first()

    def test_only_out_scanned_fines_the_missed_in_slot(self):
        """Scanned PM_OUT only: the missed AM_IN is fined once its window closed."""
        scan(self.student, self.event, self.today, "PM_OUT")
        services.compute_fines_for_event(self.event, now=aware(self.today, 18, 0))
        fine = self.fine()
        self.assertEqual(fine.missed_slots, 1)           # one slot, not "a day"
        self.assertEqual(fine.amount, Decimal("50.00"))

    def test_open_or_unopened_slots_are_not_fined(self):
        # 06:30 - AM_IN window still open, PM_OUT hasn't opened.
        services.compute_fines_for_event(self.event, now=aware(self.today, 6, 30))
        self.assertIsNone(self.fine())

    def test_each_slot_is_counted_as_its_window_closes(self):
        services.compute_fines_for_event(self.event, now=aware(self.today, 12, 0))
        self.assertEqual(self.fine().missed_slots, 1)    # AM_IN over, PM_OUT not yet
        services.compute_fines_for_event(self.event, now=aware(self.today, 17, 31))
        fine = self.fine()
        self.assertEqual((fine.missed_slots, fine.amount), (2, Decimal("100.00")))

    def test_window_end_is_inclusive(self):
        services.compute_fines_for_event(self.event, now=aware(self.today, 7, 30))
        self.assertIsNone(self.fine())                   # a scan at 07:30 is still valid

    def test_single_required_slot_only_charges_that_slot(self):
        event = make_event(self.today, required=("PM_OUT",))
        services.compute_fines_for_event(event, now=aware(self.today, 18, 0))
        fine = Fine.objects.get(student=self.student, event=event)
        self.assertEqual((fine.missed_slots, fine.amount), (1, Decimal("50.00")))

    def test_past_days_count_every_required_slot(self):
        event = make_event(self.today - datetime.timedelta(days=2), self.today)
        services.compute_fines_for_event(event, now=aware(self.today, 6, 0))
        fine = Fine.objects.get(student=self.student, event=event)
        self.assertEqual(fine.missed_slots, 4)           # 2 past days x 2 slots

    def test_future_days_are_never_fined(self):
        event = make_event(self.today + datetime.timedelta(days=1))
        services.compute_fines_for_event(event, now=aware(self.today, 23, 0))
        self.assertFalse(Fine.objects.filter(event=event).exists())

    def test_recompute_is_idempotent_and_paid_fines_are_flagged(self):
        now = aware(self.today, 18, 0)
        services.compute_fines_for_event(self.event, now=now)
        again = services.compute_fines_for_event(self.event, now=now)
        self.assertEqual((again["created"], again["updated"]), (0, 0))
        Fine.objects.filter(pk=self.fine().pk).update(status=Fine.Status.PAID)
        scan(self.student, self.event, self.today, "AM_IN")  # now actually 1 missed
        services.compute_fines_for_event(self.event, now=now)
        fine = self.fine()
        self.assertEqual(fine.missed_slots, 2)               # PAID amount untouched
        self.assertTrue(fine.needs_review)


class AutoRefreshTests(TestCase):
    """Viewing fines refreshes them - no 'Calculate Fines' click needed."""

    def setUp(self):
        cache.clear()
        self.today = timezone.localdate()
        self.student = make_student("auto", "A-1")
        # Yesterday: every required slot is already over, deterministic any time.
        self.event = make_event(self.today - datetime.timedelta(days=1))
        self.client = APIClient()
        self.client.force_authenticate(self.student.user)

    def test_student_fines_api_shows_fine_without_manual_calculation(self):
        self.assertFalse(Fine.objects.exists())
        res = self.client.get(reverse("student-fines"))
        self.assertEqual(res.status_code, 200)
        rows = res.json()["results"]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["missed_slots"], rows[0]["amount"]), (2, "100.00"))

    def test_student_balance_reflects_automatic_fine(self):
        bal = self.client.get(reverse("student-balance")).json()
        self.assertEqual(Decimal(bal["outstanding"]), Decimal("100.00"))

    def test_refresh_is_rate_limited_but_recovers_after_expiry(self):
        self.assertIsNotNone(services.refresh_active_fines())
        self.assertIsNone(services.refresh_active_fines())   # inside the interval
        cache.clear()
        self.assertIsNotNone(services.refresh_active_fines())

    def test_a_failing_refresh_does_not_break_the_page(self):
        from unittest import mock
        with mock.patch("attendance.services.compute_fines_for_event",
                        side_effect=RuntimeError("boom")):
            res = self.client.get(reverse("student-fines"))
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()["results"], [])
        self.assertIsNotNone(services.refresh_active_fines())  # lock was released

    def test_admin_dashboard_triggers_refresh(self):
        admin = User.objects.create_user(
            username="adm", password="x", is_admin=True, is_staff=True)
        c = APIClient()
        c.force_authenticate(admin)
        data = c.get(reverse("dashboard")).json()
        self.assertEqual(Decimal(str(data["total_outstanding"])), Decimal("100.00"))
