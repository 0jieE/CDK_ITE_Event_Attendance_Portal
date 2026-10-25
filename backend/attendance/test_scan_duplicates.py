"""One attendance log per student per slot, however many instructors scan (online, offline, or at once)."""

import datetime
from unittest import mock

from django.core.cache import cache
from django.db import IntegrityError
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Instructor, User

from .models import AttendanceLog, QRCode
from .tests import PASSWORD, make_event, make_student


def at(day, hour, minute=0):
    return timezone.make_aware(datetime.datetime.combine(day, datetime.time(hour, minute)))


class OneLogPerSlotTests(TestCase):
    def setUp(self):
        cache.clear()
        self.yesterday = timezone.localdate() - datetime.timedelta(days=1)
        self.event = make_event(
            start_date=self.yesterday, end_date=self.yesterday, required_types=["AM_IN", "PM_IN"],
            am_in_start=datetime.time(7, 0), am_in_end=datetime.time(8, 0),
            pm_in_start=datetime.time(13, 0), pm_in_end=datetime.time(14, 0))
        self.student = make_student("erin", "E-005")
        self.qr = QRCode.objects.create(student=self.student, event=self.event, date=self.yesterday)
        self.alice, self.alice_api = self.instructor("alice")
        self.bob, self.bob_api = self.instructor("bob")

    def instructor(self, name):
        user = User.objects.create_user(name, password=PASSWORD, is_instructor=True)
        instructor, _ = Instructor.objects.get_or_create(user=user)
        api = APIClient()
        api.force_authenticate(user)
        return instructor, api

    def sync(self, api, when):
        res = api.post(reverse("instructor-scans-sync"),
                       {"scans": [{"token": self.qr.token, "scanned_at": when.isoformat()}]}, format="json")
        return res.json()["results"][0]

    def logs(self, slot=None):
        qs = AttendanceLog.objects.filter(student=self.student, event=self.event)
        return qs.filter(attendance_type=slot) if slot else qs

    def test_the_database_itself_refuses_a_second_log_for_a_slot(self):
        AttendanceLog.objects.create(student=self.student, event=self.event, date=self.yesterday,
                                     attendance_type="AM_IN", status="PRESENT", scanned_at=timezone.now())
        with self.assertRaises(IntegrityError):
            AttendanceLog.objects.create(student=self.student, event=self.event, date=self.yesterday,
                                         attendance_type="AM_IN", status="PRESENT", scanned_at=timezone.now())

    def test_two_instructors_offline_scan_the_same_student_then_both_sync(self):
        # Alice and Bob each scanned the QR while offline in the same slot; Bob syncs first.
        bob = self.sync(self.bob_api, at(self.yesterday, 7, 40))
        alice = self.sync(self.alice_api, at(self.yesterday, 7, 30))
        self.assertEqual((bob["http_status"], bob["created"]), (201, True))
        self.assertEqual((alice["http_status"], alice["created"]), (200, False))
        self.assertIn("already recorded", alice["detail"])
        self.assertEqual(self.logs().count(), 1)                                  # a single slot log, not two
        self.assertEqual(self.logs().get().scanned_by, self.bob)                  # the first scan to reach the server counts

    def test_online_second_instructor_is_told_it_is_already_recorded(self):
        with mock.patch("django.utils.timezone.now", return_value=at(self.yesterday, 7, 30)):
            first = self.alice_api.post(reverse("instructor-scan"), {"token": self.qr.token}, format="json")
            second = self.bob_api.post(reverse("instructor-scan"), {"token": self.qr.token}, format="json")
        self.assertEqual((first.status_code, first.json()["created"]), (201, True))
        self.assertEqual((second.status_code, second.json()["created"]), (200, False))
        self.assertEqual(self.logs().count(), 1)
        self.assertEqual(self.logs().get().scanned_by, self.alice)

    def test_a_different_slot_is_a_separate_attendance_not_a_duplicate(self):
        self.sync(self.alice_api, at(self.yesterday, 7, 30))                       # AM_IN by Alice
        other = self.sync(self.bob_api, at(self.yesterday, 13, 30))                # PM_IN by Bob
        self.assertEqual((other["http_status"], other["attendance_type"]), (201, "PM_IN"))
        self.assertEqual(self.logs().count(), 2)
        self.assertEqual(self.logs("AM_IN").count(), 1)
        self.assertEqual(self.logs("PM_IN").count(), 1)

    def test_scans_arriving_at_the_very_same_moment_still_give_one_log_and_no_error(self):
        """Simulates the race: another scan wins the insert between our check and our save."""
        manager = AttendanceLog.objects
        real_filter = manager.filter
        raced = []

        def filter_then_race(*args, **kwargs):
            qs = real_filter(*args, **kwargs)
            if not raced and kwargs.get("attendance_type") == "AM_IN":            # the "is there a log yet?" check
                raced.append(True)
                seen = qs.first()                                                 # ... finds nothing, as it did for Alice
                AttendanceLog.objects.create(                                     # ... then Bob's scan lands before her save
                    student=self.student, event=self.event, date=self.yesterday, attendance_type="AM_IN",
                    status="PRESENT", scanned_at=at(self.yesterday, 7, 31), scanned_by=self.bob)
                return mock.Mock(first=lambda: seen)
            return qs

        with mock.patch.object(manager, "filter", filter_then_race):
            result = self.sync(self.alice_api, at(self.yesterday, 7, 30))
        self.assertEqual((result["http_status"], result["created"]), (200, False))   # a normal "already recorded", not a 500
        self.assertEqual(self.logs().count(), 1)
        self.assertEqual(self.logs().get().scanned_by, self.bob)

    def test_one_duplicate_does_not_break_the_rest_of_a_sync_batch(self):
        batch = [{"token": self.qr.token, "scanned_at": at(self.yesterday, 7, 30).isoformat()},
                 {"token": self.qr.token, "scanned_at": at(self.yesterday, 13, 30).isoformat()}]
        self.bob_api.post(reverse("instructor-scans-sync"), {"scans": batch[:1]}, format="json")   # Bob already recorded AM_IN
        res = self.alice_api.post(reverse("instructor-scans-sync"), {"scans": batch}, format="json")
        self.assertEqual(res.status_code, 200)
        self.assertEqual([(r["http_status"], r["created"]) for r in res.json()["results"]], [(200, False), (201, True)])
        self.assertEqual(self.logs().count(), 2)
