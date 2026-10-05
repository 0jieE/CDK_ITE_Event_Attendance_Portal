"""Security-focused tests: student data isolation, QR token handling, throttling
and the health endpoint. Run with ``python manage.py test``.
"""

import datetime
from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework.throttling import ScopedRateThrottle

from accounts.models import Instructor, Student, User

from .models import (
    AttendanceLog,
    Event,
    Fine,
    QRCode,
    SchoolYear,
    Semester,
    generate_token,
)

PASSWORD = "S3cure-Pass-for-tests!"


def make_student(username, number):
    user = User.objects.create_user(
        username=username, password=PASSWORD, is_student=True,
        first_name=username.title(), last_name="Test",
    )
    return Student.objects.create(user=user, student_number=number)


def make_event(**kwargs):
    sy = SchoolYear.objects.get_or_create(sy="2025-2026")[0]
    sem = Semester.objects.get_or_create(school_year=sy, name="1st")[0]
    today = timezone.localdate()
    defaults = dict(
        name="Tech Week", semester=sem, start_date=today, end_date=today,
        fine_rate=Decimal("10.00"), required_types=["AM_IN"],
        am_in_start=datetime.time(0, 0), am_in_end=datetime.time(23, 59, 59),
    )
    defaults.update(kwargs)
    return Event.objects.create(**defaults)


class StudentIsolationTests(TestCase):
    """A student must only ever see their own data."""

    def setUp(self):
        cache.clear()
        self.alice = make_student("alice", "A-001")
        self.bob = make_student("bob", "B-002")
        self.event = make_event()
        today = timezone.localdate()
        self.alice_qr = QRCode.objects.create(
            student=self.alice, event=self.event, date=today)
        self.bob_qr = QRCode.objects.create(
            student=self.bob, event=self.event, date=today)
        # A finished (yesterday) event nobody attended: every student really did
        # miss its one required slot, so the fine matches what the automatic
        # refresh computes (1 slot x 10.00).
        yesterday = today - datetime.timedelta(days=1)
        self.missed_event = make_event(
            name="Past", start_date=yesterday, end_date=yesterday)
        for s in (self.alice, self.bob):
            AttendanceLog.objects.create(
                student=s, event=self.event, date=today, attendance_type="AM_IN",
                status=AttendanceLog.Status.PRESENT, scanned_at=timezone.now())
            Fine.objects.create(
                student=s, event=self.missed_event, missed_slots=1,
                amount=Decimal("10.00"))
        self.client = APIClient()
        self.client.force_authenticate(self.alice.user)

    def test_qr_list_only_returns_own_codes(self):
        # Regression: this endpoint used to 500 (ordering by a removed field).
        res = self.client.get(reverse("student-qr-list"))
        self.assertEqual(res.status_code, 200)
        tokens = {r["token"] for r in res.json()["results"]}
        self.assertEqual(tokens, {self.alice_qr.token})
        self.assertNotIn(self.bob_qr.token, str(res.content))

    def test_attendance_fines_balance_are_scoped(self):
        att = self.client.get(reverse("student-attendance")).json()["results"]
        self.assertEqual(len(att), 1)
        fines = self.client.get(reverse("student-fines")).json()["results"]
        self.assertEqual(len(fines), 1)
        bal = self.client.get(reverse("student-balance")).json()
        self.assertEqual(Decimal(bal["total_fines"]), Decimal("10.00"))
        profile = self.client.get(reverse("student-profile")).json()
        self.assertEqual(profile["student_number"], "A-001")

    def test_generate_always_binds_to_requesting_student(self):
        res = self.client.post(
            reverse("student-qr-generate"),
            {"event": self.event.pk, "date": str(timezone.localdate()),
             "student": self.bob.pk},  # smuggled field must be ignored
            format="json",
        )
        self.assertIn(res.status_code, (200, 201))
        self.assertEqual(res.json()["token"], self.alice_qr.token)
        self.assertEqual(QRCode.objects.filter(student=self.bob).count(), 1)

    def test_students_cannot_use_instructor_or_admin_endpoints(self):
        self.assertEqual(
            self.client.post(reverse("instructor-scan"),
                             {"token": self.bob_qr.token}).status_code, 403)
        self.assertEqual(self.client.get(reverse("fine-list")).status_code, 403)
        self.assertEqual(self.client.get(reverse("student-list")).status_code, 403)

    def test_anonymous_is_rejected(self):
        anon = APIClient()
        for name in ("student-profile", "student-qr-list", "student-fines",
                     "student-attendance", "student-balance", "me"):
            self.assertEqual(anon.get(reverse(name)).status_code, 401, name)


class ScanTokenTests(TestCase):
    def setUp(self):
        cache.clear()
        self.student = make_student("carol", "C-003")
        self.event = make_event()
        self.qr = QRCode.objects.create(
            student=self.student, event=self.event, date=timezone.localdate())
        ins_user = User.objects.create_user(
            username="ins", password=PASSWORD, is_instructor=True)
        Instructor.objects.create(user=ins_user)
        self.client = APIClient()
        self.client.force_authenticate(ins_user)

    def test_tokens_are_long_and_random(self):
        tokens = {generate_token() for _ in range(200)}
        self.assertEqual(len(tokens), 200)
        self.assertTrue(all(len(t) >= 43 for t in tokens))  # >= 256 bits

    def test_token_is_resolved_server_side(self):
        res = self.client.post(reverse("instructor-scan"), {"token": self.qr.token})
        self.assertEqual(res.status_code, 201)
        self.assertEqual(res.json()["student_number"], "C-003")

    def test_unknown_or_guessed_token_is_rejected(self):
        for guess in ("1", "C-003", str(self.student.pk), "A" * 43):
            res = self.client.post(reverse("instructor-scan"), {"token": guess})
            self.assertEqual(res.status_code, 404, guess)
            self.assertEqual(res.json()["code"], "INVALID_TOKEN")

    def test_scan_is_rate_limited_per_instructor(self):
        with mock.patch.dict(ScopedRateThrottle.THROTTLE_RATES, {"scan": "3/min"}):
            codes = [
                self.client.post(reverse("instructor-scan"), {"token": "x"}).status_code
                for _ in range(5)
            ]
        self.assertEqual(codes[:3], [404, 404, 404])
        self.assertEqual(codes[3:], [429, 429])


class LoginThrottleAndRotationTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user(
            username="dave", password=PASSWORD, is_student=True)

    def test_login_is_throttled_after_repeated_failures(self):
        client = APIClient()
        with mock.patch.dict(ScopedRateThrottle.THROTTLE_RATES, {"login": "3/min"}):
            codes = [
                client.post(reverse("auth-login"),
                            {"username": "dave", "password": "wrong"}).status_code
                for _ in range(5)
            ]
        self.assertEqual(codes[:3], [401, 401, 401])
        self.assertEqual(codes[3:], [429, 429])

    def test_refresh_rotates_and_blacklists_old_token(self):
        client = APIClient()
        tokens = client.post(
            reverse("auth-login"),
            {"username": "dave", "password": PASSWORD}).json()
        first = client.post(reverse("auth-refresh"), {"refresh": tokens["refresh"]})
        self.assertEqual(first.status_code, 200)
        self.assertIn("refresh", first.json())            # rotated
        self.assertNotEqual(first.json()["refresh"], tokens["refresh"])
        replay = client.post(reverse("auth-refresh"), {"refresh": tokens["refresh"]})
        self.assertEqual(replay.status_code, 401)         # old one is blacklisted


class HealthzTests(TestCase):
    def test_healthz_ok_without_auth(self):
        res = self.client.get("/healthz/")
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json(), {"status": "ok", "database": "ok"})

    def test_healthz_503_when_db_down(self):
        with mock.patch("core.views.connection.cursor", side_effect=Exception("down")):
            res = self.client.get("/healthz/")
        self.assertEqual(res.status_code, 503)

    def test_healthz_rejects_writes(self):
        self.assertEqual(self.client.post("/healthz/").status_code, 405)

    @override_settings(SECURE_SSL_REDIRECT=True, ALLOWED_HOSTS=["testserver"])
    def test_healthz_is_exempt_from_https_redirect(self):
        self.assertEqual(self.client.get("/healthz/").status_code, 200)
