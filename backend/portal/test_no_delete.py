"""Records that already hold attendance / fine payments can be edited but never deleted."""

import datetime
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from attendance import services
from attendance.models import AttendanceLog, Event, Fine, SchoolYear, Semester
from attendance.tests import make_student

User = get_user_model()
PW = "pw-12345-Xy"
D = datetime.timedelta


def mk_event(sem, name):
    day = timezone.localdate() - D(days=1)
    return Event.objects.create(
        name=name, semester=sem, start_date=day, end_date=day, fine_rate=Decimal("10"),
        required_types=["AM_IN"], am_in_start=datetime.time(0, 0), am_in_end=datetime.time(0, 1))


class NoDeleteTests(TestCase):
    def setUp(self):
        self.adv = User.objects.create_user("adviser", password=PW, is_admin=True)
        self.boss = User.objects.create_user("boss", password=PW, is_admin=True, is_staff=True, is_superuser=True)
        self.sy_used = SchoolYear.objects.create(sy="2026-2027")
        self.sem_used = Semester.objects.create(school_year=self.sy_used, name="1st")
        self.sem_empty = Semester.objects.create(school_year=self.sy_used, name="2nd")
        self.sy_free = SchoolYear.objects.create(sy="2030-2031")
        self.sem_free = Semester.objects.create(school_year=self.sy_free, name="1st")
        self.student = make_student("s1", "S-1")
        self.with_logs = mk_event(self.sem_used, "Has Attendance")
        AttendanceLog.objects.create(student=self.student, event=self.with_logs, date=self.with_logs.start_date,
                                     attendance_type="AM_IN", status="PRESENT", scanned_at=timezone.now())
        self.plain = mk_event(self.sem_empty, "Plain Event")                    # no attendance, no payments
        self.paid_only = mk_event(self.sem_empty, "Paid Only")
        services.compute_fines_for_event(self.paid_only)
        services.pay_slots(Fine.objects.get(event=self.paid_only))

    def post(self, user, name, pk):
        self.client.force_login(user)
        return self.client.post(reverse(name, args=[pk]), HTTP_HX_REQUEST="true")

    # ---- events
    def test_event_with_attendance_cannot_be_deleted_by_anyone(self):
        for user in (self.adv, self.boss):
            r = self.post(user, "portal:events-delete", self.with_logs.pk)
            self.assertIn("error", r["HX-Trigger"])
            self.assertIn("attendance records", r["HX-Trigger"])
            self.assertTrue(Event.objects.filter(pk=self.with_logs.pk).exists())

    def test_event_with_fine_payments_cannot_be_deleted_but_a_plain_one_can(self):
        self.post(self.adv, "portal:events-delete", self.paid_only.pk)
        self.assertTrue(Event.objects.filter(pk=self.paid_only.pk).exists())
        r = self.post(self.adv, "portal:events-delete", self.plain.pk)
        self.assertEqual(r.status_code, 204)
        self.assertNotIn("error", r["HX-Trigger"])
        self.assertFalse(Event.objects.filter(pk=self.plain.pk).exists())

    def test_events_table_shows_a_lock_instead_of_the_delete_button(self):
        self.client.force_login(self.adv)
        html = self.client.get(reverse("portal:events-list")).content.decode()
        rows = html.split("<tbody>")[1].split("</tr>")
        used = next(r for r in rows if "Has Attendance" in r)
        free = next(r for r in rows if "Plain Event" in r)
        self.assertNotIn(reverse("portal:events-delete", args=[self.with_logs.pk]), used)
        self.assertIn("bi-lock", used)
        self.assertIn(reverse("portal:events-edit", args=[self.with_logs.pk]), used)      # still editable
        self.assertIn(reverse("portal:events-delete", args=[self.plain.pk]), free)

    def test_events_api(self):
        for user in (self.adv, self.boss):
            api = APIClient()
            api.force_authenticate(user)
            self.assertEqual(api.delete(f"/api/events/{self.with_logs.pk}/").status_code, 403)
            self.assertEqual(api.patch(f"/api/events/{self.with_logs.pk}/", {"name": "Renamed"}, format="json").status_code, 200)
        self.with_logs.refresh_from_db()
        self.assertEqual(self.with_logs.name, "Renamed")
        api = APIClient()
        api.force_authenticate(self.adv)
        self.assertEqual(api.delete(f"/api/events/{self.plain.pk}/").status_code, 204)

    # ---- semesters and school years
    def test_semester_and_year_with_attendance_cannot_be_deleted_even_by_the_super_admin(self):
        self.post(self.boss, "portal:semesters-delete", self.sem_used.pk)
        self.post(self.boss, "portal:school_years-delete", self.sy_used.pk)
        self.assertTrue(Semester.objects.filter(pk=self.sem_used.pk).exists())
        self.assertTrue(SchoolYear.objects.filter(pk=self.sy_used.pk).exists())
        # the other semester of that year holds a paid fine (event "Paid Only") -> also protected
        self.post(self.boss, "portal:semesters-delete", self.sem_empty.pk)
        self.assertTrue(Semester.objects.filter(pk=self.sem_empty.pk).exists())

    def test_terms_page_hides_delete_but_keeps_edit_for_the_super_admin(self):
        self.client.force_login(self.boss)
        html = self.client.get(reverse("portal:terms-list")).content.decode()
        self.assertNotIn(reverse("portal:semesters-delete", args=[self.sem_used.pk]), html)
        self.assertNotIn(reverse("portal:school_years-delete", args=[self.sy_used.pk]), html)
        self.assertIn(reverse("portal:semesters-edit", args=[self.sem_used.pk]), html)
        self.assertIn(reverse("portal:school_years-edit", args=[self.sy_used.pk]), html)
        self.assertIn("delete", html.lower())
        # an unused year / semester can still be deleted
        self.assertIn(reverse("portal:semesters-delete", args=[self.sem_free.pk]), html)
        self.assertIn(reverse("portal:school_years-delete", args=[self.sy_free.pk]), html)

    def test_unused_semester_and_year_are_still_deletable(self):
        self.post(self.boss, "portal:semesters-delete", self.sem_free.pk)
        self.post(self.boss, "portal:school_years-delete", self.sy_free.pk)
        self.assertFalse(Semester.objects.filter(pk=self.sem_free.pk).exists())
        self.assertFalse(SchoolYear.objects.filter(pk=self.sy_free.pk).exists())

    def test_semester_api_delete_is_refused_for_everyone(self):
        api = APIClient()
        api.force_authenticate(self.boss)
        self.assertEqual(api.delete(f"/api/semesters/{self.sem_used.pk}/").status_code, 403)
        self.assertEqual(api.delete(f"/api/school-years/{self.sy_used.pk}/").status_code, 403)
        self.assertEqual(api.patch(f"/api/school-years/{self.sy_used.pk}/", {"sy": "2026-2028"}, format="json").status_code, 200)

    # ---- Django administration
    def test_django_admin_does_not_offer_deleting_them_either(self):
        self.client.force_login(self.boss)
        page = self.client.get(reverse("admin:attendance_event_change", args=[self.with_logs.pk]))
        self.assertEqual(page.status_code, 200)
        self.assertNotContains(page, "deletelink")
        self.assertEqual(self.client.get(reverse("admin:attendance_event_delete", args=[self.with_logs.pk])).status_code, 403)
        free = self.client.get(reverse("admin:attendance_event_change", args=[self.plain.pk]))
        self.assertContains(free, "deletelink")
        listing = self.client.get(reverse("admin:attendance_event_changelist"))
        self.assertNotContains(listing, 'value="delete_selected"')
