"""User, Instructor and Student models — the RBAC backbone of the system."""

from django.contrib.auth.models import AbstractUser
from django.db import models
from django.db.models.signals import post_delete
from django.dispatch import receiver

from .images import image_url, normalise_image, profile_upload_to, validate_image_file


class User(AbstractUser):
    """
    Custom user model.

    Roles are expressed as boolean flags rather than a single ``role`` column
    so that a person can, in principle, hold more than one role (e.g. an
    instructor who is also a department adviser).  Exactly which flags are set
    drives the DRF permission classes in :mod:`accounts.permissions`.
    """

    middle_name = models.CharField(max_length=150, blank=True, null=True)

    #: Profile photo, stored in Cloudinary (or local media in dev). Normalised on
    #: save (rotated, metadata stripped, <=1024px) - see ``accounts.images``.
    profile_image = models.ImageField(
        upload_to=profile_upload_to,
        blank=True,
        null=True,
        validators=[validate_image_file],
        help_text="JPG, PNG or WebP, up to 5 MB.",
    )

    # Role flags
    is_admin = models.BooleanField(
        default=False,
        help_text="Department Adviser — full control over the system.",
    )
    is_instructor = models.BooleanField(
        default=False,
        help_text="Assigned Instructor — scans attendance (mobile).",
    )
    is_student = models.BooleanField(
        default=False,
        help_text="Student — views own data only (mobile).",
    )

    class Meta:
        ordering = ["last_name", "first_name"]

    def __str__(self):
        return self.get_full_name() or self.username

    def get_full_name(self):
        """Return ``First Middle Last`` with the middle name when present."""
        parts = [self.first_name, self.middle_name, self.last_name]
        full = " ".join(p for p in parts if p)
        return full.strip()

    # -- profile photo ------------------------------------------------------
    def get_profile_image_url(self, size=None, request=None):
        """Photo URL (``size``: ``"thumb"`` 96px / ``"medium"`` 256px) or ``None``."""
        return image_url(self.profile_image, size=size, request=request)

    @property
    def avatar_url(self):
        """Small square avatar for tables and the top bar (or ``None``)."""
        return self.get_profile_image_url("thumb")

    @property
    def initials(self):
        """Fallback avatar text when there is no photo."""
        name = self.get_full_name() or self.username or "?"
        parts = name.split()
        letters = (parts[0][0] + (parts[-1][0] if len(parts) > 1 else "")) if parts else "?"
        return letters.upper()

    def save(self, *args, **kwargs):
        update_fields = kwargs.get("update_fields")
        touches_image = update_fields is None or "profile_image" in update_fields
        old_name = None
        if touches_image:
            f = self.profile_image
            if f and not f._committed:                      # a fresh upload
                self.profile_image = normalise_image(f.file)
            if self.pk:                                      # remember the previous file
                old_name = (
                    type(self).objects.filter(pk=self.pk)
                    .values_list("profile_image", flat=True).first()
                )
        super().save(*args, **kwargs)
        # Replaced or cleared: drop the old file so storage doesn't fill with orphans.
        if touches_image and old_name and old_name != (self.profile_image.name or ""):
            self.profile_image.storage.delete(old_name)

    @property
    def role(self) -> str:
        """Human-readable primary role, used by serializers and the UI."""
        if self.is_superuser or self.is_admin:
            return "admin"
        if self.is_instructor:
            return "instructor"
        if self.is_student:
            return "student"
        return "user"


class Instructor(models.Model):
    """Profile record for a user who scans attendance."""

    user = models.OneToOneField(
        User,
        on_delete=models.CASCADE,
        related_name="instructor_profile",
    )

    class Meta:
        ordering = ["user__last_name", "user__first_name"]

    def __str__(self):
        return f"Instructor: {self.user.get_full_name() or self.user.username}"


class Student(models.Model):
    """Profile record for a student, keyed by a unique student number."""

    class YearLevel(models.TextChoices):
        FIRST = "1", "1st Year"
        SECOND = "2", "2nd Year"
        THIRD = "3", "3rd Year"
        FOURTH = "4", "4th Year"

    user = models.OneToOneField(
        User,
        on_delete=models.CASCADE,
        related_name="student_profile",
    )
    student_number = models.CharField(max_length=50, unique=True)
    year_level = models.CharField(
        max_length=2, choices=YearLevel.choices, blank=True
    )
    section = models.CharField(max_length=20, blank=True)

    class Meta:
        ordering = ["year_level", "section", "student_number"]

    def __str__(self):
        return f"{self.student_number} — {self.user.get_full_name() or self.user.username}"

    @property
    def year_section(self):
        """Compact ``"3-A"``-style label (blank parts omitted)."""
        parts = [self.get_year_level_display() if self.year_level else "", self.section]
        return " ".join(p for p in parts if p).strip()


@receiver(post_delete, sender=User)
def _delete_profile_image(sender, instance, **kwargs):
    """Remove a deleted user's photo from storage."""
    if instance.profile_image:
        instance.profile_image.storage.delete(instance.profile_image.name)
