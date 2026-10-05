"""Student mobile contract: today-only QR, all-events list, profile + password."""

import datetime
from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework.throttling import ScopedRateThrottle

from accounts.models import Student, User

from .models import Event, QRCode, SchoolYear, Semester

STRONG = "Tr1cky-Horse-Battery-9!"


def make_event(start, end, name="E", active=True):
    sy = SchoolYear.objects.get_or_create(sy="2025-2026")[0]
    sem = Semester.objects.get_or_create(school_year=sy, name="1st")[0]
    return Event.objects.create(
        name=name, semester=sem, start_date=start, end_date=end, fine_rate=Decimal("10"),
        required_types=["AM_IN"], am_in_start=datetime.time(6), am_in_end=datetime.time(7),
        is_active=active,
    )


class StudentTestBase(TestCase):
    def setUp(self):
        cache.clear()
        self.today = timezone.localdate()
        self.user = User.objects.create_user(
            "stud", password=STRONG, is_student=True, email="s@x.ph",
            first_name="Ana", middle_name="B", last_name="Reyes")
        self.student = Student.objects.create(
            user=self.user, student_number="2024-1", year_level="2", section="A")
        self.client = APIClient()
        self.client.force_authenticate(self.user)


class TodayOnlyQrTests(StudentTestBase):
    def setUp(self):
        super().setUp()
        d = datetime.timedelta
        self.event = make_event(self.today - d(days=1), self.today + d(days=2))

    def generate(self, day):
        return self.client.post(
            reverse("student-qr-generate"), {"event": self.event.pk, "date": str(day)}, format="json")

    def test_today_creates_then_is_idempotent_once_per_event_day(self):
        first = self.generate(self.today)
        self.assertEqual(first.status_code, 201)
        again = self.generate(self.today)
        self.assertEqual(again.status_code, 200)
        self.assertEqual(again.json()["token"], first.json()["token"])
        self.assertEqual(QRCode.objects.filter(student=self.student).count(), 1)

    def test_future_and_past_days_are_rejected_server_side(self):
        d = datetime.timedelta
        for day in (self.today + d(days=1), self.today + d(days=2), self.today - d(days=1)):
            res = self.generate(day)
            self.assertEqual(res.status_code, 400, day)
            self.assertIn("only generate a QR for today", str(res.json()["date"]))
        self.assertFalse(QRCode.objects.exists())          # nothing was created in advance

    def test_dates_outside_the_event_range_still_get_the_range_error(self):
        res = self.generate(self.today + datetime.timedelta(days=30))
        self.assertEqual(res.status_code, 400)
        self.assertIn("Date must be within", str(res.json()["date"]))

    def test_existing_qr_can_be_looked_up_by_event_and_date(self):
        self.generate(self.today)
        res = self.client.get(reverse("student-qr-list"), {"event": self.event.pk, "date": str(self.today)})
        self.assertEqual(res.status_code, 200)
        self.assertEqual(len(res.json()["results"]), 1)
        res = self.client.get(reverse("student-qr-list"), {"event": self.event.pk,
                                                            "date": str(self.today - datetime.timedelta(days=1))})
        self.assertEqual(res.json()["results"], [])

    def test_event_not_running_today_cannot_generate(self):
        past = make_event(self.today - datetime.timedelta(days=9), self.today - datetime.timedelta(days=8), "Old")
        res = self.client.post(reverse("student-qr-generate"),
                               {"event": past.pk, "date": str(self.today)}, format="json")
        self.assertEqual(res.status_code, 400)


class AllEventsTests(StudentTestBase):
    def test_default_hides_past_events_and_all_true_includes_them_newest_first(self):
        d = datetime.timedelta
        old = make_event(self.today - d(days=20), self.today - d(days=19), "Old")
        cur = make_event(self.today, self.today + d(days=1), "Current")
        fut = make_event(self.today + d(days=10), self.today + d(days=11), "Future")
        names = [e["name"] for e in self.client.get(reverse("student-events")).json()["results"]]
        self.assertEqual(names, ["Current", "Future"])
        names = [e["name"] for e in
                 self.client.get(reverse("student-events"), {"all": "true"}).json()["results"]]
        self.assertEqual(names, ["Future", "Current", "Old"])          # newest start first
        self.assertEqual({old.pk, cur.pk, fut.pk}, {e["id"] for e in
                         self.client.get(reverse("student-events"), {"all": "1"}).json()["results"]})

    def test_all_events_requires_a_student(self):
        self.assertEqual(APIClient().get(reverse("student-events"), {"all": "true"}).status_code, 401)


class ProfileUpdateTests(StudentTestBase):
    url = "student-profile"

    def test_get_returns_editable_fields_and_readonly_academic_info(self):
        data = self.client.get(reverse(self.url)).json()
        for key in ("first_name", "middle_name", "last_name", "username", "email",
                    "student_number", "year_level", "section", "year_section", "profile_image"):
            self.assertIn(key, data)
        self.assertEqual((data["first_name"], data["middle_name"], data["username"]), ("Ana", "B", "stud"))

    def test_patch_updates_only_own_allowed_fields(self):
        res = self.client.patch(reverse(self.url), {
            "first_name": " Anna ", "last_name": "Reyes-Lim", "email": "new@x.ph", "middle_name": "",
            # attempts to change admin-managed data must be ignored:
            "student_number": "HACK", "year_level": "4", "section": "Z", "is_admin": True,
        }, format="json")
        self.assertEqual(res.status_code, 200, res.content)
        self.user.refresh_from_db(); self.student.refresh_from_db()
        self.assertEqual((self.user.first_name, self.user.last_name, self.user.email),
                         ("Anna", "Reyes-Lim", "new@x.ph"))
        self.assertEqual((self.student.student_number, self.student.year_level, self.student.section),
                         ("2024-1", "2", "A"))
        self.assertFalse(self.user.is_admin)
        self.assertEqual(res.json()["full_name"], self.user.get_full_name())

    def test_username_change_and_uniqueness(self):
        User.objects.create_user("taken", password="x")
        res = self.client.patch(reverse(self.url), {"username": "TAKEN"}, format="json")
        self.assertEqual(res.status_code, 400)
        self.assertIn("already exists", str(res.json()["username"]))
        ok = self.client.patch(reverse(self.url), {"username": "ana.reyes"}, format="json")
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok.json()["username"], "ana.reyes")
        # keeping your own username (case change) is allowed
        self.assertEqual(self.client.patch(reverse(self.url), {"username": "Ana.Reyes"}, format="json").status_code, 200)

    def test_validation_errors_are_per_field(self):
        res = self.client.patch(reverse(self.url), {"email": "nope", "first_name": "  ", "username": ""}, format="json")
        self.assertEqual(res.status_code, 400)
        self.assertEqual(set(res.json()), {"email", "first_name", "username"})

    def test_other_students_data_is_never_touched(self):
        other = User.objects.create_user("o", password="x", is_student=True, first_name="Other")
        Student.objects.create(user=other, student_number="X-9")
        self.client.patch(reverse(self.url), {"first_name": "Changed"}, format="json")
        other.refresh_from_db()
        self.assertEqual(other.first_name, "Other")

    def test_needs_a_student_account(self):
        self.assertEqual(APIClient().patch(reverse(self.url), {}, format="json").status_code, 401)
        inst = User.objects.create_user("i", password="x", is_instructor=True)
        c = APIClient(); c.force_authenticate(inst)
        self.assertEqual(c.patch(reverse(self.url), {"first_name": "x"}, format="json").status_code, 403)


class PasswordChangeTests(StudentTestBase):
    url = "student-password"

    def post(self, cur, new):
        return self.client.post(reverse(self.url), {"current_password": cur, "new_password": new}, format="json")

    def test_success_changes_the_password_and_login_uses_it(self):
        self.assertEqual(self.post(STRONG, "Brand-New-Pass-77!").status_code, 204)
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password("Brand-New-Pass-77!"))
        login = APIClient().post(reverse("auth-login"), {"username": "stud", "password": "Brand-New-Pass-77!"})
        self.assertEqual(login.status_code, 200)

    def test_wrong_current_password(self):
        res = self.post("wrong", "Brand-New-Pass-77!")
        self.assertEqual(res.status_code, 400)
        self.assertIn("incorrect", str(res.json()["current_password"]))
        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password(STRONG))

    def test_django_validators_are_enforced(self):
        for weak in ("short1", "12345678901", "password123"):
            res = self.post(STRONG, weak)
            self.assertEqual(res.status_code, 400, weak)
            self.assertIn("new_password", res.json(), weak)

    def test_new_password_must_differ(self):
        res = self.post(STRONG, STRONG)
        self.assertEqual(res.status_code, 400)
        self.assertIn("different", str(res.json()["new_password"]))

    def test_rate_limited_to_stop_guessing_the_current_password(self):
        with mock.patch.dict(ScopedRateThrottle.THROTTLE_RATES, {"password": "3/min"}):
            codes = [self.post("guess%d" % i, "Brand-New-Pass-77!").status_code for i in range(5)]
        self.assertEqual(codes, [400, 400, 400, 429, 429])

    def test_requires_login(self):
        res = APIClient().post(reverse(self.url), {"current_password": "a", "new_password": "b"}, format="json")
        self.assertEqual(res.status_code, 401)
