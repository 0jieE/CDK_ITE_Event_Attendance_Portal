"""Template context processor that builds the sidebar navigation.

Items may be flat links or a collapsible group (with ``children``). URLs are
resolved tolerantly: a section whose routes are not wired yet renders as a
disabled placeholder rather than raising ``NoReverseMatch``.
"""

from django.urls import NoReverseMatch, reverse

# Each item: {key, label, icon, url} OR {key, label, icon, children:[...]}.
_NAV = [
    {"key": "dashboard", "label": "Dashboard", "url": "portal:dashboard", "icon": "speedometer2"},
    {"key": "users", "label": "Users", "url": "portal:users-list", "icon": "people"},
    {"key": "instructors", "label": "Instructors", "url": "portal:instructors-list", "icon": "person-badge"},
    {"key": "students", "label": "Students", "url": "portal:students-list", "icon": "mortarboard"},
    {"key": "school_years", "label": "School Years", "url": "portal:school_years-list", "icon": "calendar3"},
    {"key": "semesters", "label": "Semesters", "url": "portal:semesters-list", "icon": "calendar-week"},
    {"key": "events", "label": "Events", "url": "portal:events-list", "icon": "calendar-event"},
    {"key": "attendance_logs", "label": "Attendance Logs", "url": "portal:attendance_logs-list", "icon": "card-checklist"},
    {"key": "reports", "label": "Reports", "icon": "file-earmark-bar-graph", "children": [
        {"key": "reports_attendance", "label": "Attendance Report", "url": "portal:reports-attendance", "icon": "graph-up"},
        {"key": "reports_financial", "label": "Financial Report", "url": "portal:reports-financial", "icon": "cash-stack"},
        {"key": "fines", "label": "Fines", "url": "portal:fines-list", "icon": "cash-coin"},
    ]},
    {"key": "settings", "label": "Settings", "url": "portal:settings", "icon": "gear"},
]


def _resolve(item):
    """Resolve one nav item (and its children) to URLs, tolerating missing routes."""
    out = {"key": item["key"], "label": item["label"], "icon": item["icon"]}
    if "children" in item:
        out["children"] = [_resolve(c) for c in item["children"]]
        out["child_keys"] = [c["key"] for c in item["children"]]
    else:
        try:
            out["url"] = reverse(item["url"])
        except NoReverseMatch:
            out["url"] = None
    return out


def sidebar_nav(request):
    """Provide ``nav_items`` to every template under the portal."""
    return {"nav_items": [_resolve(item) for item in _NAV]}


def _ui_from(pal, *, theme, mode, brand_title, brand_subtitle, logo_url, compact):
    dark = mode == "dark"
    return {
        "brand_title": brand_title,
        "brand_subtitle": brand_subtitle,
        "theme": theme,
        "mode": mode,
        # Palette (see portal/theming.py)
        "primary": pal["primary"],
        "primary_dark": pal["primary_dark"],
        "on_primary": pal["on_primary"],
        "link": pal["link"],
        "sidebar": pal["sidebar"],
        "sidebar_end": pal["sidebar_end"],
        "rgb": pal["rgb"],
        # Surfaces
        "body_bg": "#0e1310" if dark else "#f3f6f3",
        "surface": "#171d19" if dark else "#ffffff",
        "logo_url": logo_url,
        "compact": compact,
    }


def _default_ui():
    from .theming import DEFAULT_THEME, palette

    return _ui_from(
        palette(DEFAULT_THEME), theme=DEFAULT_THEME, mode="light",
        brand_title="ITE Attendance", brand_subtitle="Department Adviser Portal",
        logo_url=None, compact=False,
    )


def ui_settings(request):
    """Inject the active UI theme/branding (``ui``) into every template.

    Falls back to defaults if the settings table doesn't exist yet (e.g. before
    the first migration) so management commands and admin keep working.
    """
    from .models import PortalSettings
    from .theming import palette

    try:
        s = PortalSettings.load()
    except Exception:
        return {"ui": _default_ui()}

    return {"ui": _ui_from(
        palette(s.theme), theme=s.theme, mode=s.color_mode,
        brand_title=s.brand_title, brand_subtitle=s.brand_subtitle,
        logo_url=s.logo.url if s.logo else None, compact=s.compact_sidebar,
    )}
