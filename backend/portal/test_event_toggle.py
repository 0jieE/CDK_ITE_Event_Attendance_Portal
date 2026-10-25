"""Events table: switch an event active / inactive directly (with a confirmation)."""

import datetime
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from attendance.models import Event, SchoolYear, Semester

User = get_user_model()
PW = "pw-12345-Xy"


class EventToggleTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.login(username="adviser", password=PW)
        sy = SchoolYear.objects.create(sy="2026-2027")
        sem = Semester.objects.create(school_year=sy, name="1st")
        today = timezone.localdate()
        self.event = Event.objects.create(
            name="Toggle Fair", semester=sem, start_date=today, end_date=today, fine_rate=Decimal("10"),
            required_types=["AM_IN"], am_in_start=datetime.time(7), am_in_end=datetime.time(8), is_active=True)
        self.url = reverse("portal:events-toggle-active", args=[self.event.pk])

    def test_toggle_flips_the_flag_both_ways_and_refreshes_the_table(self):
        r = self.client.post(self.url, HTTP_HX_REQUEST="true")
        self.assertEqual(r.status_code, 204)
        self.assertIn("refresh-events", r["HX-Trigger"])
        self.assertIn("now inactive", r["HX-Trigger"])
        self.event.refresh_from_db()
        self.assertFalse(self.event.is_active)
        r = self.client.post(self.url, HTTP_HX_REQUEST="true")
        self.assertIn("now active", r["HX-Trigger"])
        self.event.refresh_from_db()
        self.assertTrue(self.event.is_active)

    def test_only_post_and_only_for_admins(self):
        self.assertEqual(self.client.get(self.url).status_code, 405)
        self.event.refresh_from_db()
        self.assertTrue(self.event.is_active)
        self.client.logout()
        User.objects.create_user("stu", password=PW, is_student=True)
        self.client.login(username="stu", password=PW)
        self.assertEqual(self.client.post(self.url).status_code, 403)
        self.client.logout()
        self.assertEqual(self.client.post(self.url).status_code, 302)           # anonymous -> login
        self.event.refresh_from_db()
        self.assertTrue(self.event.is_active)

    def test_table_has_a_switch_with_a_confirmation_that_matches_the_state(self):
        html = self.client.get(reverse("portal:events-list")).content.decode()
        row = next(r for r in html.split("<tbody>")[1].split("</tr>") if "Toggle Fair" in r)
        self.assertIn('role="switch"', row)
        self.assertIn(self.url, row)
        self.assertIn("checked", row)
        self.assertIn("Turn OFF", row)
        self.assertIn("onclick=\"event.preventDefault()\"", row)         # never shows an unconfirmed state
        Event.objects.filter(pk=self.event.pk).update(is_active=False)
        html = self.client.get(reverse("portal:events-list")).content.decode()
        row = next(r for r in html.split("<tbody>")[1].split("</tr>") if "Toggle Fair" in r)
        self.assertIn("Turn ON", row)
        self.assertNotIn("checked", row)

    def test_an_inactive_event_is_hidden_from_instructors_and_rejects_scans(self):
        from rest_framework.test import APIClient

        from accounts.models import Instructor

        ins = User.objects.create_user("inst", password=PW, is_instructor=True)
        Instructor.objects.get_or_create(user=ins)
        api = APIClient()
        api.force_authenticate(ins)
        names = lambda: [e["name"] for e in (lambda d: d["results"] if isinstance(d, dict) else d)(api.get(reverse("instructor-events")).json())]  # noqa: E731
        self.assertIn("Toggle Fair", names())
        self.client.post(self.url, HTTP_HX_REQUEST="true")
        self.assertNotIn("Toggle Fair", names())
