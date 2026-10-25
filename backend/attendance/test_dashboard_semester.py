"""The dashboard shows the active semester only, and no attendance rate."""

import datetime
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from attendance import services
from attendance.models import Event, Fine, SchoolYear, Semester

from .tests import make_student

User = get_user_model()
D = datetime.timedelta


def mk_event(sem, name, rate):
    day = timezone.localdate() - D(days=1)
    return Event.objects.create(
        name=name, semester=sem, start_date=day, end_date=day, fine_rate=Decimal(rate),
        required_types=["AM_IN"], am_in_start=datetime.time(0, 0), am_in_end=datetime.time(0, 1))


class DashboardSemesterTests(TestCase):
    def setUp(self):
        cache.clear()
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.old = Semester.objects.create(school_year=sy, name="1st")
        self.cur = Semester.objects.create(school_year=sy, name="2nd", is_active=True)
        self.e_old = mk_event(self.old, "Old Fair", "100")
        self.e_cur = mk_event(self.cur, "Current Fair", "10")
        make_student("s1", "S-1")
        services.compute_fines_for_event(self.e_old)
        services.compute_fines_for_event(self.e_cur)
        adv = User.objects.create_user("adviser", password="pw-12345-Xy", is_admin=True)
        self.client.force_login(adv)

    def test_defaults_to_the_active_semester(self):
        data = services.build_dashboard()
        self.assertEqual(data["semester"], str(self.cur))
        self.assertTrue(data["is_active_semester"])
        self.assertEqual([e["event_name"] for e in data["events"]], ["Current Fair"])
        self.assertEqual(data["total_fines_issued"], Decimal("10.00"))      # not the 100 of the old semester
        self.assertNotIn("overall_attendance_rate", data)

    def test_other_semester_or_all(self):
        self.assertEqual(services.build_dashboard(semester=self.old)["total_fines_issued"], Decimal("100.00"))
        everything = services.build_dashboard(all_semesters=True)
        self.assertEqual(everything["total_fines_issued"], Decimal("110.00"))
        self.assertIsNone(everything["semester"])

    def test_no_active_semester_falls_back_to_all(self):
        Semester.objects.update(is_active=False)
        data = services.build_dashboard()
        self.assertIsNone(data["semester"])
        self.assertEqual(data["total_fines_issued"], Decimal("110.00"))

    def test_portal_page(self):
        html = self.client.get(reverse("portal:dashboard")).content.decode()
        self.assertIn("2026-2027 2nd", html)
        self.assertIn("Active semester", html)
        self.assertIn("Current Fair", html)
        self.assertNotIn("Old Fair", html)
        self.assertNotIn("Attendance rate", html)
        Semester.objects.update(is_active=False)
        self.assertIn("No active semester", self.client.get(reverse("portal:dashboard")).content.decode())

    def test_api_semester_parameter(self):
        from rest_framework.test import APIClient

        api = APIClient()
        api.force_authenticate(User.objects.get(username="adviser"))
        self.assertEqual(api.get(reverse("dashboard")).json()["total_fines_issued"], 10.0)
        self.assertEqual(api.get(reverse("dashboard"), {"semester": self.old.pk}).json()["total_fines_issued"], 100.0)
        self.assertEqual(api.get(reverse("dashboard"), {"semester": "all"}).json()["total_fines_issued"], 110.0)
