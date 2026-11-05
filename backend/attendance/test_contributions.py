"""Department contributions: the rules, the portal pages, the reports and the student API."""

import datetime
import json
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from . import contributions as contrib
from .models import (Contribution, ContributionExemption, ContributionPayment, Fine, SchoolYear,
                     Semester)
from .tests import make_event, make_student

D = Decimal


def toast(res):
    return json.loads(res.headers["HX-Trigger"])["showToast"]["message"]


class ContributionTestBase(TestCase):
    def setUp(self):
        cache.clear()
        self.sy = SchoolYear.objects.create(sy="2026-2027")
        self.sem = Semester.objects.create(school_year=self.sy, name="1st", is_active=True)
        self.old = Semester.objects.create(school_year=SchoolYear.objects.create(sy="2025-2026"), name="2nd")
        self.fee = Contribution.objects.create(semester=self.sem, name="Department fee", amount=D("150.00"))
        self.shirt = Contribution.objects.create(semester=self.sem, name="T-shirt", amount=D("300.00"),
                                                 due_date=datetime.date(2026, 12, 15))
        self.alice = make_student("alice", "A-001")
        self.bob = make_student("bob", "B-002")
        self.cara = make_student("cara", "C-003")
        self.adviser = get_user_model().objects.create_user("adv", password="x", is_admin=True, is_staff=True)

    def pay(self, contribution, student, amount, **kw):
        return contrib.record_payment(contribution, student, D(amount), recorded_by=self.adviser, **kw)


class RulesTests(ContributionTestBase):
    def test_every_student_owes_the_full_amount_until_they_pay(self):
        row = contrib.balance_of(self.fee, self.alice)
        self.assertEqual((row["owed"], row["paid"], row["balance"], row["status"]),
                         (D("150.00"), D("0.00"), D("150.00"), contrib.UNPAID))

    def test_partial_payments_add_up(self):
        self.pay(self.fee, self.alice, "50")
        self.assertEqual(contrib.balance_of(self.fee, self.alice)["status"], contrib.PARTIAL)
        self.pay(self.fee, self.alice, "100")
        row = contrib.balance_of(self.fee, self.alice)
        self.assertEqual((row["paid"], row["balance"], row["status"]), (D("150.00"), D("0.00"), contrib.PAID))
        self.assertEqual(ContributionPayment.objects.filter(student=self.alice).count(), 2)

    def test_a_payment_may_not_exceed_the_balance(self):
        self.pay(self.fee, self.alice, "100")
        with self.assertRaisesMessage(contrib.ContributionError, "more than the balance (₱50.00)"):
            self.pay(self.fee, self.alice, "60")
        self.pay(self.fee, self.alice, "50")
        with self.assertRaisesMessage(contrib.ContributionError, "already fully paid"):
            self.pay(self.fee, self.alice, "1")

    def test_zero_or_negative_is_refused(self):
        for amount in ("0", "-5"):
            with self.assertRaises(contrib.ContributionError):
                self.pay(self.fee, self.alice, amount)

    def test_the_same_ref_is_recorded_once(self):
        first = self.pay(self.fee, self.alice, "20", ref="abc")
        again = self.pay(self.fee, self.alice, "20", ref="abc")
        self.assertIsNotNone(first)
        self.assertIsNone(again)
        self.assertEqual(contrib.balance_of(self.fee, self.alice)["paid"], D("20.00"))

    def test_an_offline_payment_keeps_its_real_time(self):
        when = timezone.now() - datetime.timedelta(hours=3)
        payment = self.pay(self.fee, self.alice, "10", when=when)
        self.assertEqual(payment.paid_at, when)

    def test_exempt_students_owe_nothing_and_cannot_pay(self):
        self.assertTrue(contrib.exempt(self.fee, self.bob, reason="Scholar", recorded_by=self.adviser))
        self.assertFalse(contrib.exempt(self.fee, self.bob))                       # already exempt
        row = contrib.balance_of(self.fee, self.bob)
        self.assertEqual((row["owed"], row["balance"], row["status"]), (D("0.00"), D("0.00"), contrib.EXEMPT))
        with self.assertRaisesMessage(contrib.ContributionError, "exempted"):
            self.pay(self.fee, self.bob, "10")
        self.assertTrue(contrib.unexempt(self.fee, self.bob))
        self.assertEqual(contrib.balance_of(self.fee, self.bob)["status"], contrib.UNPAID)

    def test_a_student_who_paid_cannot_be_exempted(self):
        self.pay(self.fee, self.alice, "10")
        with self.assertRaisesMessage(contrib.ContributionError, "undo the payments first"):
            contrib.exempt(self.fee, self.alice)

    def test_summary_counts_and_money(self):
        self.pay(self.fee, self.alice, "150")
        self.pay(self.fee, self.bob, "40")
        contrib.exempt(self.fee, self.cara)
        make_student("dan", "D-004")
        s = contrib.summarize(self.fee)
        self.assertEqual((s["students"], s["exempt_count"]), (3, 1))
        self.assertEqual((s["expected"], s["collected"], s["outstanding"]), (D("450.00"), D("190.00"), D("260.00")))
        self.assertEqual((s["paid_count"], s["partial_count"], s["unpaid_count"]), (1, 1, 1))

    def test_student_totals_and_statement(self):
        self.pay(self.fee, self.alice, "150")
        self.pay(self.shirt, self.alice, "100")
        Contribution.objects.create(semester=self.old, name="Old fee", amount=D("50.00"))
        t = contrib.student_totals(self.alice)
        self.assertEqual((t["total"], t["paid"], t["outstanding"]), (D("500.00"), D("250.00"), D("250.00")))
        self.assertEqual(contrib.student_totals(self.alice, self.sem)["outstanding"], D("200.00"))
        names = [r["contribution"].name for r in contrib.for_student(self.alice)]
        self.assertEqual(names, ["Department fee", "T-shirt", "Old fee"])         # newest semester first

    def test_payments_block_deleting_the_contribution_semester_and_school_year(self):
        self.assertIsNone(self.fee.delete_block_reason)
        self.assertIsNone(self.sem.delete_block_reason)
        self.pay(self.fee, self.alice, "10")
        self.assertIn("payments recorded", self.fee.delete_block_reason)
        self.assertIn("contribution payments", self.sem.delete_block_reason)
        self.assertIn("contribution payments", self.sy.delete_block_reason)


class PortalTests(ContributionTestBase):
    def setUp(self):
        super().setUp()
        self.client.force_login(self.adviser)

    def page(self, **params):
        res = self.client.get(reverse("portal:contributions-list"), params)
        self.assertEqual(res.status_code, 200)
        return res.content.decode()

    def test_the_page_defaults_to_the_active_semester_and_its_first_contribution(self):
        Contribution.objects.create(semester=self.old, name="Old fee", amount=D("50.00"))
        html = self.page()
        self.assertIn("Department fee", html)
        self.assertIn("T-shirt", html)
        self.assertNotIn("Old fee", html)
        self.assertIn("A-001", html)                                    # the ledger of the first one
        self.assertIn('id="contribTable"', html)

    def test_the_ledger_filters_by_status(self):
        self.pay(self.fee, self.alice, "150")
        html = self.page(contribution=self.fee.pk, status="PAID")
        self.assertIn("A-001", html)
        self.assertNotIn("B-002", html)

    def test_add_edit_and_delete_a_contribution(self):
        res = self.client.post(reverse("portal:contributions-add"),
                               {"semester": self.sem.pk, "name": "Acquaintance party", "amount": "75"})
        self.assertEqual(res.status_code, 204)
        party = Contribution.objects.get(name="Acquaintance party")
        res = self.client.post(reverse("portal:contributions-edit", args=[party.pk]),
                               {"semester": self.sem.pk, "name": "Acquaintance party", "amount": "80"})
        self.assertEqual(res.status_code, 204)
        party.refresh_from_db()
        self.assertEqual(party.amount, D("80.00"))
        self.assertEqual(self.client.post(reverse("portal:contributions-delete", args=[party.pk])).status_code, 204)
        self.assertFalse(Contribution.objects.filter(pk=party.pk).exists())

    def test_the_add_form_suggests_the_active_semester(self):
        html = self.client.get(reverse("portal:contributions-add")).content.decode()
        self.assertIn(f'<option value="{self.sem.pk}" selected>', html)

    def test_names_are_unique_per_semester_ignoring_case(self):
        res = self.client.post(reverse("portal:contributions-add"),
                               {"semester": self.sem.pk, "name": "department  FEE", "amount": "10"})
        self.assertEqual(res.status_code, 422)
        self.assertIn("already has a contribution with that name", res.content.decode())
        res = self.client.post(reverse("portal:contributions-add"),
                               {"semester": self.old.pk, "name": "Department fee", "amount": "10"})
        self.assertEqual(res.status_code, 204)                          # another semester is fine

    def test_the_amount_cannot_drop_below_what_a_student_paid(self):
        self.pay(self.fee, self.alice, "120")
        res = self.client.post(reverse("portal:contributions-edit", args=[self.fee.pk]),
                               {"semester": self.sem.pk, "name": "Department fee", "amount": "100"})
        self.assertEqual(res.status_code, 422)
        self.assertIn("already paid ₱120.00", res.content.decode())

    def test_a_contribution_with_payments_cannot_be_deleted(self):
        self.pay(self.fee, self.alice, "10")
        res = self.client.post(reverse("portal:contributions-delete", args=[self.fee.pk]))
        self.assertEqual(res.status_code, 204)
        self.assertIn("cannot be deleted", toast(res))
        self.assertTrue(Contribution.objects.filter(pk=self.fee.pk).exists())

    def test_the_payment_modal_defaults_to_the_balance_and_records_a_partial_payment(self):
        self.pay(self.fee, self.alice, "50")
        url = reverse("portal:contributions-pay", args=[self.fee.pk])
        html = self.client.get(url, {"student": self.alice.pk}).content.decode()
        self.assertIn('value="100.00"', html)                            # the remaining balance
        self.assertIn('name="ref"', html)
        res = self.client.post(f"{url}?student={self.alice.pk}", {"amount": "30", "note": "OR 12", "ref": "r1"})
        self.assertEqual(res.status_code, 204)
        self.assertIn("Balance: ₱70.00", toast(res))
        p = ContributionPayment.objects.get(ref="r1")
        self.assertEqual((p.amount, p.note, p.recorded_by), (D("30.00"), "OR 12", self.adviser))
        res = self.client.post(f"{url}?student={self.alice.pk}", {"amount": "30", "ref": "r1"})   # re-sent
        self.assertIn("already recorded", toast(res))
        self.assertEqual(ContributionPayment.objects.filter(student=self.alice).count(), 2)

    def test_overpaying_re_renders_the_form_with_the_error(self):
        url = reverse("portal:contributions-pay", args=[self.fee.pk])
        res = self.client.post(f"{url}?student={self.alice.pk}", {"amount": "151"})
        self.assertEqual(res.status_code, 422)
        self.assertIn("more than the balance (₱150.00)", res.content.decode())

    def test_undo_a_payment(self):
        p = self.pay(self.fee, self.alice, "50")
        res = self.client.post(reverse("portal:contributions-payment-undo", args=[p.pk]))
        self.assertEqual(res.status_code, 204)
        self.assertFalse(ContributionPayment.objects.filter(pk=p.pk).exists())
        res = self.client.post(reverse("portal:contributions-payment-undo", args=[p.pk]))   # second click
        self.assertIn("already undone", toast(res))

    def test_exempt_with_a_reason_and_unexempt(self):
        res = self.client.post(reverse("portal:contributions-exempt", args=[self.fee.pk]),
                               {"student": self.bob.pk}, HTTP_HX_PROMPT="Scholar")
        self.assertEqual(res.status_code, 204)
        self.assertEqual(ContributionExemption.objects.get(student=self.bob).reason, "Scholar")
        self.assertIn("Scholar", self.page(contribution=self.fee.pk))
        self.client.post(reverse("portal:contributions-unexempt", args=[self.fee.pk]), {"student": self.bob.pk})
        self.assertFalse(ContributionExemption.objects.exists())

    def test_by_student_statement(self):
        self.pay(self.fee, self.alice, "150", note="OR 99")
        html = self.page(view="student", student=self.alice.pk)
        self.assertIn("OR 99", html)
        self.assertIn("T-shirt", html)
        self.assertIn("₱300.00", html)                                    # T-shirt balance

    def test_students_and_instructors_cannot_open_the_pages(self):
        self.client.force_login(self.alice.user)
        res = self.client.get(reverse("portal:contributions-list"))
        self.assertIn(res.status_code, (302, 403))
        res = self.client.post(reverse("portal:contributions-pay", args=[self.fee.pk]) + f"?student={self.alice.pk}",
                               {"amount": "150"})
        self.assertIn(res.status_code, (302, 403))
        self.assertFalse(ContributionPayment.objects.exists())

    def test_mark_paid_requires_an_adviser(self):
        event = make_event(start_date=timezone.localdate() - datetime.timedelta(days=1),
                           end_date=timezone.localdate() - datetime.timedelta(days=1))
        fine = Fine.objects.create(student=self.alice, event=event, amount=D("10"), missed_slots=1)
        self.client.logout()
        res = self.client.post(reverse("portal:fines-mark-paid", args=[fine.pk]))
        self.assertEqual(res.status_code, 302)                          # to the login page
        fine.refresh_from_db()
        self.assertEqual(fine.status, Fine.Status.UNPAID)

    def test_nav_has_the_page(self):
        self.assertIn(reverse("portal:contributions-list"), self.page())


class ReportTests(ContributionTestBase):
    def setUp(self):
        super().setUp()
        self.client.force_login(self.adviser)
        self.pay(self.fee, self.alice, "150")
        self.pay(self.shirt, self.bob, "100")

    def test_the_financial_report_lists_the_contributions_and_grand_totals(self):
        html = self.client.get(reverse("portal:reports-financial"), {"semester": self.sem.pk}).content.decode()
        self.assertIn("Department contributions", html)
        self.assertIn("Department fee", html)
        # expected 3*150 + 3*300 = 1350, collected 250, outstanding 1100 (there are no fines)
        self.assertIn("₱1350.00", html)
        self.assertIn("₱1100.00", html)
        self.assertIn("part=contributions", html)

    def test_contributions_csv(self):
        res = self.client.get(reverse("portal:reports-financial"),
                              {"semester": self.sem.pk, "format": "csv", "part": "contributions"})
        self.assertEqual(res["Content-Type"], "text/csv")
        body = res.content.decode()
        self.assertIn("contribution,semester,amount", body.splitlines()[0].replace("contribution_id,", ""))
        self.assertIn("Department fee", body)
        self.assertIn("contributions_report.csv", res["Content-Disposition"])

    def test_the_dashboard_shows_the_semester_contributions(self):
        html = self.client.get(reverse("portal:dashboard")).content.decode()
        self.assertIn("Department contributions", html)
        self.assertIn("T-shirt", html)

    def test_the_admin_api_report_includes_contributions(self):
        api = APIClient()
        api.force_authenticate(self.adviser)
        data = api.get(reverse("report-financial"), {"semester": self.sem.pk}).json()
        self.assertEqual({r["contribution"] for r in data["contributions"]}, {"Department fee", "T-shirt"})
        dash = api.get(reverse("dashboard")).json()
        self.assertEqual(D(str(dash["contributions"]["collected"])), D("250.00"))


class StudentApiTests(ContributionTestBase):
    def setUp(self):
        super().setUp()
        self.api = APIClient()
        self.api.force_authenticate(self.alice.user)

    def test_lists_the_contributions_with_the_students_own_standing(self):
        self.pay(self.fee, self.alice, "100", note="OR 1")
        self.pay(self.fee, self.bob, "150")                              # someone else's payment
        contrib.exempt(self.shirt, self.alice, reason="Has one already")
        res = self.api.get(reverse("student-contributions"))
        self.assertEqual(res.status_code, 200)
        rows = res.json()["results"]
        self.assertEqual([r["name"] for r in rows], ["Department fee", "T-shirt"])
        fee, shirt = rows
        self.assertEqual((fee["amount"], fee["owed"], fee["paid"], fee["balance"]),
                         ("150.00", "150.00", "100.00", "50.00"))
        self.assertEqual((fee["status"], fee["status_display"], fee["exempt"]), ("PARTIAL", "Part-paid", False))
        self.assertEqual(fee["semester"], self.sem.pk)
        self.assertEqual(fee["semester_name"], "2026-2027 1st")
        self.assertTrue(fee["is_active_semester"])
        self.assertEqual(len(fee["payments"]), 1)
        self.assertEqual((fee["payments"][0]["amount"], fee["payments"][0]["note"]), ("100.00", "OR 1"))
        self.assertEqual((shirt["status"], shirt["owed"], shirt["exempt"], shirt["exemption_reason"]),
                         ("EXEMPT", "0.00", True, "Has one already"))
        self.assertEqual(shirt["due_date"], "2026-12-15")

    def test_semester_filter(self):
        Contribution.objects.create(semester=self.old, name="Old fee", amount=D("50.00"))
        names = lambda **p: [r["name"] for r in self.api.get(reverse("student-contributions"), p).json()["results"]]
        self.assertEqual(names(), ["Department fee", "T-shirt", "Old fee"])
        self.assertEqual(names(semester="active"), ["Department fee", "T-shirt"])
        self.assertEqual(names(semester=self.old.pk), ["Old fee"])
        self.assertEqual(names(semester=99999), [])

    def test_balance_adds_contribution_keys_and_keeps_the_fine_keys(self):
        self.pay(self.fee, self.alice, "150")
        event = make_event(start_date=timezone.localdate() - datetime.timedelta(days=1),
                           end_date=timezone.localdate() - datetime.timedelta(days=1), is_active=False)
        Fine.objects.create(student=self.alice, event=event, amount=D("20"), missed_slots=2)
        data = self.api.get(reverse("student-balance")).json()
        self.assertEqual((data["total_fines"], data["total_paid"], data["outstanding"]), ("20.00", "0.00", "20.00"))
        self.assertEqual((data["contributions_total"], data["contributions_paid"], data["contributions_outstanding"]),
                         ("450.00", "150.00", "300.00"))
        self.assertEqual(data["total_outstanding"], "320.00")

    def test_only_students_may_call_it(self):
        api = APIClient()
        self.assertEqual(api.get(reverse("student-contributions")).status_code, 401)
        api.force_authenticate(self.adviser)
        self.assertEqual(api.get(reverse("student-contributions")).status_code, 403)
