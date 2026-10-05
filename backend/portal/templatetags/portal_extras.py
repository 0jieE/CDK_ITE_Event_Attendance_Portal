"""Template helpers for the portal (profile photos)."""

from django import template

from accounts.images import image_url

register = template.Library()


@register.filter
def img_url(field_file, size="thumb"):
    """``{{ user.profile_image|img_url:"medium" }}`` -> resized photo URL or ''."""
    return image_url(field_file, size=size) or ""
