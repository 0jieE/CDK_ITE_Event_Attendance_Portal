"""Domain models for attendance tracking and the fines ledger.

Two deliberate corrections vs. the original ERD are encoded here:

* :class:`Event` carries ``start_date``/``end_date`` (a date *range*) so a
  single event can span multiple days (e.g. a week-long seminar).
* :class:`QRCode` and :class:`AttendanceLog` are unique per
  ``(student, event, date, attendance_type)`` — i.e. up to four QR codes /
  logs per student per event-day (AM-IN, AM-OUT, PM-IN, PM-OUT).
"""

import secrets
from io import BytesIO

import qrcode
from django.core.exceptions import ValidationError
from django.core.files.base import ContentFile
from django.db import models
from django.db.models.signals import post_delete
from django.dispatch import receiver


class AttendanceType(models.TextChoices):
    """The four daily attendance slots."""

    AM_IN = "AM_IN", "AM Time-In"
    AM_OUT = "AM_OUT", "AM Time-Out"
    PM_IN = "PM_IN", "PM Time-In"
    PM_OUT = "PM_OUT", "PM Time-Out"


def default_required_types():
    """All four slots are required by default for a new event."""
    return [
        AttendanceType.AM_IN,
        AttendanceType.AM_OUT,
        AttendanceType.PM_IN,
        AttendanceType.PM_OUT,
    ]


class SchoolYear(models.Model):
    """An academic year such as ``2025-2026``."""

    sy = models.CharField("School year", max_length=9, unique=True)

    class Meta:
        ordering = ["-sy"]
        verbose_name = "School year"

    def __str__(self):
        return self.sy


class Semester(models.Model):
    """A semester within a school year (1st / 2nd / Summer)."""

    class Name(models.TextChoices):
        FIRST = "1st", "1st Semester"
        SECOND = "2nd", "2nd Semester"
        SUMMER = "Summer", "Summer"

    school_year = models.ForeignKey(
        SchoolYear, on_delete=models.CASCADE, related_name="semesters"
    )
    name = models.CharField(max_length=10, choices=Name.choices)

    class Meta:
        ordering = ["-school_year__sy", "name"]
        unique_together = ("school_year", "name")

    def __str__(self):
        return f"{self.school_year.sy} {self.name}"


class Event(models.Model):
    """A (possibly multi-day) event for which attendance is collected."""

    name = models.CharField(max_length=255)
    semester = models.ForeignKey(
        Semester, on_delete=models.CASCADE, related_name="events"
    )
    start_date = models.DateField()
    end_date = models.DateField()
    fine_rate = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=0,
        help_text="Amount charged per missed required attendance slot.",
    )
    required_types = models.JSONField(
        default=default_required_types,
        help_text="Which AttendanceType slots are required for this event.",
    )
    is_active = models.BooleanField(default=True)

    # Per-slot scan windows (admin-set; reused for every day of the event).
    # A daily QR is only scannable into a slot while "now" is inside its window;
    # outside every window the scan is rejected and the slot stays absent.
    am_in_start = models.TimeField(blank=True, null=True)
    am_in_end = models.TimeField(blank=True, null=True)
    am_out_start = models.TimeField(blank=True, null=True)
    am_out_end = models.TimeField(blank=True, null=True)
    pm_in_start = models.TimeField(blank=True, null=True)
    pm_in_end = models.TimeField(blank=True, null=True)
    pm_out_start = models.TimeField(blank=True, null=True)
    pm_out_end = models.TimeField(blank=True, null=True)

    #: slot code -> (start_field, end_field)
    SLOT_TIME_FIELDS = {
        AttendanceType.AM_IN: ("am_in_start", "am_in_end"),
        AttendanceType.AM_OUT: ("am_out_start", "am_out_end"),
        AttendanceType.PM_IN: ("pm_in_start", "pm_in_end"),
        AttendanceType.PM_OUT: ("pm_out_start", "pm_out_end"),
    }

    class Meta:
        ordering = ["-start_date", "name"]

    def __str__(self):
        return f"{self.name} ({self.start_date} – {self.end_date})"

    def clean(self):
        """Validate the date range, ``required_types`` and slot time windows."""
        if self.start_date and self.end_date and self.end_date < self.start_date:
            raise ValidationError(
                {"end_date": "End date must be on or after the start date."}
            )
        if self.required_types is not None:
            if not isinstance(self.required_types, list) or not self.required_types:
                raise ValidationError(
                    {"required_types": "Must be a non-empty list of attendance types."}
                )
            valid = set(AttendanceType.values)
            invalid = [t for t in self.required_types if t not in valid]
            if invalid:
                raise ValidationError(
                    {"required_types": f"Invalid attendance type(s): {invalid}."}
                )

        # Each required slot needs a valid time window; end must follow start.
        errors = {}
        for slot, (sf, ef) in self.SLOT_TIME_FIELDS.items():
            start, end = getattr(self, sf), getattr(self, ef)
            required = slot in (self.required_types or [])
            if required and (start is None or end is None):
                errors[sf] = (
                    f"{AttendanceType(slot).label}: set a start and end time "
                    "(required slot)."
                )
            if start is not None and end is not None and end <= start:
                errors[ef] = "End time must be after the start time."
        if errors:
            raise ValidationError(errors)

    def slot_window(self, slot):
        """Return ``(start, end)`` times for a slot, or ``(None, None)``."""
        sf, ef = self.SLOT_TIME_FIELDS.get(slot, (None, None))
        if sf is None:
            return (None, None)
        return (getattr(self, sf), getattr(self, ef))

    def slot_for_time(self, when):
        """Which required slot's window contains time ``when`` (or ``None``).

        Only required slots with a fully-configured window are considered; the
        first match in canonical slot order wins.
        """
        for slot in default_required_types():  # canonical order
            if slot not in (self.required_types or []):
                continue
            start, end = self.slot_window(slot)
            if start is not None and end is not None and start <= when <= end:
                return slot
        return None

    def iter_dates(self):
        """Yield every :class:`~datetime.date` in ``[start_date, end_date]``."""
        from datetime import timedelta

        current = self.start_date
        while current <= self.end_date:
            yield current
            current += timedelta(days=1)


def generate_token():
    """Return a cryptographically-secure, URL-safe token for a QR code."""
    return secrets.token_urlsafe(32)


class QRCode(models.Model):
    """A single **daily** QR code for one student / event-day.

    One QR now covers the whole day; the slot it records is decided server-side
    at scan time by which of the event's slot time windows the scan falls into.
    """

    student = models.ForeignKey(
        "accounts.Student", on_delete=models.CASCADE, related_name="qr_codes"
    )
    event = models.ForeignKey(
        Event, on_delete=models.CASCADE, related_name="qr_codes"
    )
    date = models.DateField()
    token = models.CharField(max_length=64, unique=True, default=generate_token)
    image = models.ImageField(upload_to="qrcodes/", blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-date", "student"]
        unique_together = ("student", "event", "date")
        verbose_name = "QR code"

    def __str__(self):
        return f"QR {self.student.student_number} {self.date}"

    def generate_image(self, save=True):
        """(Re)generate the PNG QR image from ``self.token``.

        The image is stored in the ``image`` field.  Pass ``save=False`` to
        avoid hitting the database (useful inside ``save()``).
        """
        img = qrcode.make(self.token)
        buffer = BytesIO()
        img.save(buffer, format="PNG")
        filename = f"qr_{self.token}.png"
        self.image.save(filename, ContentFile(buffer.getvalue()), save=False)
        if save:
            super().save(update_fields=["image"])
        return self.image

    def save(self, *args, **kwargs):
        """Ensure an image exists the first time the QR code is persisted."""
        creating = self._state.adding
        super().save(*args, **kwargs)
        if creating and not self.image:
            self.generate_image(save=True)


class AttendanceLog(models.Model):
    """A recorded scan (or absence) for one student / event-day / slot."""

    class Status(models.TextChoices):
        PRESENT = "PRESENT", "Present"
        LATE = "LATE", "Late"
        ABSENT = "ABSENT", "Absent"

    student = models.ForeignKey(
        "accounts.Student", on_delete=models.CASCADE, related_name="attendance_logs"
    )
    event = models.ForeignKey(
        Event, on_delete=models.CASCADE, related_name="attendance_logs"
    )
    date = models.DateField()
    attendance_type = models.CharField(max_length=10, choices=AttendanceType.choices)
    scanned_at = models.DateTimeField(blank=True, null=True)
    status = models.CharField(
        max_length=10, choices=Status.choices, default=Status.ABSENT
    )
    scanned_by = models.ForeignKey(
        "accounts.Instructor",
        on_delete=models.SET_NULL,
        blank=True,
        null=True,
        related_name="scans",
    )

    class Meta:
        ordering = ["-date", "student", "attendance_type"]
        unique_together = ("student", "event", "date", "attendance_type")
        verbose_name = "Attendance log"

    def __str__(self):
        return (
            f"{self.student.student_number} {self.date} "
            f"{self.attendance_type} → {self.status}"
        )

    @property
    def is_credited(self):
        """True when this slot counts as attended (PRESENT or LATE)."""
        return self.status in (self.Status.PRESENT, self.Status.LATE)


class Fine(models.Model):
    """A per-student, per-event fine ledger entry.

    This is a *ledger only* — there is no payment gateway.  ``mark_paid``
    simply records that the student handed cash to the treasurer.
    """

    class Status(models.TextChoices):
        UNPAID = "UNPAID", "Unpaid"
        PAID = "PAID", "Paid"

    student = models.ForeignKey(
        "accounts.Student", on_delete=models.CASCADE, related_name="fines"
    )
    event = models.ForeignKey(
        Event, on_delete=models.CASCADE, related_name="fines"
    )
    amount = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    missed_slots = models.PositiveIntegerField(default=0)
    status = models.CharField(
        max_length=10, choices=Status.choices, default=Status.UNPAID
    )
    paid_at = models.DateTimeField(blank=True, null=True)
    recorded_by = models.ForeignKey(
        "accounts.User",
        on_delete=models.SET_NULL,
        blank=True,
        null=True,
        related_name="recorded_fines",
    )
    needs_review = models.BooleanField(
        default=False,
        help_text="Set when a recompute disagrees with an already-PAID fine.",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-created_at"]
        unique_together = ("student", "event")

    def __str__(self):
        return f"Fine {self.student.student_number} / {self.event.name}: {self.amount} ({self.status})"

    def mark_paid(self, recorded_by=None, when=None):
        """Record that the fine was settled in cash with the treasurer."""
        from django.utils import timezone

        self.status = self.Status.PAID
        self.paid_at = when or timezone.now()
        if recorded_by is not None:
            self.recorded_by = recorded_by
        self.needs_review = False
        self.save(update_fields=["status", "paid_at", "recorded_by", "needs_review", "updated_at"])
        return self


@receiver(post_delete, sender=QRCode)
def _delete_qr_image(sender, instance, **kwargs):
    """Remove a deleted QR's PNG from storage (Cloudinary or local)."""
    if instance.image:
        instance.image.storage.delete(instance.image.name)
