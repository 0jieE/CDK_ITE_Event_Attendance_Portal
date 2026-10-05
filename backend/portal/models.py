"""Portal-level configuration (a single, editable settings row)."""

from django.db import models


class PortalSettings(models.Model):
    """Site-wide UI settings for the admin portal.

    This is a **singleton** (always ``pk=1``) edited from the Settings page —
    branding, accent theme, light/dark mode and an optional uploaded logo.
    """

    class Theme(models.TextChoices):
        BRAND = "brand", "ITE Brand Green"
        VIOLET = "violet", "Violet"
        GREEN = "green", "Forest Green"
        BLUE = "blue", "Blue"
        TEAL = "teal", "Teal"
        CRIMSON = "crimson", "Crimson"
        SLATE = "slate", "Slate"

    class Mode(models.TextChoices):
        LIGHT = "light", "Light"
        DARK = "dark", "Dark"

    brand_title = models.CharField(max_length=80, default="ITE Attendance")
    brand_subtitle = models.CharField(
        max_length=120, default="Department Adviser Portal"
    )
    theme = models.CharField(
        max_length=20, choices=Theme.choices, default=Theme.BRAND
    )
    color_mode = models.CharField(
        max_length=10, choices=Mode.choices, default=Mode.LIGHT
    )
    logo = models.ImageField(upload_to="branding/", blank=True, null=True)
    compact_sidebar = models.BooleanField(
        default=False,
        help_text="Start with the sidebar collapsed to icons (users can still toggle it).",
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = "Portal settings"
        verbose_name_plural = "Portal settings"

    def __str__(self):
        return "Portal settings"

    def save(self, *args, **kwargs):
        # Enforce the singleton invariant.
        self.pk = 1
        super().save(*args, **kwargs)

    @classmethod
    def load(cls):
        """Return the singleton settings row, creating defaults on first use."""
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj
