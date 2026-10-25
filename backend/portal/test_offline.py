"""Full offline support: pages saved for offline use, queued changes replayed with their real time."""

import datetime
import re
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.contrib.staticfiles import finders
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from attendance import services
from attendance.models import Event, Fine, FineSlotPayment, SchoolYear, Semester
from attendance.tests import make_student
from portal.views import OFFLINE_CDN_ASSETS

User = get_user_model()
PW = "pw-12345-Xy"
D = datetime.timedelta


def mk_event(sem, name, days_ago=1):
    day = timezone.localdate() - D(days=days_ago)
    return Event.objects.create(
        name=name, semester=sem, start_date=day, end_date=day, fine_rate=Decimal("10"),
        required_types=["AM_IN", "PM_OUT"], am_in_start=datetime.time(0, 0), am_in_end=datetime.time(0, 1),
        pm_out_start=datetime.time(0, 2), pm_out_end=datetime.time(0, 3))


class OfflineSetupMixin:
    def setUp(self):
        cache.clear()
        self.adviser = User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.login(username="adviser", password=PW)
        sy = SchoolYear.objects.create(sy="2026-2027")
        self.sem = Semester.objects.create(school_year=sy, name="1st")
        self.event = mk_event(self.sem, "Offline Fair")
        self.s1 = make_student("s1", "S-1")
        self.s2 = make_student("s2", "S-2")
        services.compute_fines_for_event(self.event)
        self.fine1 = Fine.objects.get(student=self.s1)


class OfflineManifestTests(OfflineSetupMixin, TestCase):
    def get(self):
        return self.client.get(reverse("portal:offline-manifest"))

    def test_lists_main_pages_and_the_fines_that_need_action(self):
        data = self.get().json()
        urls = data["urls"]
        for page in ("/portal/", "/portal/students/", "/portal/fines/", "/portal/events/", "/portal/attendance_logs/"):
            self.assertIn(page, urls)
        sid = self.sem.pk
        self.assertIn(f"/portal/attendance_logs/?tab=event&semester={sid}&event={self.event.pk}", urls)
        self.assertIn(f"/portal/fines/?view=student&semester={sid}&student={self.s1.pk}&event={self.event.pk}", urls)   # the pay page
        self.assertIn(f"/portal/fines/?view=student&semester={sid}&student={self.s1.pk}", urls)                          # the statement
        self.assertEqual(data["user"], self.adviser.pk)
        self.assertEqual(self.get()["Cache-Control"], "no-store")

    def test_never_lists_credentials_or_downloads_and_skips_settled_fines(self):
        services.pay_slots(self.fine1)                                          # fully paid: nothing left to do offline
        urls = self.get().json()["urls"]
        self.assertFalse([u for u in urls if "credentials" in u or "format=" in u])
        self.assertFalse([u for u in urls if f"student={self.s1.pk}&event=" in u])
        self.assertTrue([u for u in urls if f"student={self.s2.pk}&event=" in u])

    def test_only_portal_admins(self):
        self.client.logout()
        self.assertEqual(self.get().status_code, 302)
        User.objects.create_user("stu", password=PW, is_student=True)
        self.client.login(username="stu", password=PW)
        self.assertEqual(self.get().status_code, 403)

    def test_the_listed_pages_all_render(self):
        for url in self.get().json()["urls"][:25]:
            self.assertEqual(self.client.get(url).status_code, 200, url)


class ReplayTests(OfflineSetupMixin, TestCase):
    def pay(self, when=None, replay=True):
        headers = {"HTTP_HX_REQUEST": "true"}
        if replay:
            headers["HTTP_X_OFFLINE_REPLAY"] = "1"
        if when is not None:
            headers["HTTP_X_OFFLINE_TIME"] = when
        return self.client.post(reverse("portal:fines-pay-slot", args=[self.fine1.pk]),
                                {"date": self.event.start_date.isoformat(), "slot": "AM_IN"}, **headers)

    def test_a_queued_payment_keeps_the_time_it_was_really_taken(self):
        when = (timezone.now() - D(hours=5)).replace(microsecond=0)
        res = self.pay(when.isoformat().replace("+00:00", "Z"))
        self.assertEqual(res.status_code, 204)
        self.assertEqual(FineSlotPayment.objects.get().paid_at, when)

    def test_mark_paid_replay_stamps_the_fine_with_the_real_time(self):
        when = (timezone.now() - D(hours=2)).replace(microsecond=0)
        self.client.post(reverse("portal:fines-mark-paid", args=[self.fine1.pk]), HTTP_HX_REQUEST="true",
                         HTTP_X_OFFLINE_REPLAY="1", HTTP_X_OFFLINE_TIME=when.isoformat())
        self.fine1.refresh_from_db()
        self.assertEqual((self.fine1.status, self.fine1.paid_at), (Fine.Status.PAID, when))

    def test_implausible_or_unmarked_times_are_ignored(self):
        before = timezone.now()
        cases = (
            dict(when=(timezone.now() + D(hours=3)).isoformat()),                       # in the future
            dict(when=(timezone.now() - D(days=40)).isoformat()),                       # too old
            dict(when="not a date"), dict(when="2026-01-01T10:00:00"),                  # junk / no timezone
            dict(when=(timezone.now() - D(hours=1)).isoformat(), replay=False),         # not marked as a replay
        )
        for kwargs in cases:
            FineSlotPayment.objects.all().delete()
            Fine.objects.filter(pk=self.fine1.pk).update(status=Fine.Status.UNPAID, amount_paid=0, paid_at=None)
            self.pay(**kwargs)
            self.assertGreaterEqual(FineSlotPayment.objects.get().paid_at, before, kwargs)      # stamped "now" instead

    def test_replaying_twice_is_harmless(self):
        self.pay()
        res = self.pay()
        self.assertEqual(FineSlotPayment.objects.count(), 1)
        self.assertIn("already paid", res["HX-Trigger"])

    def test_event_switch_replay_sets_a_state_instead_of_flipping(self):
        url = reverse("portal:events-toggle-active", args=[self.event.pk])
        for _ in range(2):                                                                # sending "off" twice keeps it off
            self.client.post(url, {"value": "off"}, HTTP_HX_REQUEST="true")
            self.event.refresh_from_db()
            self.assertFalse(self.event.is_active)
        self.client.post(url, {"value": "on"}, HTTP_HX_REQUEST="true")
        self.event.refresh_from_db()
        self.assertTrue(self.event.is_active)
        self.client.post(url, HTTP_HX_REQUEST="true")                                      # no value: the old flip behaviour
        self.event.refresh_from_db()
        self.assertFalse(self.event.is_active)

    def test_semester_activation_replay_is_idempotent(self):
        other = Semester.objects.create(school_year=self.sem.school_year, name="2nd")
        url = reverse("portal:semesters-activate", args=[other.pk])
        for _ in range(2):
            self.assertEqual(self.client.post(url, HTTP_HX_REQUEST="true").status_code, 204)
        self.assertEqual(Semester.current(), other)

    def test_an_expired_session_is_a_redirect_so_the_queue_can_wait(self):
        self.client.logout()
        res = self.client.post(reverse("portal:fines-pay-slot", args=[self.fine1.pk]), HTTP_HX_REQUEST="true")
        self.assertEqual(res.status_code, 302)
        self.assertIn("/portal/login/", res["Location"])
        self.assertEqual(FineSlotPayment.objects.count(), 0)


class ServiceWorkerAndPageTests(OfflineSetupMixin, TestCase):
    def test_cdn_list_matches_the_libraries_base_html_loads(self):
        with open("portal/templates/portal/base.html", encoding="utf-8") as handle:
            html = handle.read()
        used = set()
        for m in re.finditer(r'<(?:link|script)\b[^>]*\b(?:href|src)="(https://[^"]+)"', html):
            if 'rel="preconnect"' not in m.group(0):
                used.add(m.group(1))
        self.assertEqual(used, set(OFFLINE_CDN_ASSETS))

    def test_service_worker_precaches_them_and_escapes_the_urls(self):
        js = self.client.get(reverse("portal:sw")).content.decode()
        self.assertIn("cdn.jsdelivr.net/npm/bootstrap@5.3.3", js)
        self.assertIn("\\u0026display\\u003Dswap", js)                          # the "&" in the font URL survives inside a JS string
        self.assertNotIn("&amp;", js)
        for needle in ("networkFirst", "staleWhileRevalidate", "x-offline-copy", "clear-pages", "prefetch", "NAV_TIMEOUT_MS"):
            self.assertIn(needle, js, needle)

    def test_pages_carry_the_offline_ui(self):
        html = self.client.get(reverse("portal:dashboard")).content.decode()
        for needle in ('name="portal-user"', 'id="syncChip"', 'id="offlineBanner"', 'id="syncDialog"', "data-reload",
                       "portal/js/offline.js", "portal/css/offline.css", "data-refresh-offline", "data-sync-now"):
            self.assertIn(needle, html, needle)
        self.assertIn(f'content="{self.adviser.pk}"', html)
        self.client.logout()
        self.assertNotIn("portal-user", self.client.get(reverse("portal:login")).content.decode())   # nothing to queue when signed out

    def test_offline_script_knows_exactly_which_changes_may_queue(self):
        with open(finders.find("portal/js/offline.js"), encoding="utf-8") as handle:
            js = handle.read()
        queueable = re.search(r"var QUEUEABLE = \[(.*?)\];", js, re.S).group(1)
        for kind in ("pay-slot", "unpay-slot", "mark-paid", "toggle-active", "activate"):
            self.assertIn(f"kind: '{kind}'", queueable)
        for destructive in ("delete", "add", "import", "calculate", "edit"):
            self.assertNotIn(destructive, queueable)
        for feature in ("indexedDB", "X-Offline-Replay", "X-Offline-Time", "navigator.locks", "clear-pages", "opaqueredirect"):
            self.assertIn(feature, js, feature)
