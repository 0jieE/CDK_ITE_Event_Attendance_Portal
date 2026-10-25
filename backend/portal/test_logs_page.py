"""Attendance Logs: By Event / By Student tabs, semester filter + active semester, print header."""

import datetime
import re

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from accounts.models import Student
from attendance.models import AttendanceLog, Event, SchoolYear, Semester

User = get_user_model()
PW = "pw-12345-Xy"
T = datetime.time


def mk_event(sem, name, days_ago=0):
    d = timezone.localdate() - datetime.timedelta(days=days_ago)
    return Event.objects.create(
        name=name, semester=sem, start_date=d, end_date=d, fine_rate=10, required_types=["AM_IN"],
        am_in_start=T(7), am_in_end=T(8),
    )


def mk_student(n, section="A"):
    u = User.objects.create_user(f"s{n}", password=PW, is_student=True, first_name=f"First{n}", last_name=f"Last{n}")
    return Student.objects.create(user=u, student_number=f"N-{n}", year_level="1", section=section)


def mk_log(student, event, slot="AM_IN"):
    return AttendanceLog.objects.create(
        student=student, event=event, date=event.start_date, attendance_type=slot,
        status="PRESENT", scanned_at=timezone.now(),
    )


def table_headers(html):
    head = html[html.index("<thead>"): html.index("</thead>")]
    return [re.sub(r"<[^>]+>", "", c).strip().replace("&amp;", "&")
            for c in re.findall(r"<th[^>]*>.*?</th>", head, re.S)]


class ActiveSemesterTests(TestCase):
    def setUp(self):
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.s1 = Semester.objects.create(school_year=sy, name="1st")
        self.s2 = Semester.objects.create(school_year=sy, name="2nd")

    def test_only_one_semester_is_active(self):
        self.s1.is_active = True
        self.s1.save()
        self.s2.is_active = True
        self.s2.save()
        self.s1.refresh_from_db()
        self.assertFalse(self.s1.is_active)
        self.assertEqual(Semester.current(), self.s2)
        self.assertEqual(Semester.objects.filter(is_active=True).count(), 1)

    def test_migration_activates_the_semester_of_the_latest_event(self):
        import importlib

        from django.apps import apps

        Semester.objects.update(is_active=False)            # as on a database that predates the flag
        mk_event(self.s1, "Old", days_ago=40)
        mk_event(self.s2, "New", days_ago=1)
        importlib.import_module("attendance.migrations.0005_semester_is_active").activate_latest(apps, None)
        self.assertEqual(Semester.current(), self.s2)


class LogsPageTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.force_login(User.objects.get(username="adviser"))
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.old = Semester.objects.create(school_year=sy, name="1st")
        self.cur = Semester.objects.create(school_year=sy, name="2nd", is_active=True)
        self.e_old = mk_event(self.old, "Old Seminar", days_ago=60)
        self.e1 = mk_event(self.cur, "Current Fair", days_ago=1)
        mk_event(self.cur, "Upcoming Gala", days_ago=-10)             # future: not the default
        self.e2 = mk_event(self.cur, "Current Run", days_ago=3)
        self.a, self.b = mk_student(1, "A"), mk_student(2, "B")
        mk_log(self.a, self.e1)
        mk_log(self.b, self.e1)
        mk_log(self.a, self.e2)
        mk_log(self.a, self.e_old)

    url = staticmethod(lambda: reverse("portal:attendance_logs-list"))

    def test_by_event_defaults_to_the_active_semester_and_its_latest_event(self):
        html = self.client.get(self.url()).content.decode()
        self.assertEqual(table_headers(html), ["Student", "Year & Section", "Date", "Type", "Scanned At", "Scanned By"])
        self.assertIn("Current Fair", html)                 # latest event of the active semester
        self.assertNotIn("Old Seminar", html)               # other semester is not listed
        self.assertIn("(active)", html)
        self.assertEqual(html.count("N-1 &mdash;") + html.count("N-1 —"), 1)
        self.assertEqual(html.count("N-2 &mdash;") + html.count("N-2 —"), 1)

    def test_by_event_has_no_student_filter_and_no_event_column(self):
        html = self.client.get(self.url()).content.decode()
        self.assertNotIn('name="student"', html)
        self.assertNotIn("<th>Event</th>", html)
        self.assertNotIn("Status", table_headers(html))
        for removed in ('name="year_level"', 'name="date_from"', 'name="date_to"', 'name="status"'):
            self.assertNotIn(removed, html)

    def test_by_event_filters(self):
        html = self.client.get(self.url(), {"semester": self.cur.pk, "event": self.e2.pk, "section": "B"}).content.decode()
        self.assertNotIn("N-1 &mdash;", html)               # event 2 only has student 1 in section A
        self.assertNotIn("N-2 &mdash;", html)

    def test_semester_filter_switches_and_all_semesters_works(self):
        html = self.client.get(self.url(), {"semester": self.old.pk}).content.decode()
        self.assertIn("Old Seminar", html)
        html = self.client.get(self.url(), {"semester": ""}).content.decode()
        self.assertIn("Old Seminar", html)
        self.assertIn("Current Fair", html)

    def test_by_student_tab(self):
        r = self.client.get(self.url(), {"tab": "student"})
        self.assertContains(r, "Select a")
        html = self.client.get(self.url(), {"tab": "student", "student": self.a.pk}).content.decode()
        self.assertEqual(table_headers(html), ["Event", "Date", "Type", "Scanned At", "Scanned By"])
        self.assertIn("Current Fair", html)
        self.assertIn("Current Run", html)
        self.assertNotIn("Old Seminar", html)               # default = active semester
        self.assertIn('name="student"', html)
        self.assertIn('name="event"', html)                 # event filter kept
        html = self.client.get(self.url(), {"tab": "student", "student": self.a.pk, "event": self.e2.pk}).content.decode()
        self.assertIn("Current Run", html.split("<tbody>")[1])
        self.assertNotIn("Current Fair", html.split("<tbody>")[1])

    def test_print_header_names_the_event_or_the_student_with_the_logo(self):
        html = self.client.get(self.url()).content.decode()
        head = html[html.index('class="print-head"'):]
        head = head[: head.index("</div>\n    </div>")]
        self.assertIn("ite-logo", head)
        self.assertIn("Current Fair", head)
        html = self.client.get(self.url(), {"tab": "student", "student": self.a.pk}).content.decode()
        head = html[html.index('class="print-head"'):]
        self.assertIn("First1 Last1", head[:700])
        self.assertIn("ite-logo", head[:700])

    def test_csv_columns_follow_the_tab(self):
        r = self.client.get(self.url(), {"format": "csv"})
        header = r.content.decode().splitlines()[0]
        self.assertEqual(header, "Student No.,Student,Year & Section,Date,Type,Scanned At,Scanned By")
        self.assertIn("N-1", r.content.decode())
        r = self.client.get(self.url(), {"format": "csv", "tab": "student", "student": self.a.pk})
        self.assertEqual(r.content.decode().splitlines()[0], "Event,Date,Type,Scanned At,Scanned By")
        self.assertIn("Current Fair", r.content.decode())
        self.assertNotIn("Old Seminar", r.content.decode())


class SemesterManagementTests(TestCase):
    def setUp(self):
        self.adv = User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.force_login(self.adv)
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.s1 = Semester.objects.create(school_year=sy, name="1st", is_active=True)
        self.s2 = Semester.objects.create(school_year=sy, name="2nd")

    def test_set_active_works_even_when_the_semester_has_events(self):
        mk_event(self.s2, "Locked Fair")                    # events lock edit/delete for advisers...
        r = self.client.post(reverse("portal:semesters-activate", args=[self.s2.pk]), HTTP_HX_REQUEST="true")
        self.assertEqual(r.status_code, 204)                # ...but not switching the active semester
        self.assertEqual(Semester.current(), self.s2)

    def test_terms_table_shows_active_badge_and_set_active_button(self):
        html = self.client.get(reverse("portal:terms-list")).content.decode()
        self.assertIn("Active</span>", html)
        self.assertIn(reverse("portal:semesters-activate", args=[self.s2.pk]), html)
        self.assertNotIn(reverse("portal:semesters-activate", args=[self.s1.pk]), html)

    def test_new_events_default_to_the_active_semester(self):
        r = self.client.get(reverse("portal:events-add"), HTTP_HX_REQUEST="true")
        html = r.content.decode()
        m = re.search(r'<option value="(\d+)" selected>', html[html.index('name="semester"'):])
        self.assertEqual(m.group(1), str(self.s1.pk))

    def test_semester_form_has_the_active_switch_and_api_patch_is_allowed_when_locked(self):
        from rest_framework.test import APIClient

        self.assertContains(self.client.get(reverse("portal:semesters-add"), HTTP_HX_REQUEST="true"), 'name="is_active"')
        mk_event(self.s2, "Locked Fair")
        api = APIClient()
        api.force_authenticate(self.adv)
        r = api.patch(f"/api/semesters/{self.s2.pk}/", {"is_active": True}, format="json"); self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(api.patch(f"/api/semesters/{self.s2.pk}/", {"name": "Summer"}, format="json").status_code, 403)
        self.assertEqual(Semester.current(), self.s2)


class SemesterFormActivationTests(TestCase):
    def test_portal_form_can_activate_a_semester_while_another_is_active(self):
        User.objects.create_user("adviser", password=PW, is_admin=True)
        c = self.client
        c.login(username="adviser", password=PW)
        sy = SchoolYear.objects.create(sy="2026-2027")
        first = Semester.objects.create(school_year=sy, name="1st", is_active=True)
        r = c.post(reverse("portal:semesters-add"),
                   {"school_year": sy.pk, "name": "2nd", "is_active": "on"}, HTTP_HX_REQUEST="true")
        self.assertEqual(r.status_code, 204, r.content[:300])
        first.refresh_from_db()
        self.assertFalse(first.is_active)
        self.assertEqual(Semester.current().name, "2nd")


class PrintLayoutTests(TestCase):
    """Reports and logs print with a logo header and tables that fit the page."""

    def setUp(self):
        User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.login(username="adviser", password=PW)
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.sem = Semester.objects.create(school_year=sy, name="1st")
        self.event = mk_event(self.sem, "Print Fair")

    def test_reports_have_a_printed_header_with_the_filters(self):
        for name, title in (("portal:reports-attendance", "Attendance Report"),
                            ("portal:reports-financial", "Financial Report")):
            html = self.client.get(reverse(name), {"semester": self.sem.pk, "event": self.event.pk}).content.decode()
            head = html[html.index('class="print-head"'):]
            head = head[: head.index("Printed")]
            self.assertIn("ite-logo", head)
            self.assertIn(title, head)
            self.assertIn("2026-2027 1st", head)
            self.assertIn("Print Fair", head)
            self.assertIn('class="page-head no-print"', html)           # no duplicate on-screen title in print
        html = self.client.get(reverse("portal:reports-financial"), {"semester": "x", "event": "y"}).content.decode()
        self.assertIn("All semesters", html)                             # junk filters never crash

    def test_print_css_fits_tables_to_the_page(self):
        html = self.client.get(reverse("portal:reports-attendance")).content.decode()
        for rule in ("@page { size: A4; margin: 12mm; }", "table-layout: auto", "table-header-group",
                     "overflow: visible !important; margin: 0 !important"):
            self.assertIn(rule, html)

    def test_log_rows_keep_dates_on_one_line(self):
        mk_log(mk_student(1), self.event)
        html = self.client.get(reverse("portal:attendance_logs-list")).content.decode()
        self.assertGreaterEqual(html.count('class="text-nowrap"'), 3)
