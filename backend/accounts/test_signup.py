"""Email is gone and self-registration is gone: only the adviser creates accounts."""

from django.db import connection
from django.test import TestCase
from django.urls import NoReverseMatch, reverse
from rest_framework.test import APIClient

from .models import Student, User

STRONG = "Tr1cky-Horse-Battery-9!"


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

    def test_api_payloads_do_not_expose_email(self):
        admin = User.objects.create_user("adm", password="x", is_admin=True)
        c = APIClient()
        c.force_authenticate(admin)
        self.assertNotIn("email", c.get(reverse("me")).json())
        self.assertNotIn("email", c.get(reverse("user-list")).json()["results"][0])


class SelfRegistrationRemovedTests(TestCase):
    """Only the Department Adviser creates student accounts (masterlist import)."""

    def test_the_public_register_endpoint_no_longer_exists(self):
        with self.assertRaises(NoReverseMatch):
            reverse("auth-register")
        res = APIClient().post("/api/auth/register/", {"username": "x", "password": STRONG}, format="json")
        self.assertEqual(res.status_code, 404)
        self.assertFalse(User.objects.filter(username="x").exists())

    def test_there_is_no_approval_machinery_left(self):
        names = {f.name for f in Student._meta.get_fields()}
        for gone in ("approval_status", "reviewed_at", "reviewed_by", "rejection_reason"):
            self.assertNotIn(gone, names)
        self.assertFalse(hasattr(Student, "approve"))
        with self.assertRaises(NoReverseMatch):
            reverse("portal:approvals")

    def test_login_of_an_inactive_account_is_a_plain_401(self):
        User.objects.create_user("off", password=STRONG, is_student=True, is_active=False)
        res = APIClient().post(reverse("auth-login"), {"username": "off", "password": STRONG})
        self.assertEqual(res.status_code, 401)
        self.assertNotIn("code", res.json())

    def test_student_api_payload_has_no_approval_fields(self):
        adm = User.objects.create_user("adm", password="x", is_admin=True)
        u = User.objects.create_user("s1", password="x", is_student=True)
        Student.objects.create(user=u, student_number="N-1", year_level="1")
        c = APIClient()
        c.force_authenticate(adm)
        row = c.get(reverse("student-list")).json()["results"][0]
        self.assertEqual(set(row), {"id", "student_number", "user"})
