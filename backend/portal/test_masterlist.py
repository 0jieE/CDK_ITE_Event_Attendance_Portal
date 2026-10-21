import io

from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from django.urls import reverse
from openpyxl import Workbook, load_workbook

from accounts.models import Student
from portal import masterlist

User = get_user_model()

CSV = (
    "Student No.,Last Name,First Name,Middle Name,Year Level,Section\n"
    "2024-0001,Dela Cruz,Juan,Santos,1st Year,A\n"
    "2024-0002,Reyes,Maria,,2,B\n"
    ",NoNumber,Ana,,1,A\n"
    "2024-0001,Dup,Juan,,1,A\n"
    "2024-0003,Lim,Bob,,9,A\n"
)


def _upload(name, data):
    return SimpleUploadedFile(name, data)


class MasterlistParsingTests(TestCase):
    def test_csv_validation_flags_each_problem(self):
        rows = masterlist.validate_rows(masterlist.parse_upload(_upload("m.csv", CSV.encode())))
        status = [r["status"] for r in rows]
        self.assertEqual(status, ["new", "new", "error", "error", "error"])
        self.assertEqual(rows[0]["year_level"], "1")
        self.assertIn("Duplicate", rows[3]["message"])
        self.assertIn("not 1-4", rows[4]["message"])

    def test_xlsx_and_numeric_cells(self):
        wb = Workbook()
        ws = wb.active
        ws.append(masterlist.COLUMNS)
        ws.append([20240005, "Tan", "Eve", None, 3, "C"])
        buf = io.BytesIO()
        wb.save(buf)
        rows = masterlist.validate_rows(masterlist.parse_upload(_upload("m.xlsx", buf.getvalue())))
        self.assertEqual(rows[0]["student_number"], "20240005")
        self.assertEqual(rows[0]["year_level"], "3")
        self.assertEqual(rows[0]["status"], "new")

    def test_missing_columns_and_bad_type(self):
        with self.assertRaises(masterlist.MasterlistError):
            masterlist.parse_upload(_upload("m.csv", b"Foo,Bar\n1,2\n"))
        with self.assertRaises(masterlist.MasterlistError):
            masterlist.parse_upload(_upload("m.pdf", b"x"))

    def test_templates_round_trip(self):
        self.assertIn("Student No.", masterlist.template_csv_bytes().decode("utf-8-sig"))
        wb = load_workbook(io.BytesIO(masterlist.template_xlsx_bytes()))
        self.assertEqual([c.value for c in wb["Masterlist"][1]], masterlist.COLUMNS)

    def test_import_creates_accounts_that_can_log_in_and_skips_existing(self):
        rows = masterlist.validate_rows(masterlist.parse_upload(_upload("m.csv", CSV.encode())))
        creds = masterlist.import_rows(rows)
        self.assertEqual(len(creds), 2)
        user = User.objects.get(username="2024-0001")
        self.assertTrue(user.is_student)
        self.assertTrue(user.check_password(creds[0]["password"]))
        self.assertEqual(Student.objects.get(user=user).year_level, "1")
        # second pass: both now exist
        again = masterlist.validate_rows(masterlist.parse_upload(_upload("m.csv", CSV.encode())))
        self.assertEqual(masterlist.summarize(again)["exists"], 2)
        self.assertEqual(masterlist.import_rows(again), [])


class MasterlistPortalTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password="pw-12345-x", is_admin=True)
        self.client.login(username="adviser", password="pw-12345-x")

    def test_pages_and_templates_load(self):
        for name in ("students-import", "students-credentials"):
            self.assertEqual(self.client.get(reverse(f"portal:{name}")).status_code, 200)
        for fmt in ("csv", "xlsx"):
            r = self.client.get(reverse("portal:students-import-template", args=[fmt]))
            self.assertEqual(r.status_code, 200)
            self.assertIn("attachment", r["Content-Disposition"])
        self.assertEqual(self.client.get(reverse("portal:students-import-template", args=["pdf"])).status_code, 404)
        self.assertContains(self.client.get(reverse("portal:students-list")), "Import masterlist")

    def test_preview_confirm_print_and_csv(self):
        r = self.client.post(reverse("portal:students-import"),
                             {"action": "preview", "file": _upload("m.csv", CSV.encode())})
        self.assertContains(r, "2 new")
        self.assertEqual(Student.objects.count(), 0, list(Student.objects.values_list("student_number", flat=True)))
        r = self.client.post(reverse("portal:students-import"), {"action": "confirm"}, follow=True)
        self.assertEqual(Student.objects.count(), 2, list(Student.objects.values_list("student_number", flat=True)))
        self.assertContains(r, "Dela Cruz")
        self.assertContains(r, "Password")
        csv_resp = self.client.get(reverse("portal:students-credentials") + "?format=csv")
        self.assertIn("2024-0002", csv_resp.content.decode())
        self.client.post(reverse("portal:students-credentials") + "?clear=1")
        self.assertNotContains(self.client.get(reverse("portal:students-credentials")), "Dela Cruz")

    def test_bulk_reset_changes_passwords_for_the_filter_only(self):
        a = User.objects.create_user("s1", password="old-pass-1", is_student=True)
        b = User.objects.create_user("s2", password="old-pass-2", is_student=True)
        Student.objects.create(user=a, student_number="s1", year_level="1", section="A")
        Student.objects.create(user=b, student_number="s2", year_level="2", section="A")
        url = reverse("portal:students-credentials-reset")
        self.client.post(url, {"year_level": "1"})                  # no confirmation -> nothing
        a.refresh_from_db()
        self.assertTrue(a.check_password("old-pass-1"))
        r = self.client.post(url, {"year_level": "1", "confirm": "yes"}, follow=True)
        a.refresh_from_db(); b.refresh_from_db()
        self.assertFalse(a.check_password("old-pass-1"))
        self.assertTrue(b.check_password("old-pass-2"))
        self.assertContains(r, "s1")

    def test_non_admin_is_refused(self):
        self.client.logout()
        User.objects.create_user("stu", password="pw-12345-x", is_student=True)
        self.client.login(username="stu", password="pw-12345-x")
        self.assertEqual(self.client.get(reverse("portal:students-import")).status_code, 403)


class LogsAndNavTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password="pw-12345-x", is_admin=True)
        self.client.login(username="adviser", password="pw-12345-x")

    def test_logs_csv_download(self):
        r = self.client.get(reverse("portal:attendance_logs-list") + "?format=csv")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Type"], "text/csv")
        self.assertIn("Student No.", r.content.decode())

    def test_logs_page_has_download_and_print(self):
        r = self.client.get(reverse("portal:attendance_logs-list"))
        self.assertContains(r, "Download CSV")
        self.assertContains(r, "window.print()")

    def test_nav_groups(self):
        from portal.context import sidebar_nav

        nav = {i["label"]: i for i in sidebar_nav(None)["nav_items"]}
        self.assertEqual([c["label"] for c in nav["Reports"]["children"]],
                         ["Attendance Report", "Attendance Logs", "Financial Report", "Fines"])
        self.assertEqual([c["label"] for c in nav["Settings"]["children"]],
                         ["Appearance", "School Years & Semesters"])
        self.assertNotIn("School Years", nav)


class TermsPageTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password="pw-12345-x", is_admin=True)
        self.client.login(username="adviser", password="pw-12345-x")

    def test_one_page_two_add_buttons_nested_rows(self):
        from attendance.models import SchoolYear, Semester

        sy = SchoolYear.objects.create(sy="2030-2031")
        Semester.objects.create(school_year=sy, name="1st")
        SchoolYear.objects.create(sy="2029-2030")
        r = self.client.get(reverse("portal:terms-list"))
        self.assertContains(r, "Add School Year")
        self.assertContains(r, "Add Semester")
        html = r.content.decode()
        # one flat row per semester: school year and semester in the same <tr>
        self.assertRegex(html, r"(?s)<tr>\s*<td>\s*2030-2031.*?</td>\s*<td>1st Semester</td>")
        self.assertIn("2029-2030", html)             # a year without semesters still has a row
        self.assertIn("No semester yet", html)
        # the old list URLs show the same combined page; the table fragment refreshes via HTMX
        self.assertContains(self.client.get(reverse("portal:semesters-list")), "Add School Year")
        part = self.client.get(reverse("portal:terms-list") + "?partial=table", HTTP_HX_REQUEST="true")
        self.assertNotContains(part, "<html")
        self.assertContains(part, "1st Semester")

    def test_add_forms_still_work(self):
        r = self.client.post(reverse("portal:school_years-add"), {"sy": "2031-2032"}, HTTP_HX_REQUEST="true")
        self.assertEqual(r.status_code, 204, r.content[:200])
        from attendance.models import SchoolYear
        sy = SchoolYear.objects.get(sy="2031-2032")
        r = self.client.post(reverse("portal:semesters-add"), {"school_year": sy.pk, "name": "2nd"}, HTTP_HX_REQUEST="true")
        self.assertEqual(r.status_code, 204, r.content[:200])
        self.assertEqual(sy.semesters.count(), 1)


class TermsLockedWhenUsedTests(TestCase):
    """Once an event exists, only the Super Admin can edit/delete its school year / semester."""

    def setUp(self):
        from attendance.models import SchoolYear, Semester
        from attendance.tests import make_event

        self.adv = User.objects.create_user("adviser", password="pw-12345-x", is_admin=True)
        self.boss = User.objects.create_user("boss", password="pw-12345-x", is_admin=True,
                                             is_superuser=True, is_staff=True)
        self.event = make_event()                       # creates 2025-2026 / 1st with one event
        self.sem = self.event.semester
        self.sy = self.sem.school_year
        self.free_sy = SchoolYear.objects.create(sy="2099-2100")
        self.free_sem = Semester.objects.create(school_year=self.free_sy, name="2nd")

    def _urls(self):
        return {
            "sem_edit": reverse("portal:semesters-edit", args=[self.sem.pk]),
            "sem_del": reverse("portal:semesters-delete", args=[self.sem.pk]),
            "sy_edit": reverse("portal:school_years-edit", args=[self.sy.pk]),
            "sy_del": reverse("portal:school_years-delete", args=[self.sy.pk]),
        }

    def test_buttons_hidden_for_adviser_but_shown_for_super_admin(self):
        u = self._urls()
        self.client.force_login(self.adv)
        html = self.client.get(reverse("portal:terms-list")).content.decode()
        for key in u.values():
            self.assertNotIn(key, html)
        self.assertIn("Locked", html)
        # a school year / semester without events stays editable
        self.assertIn(reverse("portal:semesters-edit", args=[self.free_sem.pk]), html)
        self.assertIn(reverse("portal:school_years-edit", args=[self.free_sy.pk]), html)
        self.client.force_login(self.boss)
        html = self.client.get(reverse("portal:terms-list")).content.decode()
        for key in u.values():
            self.assertIn(key, html)

    def test_adviser_is_refused_server_side(self):
        from attendance.models import SchoolYear, Semester

        u = self._urls()
        self.client.force_login(self.adv)
        for name in ("sem_edit", "sy_edit"):
            r = self.client.get(u[name], HTTP_HX_REQUEST="true")
            self.assertEqual(r.status_code, 204)
            self.assertIn("Super Admin", r["HX-Trigger"])
        self.client.post(u["sem_del"], HTTP_HX_REQUEST="true")
        self.client.post(u["sy_del"], HTTP_HX_REQUEST="true")
        self.client.post(u["sy_edit"], {"sy": "1999-2000"}, HTTP_HX_REQUEST="true")
        self.assertTrue(Semester.objects.filter(pk=self.sem.pk).exists())
        self.assertEqual(SchoolYear.objects.get(pk=self.sy.pk).sy, "2025-2026")
        # unlocked records can still be deleted by the adviser
        self.assertEqual(self.client.post(reverse("portal:semesters-delete", args=[self.free_sem.pk]),
                                          HTTP_HX_REQUEST="true").status_code, 204)
        self.assertFalse(Semester.objects.filter(pk=self.free_sem.pk).exists())

    def test_api_blocks_adviser_but_not_super_admin(self):
        from rest_framework.test import APIClient

        api = APIClient()
        api.force_authenticate(self.adv)
        self.assertEqual(api.patch(f"/api/school-years/{self.sy.pk}/", {"sy": "1999-2000"}, format="json").status_code, 403)
        self.assertEqual(api.delete(f"/api/semesters/{self.sem.pk}/").status_code, 403)
        self.assertEqual(api.delete(f"/api/semesters/{self.free_sem.pk}/").status_code, 204)
        sup = APIClient()
        sup.force_authenticate(self.boss)
        self.assertEqual(sup.patch(f"/api/school-years/{self.sy.pk}/", {"sy": "1999-2000"}, format="json").status_code, 200)

    def test_super_admin_can_still_delete_through_the_portal(self):
        from attendance.models import Semester

        self.client.force_login(self.boss)
        r = self.client.post(self._urls()["sem_del"], HTTP_HX_REQUEST="true")
        self.assertEqual(r.status_code, 204)
        self.assertFalse(Semester.objects.filter(pk=self.sem.pk).exists())
