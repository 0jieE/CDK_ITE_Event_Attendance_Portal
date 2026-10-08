"""The demo-data seeder: complete, repeatable, and removable without touching real data."""

import datetime
import io
from decimal import Decimal

from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from accounts.models import Instructor, Student, User

from .models import AttendanceLog, Event, Fine, SchoolYear, Semester


def run(*args):
    out = io.StringIO()
    call_command("seed_demo", *args, stdout=out)
    return out.getvalue()


class SeedDemoTests(TestCase):
    def setUp(self):
        self.adviser = User.objects.create_user("adviser", password="x", is_admin=True, is_staff=True)
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.sem = Semester.objects.create(school_year=sy, name="1st")
        today = timezone.localdate()
        # a REAL event + REAL student that must be left alone
        self.real_event = Event.objects.create(
            name="Entrams", semester=self.sem, start_date=today - datetime.timedelta(days=3),
            end_date=today - datetime.timedelta(days=1), fine_rate=Decimal("50"),
            required_types=["AM_IN"], am_in_start=datetime.time(6), am_in_end=datetime.time(7))
        ru = User.objects.create_user("julius", password="real-pass", is_student=True)
        self.real = Student.objects.create(user=ru, student_number="2025-REAL", year_level="3")

    def test_seeds_students_events_logs_fines_and_signups(self):
        out = run("--students", "10")
        self.assertIn("Demo data ready", out)
        self.assertEqual(Student.objects.filter(student_number__startswith="DEMO-0").count(), 10)
        self.assertEqual(Student.objects.filter(approval_status="PENDING").count(), 3)
        self.assertEqual(Student.objects.filter(approval_status="REJECTED").count(), 1)
        self.assertEqual(Instructor.objects.count(), 2)
        self.assertEqual(Event.objects.filter(name__in=["Intramurals 2026", "ITE Tech Week 2026",
                                                        "Foundation Day 2026"]).count(), 3)
        # pending / rejected demo accounts can't sign in; approved ones can
        self.assertFalse(User.objects.get(username="pending01").is_active)
        self.assertTrue(User.objects.get(username="stud01").check_password("Demo-Pass-2026"))
        self.assertTrue(User.objects.get(username="stud01").is_active)
        self.assertTrue(AttendanceLog.objects.exists() and Fine.objects.exists())
        self.assertTrue(Fine.objects.filter(status="PAID").exists())          # some settled in cash

    def test_events_are_relative_to_today(self):
        run("--students", "5")
        today = timezone.localdate()
        past = Event.objects.get(name="Intramurals 2026")
        cur = Event.objects.get(name="ITE Tech Week 2026")
        fut = Event.objects.get(name="Foundation Day 2026")
        self.assertLess(past.end_date, today)
        self.assertTrue(cur.start_date <= today <= cur.end_date)
        self.assertGreater(fut.start_date, today)
        self.assertFalse(Fine.objects.filter(event=fut).exists())             # nothing is fined in advance

    def test_rerun_is_idempotent(self):
        run("--students", "8")
        counts = lambda: (User.objects.count(), Student.objects.count(), Event.objects.count(),  # noqa: E731
                          AttendanceLog.objects.count(), Fine.objects.count(), Fine.objects.filter(status="PAID").count())
        before = counts()
        out = run("--students", "8")
        self.assertEqual(counts(), before)
        self.assertIn("0 attendance logs added", out)

    def test_existing_real_student_is_not_fined_for_the_demo_events(self):
        run("--students", "6")
        fines = Fine.objects.filter(student=self.real, event__name__in=[
            "Intramurals 2026", "ITE Tech Week 2026"])
        # he got plausible attendance in the finished demo event, so he is not charged for all 8 slots
        self.assertTrue(AttendanceLog.objects.filter(student=self.real, event__name="Intramurals 2026").exists())
        self.assertLess(sum(f.missed_slots for f in fines), 8 + 6)
        # and the REAL event got no fabricated attendance for him
        self.assertFalse(AttendanceLog.objects.filter(student=self.real, event=self.real_event).exists())

    def test_demo_students_also_get_history_in_the_real_event(self):
        run("--students", "6")
        self.assertTrue(AttendanceLog.objects.filter(event=self.real_event,
                                                     student__student_number__startswith="DEMO-").exists())

    def test_clear_removes_only_demo_data(self):
        run("--students", "6")
        out = run("--clear")
        self.assertIn("Removed", out)
        self.assertFalse(Student.objects.filter(student_number__startswith="DEMO-").exists())
        self.assertFalse(User.objects.filter(username__in=["stud01", "inst01", "pending01", "rejected01"]).exists())
        self.assertFalse(Event.objects.filter(name__in=["Intramurals 2026", "ITE Tech Week 2026",
                                                        "Foundation Day 2026"]).exists())
        # real data untouched
        self.assertTrue(User.objects.filter(username="julius").exists())
        self.assertTrue(User.objects.filter(username="adviser").exists())
        self.assertTrue(Event.objects.filter(pk=self.real_event.pk).exists())
        self.assertTrue(Student.objects.filter(pk=self.real.pk).exists())
        self.assertFalse(Fine.objects.filter(student__student_number__startswith="DEMO-").exists())

    def test_custom_password_is_applied(self):
        run("--students", "3", "--password", "Another-Demo-9")
        self.assertTrue(User.objects.get(username="stud01").check_password("Another-Demo-9"))
