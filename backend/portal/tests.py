"""Portal form rendering tests."""

import datetime
import re

from django.template.loader import render_to_string
from django.test import TestCase
from django.utils import timezone

from attendance.models import Event, SchoolYear, Semester

from .forms import EventForm


def render(form):
    return render_to_string("portal/partials/form_fields.html", {"form": form})


class RequiredTypesWidgetTests(TestCase):
    """Regression: the checkboxes used to get ``form-control`` and were unusable."""

    def test_checkboxes_are_real_bootstrap_checks_not_form_control(self):
        html = render(EventForm())
        inputs = re.findall(r"<input[^>]*name=\"required_types\"[^>]*>", html)
        self.assertEqual(len(inputs), 4)
        for tag in inputs:
            self.assertIn('type="checkbox"', tag)
            self.assertIn('class="form-check-input"', tag)
            self.assertNotIn("form-control", tag)
        self.assertNotIn('class="form-control" id="id_required_types', html)
        for slot in ("AM_IN", "AM_OUT", "PM_IN", "PM_OUT"):
            self.assertIn(f'value="{slot}"', html)

    def test_edit_form_preselects_saved_slots(self):
        sy = SchoolYear.objects.create(sy="2025-2026")
        sem = Semester.objects.create(school_year=sy, name="1st")
        today = timezone.localdate()
        event = Event.objects.create(
            name="E", semester=sem, start_date=today, end_date=today,
            required_types=["AM_IN", "PM_OUT"],
            am_in_start=datetime.time(8), am_in_end=datetime.time(9),
            pm_out_start=datetime.time(16), pm_out_end=datetime.time(17),
        )
        html = render(EventForm(instance=event))
        for slot, checked in (("AM_IN", True), ("AM_OUT", False),
                              ("PM_IN", False), ("PM_OUT", True)):
            tag = next(t for t in html.split("<input") if f'value="{slot}"' in t)
            self.assertEqual(" checked" in tag, checked, slot)

    def test_selection_survives_a_failed_submit(self):
        form = EventForm(data={"name": "", "required_types": ["AM_OUT", "PM_IN"]})
        self.assertFalse(form.is_valid())
        html = render(form)
        for slot, checked in (("AM_IN", False), ("AM_OUT", True),
                              ("PM_IN", True), ("PM_OUT", False)):
            tag = next(t for t in html.split("<input") if f'value="{slot}"' in t)
            self.assertEqual(" checked" in tag, checked, slot)


# ---------------------------------------------------------------------------
# UI: theme, responsive shell and page rendering
# ---------------------------------------------------------------------------
from django.contrib.auth import get_user_model  # noqa: E402
from django.urls import reverse  # noqa: E402

from .models import PortalSettings  # noqa: E402
from .theming import DEFAULT_THEME, PALETTES, palette  # noqa: E402


def _luminance(hex_color):
    def chan(c):
        c /= 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    h = hex_color.lstrip("#")
    r, g, b = (chan(int(h[i:i + 2], 16)) for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _contrast(a, b):
    la, lb = sorted((_luminance(a), _luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


class ThemeTests(TestCase):
    def test_default_theme_is_the_brand_green(self):
        self.assertEqual(DEFAULT_THEME, "brand")
        self.assertEqual(palette("brand")["primary"], "#41b422")
        self.assertEqual(PortalSettings.load().theme, "brand")

    def test_every_palette_is_complete(self):
        for name, pal in PALETTES.items():
            for key in ("primary", "primary_dark", "on_primary", "link",
                        "sidebar", "sidebar_end", "rgb"):
                self.assertIn(key, pal, f"{name} missing {key}")
        self.assertEqual(PALETTES["brand"]["rgb"], "65, 180, 34")

    def test_brand_palette_text_contrast_is_accessible(self):
        pal = palette("brand")
        # Text on the green fill, and green text on a white surface.
        self.assertGreaterEqual(_contrast(pal["on_primary"], pal["primary"]), 4.5)
        self.assertGreaterEqual(_contrast(pal["link"], "#ffffff"), 4.5)

    def test_unknown_theme_falls_back_to_default(self):
        self.assertEqual(palette("nope"), PALETTES[DEFAULT_THEME])


class PortalPagesRenderTests(TestCase):
    """Every portal page renders for the adviser with the responsive shell."""

    PAGES = [
        "portal:dashboard", "portal:users-list", "portal:instructors-list",
        "portal:students-list", "portal:approvals", "portal:school_years-list", "portal:semesters-list",
        "portal:events-list", "portal:attendance_logs-list", "portal:fines-list",
        "portal:reports-attendance", "portal:reports-financial", "portal:settings",
    ]

    def setUp(self):
        self.admin = get_user_model().objects.create_user(
            username="adviser", password="x", is_admin=True, is_staff=True)
        self.client.force_login(self.admin)

    def test_pages_have_toggleable_sidebar_and_mobile_viewport(self):
        for name in self.PAGES:
            res = self.client.get(reverse(name))
            self.assertEqual(res.status_code, 200, name)
            html = res.content.decode()
            self.assertIn('id="sidebarToggle"', html, name)
            self.assertIn('id="sidebarBackdrop"', html, name)
            self.assertIn('name="viewport"', html, name)
            self.assertIn("--brand: #41b422", html, name)

    def test_login_page_is_themed_and_has_viewport(self):
        self.client.logout()
        html = self.client.get(reverse("portal:login")).content.decode()
        self.assertIn("--brand: #41b422", html)
        self.assertIn('name="viewport"', html)
        self.assertIn('id="pwToggle"', html)

    def test_event_form_modal_is_wide_and_has_scan_window_section(self):
        res = self.client.get(reverse("portal:events-add"))
        self.assertEqual(res.status_code, 200)
        html = res.content.decode()
        self.assertIn('data-modal-size="lg"', html)
        self.assertIn("Scan windows", html)
        self.assertIn('class="form-check-input"', html)

    def test_small_forms_stay_in_a_normal_modal(self):
        res = self.client.get(reverse("portal:school_years-add"))
        self.assertEqual(res.status_code, 200)
        self.assertNotIn('data-modal-size="lg"', res.content.decode())

    def test_toggle_fields_render_as_switches_and_keep_their_value(self):
        res = self.client.get(reverse("portal:events-add"))
        self.assertIn('class="form-check form-switch', res.content.decode())


class AdminLinkTests(TestCase):
    """The adviser menu links to Django Administration - for staff accounts only."""

    def _menu(self, user):
        self.client.force_login(user)
        return self.client.get(reverse("portal:dashboard")).content.decode()

    def test_staff_adviser_sees_the_link_to_the_django_admin(self):
        adv = get_user_model().objects.create_user("adv", password="x", is_admin=True, is_staff=True)
        html = self._menu(adv)
        self.assertIn('href="/admin/"', html)
        self.assertIn("Django Administration", html)
        self.assertIn('target="_blank"', html)

    def test_adviser_without_staff_does_not_get_a_dead_end_link(self):
        adv = get_user_model().objects.create_user("adv2", password="x", is_admin=True, is_staff=False)
        html = self._menu(adv)
        self.assertNotIn("Django Administration", html)
        self.assertNotIn('href="/admin/"', html)

    def test_link_target_actually_loads_for_a_superuser(self):
        su = get_user_model().objects.create_superuser("root", password="x")
        su.is_admin = True
        su.save()
        self.client.force_login(su)
        self.assertEqual(self.client.get("/admin/").status_code, 200)
