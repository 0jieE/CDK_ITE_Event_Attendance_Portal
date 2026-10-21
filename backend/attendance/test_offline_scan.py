"""Offline scanning: the instructor's offline pack and the queued-scan sync."""

import datetime
import hashlib
from decimal import Decimal

from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Instructor, User

from . import services
from .models import AttendanceLog, Fine, QRCode
from .tests import PASSWORD, make_event, make_student


def at(day, hour, minute=0):
    """An aware datetime for ``day`` at ``hour:minute`` local time."""
    return timezone.make_aware(datetime.datetime.combine(day, datetime.time(hour, minute)))


class OfflineScanTests(TestCase):
    def setUp(self):
        cache.clear()
        self.today = timezone.localdate()
        self.yesterday = self.today - datetime.timedelta(days=1)
        # Yesterday + today, with fixed windows, so a scan time from yesterday is
        # never "in the future" whatever time the tests run.
        self.event = make_event(
            start_date=self.yesterday, end_date=self.today,
            required_types=["AM_IN", "PM_IN"],
            am_in_start=datetime.time(7, 0), am_in_end=datetime.time(8, 0),
            pm_in_start=datetime.time(13, 0), pm_in_end=datetime.time(14, 0),
        )
        self.student = make_student("erin", "E-005")
        self.qr = QRCode.objects.create(
            student=self.student, event=self.event, date=self.yesterday)
        ins_user = User.objects.create_user(
            username="ins", password=PASSWORD, is_instructor=True)
        self.instructor, _ = Instructor.objects.get_or_create(user=ins_user)
        self.client = APIClient()
        self.client.force_authenticate(ins_user)

    def sync(self, *scans):
        return self.client.post(
            reverse("instructor-scans-sync"),
            {"scans": [{"token": t, "scanned_at": when.isoformat()} for t, when in scans]},
            format="json",
        )

    # -- sync --------------------------------------------------------------
    def test_queued_scan_is_judged_at_its_scan_time(self):
        res = self.sync((self.qr.token, at(self.yesterday, 13, 30)))
        self.assertEqual(res.status_code, 200)
        [result] = res.json()["results"]
        self.assertEqual(result["http_status"], 201)
        self.assertEqual(result["attendance_type"], "PM_IN")
        log = AttendanceLog.objects.get(student=self.student, date=self.yesterday)
        self.assertEqual(log.attendance_type, "PM_IN")
        self.assertEqual(log.status, AttendanceLog.Status.PRESENT)
        self.assertEqual(log.scanned_at, at(self.yesterday, 13, 30))
        self.assertEqual(log.scanned_by, self.instructor)

    def test_each_scan_gets_its_own_result_in_order(self):
        res = self.sync(
            (self.qr.token, at(self.yesterday, 7, 15)),
            (self.qr.token, at(self.yesterday, 7, 40)),   # same slot again
            ("not-a-real-token", at(self.yesterday, 7, 20)),
            (self.qr.token, at(self.yesterday, 10, 0)),   # between windows
        )
        codes = [(r["http_status"], r.get("code")) for r in res.json()["results"]]
        self.assertEqual(codes, [
            (201, None), (200, None), (404, "INVALID_TOKEN"), (400, "OUTSIDE_WINDOW"),
        ])
        self.assertEqual(AttendanceLog.objects.count(), 1)

    def test_future_and_too_old_scan_times_are_refused(self):
        res = self.sync(
            (self.qr.token, timezone.now() + datetime.timedelta(hours=1)),
            (self.qr.token, timezone.now() - datetime.timedelta(days=8)),
        )
        self.assertEqual([r["code"] for r in res.json()["results"]],
                         ["BAD_SCAN_TIME", "OFFLINE_TOO_OLD"])
        self.assertFalse(AttendanceLog.objects.exists())

    def test_qr_from_another_day_is_still_stale(self):
        res = self.sync((self.qr.token, at(self.today, 0, 1)))
        self.assertEqual(res.json()["results"][0]["code"], "STALE_QR")

    def test_late_sync_lowers_an_already_computed_fine(self):
        services.compute_fines_for_event(self.event, as_of=self.yesterday)
        fine = Fine.objects.get(student=self.student, event=self.event)
        self.assertEqual(fine.amount, Decimal("20.00"))   # both slots missed
        self.sync((self.qr.token, at(self.yesterday, 7, 30)))
        services.compute_fines_for_event(self.event, as_of=self.yesterday)
        fine.refresh_from_db()
        self.assertEqual((fine.missed_slots, fine.amount), (1, Decimal("10.00")))

    def test_sync_body_is_validated(self):
        url = reverse("instructor-scans-sync")
        self.assertEqual(self.client.post(url, {"scans": []}, format="json").status_code, 400)
        too_many = [{"token": "x", "scanned_at": timezone.now().isoformat()}] * 501
        self.assertEqual(self.client.post(url, {"scans": too_many}, format="json").status_code, 400)

    # -- offline pack ------------------------------------------------------
    def test_pack_lists_todays_codes_as_hashes(self):
        today_qr = QRCode.objects.create(
            student=self.student, event=self.event, date=self.today)
        AttendanceLog.objects.create(
            student=self.student, event=self.event, date=self.today,
            attendance_type="AM_IN", status=AttendanceLog.Status.PRESENT,
            scanned_at=timezone.now())
        other = make_event(name="Inactive", is_active=False)
        QRCode.objects.create(student=self.student, event=other, date=self.today)

        res = self.client.get(reverse("instructor-offline-pack"))
        self.assertEqual(res.status_code, 200)
        body = res.json()
        self.assertEqual([e["id"] for e in body["events"]], [self.event.id])
        self.assertEqual(body["events"][0]["am_in_start"], "07:00:00")
        self.assertIn("server_time", body)
        self.assertEqual(body["codes"], [{
            "hash": hashlib.sha256(today_qr.token.encode()).hexdigest(),
            "event": self.event.id,
            "student_name": "Erin Test",
            "student_number": "E-005",
            "credited": ["AM_IN"],
        }])
        # Raw tokens never leave the server in the pack.
        self.assertNotIn(today_qr.token, res.content.decode())

    def test_students_cannot_use_the_offline_endpoints(self):
        client = APIClient()
        client.force_authenticate(self.student.user)
        self.assertEqual(client.get(reverse("instructor-offline-pack")).status_code, 403)
        self.assertEqual(client.post(reverse("instructor-scans-sync"), {}, format="json").status_code, 403)
