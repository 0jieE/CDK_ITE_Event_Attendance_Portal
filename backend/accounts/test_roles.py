"""Super Admin vs Department Adviser, and account creation for instructors/students."""

import importlib
import io
import re
from unittest import mock

from django.apps import apps
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from .models import Instructor, Student, User

STRONG = "Tr1cky-Horse-Battery-9!"


def make_adviser(name="adv"):
    return User.objects.create_user(name, password="x", is_admin=True)       # portal only


def make_super(name="boss"):
    return User.objects.create_user(name, password="x", is_superuser=True, is_staff=True, is_admin=True)


class RoleAccessTests(TestCase):
    def test_roles_are_labelled(self):
        self.assertEqual(make_super("s").role, "superadmin")
        self.assertEqual(make_adviser("a").role, "admin")
        self.assertEqual(User.objects.create_user("i", password="x", is_instructor=True).role, "instructor")

    def test_adviser_uses_the_portal_but_not_django_administration(self):
        self.client.force_login(make_adviser())
        self.assertEqual(self.client.get(reverse("portal:dashboard")).status_code, 200)
        res = self.client.get("/admin/")
        self.assertEqual(res.status_code, 302)
        self.assertIn("/admin/login/", res["Location"])           # bounced to the admin login

    def test_super_admin_uses_both(self):
        self.client.force_login(make_super())
        self.assertEqual(self.client.get(reverse("portal:dashboard")).status_code, 200)
        self.assertEqual(self.client.get("/admin/").status_code, 200)

    def test_menu_shows_the_django_admin_link_only_to_the_super_admin(self):
        self.client.force_login(make_adviser("a1"))
        html = self.client.get(reverse("portal:dashboard")).content.decode()
        self.assertNotIn("Django Administration", html)
        self.assertIn("Department Adviser", html)
        self.client.force_login(make_super("s1"))
        html = self.client.get(reverse("portal:dashboard")).content.decode()
        self.assertIn("Django Administration", html)
        self.assertIn("Super Admin", html)

    def test_plain_users_get_no_portal_access(self):
        self.client.force_login(User.objects.create_user("stu", password="x", is_student=True))
        self.assertEqual(self.client.get(reverse("portal:dashboard")).status_code, 403)


class SuperAdminIsProtectedFromAdvisersTests(TestCase):
    """An adviser must not be able to take over the Super Admin account."""

    def setUp(self):
        self.boss = make_super()
        self.adv = make_adviser()

    def test_portal_users_page_hides_the_super_admin_from_advisers(self):
        self.client.force_login(self.adv)
        html = self.client.get(reverse("portal:users-list")).content.decode()
        self.assertNotIn(">boss<", html)
        self.assertIn(">adv<", html)

    def test_adviser_cannot_open_edit_or_delete_the_super_admin(self):
        self.client.force_login(self.adv)
        self.assertEqual(self.client.get(reverse("portal:users-edit", args=[self.boss.pk])).status_code, 404)
        res = self.client.post(reverse("portal:users-edit", args=[self.boss.pk]),
                               {"username": "boss", "password": "Hacked-Pass-123!", "is_active": "on"})
        self.assertEqual(res.status_code, 404)
        self.assertEqual(self.client.post(reverse("portal:users-delete", args=[self.boss.pk])).status_code, 404)
        self.boss.refresh_from_db()
        self.assertFalse(self.boss.check_password("Hacked-Pass-123!"))
        self.assertTrue(User.objects.filter(pk=self.boss.pk).exists())

    def test_super_admin_sees_and_edits_super_admins(self):
        self.client.force_login(self.boss)
        html = self.client.get(reverse("portal:users-list")).content.decode()
        self.assertIn(">boss<", html)
        self.assertEqual(self.client.get(reverse("portal:users-edit", args=[self.boss.pk])).status_code, 200)

    def test_api_users_endpoint_hides_and_protects_the_super_admin(self):
        api = APIClient()
        api.force_authenticate(self.adv)
        names = [u["username"] for u in api.get(reverse("user-list")).json()["results"]]
        self.assertIn("adv", names)
        self.assertNotIn("boss", names)
        self.assertEqual(api.get(reverse("user-detail", args=[self.boss.pk])).status_code, 404)
        self.assertEqual(api.patch(reverse("user-detail", args=[self.boss.pk]), {"first_name": "x"}).status_code, 404)
        self.assertEqual(api.delete(reverse("user-detail", args=[self.boss.pk])).status_code, 404)
        sup = APIClient()
        sup.force_authenticate(self.boss)
        self.assertIn("boss", [u["username"] for u in sup.get(reverse("user-list")).json()["results"]])

    def test_an_adviser_cannot_grant_super_admin_through_the_api(self):
        api = APIClient()
        api.force_authenticate(self.adv)
        res = api.post(reverse("user-list"), {"username": "sneaky", "password": STRONG,
                                              "is_superuser": True, "is_staff": True}, format="json")
        self.assertEqual(res.status_code, 201)
        u = User.objects.get(username="sneaky")
        self.assertFalse(u.is_superuser or u.is_staff)


class SeedCommandsTests(TestCase):
    def run_cmd(self, *args):
        out = io.StringIO()
        call_command(*args, stdout=out)
        return out.getvalue()

    def test_seed_admin_makes_a_portal_only_adviser(self):
        self.run_cmd("seed_admin", "--username", "adviser", "--password", STRONG)
        u = User.objects.get(username="adviser")
        self.assertTrue(u.is_admin)
        self.assertFalse(u.is_staff or u.is_superuser)

    def test_seed_admin_demotes_an_old_super_adviser(self):
        User.objects.create_user("adviser", password="old", is_admin=True, is_staff=True, is_superuser=True)
        self.run_cmd("seed_admin", "--username", "adviser", "--password", STRONG)
        u = User.objects.get(username="adviser")
        self.assertFalse(u.is_staff or u.is_superuser)
        self.assertTrue(u.check_password(STRONG))

    def test_seed_superadmin_creates_and_if_missing_is_idempotent(self):
        out = self.run_cmd("seed_superadmin", "--username", "superadmin", "--password", STRONG)
        self.assertIn("Created Super Admin", out)
        u = User.objects.get(username="superadmin")
        self.assertTrue(u.is_superuser and u.is_staff and u.is_admin)
        self.assertIn("left unchanged", self.run_cmd("seed_superadmin", "--username", "superadmin",
                                                      "--password", "other-pass", "--if-missing"))
        self.assertTrue(User.objects.get(username="superadmin").check_password(STRONG))

    def test_seed_superadmin_skips_quietly_without_a_password_in_the_entrypoint(self):
        with mock.patch.dict("os.environ", {}, clear=False):
            out = self.run_cmd("seed_superadmin", "--username", "superadmin", "--password", "", "--if-missing")
        self.assertIn("not set", out)
        self.assertFalse(User.objects.filter(username="superadmin").exists())
        with self.assertRaises(CommandError):
            self.run_cmd("seed_superadmin", "--username", "superadmin", "--password", "")


class InstructorAndStudentCreationTests(TestCase):
    """The bug: a user created first on the Users page could not become an instructor."""

    def setUp(self):
        self.client.force_login(make_adviser())

    def user_post(self, **over):
        data = {"username": "prof.lim", "first_name": "Ana", "last_name": "Lim", "password": STRONG, "is_active": "on"}
        data.update(over)
        return self.client.post(reverse("portal:users-add"), data)

    def test_user_created_first_as_an_instructor_gets_its_profile_automatically(self):
        self.assertEqual(self.user_post(is_instructor="on").status_code, 204)
        user = User.objects.get(username="prof.lim")
        self.assertTrue(Instructor.objects.filter(user=user).exists())
        html = self.client.get(reverse("portal:instructors-list")).content.decode()
        self.assertIn("prof.lim", html)                       # appears on the Instructors page too

    def test_the_instructor_form_then_gives_a_clear_error_for_a_taken_username(self):
        self.user_post(is_instructor="on")
        res = self.client.post(reverse("portal:instructors-add"), {
            "username": "prof.lim", "first_name": "Ana", "last_name": "Lim", "password": STRONG, "is_active": "on"})
        self.assertEqual(res.status_code, 422)
        self.assertIn("already exists", res.content.decode())
        self.assertEqual(Instructor.objects.filter(user__username="prof.lim").count(), 1)

    def test_creating_an_instructor_directly_works_and_edit_delete_round_trip(self):
        res = self.client.post(reverse("portal:instructors-add"), {
            "username": "prof.santos", "first_name": "Rey", "last_name": "Santos", "password": STRONG, "is_active": "on"})
        self.assertEqual(res.status_code, 204, res.content[:300])
        ins = Instructor.objects.get(user__username="prof.santos")
        self.assertTrue(ins.user.is_instructor and ins.user.check_password(STRONG))
        edit = self.client.post(reverse("portal:instructors-edit", args=[ins.pk]), {
            "username": "prof.santos", "first_name": "Rey", "last_name": "Updated", "is_active": "on"})
        self.assertEqual(edit.status_code, 204)
        ins.user.refresh_from_db()
        self.assertEqual(ins.user.last_name, "Updated")
        self.assertEqual(self.client.post(reverse("portal:instructors-delete", args=[ins.pk])).status_code, 204)
        self.assertFalse(User.objects.filter(username="prof.santos").exists())

    def test_a_failure_while_saving_the_profile_leaves_no_orphan_user(self):
        with mock.patch("accounts.models.Instructor.save", side_effect=RuntimeError("db hiccup")):
            with self.assertRaises(RuntimeError):
                self.client.raise_request_exception = True
                self.client.post(reverse("portal:instructors-add"), {
                    "username": "ghost.user", "first_name": "G", "last_name": "H", "password": STRONG, "is_active": "on"})
        self.assertFalse(User.objects.filter(username="ghost.user").exists())

    def test_students_are_created_with_their_user_in_one_step(self):
        res = self.client.post(reverse("portal:students-add"), {
            "student_number": "2026-0001", "year_level": "1", "section": "A", "username": "2026-0001",
            "first_name": "Maria", "last_name": "Santos", "password": STRONG, "is_active": "on"})
        self.assertEqual(res.status_code, 204, res.content[:300])
        st = Student.objects.get(student_number="2026-0001")
        self.assertTrue(st.user.is_student and st.user.check_password(STRONG))

    def test_a_student_role_on_the_users_page_is_refused_with_guidance(self):
        res = self.user_post(username="fake.student", is_student="on")
        self.assertEqual(res.status_code, 422)
        self.assertIn("student number", res.content.decode())
        self.assertFalse(User.objects.filter(username="fake.student").exists())

    def test_an_existing_student_can_still_be_edited_on_the_users_page(self):
        u = User.objects.create_user("stu1", password="x", is_student=True, first_name="S")
        Student.objects.create(user=u, student_number="N-1")
        res = self.client.post(reverse("portal:users-edit", args=[u.pk]), {
            "username": "stu1", "first_name": "Renamed", "is_student": "on", "is_active": "on"})
        self.assertEqual(res.status_code, 204, res.content[:300])
        u.refresh_from_db()
        self.assertEqual(u.first_name, "Renamed")

    def test_creating_an_instructor_through_the_api_also_creates_the_profile(self):
        api = APIClient()
        api.force_authenticate(User.objects.get(username="adv"))
        res = api.post(reverse("user-list"), {"username": "api.inst", "password": STRONG, "is_instructor": True},
                       format="json")
        self.assertEqual(res.status_code, 201)
        self.assertTrue(Instructor.objects.filter(user__username="api.inst").exists())

    def test_backfill_migration_repairs_instructors_created_without_a_profile(self):
        # Simulate the old behaviour: users flagged instructor but with no profile row.
        orphan = User.objects.bulk_create([User(username="orphan", is_instructor=True)])[0]
        self.assertFalse(Instructor.objects.filter(user__username="orphan").exists())
        migration = importlib.import_module("accounts.migrations.0006_backfill_instructor_profiles")
        migration.backfill(apps, None)
        self.assertTrue(Instructor.objects.filter(user__username="orphan").exists())
        migration.backfill(apps, None)                                # idempotent
        self.assertEqual(Instructor.objects.filter(user__username="orphan").count(), 1)


class InstructorApiCreationTests(TestCase):
    """POST /api/instructors/ creates the user AND the profile exactly once."""

    def test_admin_api_creates_an_instructor_with_one_profile(self):
        api = APIClient()
        api.force_authenticate(make_adviser())
        res = api.post(reverse("instructor-list"), {
            "user": {"username": "api.prof", "password": STRONG, "first_name": "Api", "last_name": "Prof"}},
            format="json")
        self.assertEqual(res.status_code, 201, res.content)
        self.assertEqual(Instructor.objects.filter(user__username="api.prof").count(), 1)
        self.assertTrue(User.objects.get(username="api.prof").is_instructor)
