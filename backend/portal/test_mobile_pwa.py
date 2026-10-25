"""Mobile-first shell and PWA readiness: manifest, icons, head tags, bottom bar, drawer, hooks for the JS."""

import re

from django.contrib.auth import get_user_model
from django.contrib.staticfiles import finders
from django.test import TestCase
from django.urls import reverse

from portal.models import PortalSettings

User = get_user_model()
PW = "pw-12345-Xy"


class ManifestTests(TestCase):
    def test_manifest_is_public_and_describes_an_installable_app(self):
        res = self.client.get(reverse("portal:manifest"))                 # no login: browsers fetch it anonymously
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res["Content-Type"], "application/manifest+json")
        data = res.json()
        self.assertEqual(data["display"], "standalone")
        self.assertEqual(data["scope"], "/portal/")
        self.assertTrue(data["start_url"].startswith("/portal/"))
        self.assertTrue(data["theme_color"].startswith("#"))
        self.assertTrue(data["background_color"].startswith("#"))
        purposes = {(i["sizes"], i["purpose"]) for i in data["icons"]}
        self.assertEqual(purposes, {("192x192", "any"), ("512x512", "any"), ("512x512", "maskable")})
        self.assertGreaterEqual(len(data["shortcuts"]), 3)

    def test_manifest_follows_the_portal_branding(self):
        ps = PortalSettings.load()
        ps.brand_title = "CdK ITE Events"
        ps.save()
        self.assertEqual(self.client.get(reverse("portal:manifest")).json()["name"], "CdK ITE Events")

    def test_every_icon_exists_and_has_the_right_size(self):
        from PIL import Image

        for src in [i["src"] for i in self.client.get(reverse("portal:manifest")).json()["icons"]]:
            path = finders.find(src.replace("/static/", "", 1))
            self.assertTrue(path, src)
            with Image.open(path) as img:
                size = img.size
            expected = 192 if "192" in src else 512
            self.assertEqual(size, (expected, expected), src)
        with Image.open(finders.find("portal/pwa/apple-touch-icon.png")) as img:
            self.assertEqual(img.size, (180, 180))
            self.assertEqual(img.mode, "RGB")                                # iOS: opaque


class MobileShellTests(TestCase):
    def setUp(self):
        User.objects.create_user("adviser", password=PW, is_admin=True)
        self.client.login(username="adviser", password=PW)

    def page(self, name="portal:dashboard", **params):
        return self.client.get(reverse(name), params).content.decode()

    def test_head_has_the_installable_app_tags(self):
        html = self.page()
        for needle in ('rel="manifest"', 'rel="apple-touch-icon"', 'name="apple-mobile-web-app-capable"',
                       'name="mobile-web-app-capable"', 'name="theme-color"', "viewport-fit=cover",
                       "portal/css/mobile.css", "portal/js/mobile.js"):
            self.assertIn(needle, html, needle)
        self.client.logout()
        self.assertIn('rel="manifest"', self.client.get(reverse("portal:login")).content.decode())

    def test_bottom_navigation_has_five_destinations_and_marks_the_current_one(self):
        for name, label in (("portal:dashboard", "Home"), ("portal:students-list", "Students"),
                            ("portal:events-list", "Events"), ("portal:fines-list", "Fines")):
            html = self.page(name)
            bar = html[html.index('class="bottom-nav'): html.index("</nav>", html.index('class="bottom-nav'))]
            self.assertEqual(len(re.findall(r"<(?:a|button)\b", bar)), 5)
            current = re.findall(r'<a href="[^"]+" class="active" aria-current="page">.*?<span>(.*?)</span>', bar)
            self.assertEqual(current, [label], name)
        # any other page highlights "More"
        bar = self.page("portal:terms-list")
        bar = bar[bar.index('class="bottom-nav'):]
        self.assertIn('id="bottomMore" class="active"', bar)

    def test_drawer_has_a_close_button_user_card_and_logout(self):
        html = self.page()
        self.assertIn('class="drawer-close drawer-only"', html)
        self.assertIn('class="drawer-user drawer-only"', html)
        self.assertIn(reverse("portal:logout"), html)
        self.assertIn("Skip to content", html)
        self.assertIn('id="main"', html)

    def test_filter_forms_opt_in_to_the_collapsing_behaviour(self):
        self.assertIn("filters-form", self.page("portal:attendance_logs-list"))
        self.assertIn("filters-form", self.page("portal:fines-list"))
        self.assertIn("filters-form", self.page("portal:reports-attendance"))

    def test_static_assets_exist_and_are_screen_only(self):
        css = open(finders.find("portal/css/mobile.css"), encoding="utf-8").read()
        js = open(finders.find("portal/js/mobile.js"), encoding="utf-8").read()
        self.assertIn("env(safe-area-inset-bottom)", css)
        self.assertIn("@media screen and (max-width: 767.98px)", css)          # screen only: printing keeps real tables
        self.assertNotIn("@media (max-width: 767.98px)", css)
        self.assertIn("overscroll-behavior-x: none", css)
        self.assertIn("attr(data-label)", css)
        for feature in ("touchstart", "inert", "data-label", "chrome-hidden", "filters-toggle"):
            self.assertIn(feature, js, feature)
