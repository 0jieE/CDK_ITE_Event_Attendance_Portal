"""Accent-colour palettes for the portal UI themes.

Each palette drives the CSS custom properties consumed by ``base.html`` /
``login.html`` (see ``partials/style_theme.html``):

* ``primary``      - the accent / brand fill (buttons, active nav, focus rings)
* ``primary_dark`` - hover/pressed shade of the accent
* ``on_primary``   - text colour that stays readable *on* a primary fill
* ``link``         - accent used for text/links on a light surface (contrast-safe)
* ``sidebar`` / ``sidebar_end`` - the sidebar gradient
* ``rgb``          - ``"r, g, b"`` of ``primary`` (for Bootstrap's ``rgba()`` vars)

The default **brand** palette is the ITE green ``#41b422`` (it matches the
department seal). White text on that exact green is only ~2.7:1, so solid
buttons use a very dark green ink and text links use a deeper green shade.
"""

DEFAULT_THEME = "brand"


def _rgb(hex_color):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _darken(hex_color, factor):
    """Mix ``hex_color`` toward black by ``factor`` (0-1)."""
    r, g, b = (round(c * (1 - factor)) for c in _rgb(hex_color))
    return f"#{r:02x}{g:02x}{b:02x}"


_RAW = {
    # ITE brand green - the default.
    "brand": {
        "primary": "#41b422", "primary_dark": "#379c1c",
        "on_primary": "#06200a", "link": "#2b8416",
        "sidebar": "#0d2c12",
    },
    "green":   {"primary": "#1f7a3d", "primary_dark": "#155c2c", "sidebar": "#103d20"},
    "violet":  {"primary": "#5b2a86", "primary_dark": "#45206a", "sidebar": "#2e1746"},
    "blue":    {"primary": "#1f5fae", "primary_dark": "#174a87", "sidebar": "#122f52"},
    "teal":    {"primary": "#0f807f", "primary_dark": "#0b6463", "sidebar": "#0a3f43"},
    "crimson": {"primary": "#b02a37", "primary_dark": "#8a1f29", "sidebar": "#4a1318"},
    "slate":   {"primary": "#475569", "primary_dark": "#334155", "sidebar": "#1e293b"},
}


def _complete(p):
    full = dict(p)
    full.setdefault("on_primary", "#ffffff")
    full.setdefault("link", full["primary"])
    full["sidebar_end"] = _darken(full["sidebar"], 0.38)
    full["rgb"] = ", ".join(str(c) for c in _rgb(full["primary"]))
    return full


PALETTES = {name: _complete(p) for name, p in _RAW.items()}


def palette(theme):
    """Return the palette dict for ``theme`` (falling back to the default)."""
    return PALETTES.get(theme, PALETTES[DEFAULT_THEME])
