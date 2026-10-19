"""Template helpers for the portal (profile photos)."""

from django import template

from accounts.images import image_url

register = template.Library()


@register.filter
def img_url(field_file, size="thumb"):
    """``{{ user.profile_image|img_url:"medium" }}`` -> resized photo URL or ''."""
    return image_url(field_file, size=size) or ""


_SLOT_PREFIXES = (("am_in_", "AM_IN"), ("am_out_", "AM_OUT"), ("pm_in_", "PM_IN"), ("pm_out_", "PM_OUT"))


@register.filter
def slot_of(field_name):
    """``am_in_start`` -> ``AM_IN`` (the attendance slot a scan-window field belongs to), else ''."""
    for prefix, slot in _SLOT_PREFIXES:
        if str(field_name).startswith(prefix):
            return slot
    return ""
