"""Student sections are a fixed list A-G (free text produced duplicates that broke the filters)."""

import importlib
import io

from django.apps import apps
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from django.urls import reverse

from portal import masterlist

from .models import Student, User

PW = "pw-12345-Xy"


def mk(n, section):
    u = User.objects.create_user(f"u{n}", password=PW, is_student=True, first_name="F", last_name=f"L{n}")
    return Student.objects.create(user=u, student_number=f"N{n}", year_level="1", section=section)


class NormalizeTests(TestCase):
    def test_variants_collapse_to_a_single_letter(self):
        cases = {"A": "A", "a": "A", " b ": "B", "Section C": "C", "1-D": "D", "3A": "A",
                 "bsit 2-g": "G", "Year 1 Section E": "E", "f": "F", "": "", "H": "", "XYZ": "", "A/B": "", "AB": ""}
        for raw, want in cases.items():
            self.assertEqual(Student.normalize_section(raw), want, raw)

    def test_choices_are_exactly_a_to_g(self):
        self.assertEqual([v for v in Student.Section.values if v], list("ABCDEFG"))


class DataMigrationTests(TestCase):
    def test_existing_duplicates_are_cleaned_up(self):
        rows = {1: "A", 2: "a", 3: " A ", 4: "Section B", 5: "1-C", 6: "nonsense", 7: "G", 8: ""}
        students = {n: mk(n, s) for n, s in rows.items()}
        mig = importlib.import_module("accounts.migrations.0007_student_section_choices")
        mig.clean_sections(apps, None)
        got = {n: Student.objects.get(pk=s.pk).section for n, s in students.items()}
        self.assertEqual(got, {1: "A", 2: "A", 3: "A", 4: "B", 5: "C", 6: "", 7: "G", 8: ""})
        self.assertEqual(set(Student.objects.values_list("section", flat=True)) - set("ABCDEFG"), {""})
        mig.clean_sections(apps, None)                                     # idempotent
        self.assertEqual(Student.objects.filter(section="A").count(), 3)


class PortalSectionTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.login(username="adviser", password=PW)

    def test_student_form_offers_a_dropdown_of_a_to_g(self):
        html = self.client.get(reverse("portal:students-add"), HTTP_HX_REQUEST="true").content.decode()
        block = html[html.index('name="section"'):]
        block = block[: block.index("</select>")]
        for letter in "ABCDEFG":
            self.assertIn(f'value="{letter}"', block)
        self.assertNotIn('value="H"', block)
        self.assertNotIn('type="text" name="section"', html)

    def test_form_rejects_a_free_text_section(self):
        r = self.client.post(reverse("portal:students-add"), {
            "student_number": "X-1", "year_level": "1", "section": "Z", "username": "x1",
            "first_name": "A", "last_name": "B", "password": "Tr1cky-Horse-Battery-9!", "is_active": "on"},
            HTTP_HX_REQUEST="true")
        self.assertEqual(r.status_code, 422)
        self.assertFalse(Student.objects.filter(student_number="X-1").exists())

    def test_every_section_filter_lists_a_to_g_without_duplicates(self):
        mk(1, "A")
        for name in ("portal:attendance_logs-list", "portal:fines-list", "portal:students-import"):
            html = self.client.get(reverse(name)).content.decode()
            i = html.index('name="section"')
            block = html[i: html.index("</select>", i)]
            opts = [o for o in __import__("re").findall(r'<option value="([^"]*)"', block) if o]
            self.assertEqual(opts, list("ABCDEFG"), name)

    def test_masterlist_import_normalizes_and_rejects_sections(self):
        csv = ("Student No.,Last Name,First Name,Middle Name,Year Level,Section\\n"
               "1001,Lopez,Ana,,1,a\\n1002,Cruz,Ben,,2,Section C\\n1003,Tan,Cy,,3,Z\\n").encode().decode("unicode_escape")
        rows = masterlist.validate_rows(masterlist.parse_upload(SimpleUploadedFile("m.csv", csv.encode())))
        self.assertEqual([(r["section"], r["status"]) for r in rows[:2]], [("A", "new"), ("C", "new")])
        self.assertEqual(rows[2]["status"], "error")
        self.assertIn("not A-G", rows[2]["message"])
        masterlist.import_rows(rows)
        self.assertEqual(set(Student.objects.values_list("section", flat=True)), {"A", "C"})
        # re-validating a stored preview (the confirm step) keeps the verdicts
        again = masterlist.validate_rows([dict(r) for r in rows if r["status"] == "error"])
        self.assertEqual(again[0]["status"], "error")
