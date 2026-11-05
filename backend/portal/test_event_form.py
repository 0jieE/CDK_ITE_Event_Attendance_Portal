"""Event form: the start date suggests today (never earlier) and scan windows are AM / PM aware."""

import datetime
import re

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from attendance.models import Event, SchoolYear, Semester

from .forms import SlotTimeWidget

DAY = datetime.timedelta(days=1)


class EventFormTestBase(TestCase):
    def setUp(self):
        adv = get_user_model().objects.create_user("advf", password="x", is_admin=True, is_staff=True)
        self.client.force_login(adv)
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.sem = Semester.objects.create(school_year=sy, name="1st")
        self.today = timezone.localdate()

    def post(self, url=None, **over):
        data = {"name": "Form test", "semester": self.sem.pk, "start_date": self.today.isoformat(),
                "end_date": self.today.isoformat(), "fine_rate": "10", "is_active": "on",
                "required_types": ["AM_IN"], "am_in_start": "06:00", "am_in_end": "07:30"}
        data.update(over)
        return self.client.post(url or reverse("portal:events-add"), data)


class StartDateTests(EventFormTestBase):
    def test_new_event_suggests_today_for_both_dates_and_sets_the_minimum(self):
        html = self.client.get(reverse("portal:events-add")).content.decode()
        start = html[html.index('id="id_start_date"') - 250: html.index('id="id_start_date"') + 250]
        self.assertIn(f'value="{self.today.isoformat()}"', start)
        self.assertIn(f'min="{self.today.isoformat()}"', start)
        end = html[html.index('id="id_end_date"') - 250: html.index('id="id_end_date"') + 250]
        self.assertIn(f'value="{self.today.isoformat()}"', end)

    def test_a_past_start_date_is_refused(self):
        res = self.post(start_date=(self.today - DAY).isoformat(), end_date=self.today.isoformat())
        self.assertEqual(res.status_code, 422)
        self.assertIn("cannot be in the past", res.content.decode())
        self.assertFalse(Event.objects.filter(name="Form test").exists())

    def test_today_and_future_start_dates_are_accepted(self):
        self.assertEqual(self.post().status_code, 204)
        res = self.post(name="Later", start_date=(self.today + 5 * DAY).isoformat(),
                        end_date=(self.today + 6 * DAY).isoformat())
        self.assertEqual(res.status_code, 204)

    def test_editing_a_started_event_keeps_its_date_but_cannot_move_further_back(self):
        ev = Event.objects.create(
            name="Old", semester=self.sem, start_date=self.today - 3 * DAY, end_date=self.today + DAY,
            required_types=["AM_IN"], am_in_start="06:00", am_in_end="07:30")
        url = reverse("portal:events-edit", args=[ev.pk])
        html = self.client.get(url).content.decode()
        chunk = html[html.index('id="id_start_date"') - 250: html.index('id="id_start_date"') + 250]
        self.assertIn(f'min="{(self.today - 3 * DAY).isoformat()}"', chunk)
        self.assertNotIn("data-suggest-today", chunk)
        keep = self.post(url, name="Old renamed", start_date=(self.today - 3 * DAY).isoformat(),
                         end_date=(self.today + DAY).isoformat())
        self.assertEqual(keep.status_code, 204, keep.content[:300])
        back = self.post(url, start_date=(self.today - 9 * DAY).isoformat(), end_date=(self.today + DAY).isoformat())
        self.assertEqual(back.status_code, 422)
        ahead = self.post(url, start_date=self.today.isoformat(), end_date=(self.today + DAY).isoformat())
        self.assertEqual(ahead.status_code, 204)


class ScanWindowDefaultsTests(EventFormTestBase):
    def test_a_new_event_comes_with_the_suggested_windows(self):
        html = self.client.get(reverse("portal:events-add")).content.decode()
        for field, value in (("am_in_start", "06:00"), ("am_in_end", "07:30"), ("am_out_start", "11:00"),
                             ("am_out_end", "12:00"), ("pm_in_start", "12:30"), ("pm_in_end", "13:00"),
                             ("pm_out_start", "16:00"), ("pm_out_end", "17:00")):
            tag = html[html.index(f'id="id_{field}"') - 250: html.index(f'id="id_{field}"') + 250]
            self.assertIn(f'value="{value}"', tag, field)
            self.assertIn(f'data-default="{value}"', tag, field)

    def test_am_fields_are_marked_am_and_pm_fields_pm(self):
        html = self.client.get(reverse("portal:events-add")).content.decode()
        for field, period in (("am_in_start", "AM"), ("am_out_end", "AM"), ("pm_in_start", "PM"), ("pm_out_end", "PM")):
            idx = html.index(f'id="id_{field}"')
            box = html.rfind('<div class="slot-time"', 0, idx)
            self.assertIn(f'data-period="{period}"', html[box:box + 60], field)
            self.assertIn(f'<span class="slot-time-period">{period}</span>', html[box:idx], field)

    def test_an_am_picker_offers_no_afternoon_hour_and_a_pm_picker_no_morning_hour(self):
        am = SlotTimeWidget("AM").render("x", datetime.time(7, 30), {"id": "id_x"})
        pm = SlotTimeWidget("PM").render("x", datetime.time(16, 0), {"id": "id_x"})
        am_hours = [int(v) for v in re.findall(r'<option value="(\d+)"', am.split("slot-time-m")[0])]
        pm_hours = [int(v) for v in re.findall(r'<option value="(\d+)"', pm.split("slot-time-m")[0])]
        self.assertEqual(am_hours, list(range(1, 13)))                                   # 1-11 AM and 12 = noon
        self.assertEqual(sorted(pm_hours), [12] + list(range(13, 24)))                   # noon..11 PM, never a morning hour
        self.assertIn('<option value="7" selected>07</option>', am)
        self.assertIn('<option value="30" selected>30</option>', am)
        self.assertIn('<option value="16" selected>04</option>', pm)                     # 16:00 shows as 04 (PM)
        self.assertIn('name="x" id="id_x" value="07:30"', am)

    def test_the_widget_posts_a_plain_hh_mm_and_handles_empty_values(self):
        widget = SlotTimeWidget("AM")
        self.assertEqual(widget.value_from_datadict({"x": "07:30"}, {}, "x"), "07:30")
        self.assertIn('value=""', widget.render("x", None, {"id": "id_x"}))
        self.assertIn('value="07:20"', widget.render("x", "07:20", {"id": "id_x"}))
        self.assertIn('value="07:20"', widget.render("x", "07:20:00", {"id": "id_x"}))

    def test_editing_keeps_the_saved_windows_not_the_defaults(self):
        ev = Event.objects.create(
            name="Custom", semester=self.sem, start_date=self.today, end_date=self.today,
            required_types=["AM_IN"], am_in_start="07:15", am_in_end="08:45")
        html = self.client.get(reverse("portal:events-edit", args=[ev.pk])).content.decode()
        self.assertIn('value="07:15"', html)
        self.assertIn('value="08:45"', html)
        self.assertNotIn('id="id_am_in_start" value="06:00"', html)

    def test_a_failed_save_shows_what_was_typed_not_the_defaults(self):
        res = self.post(am_in_start="07:20", am_in_end="07:10")           # end before start
        self.assertEqual(res.status_code, 422)
        html = res.content.decode()
        self.assertIn('value="07:20"', html)
        self.assertIn('value="07:10"', html)

    def test_the_page_script_enforces_the_halves_of_the_day(self):
        html = self.client.get(reverse("portal:events-list")).content.decode()
        for marker in ("function syncEventForm", "function slotTimeSync", "function slotTimeLoad", "data-suggest-today"):
            self.assertIn(marker, html)
