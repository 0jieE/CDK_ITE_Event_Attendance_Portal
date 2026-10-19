"""The LATE status is gone (the scan time is recorded instead) and the report has no Rate column."""

import csv
import datetime
import importlib
import io
from decimal import Decimal

from django.apps import apps
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Student, User

from . import services
from .models import AttendanceLog, Event, SchoolYear, Semester

T = datetime.time
D = datetime.timedelta


def setup_event(today, name="Report Event"):
    sy = SchoolYear.objects.get_or_create(sy="2026-2027")[0]
    sem = Semester.objects.get_or_create(school_year=sy, name="1st")[0]
    return Event.objects.create(
        name=name, semester=sem, start_date=today - D(days=2), end_date=today - D(days=1),
        fine_rate=Decimal("10"), required_types=["AM_IN"], am_in_start=T(7), am_in_end=T(8))


def make_student(n, **kw):
    u = User.objects.create_user(f"s{n}", password="x", is_student=True, first_name=f"First{n}", last_name=f"Last{n}")
    return Student.objects.create(user=u, student_number=f"N-{n}", year_level="2", section="A", **kw)


class LateStatusRemovedTests(TestCase):
    def setUp(self):
        self.today = timezone.localdate()
        self.event = setup_event(self.today)
        self.s1, self.s2 = make_student(1), make_student(2)
        day = self.today - D(days=2)
        AttendanceLog.objects.create(student=self.s1, event=self.event, date=day, attendance_type="AM_IN",
                                     status="PRESENT", scanned_at=timezone.now())
        AttendanceLog.objects.create(student=self.s2, event=self.event, date=day, attendance_type="AM_IN",
                                     status="ABSENT")
        adv = get_user_model().objects.create_user("adv", password="x", is_admin=True, is_staff=True)
        self.client.force_login(adv)
        self.api = APIClient()
        self.api.force_authenticate(adv)

    # --- the model ---------------------------------------------------------------
    def test_status_choices_are_only_present_and_absent(self):
        self.assertEqual({v for v, _ in AttendanceLog.Status.choices}, {"PRESENT", "ABSENT"})
        self.assertFalse(hasattr(AttendanceLog.Status, "LATE"))

    def test_only_a_present_scan_is_credited(self):
        self.assertTrue(AttendanceLog(status="PRESENT").is_credited)
        self.assertFalse(AttendanceLog(status="ABSENT").is_credited)
        self.assertEqual(services.CREDITED, (AttendanceLog.Status.PRESENT,))

    def test_migration_converts_existing_late_rows_to_present(self):
        AttendanceLog.objects.filter(pk=AttendanceLog.objects.first().pk).update(status="LATE")
        AttendanceLog.objects.filter(student=self.s2).update(status="LATE")
        migration = importlib.import_module("attendance.migrations.0003_remove_late_status")
        migration.late_to_present(apps, None)
        self.assertFalse(AttendanceLog.objects.filter(status="LATE").exists())
        self.assertEqual(AttendanceLog.objects.filter(status="PRESENT").count(), 2)

    def test_the_api_no_longer_accepts_late_as_a_filter(self):
        ok = self.api.get(reverse("attendancelog-list"), {"status": "PRESENT"})
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(self.api.get(reverse("attendancelog-list"), {"status": "LATE"}).status_code, 400)

    # --- the attendance report ------------------------------------------------------
    def test_report_rows_have_no_late_or_rate(self):
        rows = services.attendance_report()
        self.assertEqual(len(rows), 1)
        self.assertEqual(set(rows[0]), {"event_id", "event_name", "semester", "start_date", "end_date",
                                        "total_logs", "present", "absent"})
        self.assertEqual((rows[0]["total_logs"], rows[0]["present"], rows[0]["absent"]), (2, 1, 1))

    def test_report_json_and_csv_have_no_late_or_rate(self):
        data = self.api.get(reverse("report-attendance")).json()
        row = data["results"][0] if isinstance(data, dict) and "results" in data else data[0]
        self.assertNotIn("late", row)
        self.assertNotIn("attendance_rate", row)
        res = self.api.get(reverse("report-attendance"), {"format": "csv"})
        header = next(csv.reader(io.StringIO(res.content.decode())))
        self.assertEqual(header, ["event_id", "event_name", "semester", "start_date", "end_date",
                                  "total_logs", "present", "absent"])

    def test_portal_report_table_columns(self):
        html = self.client.get(reverse("portal:reports-attendance")).content.decode()
        head = html[html.index("<thead>"): html.index("</thead>")]
        import re
        cols = [re.sub(r"<[^>]+>", "", c).strip() for c in re.findall(r"<th[^>]*>.*?</th>", head, re.S)]
        self.assertEqual(cols, ["Event", "Semester", "Start", "End", "Total", "Present", "Absent"])
        self.assertNotIn("Late", cols)
        self.assertNotIn("Rate", cols)
        self.assertIn("Report Event", html)

    def test_portal_report_empty_state_spans_the_remaining_columns(self):
        Event.objects.all().delete()
        html = self.client.get(reverse("portal:reports-attendance")).content.decode()
        self.assertIn('colspan="7"', html)

    def test_dashboard_attendance_rate_is_kept(self):
        html = self.client.get(reverse("portal:dashboard")).content.decode()
        self.assertIn("Attendance rate", html)             # only the REPORT's Rate column was removed

    # --- other pages -------------------------------------------------------------------
    def test_no_late_option_or_badge_on_any_portal_page(self):
        logs = self.client.get(reverse("portal:attendance_logs-list")).content.decode()
        self.assertNotIn(">Late<", logs)
        self.assertIn(">Present<", logs)
        grid = self.client.get(reverse("portal:fines-list"), {"view": "student", "student": self.s1.pk,
                                                               "event": self.event.pk}).content.decode()
        self.assertNotIn(">Late<", grid)
        self.assertIn("Absent", grid)
        settings_page = self.client.get(reverse("portal:settings")).content.decode()
        self.assertNotIn(">Late<", settings_page)

    def test_fines_still_work_with_present_only(self):
        services.compute_fines_for_event(self.event)
        # s1 attended day 1 only (1 of 2 days missed), s2 missed both days
        self.assertEqual(self.s1.fines.get().missed_slots, 1)
        self.assertEqual(self.s2.fines.get().missed_slots, 2)
