"""``GET /api/student/missed-slots/`` - the slots a student missed, computed like the fines."""

import datetime
from decimal import Decimal

from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from .models import AttendanceLog, EventDayFine, Fine, FineSlotPayment
from .tests import make_event, make_student


class MissedSlotsApiTests(TestCase):
    def setUp(self):
        cache.clear()
        self.today = timezone.localdate()
        self.d1 = self.today - datetime.timedelta(days=2)
        self.d2 = self.today - datetime.timedelta(days=1)
        self.event = make_event(
            name="ITE Week", start_date=self.d1, end_date=self.d2, required_types=["AM_IN", "PM_IN"],
            am_in_start=datetime.time(7, 0), am_in_end=datetime.time(8, 0),
            pm_in_start=datetime.time(13, 0), pm_in_end=datetime.time(14, 0),
            fine_rate=Decimal("10.00"))
        EventDayFine.objects.create(event=self.event, date=self.d2, fine_rate=Decimal("50.00"))
        self.alice = make_student("alice", "A-001")
        self.bob = make_student("bob", "B-002")
        self.api = APIClient()
        self.api.force_authenticate(self.alice.user)

    def rows(self, **params):
        res = self.api.get(reverse("student-missed-slots"), params)
        self.assertEqual(res.status_code, 200)
        return res.json()["results"]

    def attend(self, student, day, slot):
        AttendanceLog.objects.create(student=student, event=self.event, date=day, attendance_type=slot,
                                     status=AttendanceLog.Status.PRESENT, scanned_at=timezone.now())

    def test_lists_every_missed_slot_newest_day_first_then_slot_order(self):
        rows = self.rows()
        self.assertEqual([(r["date"], r["attendance_type"]) for r in rows],
                         [(str(self.d2), "AM_IN"), (str(self.d2), "PM_IN"),
                          (str(self.d1), "AM_IN"), (str(self.d1), "PM_IN")])
        first = rows[0]
        self.assertEqual(first["event"], self.event.id)
        self.assertEqual(first["event_name"], "ITE Week")
        self.assertEqual(first["attendance_type_display"], "AM Time-In")
        self.assertEqual((first["window_start"], first["window_end"]), ("07:00:00", "08:00:00"))
        self.assertEqual((first["rate"], first["paid"]), ("50.00", False))     # the day's own rate
        self.assertEqual(rows[2]["rate"], "10.00")                              # default rate other day

    def test_a_credited_scan_is_not_missed(self):
        self.attend(self.alice, self.d1, "AM_IN")
        self.attend(self.bob, self.d2, "PM_IN")                                 # someone else's scan
        keys = [(r["date"], r["attendance_type"]) for r in self.rows()]
        self.assertNotIn((str(self.d1), "AM_IN"), keys)
        self.assertIn((str(self.d2), "PM_IN"), keys)
        self.assertEqual(len(keys), 3)

    def test_open_or_future_slots_are_not_listed(self):
        future = make_event(name="Soon", start_date=self.today + datetime.timedelta(days=3),
                            end_date=self.today + datetime.timedelta(days=3))
        open_today = make_event(name="Now", start_date=self.today, end_date=self.today)   # window ends 23:59:59
        ids = {r["event"] for r in self.rows()}
        self.assertNotIn(future.id, ids)
        self.assertNotIn(open_today.id, ids)

    def test_inactive_event_without_a_fine_is_left_out(self):
        self.event.is_active = False
        self.event.save()
        self.assertEqual(self.rows(), [])

    def test_inactive_event_stays_listed_when_the_student_has_a_fine_for_it(self):
        # The fine (and its payments) outlive the Active switch, so its slots must still be listable.
        Fine.objects.create(student=self.alice, event=self.event, missed_slots=4, amount=Decimal("120.00"))
        self.event.is_active = False
        self.event.save()
        self.assertEqual(len(self.rows()), 4)
        bob_api = APIClient()
        bob_api.force_authenticate(self.bob.user)
        self.assertEqual(bob_api.get(reverse("student-missed-slots")).json()["results"], [])   # Bob has no fine

    def test_event_filter(self):
        other = make_event(name="Other", start_date=self.d1, end_date=self.d1)
        self.assertEqual({r["event"] for r in self.rows(event=other.id)}, {other.id})
        self.assertEqual({r["event"] for r in self.rows(event=self.event.id)}, {self.event.id})
        self.assertEqual(self.rows(event="abc"), [])
        self.assertEqual(self.rows(event=999999), [])

    def test_paid_reflects_the_slot_payments_of_this_student_only(self):
        fine = Fine.objects.create(student=self.alice, event=self.event, missed_slots=4, amount=Decimal("120.00"))
        FineSlotPayment.objects.create(fine=fine, date=self.d2, attendance_type="AM_IN", amount=Decimal("50.00"))
        other = Fine.objects.create(student=self.bob, event=self.event, missed_slots=4, amount=Decimal("120.00"))
        FineSlotPayment.objects.create(fine=other, date=self.d1, attendance_type="PM_IN", amount=Decimal("10.00"))
        paid = {(r["date"], r["attendance_type"]): r["paid"] for r in self.rows()}
        self.assertTrue(paid[(str(self.d2), "AM_IN")])
        self.assertFalse(paid[(str(self.d1), "PM_IN")])                         # Bob's payment, not Alice's

    def test_only_a_student_can_read_it_and_only_their_own(self):
        self.assertEqual(APIClient().get(reverse("student-missed-slots")).status_code, 401)
        self.attend(self.bob, self.d1, "AM_IN")                                 # Bob attended, Alice did not
        bob_api = APIClient()
        bob_api.force_authenticate(self.bob.user)
        bob_keys = {(r["date"], r["attendance_type"]) for r in bob_api.get(reverse("student-missed-slots")).json()["results"]}
        self.assertNotIn((str(self.d1), "AM_IN"), bob_keys)
        self.assertIn((str(self.d1), "AM_IN"), {(r["date"], r["attendance_type"]) for r in self.rows()})

    def test_it_is_paginated_like_the_other_student_lists(self):
        body = self.api.get(reverse("student-missed-slots")).json()
        self.assertEqual(set(body), {"count", "next", "previous", "results"})
        self.assertEqual(body["count"], 4)
