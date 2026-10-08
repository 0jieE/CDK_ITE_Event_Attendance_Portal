"""Email removal + student self-registration that the adviser must approve."""

import datetime
import io
import tempfile
from decimal import Decimal
from unittest import mock

from django.contrib import admin as dj_admin
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.db import connection
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from PIL import Image
from rest_framework.test import APIClient
from rest_framework.throttling import ScopedRateThrottle

from attendance import services
from attendance.models import AttendanceLog, Event, Fine, SchoolYear, Semester

from .models import Student, User

STRONG = "Tr1cky-Horse-Battery-9!"
PAYLOAD = {
    "student_number": "2026-0001", "first_name": "Maria", "middle_name": "Lopez",
    "last_name": "Santos", "username": "maria.santos", "password": STRONG,
    "year_level": "2", "section": "A",
}


def png(name="p.png"):
    buf = io.BytesIO()
    Image.new("RGB", (120, 120), (30, 160, 40)).save(buf, "PNG")
    return SimpleUploadedFile(name, buf.getvalue(), content_type="image/png")


class EmailRemovedTests(TestCase):
    def test_user_model_has_no_email_column(self):
        names = {f.name for f in User._meta.get_fields()}
        self.assertNotIn("email", names)
        with connection.cursor() as cur:
            cols = [c.name for c in connection.introspection.get_table_description(cur, User._meta.db_table)]
        self.assertNotIn("email", cols)

    def test_create_user_and_superuser_still_work(self):
        u = User.objects.create_user("plain", password="x")
        su = User.objects.create_superuser("root", password="x")
        self.assertTrue(u.check_password("x"))
        self.assertTrue(su.is_superuser and su.is_staff)

    def test_stray_email_argument_is_ignored_not_fatal(self):
        self.assertEqual(User.objects.create_user("legacy", "old@x.ph", "pw").username, "legacy")

    def test_django_admin_user_pages_render_without_email(self):
        admin = User.objects.create_superuser("root", password="x")
        self.client.force_login(admin)
        for url in (reverse("admin:accounts_user_changelist"),
                    reverse("admin:accounts_user_add"),
                    reverse("admin:accounts_user_change", args=[admin.pk]),
                    reverse("admin:accounts_student_changelist")):
            self.assertEqual(self.client.get(url).status_code, 200, url)

    def test_api_payloads_do_not_expose_email(self):
        admin = User.objects.create_user("adm", password="x", is_admin=True, is_staff=True)
        c = APIClient()
        c.force_authenticate(admin)
        self.assertNotIn("email", c.get(reverse("me")).json())
        self.assertNotIn("email", c.get(reverse("user-list")).json()["results"][0])


@override_settings(MEDIA_ROOT=tempfile.mkdtemp(prefix="signup-media-"))
class RegistrationTests(TestCase):
    def setUp(self):
        cache.clear()
        self.client = APIClient()

    def register(self, **over):
        data = {**PAYLOAD, **over}
        return self.client.post(reverse("auth-register"), data, format="json")

    def test_signup_creates_an_inactive_pending_student(self):
        res = self.register()
        self.assertEqual(res.status_code, 201, res.content)
        self.assertEqual(res.json()["status"], "PENDING")
        user = User.objects.get(username="maria.santos")
        student = user.student_profile
        self.assertFalse(user.is_active)
        self.assertTrue(user.is_student and not user.is_admin and not user.is_staff)
        self.assertEqual((student.approval_status, student.year_level, student.section, user.middle_name),
                         ("PENDING", "2", "A", "Lopez"))

    def test_public_endpoint_needs_no_token_and_ignores_stale_auth_headers(self):
        c = APIClient()
        c.credentials(HTTP_AUTHORIZATION="Bearer not-a-real-token")
        self.assertEqual(c.post(reverse("auth-register"), PAYLOAD, format="json").status_code, 201)

    def test_validation_errors_are_per_field(self):
        res = self.register(student_number="", first_name=" ", username="a b", password="123", year_level="9")
        self.assertEqual(res.status_code, 400)
        self.assertTrue({"student_number", "first_name", "username", "year_level"} <= set(res.json()))
        weak = self.register(password="password123")
        self.assertIn("password", weak.json())

    def test_duplicate_student_number_and_username(self):
        self.assertEqual(self.register().status_code, 201)
        dup = self.register(username="other.user")
        self.assertIn("student_number", dup.json())
        dup = self.register(student_number="2026-0002", username="MARIA.SANTOS")
        self.assertIn("username", dup.json())
        self.assertEqual(User.objects.filter(is_student=True).count(), 1)

    def test_password_similar_to_username_is_rejected(self):
        res = self.register(username="mariasantos", password="mariasantos1")
        self.assertEqual(res.status_code, 400)
        self.assertIn("password", res.json())

    def test_optional_photo_via_multipart(self):
        res = self.client.post(reverse("auth-register"), {**PAYLOAD, "profile_image": png()}, format="multipart")
        self.assertEqual(res.status_code, 201, res.content)
        self.assertRegex(User.objects.get(username="maria.santos").profile_image.name, r"^profiles/[0-9a-f]{32}\.jpg$")
        bad = self.client.post(reverse("auth-register"), {**PAYLOAD, "student_number": "X", "username": "x1",
                                                          "profile_image": SimpleUploadedFile("a.png", b"junk")},
                               format="multipart")
        self.assertEqual(bad.status_code, 400)
        self.assertIn("profile_image", bad.json())

    def test_signups_are_rate_limited(self):
        with mock.patch.dict(ScopedRateThrottle.THROTTLE_RATES, {"register": "2/hour"}):
            codes = [self.register(student_number=f"S{i}", username=f"user{i}").status_code for i in range(4)]
        self.assertEqual(codes, [201, 201, 429, 429])

    def test_cannot_register_privileged_roles(self):
        res = self.register(is_admin=True, is_instructor=True, is_staff=True, is_superuser=True)
        self.assertEqual(res.status_code, 201)
        u = User.objects.get(username="maria.santos")
        self.assertFalse(u.is_admin or u.is_instructor or u.is_staff or u.is_superuser)


class LoginStateTests(TestCase):
    def setUp(self):
        cache.clear()
        self.client = APIClient()
        self.client.post(reverse("auth-register"), PAYLOAD, format="json")
        self.student = Student.objects.get(student_number="2026-0001")
        self.adviser = User.objects.create_user("adv", password="x", is_admin=True, is_staff=True)

    def login(self, password=STRONG, username="maria.santos"):
        return self.client.post(reverse("auth-login"), {"username": username, "password": password})

    def test_pending_account_gets_a_clear_403(self):
        res = self.login()
        self.assertEqual(res.status_code, 403)
        self.assertEqual(res.json()["code"], "PENDING_APPROVAL")
        self.assertIn("approval", res.json()["detail"].lower())

    def test_wrong_credentials_stay_a_generic_401_and_leak_nothing(self):
        self.assertEqual(self.login(password="wrong").status_code, 401)
        self.assertEqual(self.login(username="nobody").status_code, 401)
        self.assertNotIn("code", self.login(password="wrong").json())

    def test_rejected_account_sees_the_reason(self):
        self.student.reject(by=self.adviser, reason="Not on the class list")
        res = self.login()
        self.assertEqual(res.status_code, 403)
        self.assertEqual(res.json()["code"], "REGISTRATION_REJECTED")
        self.assertIn("Not on the class list", res.json()["detail"])

    def test_approved_account_can_sign_in_and_use_the_app(self):
        self.student.approve(by=self.adviser)
        res = self.login()
        self.assertEqual(res.status_code, 200)
        c = APIClient()
        c.credentials(HTTP_AUTHORIZATION="Bearer " + res.json()["access"])
        self.assertEqual(c.get(reverse("student-profile")).status_code, 200)

    def test_inactive_non_student_gets_no_special_message(self):
        User.objects.create_user("ghost", password="pw", is_active=False, is_instructor=True)
        self.assertEqual(self.login(username="ghost", password="pw").status_code, 401)

    def test_unapproved_student_api_access_is_blocked_even_with_a_valid_token(self):
        self.student.user.is_active = True            # e.g. flipped by hand somewhere
        self.student.user.save()
        c = APIClient()
        c.force_authenticate(self.student.user)
        self.assertEqual(c.get(reverse("student-profile")).status_code, 403)


class ApprovalApiAndPortalTests(TestCase):
    def setUp(self):
        cache.clear()
        APIClient().post(reverse("auth-register"), PAYLOAD, format="json")
        self.student = Student.objects.get(student_number="2026-0001")
        self.adviser = User.objects.create_user("adv", password="x", is_admin=True, is_staff=True)
        self.api = APIClient()
        self.api.force_authenticate(self.adviser)

    def test_admin_api_lists_filters_approves_and_rejects(self):
        res = self.api.get(reverse("student-list"), {"approval_status": "PENDING"}).json()
        self.assertEqual(res["count"], 1)
        self.assertEqual(res["results"][0]["approval_status"], "PENDING")
        ok = self.api.post(reverse("student-approve", args=[self.student.pk]))
        self.assertEqual((ok.status_code, ok.json()["approval_status"]), (200, "APPROVED"))
        self.student.refresh_from_db()
        self.assertTrue(self.student.user.is_active)
        self.assertEqual((self.student.reviewed_by, bool(self.student.reviewed_at)), (self.adviser, True))
        no = self.api.post(reverse("student-reject", args=[self.student.pk]), {"reason": "dup"}, format="json")
        self.assertEqual(no.json()["approval_status"], "REJECTED")
        self.student.refresh_from_db()
        self.assertFalse(self.student.user.is_active)
        self.assertEqual(self.student.rejection_reason, "dup")

    def test_only_admins_can_approve(self):
        c = APIClient()
        c.force_authenticate(User.objects.create_user("stu", password="x", is_student=True))
        self.assertEqual(c.post(reverse("student-approve", args=[self.student.pk])).status_code, 403)
        self.assertEqual(APIClient().post(reverse("student-approve", args=[self.student.pk])).status_code, 401)
        self.student.refresh_from_db()
        self.assertEqual(self.student.approval_status, "PENDING")

    def test_portal_approvals_page_lists_pending_and_shows_the_badge(self):
        self.client.force_login(self.adviser)
        html = self.client.get(reverse("portal:approvals")).content.decode()
        self.assertIn("Maria Lopez Santos", html)
        self.assertIn("2026-0001", html)
        self.assertIn("Approve", html)
        dash = self.client.get(reverse("portal:dashboard")).content.decode()
        self.assertIn("waiting for your approval", dash)
        self.assertRegex(dash, r'id="navApprovalsBadge" class="nav-badge">1<')

    def test_portal_approve_and_reject_flow(self):
        self.client.force_login(self.adviser)
        res = self.client.post(reverse("portal:approvals-approve", args=[self.student.pk]))
        self.assertEqual(res.status_code, 204)
        self.assertIn("refresh-approvals", res["HX-Trigger"])
        self.student.refresh_from_db()
        self.assertEqual(self.student.approval_status, "APPROVED")
        # reject modal + submit (another student)
        APIClient().post(reverse("auth-register"),
                         {**PAYLOAD, "student_number": "2026-0002", "username": "second"}, format="json")
        other = Student.objects.get(student_number="2026-0002")
        self.assertEqual(self.client.get(reverse("portal:approvals-reject", args=[other.pk])).status_code, 200)
        res = self.client.post(reverse("portal:approvals-reject", args=[other.pk]), {"reason": "Not enrolled"})
        self.assertEqual(res.status_code, 204)
        other.refresh_from_db()
        self.assertEqual((other.approval_status, other.rejection_reason), ("REJECTED", "Not enrolled"))
        page = self.client.get(reverse("portal:approvals"), {"status": "REJECTED"}).content.decode()
        self.assertIn("Not enrolled", page)

    def test_approval_actions_are_post_only_and_admin_only(self):
        self.client.force_login(self.adviser)
        self.assertEqual(self.client.get(reverse("portal:approvals-approve", args=[self.student.pk])).status_code, 405)
        self.client.logout()
        res = self.client.post(reverse("portal:approvals-approve", args=[self.student.pk]))
        self.assertEqual(res.status_code, 302)                      # redirected to login
        self.student.refresh_from_db()
        self.assertEqual(self.student.approval_status, "PENDING")

    def test_editing_a_pending_student_cannot_activate_them(self):
        self.client.force_login(self.adviser)
        url = reverse("portal:students-edit", args=[self.student.pk])
        res = self.client.post(url, {"student_number": "2026-0001", "year_level": "2", "section": "A",
                                     "username": "maria.santos", "first_name": "Maria",
                                     "last_name": "Santos", "is_active": "on"})
        self.assertEqual(res.status_code, 204, res.content[:200])
        self.student.user.refresh_from_db()
        self.assertFalse(self.student.user.is_active)               # still needs approval

    def test_students_created_by_the_adviser_are_approved_and_active(self):
        self.client.force_login(self.adviser)
        res = self.client.post(reverse("portal:students-add"), {
            "student_number": "A-1", "year_level": "1", "section": "B", "username": "adm.made",
            "first_name": "Made", "last_name": "ByAdviser", "password": STRONG, "is_active": "on"})
        self.assertEqual(res.status_code, 204, res.content[:200])
        s = Student.objects.get(student_number="A-1")
        self.assertEqual(s.approval_status, "APPROVED")
        self.assertTrue(s.user.is_active)


class FinesAndEnrolmentTests(TestCase):
    """Pending sign-ups are never fined; late joiners are fined only from approval day."""

    def setUp(self):
        self.today = timezone.localdate()
        sy = SchoolYear.objects.create(sy="2025-2026")
        sem = Semester.objects.create(school_year=sy, name="1st")
        d = datetime.timedelta
        self.event = Event.objects.create(
            name="Week", semester=sem, start_date=self.today - d(days=3), end_date=self.today - d(days=1),
            fine_rate=Decimal("10"), required_types=["AM_IN"],
            am_in_start=datetime.time(6), am_in_end=datetime.time(7))
        self.adviser = User.objects.create_user("adv", password="x", is_admin=True, is_staff=True)

    def make(self, number, **kw):
        u = User.objects.create_user(f"u{number}", password="x", is_student=True)
        return Student.objects.create(user=u, student_number=number, **kw)

    def test_pending_and_rejected_students_are_never_fined(self):
        pending = self.make("P", approval_status="PENDING")
        rejected = self.make("R", approval_status="REJECTED")
        approved = self.make("A")
        services.compute_fines_for_event(self.event)
        self.assertEqual(Fine.objects.filter(student__in=[pending, rejected]).count(), 0)
        self.assertEqual(Fine.objects.get(student=approved).missed_slots, 3)       # 3 past days

    def test_signup_approved_today_is_fined_only_from_today_on(self):
        late = self.make("L", approval_status="PENDING")
        late.approve(by=self.adviser)                      # approved today; event ended yesterday
        services.compute_fines_for_event(self.event)
        self.assertFalse(Fine.objects.filter(student=late).exists())

    def test_signup_approved_mid_event_counts_only_days_since_approval(self):
        mid = self.make("M")
        mid.reviewed_at = timezone.now() - datetime.timedelta(days=2)   # approved 2 days ago
        mid.save()
        services.compute_fines_for_event(self.event)
        self.assertEqual(Fine.objects.get(student=mid).missed_slots, 2)            # days -2 and -1
