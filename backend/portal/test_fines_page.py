"""Fines page: semester filter, searchable student picker, statement and print header."""

import datetime
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from attendance import services
from attendance.models import Event, Fine, SchoolYear, Semester
from attendance.tests import make_student

User = get_user_model()
D = datetime.timedelta


def mk_event(sem, name, rate):
    day = timezone.localdate() - D(days=1)
    return Event.objects.create(
        name=name, semester=sem, start_date=day, end_date=day, fine_rate=Decimal(rate),
        required_types=["AM_IN"], am_in_start=datetime.time(0, 0), am_in_end=datetime.time(0, 1))


class FinesPageTests(TestCase):
    def setUp(self):
        cache.clear()
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.old = Semester.objects.create(school_year=sy, name="1st")
        self.cur = Semester.objects.create(school_year=sy, name="2nd", is_active=True)
        self.e_old = mk_event(self.old, "Old Fair", "100")
        self.e_cur = mk_event(self.cur, "Current Fair", "10")
        self.s1 = make_student("s1", "S-1")
        self.s2 = make_student("s2", "S-2")
        services.compute_fines_for_event(self.e_old)
        services.compute_fines_for_event(self.e_cur)
        User.objects.create_user("adviser", password="pw-12345-Xy", is_admin=True)
        self.client.login(username="adviser", password="pw-12345-Xy")
        self.url = reverse("portal:fines-list")

    def ledger(self, **params):
        return self.client.get(self.url, params).content.decode()

    def test_ledger_defaults_to_the_active_semester(self):
        html = self.ledger()
        self.assertIn("(active)", html)
        body = html.split("<tbody>")[1]
        self.assertIn("Current Fair", body)
        self.assertNotIn("Old Fair", body)
        self.assertIn("Old Fair", self.ledger(semester=self.old.pk).split("<tbody>")[1])
        both = self.ledger(semester="").split("<tbody>")[1]
        self.assertIn("Old Fair", both)
        self.assertIn("Current Fair", both)

    def test_event_choices_follow_the_semester_and_foreign_events_are_ignored(self):
        html = self.ledger()
        select = html[html.index('name="event"'): html.index("</select>", html.index('name="event"'))]
        self.assertIn("Current Fair", select)
        self.assertNotIn("Old Fair", select)
        body = self.ledger(event=self.e_old.pk).split("<tbody>")[1]        # not in the active semester
        self.assertIn("Current Fair", body)
        self.assertNotIn("Old Fair", body)
        self.assertEqual(self.client.get(self.url, {"event": "junk", "semester": "x", "status": "zzz"}).status_code, 200)

    def test_print_header_names_the_filters(self):
        html = self.ledger(event=self.e_cur.pk, status="UNPAID")
        head = html[html.index('class="print-head"'):]
        head = head[: head.index("Printed")]
        self.assertIn("ite-logo", head)
        self.assertIn("Fines — Current Fair", head)
        self.assertIn("2026-2027 2nd", head)
        self.assertIn("Unpaid", head)
        self.assertIn("window.print()", html)

    def test_student_picker_is_searchable(self):
        html = self.ledger(view="student")
        i = html.index('name="student"')
        self.assertIn("searchable-select", html[i - 120: i + 160])
        self.assertIn("tom-select", html)

    def test_by_student_statement_across_events(self):
        html = self.ledger(view="student", student=self.s1.pk)
        self.assertIn("Current Fair", html)
        self.assertNotIn("Old Fair", html)                    # active semester only
        self.assertIn("<tfoot>", html)
        self.assertIn("₱10.00", html)
        head = html[html.index('class="print-head"'):]
        self.assertIn("First", head[:600].replace("S1", "First"))  # student name is the print title
        self.assertIn("S-1", head[:900])
        both = self.ledger(view="student", student=self.s1.pk, semester="")
        self.assertIn("Old Fair", both)
        self.assertIn("₱110.00", both)                        # statement total over both semesters

    def test_statement_reflects_payments_and_empty_state(self):
        fine = Fine.objects.get(student=self.s1, event=self.e_cur)
        fine.mark_paid(recorded_by=User.objects.get(username="adviser"))
        html = self.ledger(view="student", student=self.s1.pk)
        self.assertIn("Paid", html.split("<tbody>")[1])
        empty = make_student("s3", "S-3")
        self.assertIn("No fines for this student", self.ledger(view="student", student=empty.pk))
        self.assertIn("Search and select", self.ledger(view="student"))

    def test_day_by_day_view_still_works_for_one_event(self):
        html = self.ledger(view="student", student=self.s1.pk, event=self.e_cur.pk)
        self.assertIn("Pay ₱10.00", html)
        self.assertNotIn("<tfoot>", html)

    def test_logs_student_picker_is_searchable_too(self):
        html = self.client.get(reverse("portal:attendance_logs-list"), {"tab": "student"}).content.decode()
        i = html.index('name="student"')
        self.assertIn("searchable-select", html[i - 120: i + 160])

    def test_printed_grid_shows_the_rate_in_each_missed_cell_and_has_no_legend(self):
        html = self.ledger(view="student", student=self.s1.pk, event=self.e_cur.pk)
        self.assertIn('<span class="print-only small">₱10.00</span>', html)
        legend = html[html.index("= missed required slot"):]
        self.assertIn("mt-2 mb-0 no-print", html[html.index("= missed required slot") - 400: html.index("= missed required slot")])
        services.pay_slots(Fine.objects.get(student=self.s1, event=self.e_cur), slots=None)
        html = self.ledger(view="student", student=self.s1.pk, event=self.e_cur.pk)
        self.assertIn('title="₱10.00 paid">Paid</span>', html)
        self.assertIn('<span class="print-only small">₱10.00</span>', html)       # paid cells keep the rate too
