"""Django Administration: branding, and the Super-Admin-only backup / restore."""

import datetime
import io
import json
import os
import tempfile
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import CommandError
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from accounts.models import Instructor, Student
from attendance import services
from attendance.models import (
    AttendanceLog, Event, EventDayFine, Fine, FineSlotPayment, QRCode, SchoolYear, Semester,
)
from core import backup
from portal.models import PortalSettings

User = get_user_model()
PW = "pw-12345-Xy"
D = datetime.timedelta


def build_world():
    """A small but complete data set touching every backed-up table."""
    boss = User.objects.create_user("boss", password=PW, is_admin=True, is_staff=True, is_superuser=True,
                                    first_name="Super", last_name="Admin")
    User.objects.create_user("adviser", password=PW, is_admin=True)
    ins_user = User.objects.create_user("inst", password=PW, is_instructor=True, first_name="Ina", last_name="Prof")
    stu_user = User.objects.create_user("stud", password=PW, is_student=True, first_name="Stu", last_name="Dent")
    stu_user.profile_image = "profiles/stud.jpg"
    stu_user.save()
    student = Student.objects.create(user=stu_user, student_number="2026-1", year_level="2", section="C")
    sy = SchoolYear.objects.create(sy="2026-2027")
    old = Semester.objects.create(school_year=sy, name="1st")
    cur = Semester.objects.create(school_year=sy, name="2nd", is_active=True)
    day = timezone.localdate() - D(days=2)
    event = Event.objects.create(
        name="Backup Fair", semester=cur, start_date=day, end_date=day + D(days=1), fine_rate=Decimal("10.00"),
        required_types=["AM_IN", "PM_OUT"], am_in_start=datetime.time(0, 0), am_in_end=datetime.time(0, 1),
        pm_out_start=datetime.time(0, 2), pm_out_end=datetime.time(0, 3))
    EventDayFine.objects.create(event=event, date=day, fine_rate=Decimal("50.00"))
    qr = QRCode.objects.create(student=student, event=event, date=day)
    AttendanceLog.objects.create(student=student, event=event, date=day, attendance_type="AM_IN",
                                 status="PRESENT", scanned_at=timezone.now(), scanned_by=Instructor.objects.get(user=ins_user))
    services.compute_fines_for_event(event)
    fine = Fine.objects.get(student=student, event=event)
    services.pay_slots(fine, slots=[(day, "PM_OUT")], recorded_by=boss)
    ps = PortalSettings.load()
    ps.brand_title = "Demo Title"
    ps.save()
    return dict(boss=boss, student=student, event=event, fine=fine, cur=cur, old=old, qr=qr)


def snapshot():
    return {
        "users": sorted(User.objects.values_list("username", "password", "is_superuser", "is_instructor")),
        "students": list(Student.objects.values_list("student_number", "section", "user__username")),
        "instructors": list(Instructor.objects.values_list("user__username", flat=True)),
        "semesters": sorted(Semester.objects.values_list("name", "is_active")),
        "events": list(Event.objects.values_list("name", "fine_rate")),
        "day_fines": list(EventDayFine.objects.values_list("date", "fine_rate")),
        "logs": list(AttendanceLog.objects.values_list("attendance_type", "status", "scanned_by__user__username")),
        "qr": list(QRCode.objects.values_list("token", "date")),
        "fines": list(Fine.objects.values_list("amount", "amount_paid", "status", "missed_slots")),
        "payments": list(FineSlotPayment.objects.values_list("attendance_type", "amount", "recorded_by__username")),
        "brand": PortalSettings.load().brand_title,
        "photo": User.objects.get(username="stud").profile_image.name,
    }


class BackupRoundTripTests(TestCase):
    def setUp(self):
        self.world = build_world()

    def test_backup_then_restore_brings_everything_back(self):
        before = snapshot()
        data = backup.build_backup()
        # destroy everything, as if the database had been replaced by a fresh one
        User.objects.all().delete()
        SchoolYear.objects.all().delete()
        PortalSettings.objects.all().delete()
        self.assertEqual(Fine.objects.count() + Student.objects.count() + Event.objects.count(), 0)
        result = backup.restore_backup(data)
        self.assertGreater(result["objects"], 10)
        self.assertEqual(snapshot(), before)
        self.assertTrue(User.objects.get(username="boss").check_password(PW))       # password hashes survive
        self.assertEqual(Fine.objects.get().balance, Decimal("20.00"))

    def test_restore_replaces_data_created_after_the_backup(self):
        data = backup.build_backup()
        User.objects.create_user("latecomer", password=PW)
        SchoolYear.objects.create(sy="2099-2100")
        backup.restore_backup(data)
        self.assertFalse(User.objects.filter(username="latecomer").exists())
        self.assertFalse(SchoolYear.objects.filter(sy="2099-2100").exists())

    def test_restore_keeps_the_images_in_storage(self):
        data = backup.build_backup()
        with mock.patch("django.core.files.storage.FileSystemStorage.delete") as storage_delete:
            backup.restore_backup(data)
            storage_delete.assert_not_called()           # restoring must never delete photos / QR PNGs
        # ...and the normal "delete a user removes their photo" behaviour is back afterwards
        with mock.patch("django.core.files.storage.FileSystemStorage.delete") as storage_delete:
            User.objects.get(username="stud").delete()
            storage_delete.assert_called()

    def test_instructor_profile_is_not_duplicated_by_the_restore(self):
        data = backup.build_backup()
        backup.restore_backup(data)
        self.assertEqual(Instructor.objects.count(), 1)

    def test_backup_file_only_contains_our_tables_and_no_sessions(self):
        models = {o["model"].split(".")[0] for o in json.loads(backup.build_backup())}
        self.assertEqual(models, {"accounts", "attendance", "portal"})

    def test_a_failed_restore_changes_nothing(self):
        before = snapshot()
        good = json.loads(backup.build_backup())
        good.append({"model": "accounts.student", "pk": 999,
                     "fields": {"user": 424242, "student_number": "ghost", "year_level": "1", "section": "A"}})
        with self.assertRaises(backup.BackupError):
            backup.restore_backup(json.dumps(good).encode())
        self.assertEqual(snapshot(), before)

    def test_bad_files_are_rejected(self):
        for raw, fragment in (
            (b"not json at all", "not JSON"),
            (b'{"a": 1}', "not a backup"),
            (b"[]", "not a backup"),
            (json.dumps([{"model": "auth.permission", "pk": 1, "fields": {}}]).encode(), "will not touch"),
            (json.dumps([{"model": "attendance.event", "pk": 1, "fields": {}}]).encode(), "no users"),
        ):
            with self.assertRaises(backup.BackupError) as ctx:
                backup.restore_backup(raw)
            self.assertIn(fragment, str(ctx.exception))
        self.assertTrue(User.objects.filter(username="boss").exists())


class AdminSiteTests(TestCase):
    def setUp(self):
        self.world = build_world()

    def login(self, username):
        self.client.force_login(User.objects.get(username=username))

    def test_branded_admin(self):
        from django.contrib import admin

        self.assertEqual(type(admin.site._wrapped).__name__, "IteAdminSite")
        self.login("boss")
        html = self.client.get(reverse("admin:index")).content.decode()
        self.assertIn("ITE Attendance · Administration", html)
        self.assertIn("ite-logo", html)
        self.assertIn("Download backup now", html)
        self.assertIn("Open portal", html)
        self.assertIn("--primary: #41b422", html)

    def test_only_the_super_admin_gets_the_backup_page(self):
        url = reverse("admin:backup")
        self.assertEqual(self.client.get(url).status_code, 302)                 # anonymous -> login
        self.login("adviser")
        self.assertEqual(self.client.get(url).status_code, 302)                 # not staff -> login
        staff = User.objects.create_user("staffer", password=PW, is_admin=True, is_staff=True)
        self.client.force_login(staff)
        self.assertEqual(self.client.get(url).status_code, 403)                 # staff but not super
        self.assertEqual(self.client.post(url, {"action": "download"}).status_code, 403)
        self.login("boss")
        page = self.client.get(url)
        self.assertEqual(page.status_code, 200)
        self.assertContains(page, "Download backup (.json)")
        self.assertContains(page, "Restore from file")

    def test_download_button_returns_the_backup(self):
        self.login("boss")
        res = self.client.post(reverse("admin:backup"), {"action": "download"})
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res["Content-Type"], "application/json")
        self.assertRegex(res["Content-Disposition"], r'attachment; filename="ite-attendance-backup-\d{8}-\d{4}\.json"')
        self.assertTrue(any(o["model"] == "attendance.fine" for o in json.loads(res.content)))

    def test_restore_through_the_page(self):
        self.login("boss")
        data = self.client.post(reverse("admin:backup"), {"action": "download"}).content
        Fine.objects.all().delete()
        Event.objects.all().delete()
        url = reverse("admin:backup")
        up = lambda: SimpleUploadedFile("b.json", data, content_type="application/json")  # noqa: E731
        # without the confirmation word nothing happens
        self.client.post(url, {"action": "restore", "file": up(), "confirm": "yes"})
        self.assertEqual(Event.objects.count(), 0)
        res = self.client.post(url, {"action": "restore", "file": up(), "confirm": "RESTORE"}, follow=True)
        self.assertContains(res, "Restored")
        self.assertEqual(Event.objects.count(), 1)
        self.assertEqual(Fine.objects.get().amount_paid, Decimal("50.00"))
        bad = self.client.post(url, {"action": "restore", "confirm": "RESTORE",
                                     "file": SimpleUploadedFile("x.json", b"nope")}, follow=True)
        self.assertContains(bad, "not a valid backup file")
        self.assertEqual(Event.objects.count(), 1)

    def test_other_admin_pages_still_render_with_the_theme(self):
        self.login("boss")
        for name in ("admin:accounts_user_changelist", "admin:attendance_event_changelist",
                     "admin:attendance_fine_changelist", "admin:portal_portalsettings_changelist"):
            self.assertEqual(self.client.get(reverse(name)).status_code, 200, name)


class BackupCommandTests(TestCase):
    def test_backup_and_restore_commands(self):
        build_world()
        before = snapshot()
        path = os.path.join(tempfile.mkdtemp(), "b.json")
        call_command("backup_db", output=path, stdout=io.StringIO())
        self.assertGreater(os.path.getsize(path), 1000)
        User.objects.all().delete()
        SchoolYear.objects.all().delete()
        PortalSettings.objects.all().delete()
        with self.assertRaises(CommandError):
            call_command("restore_db", path, stdout=io.StringIO())              # needs --yes
        call_command("restore_db", path, yes=True, stdout=io.StringIO())
        self.assertEqual(snapshot(), before)
        with self.assertRaises(CommandError):
            call_command("restore_db", path + ".missing", yes=True, stdout=io.StringIO())
