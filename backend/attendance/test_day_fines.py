"""Customisable fine per day for multi-day events."""

import datetime
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from accounts.models import Student
from attendance import services
from attendance.models import AttendanceLog, EventDayFine, Fine

from .tests import make_event, make_student

User = get_user_model()
PW = "pw-12345-Xy"


def _past_event(days=3, **kw):
    today = timezone.localdate()
    return make_event(
        start_date=today - datetime.timedelta(days=days - 1), end_date=today,
        required_types=["AM_IN"], am_in_start=datetime.time(0, 0), am_in_end=datetime.time(0, 1), **kw,
    )


class CalculatorTests(TestCase):
    def test_each_day_uses_its_own_rate(self):
        student = make_student("s1", "S-1")
        event = _past_event(3)                       # 3 days, default 10
        d = list(event.iter_dates())
        EventDayFine.objects.create(event=event, date=d[1], fine_rate=Decimal("50"))
        # present on day 0 only; absent on day 1 (50) and day 2 (default 10); today's
        # slot has long closed at 00:01 only if the clock is past it, so pin `now`.
        AttendanceLog.objects.create(student=student, event=event, date=d[0], attendance_type="AM_IN", status="PRESENT")
        now = timezone.make_aware(datetime.datetime.combine(d[2], datetime.time(12, 0)))
        services.compute_fines_for_event(event, now=now)
        fine = Fine.objects.get(student=student, event=event)
        self.assertEqual(fine.missed_slots, 2)
        self.assertEqual(fine.amount, Decimal("60.00"))

    def test_no_overrides_behaves_like_a_flat_rate(self):
        student = make_student("s1", "S-1")
        event = _past_event(2)
        d = list(event.iter_dates())
        now = timezone.make_aware(datetime.datetime.combine(d[1], datetime.time(12, 0)))
        services.compute_fines_for_event(event, now=now)
        self.assertEqual(Fine.objects.get(student=student).amount, Decimal("20.00"))

    def test_rate_for(self):
        event = _past_event(2)
        d = list(event.iter_dates())
        EventDayFine.objects.create(event=event, date=d[0], fine_rate=Decimal("5"))
        self.assertEqual(event.rate_for(d[0]), Decimal("5"))
        self.assertEqual(event.rate_for(d[1]), event.fine_rate)


class PortalFormTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.login(username="adviser", password=PW)
        self.event = _past_event(3)

    def _post(self, **extra):
        e = self.event
        data = {
            "name": e.name, "semester": e.semester_id,
            "start_date": e.start_date.isoformat(), "end_date": e.end_date.isoformat(),
            "fine_rate": "10.00", "required_types": ["AM_IN"], "is_active": "on",
            "am_in_start": "00:00", "am_in_end": "00:01",
        }
        data.update(extra)
        return self.client.post(reverse("portal:events-edit", args=[e.pk]), data, HTTP_HX_REQUEST="true")

    def test_edit_form_has_day_inputs_container(self):
        r = self.client.get(reverse("portal:events-edit", args=[self.event.pk]), HTTP_HX_REQUEST="true")
        self.assertContains(r, "day-fines")

    def test_saving_day_fines_stores_only_real_overrides(self):
        d = list(self.event.iter_dates())
        r = self._post(**{
            f"day_fine__{d[0]}": "25",
            f"day_fine__{d[1]}": "",                 # blank -> default
            f"day_fine__{d[2]}": "10.00",            # equals default -> not stored
            "day_fine__1999-01-01": "99",            # outside the event -> ignored
        })
        self.assertEqual(r.status_code, 204, r.content[:300])
        self.assertEqual(
            {k: v for k, v in self.event.day_rates.items()},
            {d[0].isoformat(): Decimal("25.00")},
        )

    def test_changing_a_day_rate_refreshes_existing_fines(self):
        student = make_student("s1", "S-1")
        d = list(self.event.iter_dates())
        today = d[-1]
        services.compute_fines_for_event(
            self.event, now=timezone.make_aware(datetime.datetime.combine(today, datetime.time(12, 0))))
        self.assertEqual(Fine.objects.get(student=student).amount, Decimal("30.00"))
        self._post(**{f"day_fine__{d[0]}": "100"})
        self.assertEqual(Fine.objects.get(student=student).amount, Decimal("120.00"))

    def test_invalid_amounts_are_rejected(self):
        d = list(self.event.iter_dates())
        for bad in ("abc", "-5"):
            r = self._post(**{f"day_fine__{d[0]}": bad})
            self.assertEqual(r.status_code, 422)
        self.assertEqual(EventDayFine.objects.count(), 0)

    def test_events_list_and_fines_grid_show_day_rates(self):
        d = list(self.event.iter_dates())
        EventDayFine.objects.create(event=self.event, date=d[0], fine_rate=Decimal("40"))
        self.assertContains(self.client.get(reverse("portal:events-list")), "per-day")
        student = make_student("s1", "S-1")
        r = self.client.get(reverse("portal:fines-list"),
                            {"view": "student", "student": student.pk, "event": self.event.pk})
        self.assertContains(r, "₱40")


class ApiTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.login(username="adviser", password=PW)
        self.event = _past_event(3)

    def test_event_api_round_trip(self):
        from rest_framework.test import APIClient

        api = APIClient()
        api.force_authenticate(User.objects.get(username="adviser"))
        d = list(self.event.iter_dates())
        r = api.patch(f"/api/events/{self.event.pk}/", {"day_fines": {d[1].isoformat(): "45"}}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["day_fines"], {d[1].isoformat(): "45.00"})
        bad = api.patch(f"/api/events/{self.event.pk}/", {"day_fines": {"1999-01-01": "3"}}, format="json")
        self.assertEqual(bad.status_code, 400)
