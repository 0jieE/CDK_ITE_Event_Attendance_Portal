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
from django.db import models, transaction
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

    @property
    def has_events(self):
        """True once any event exists under this school year (it is then locked for advisers)."""
        return Event.objects.filter(semester__school_year=self).exists()


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
    is_active = models.BooleanField(
        default=False,
        help_text="The current semester: the default filter on the attendance pages and the "
                  "default semester of a new event. Only one semester is active at a time.",
    )

    class Meta:
        ordering = ["-school_year__sy", "name"]
        unique_together = ("school_year", "name")
        constraints = [
            models.UniqueConstraint(
                fields=["is_active"], condition=models.Q(is_active=True), name="uniq_active_semester",
            ),
        ]

    def save(self, *args, **kwargs):
        # Activating this semester deactivates whichever one was active before.
        with transaction.atomic():
            if self._state.adding and not Semester.objects.filter(is_active=True).exists():
                self.is_active = True          # the first semester ever created starts out active
            if self.is_active:
                Semester.objects.exclude(pk=self.pk).filter(is_active=True).update(is_active=False)
            super().save(*args, **kwargs)

    def validate_constraints(self, exclude=None):
        # The only constraint is "one active semester", which save() resolves by deactivating
        # the previous one; forms/serializers must not reject activating another semester.
        return

    @classmethod
    def current(cls):
        """The active semester, or ``None`` when none is marked active."""
        return cls.objects.select_related("school_year").filter(is_active=True).first()

    def __str__(self):
        return f"{self.school_year.sy} {self.name}"

    @property
    def has_events(self):
        """True once an event exists under this semester (it is then locked for advisers)."""
        return self.events.exists()


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
        help_text="Default amount charged per missed required attendance slot "
                  "(a day can override it - see EventDayFine).",
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

    @property
    def day_rates(self):
        """``{iso-date: Decimal}`` of the days whose fine differs from ``fine_rate``."""
        return {row.date.isoformat(): row.fine_rate for row in self.day_fines.all()}

    def rate_map(self):
        """``{date: Decimal}`` override lookup (dates, not strings) for fine maths."""
        return {row.date: row.fine_rate for row in self.day_fines.all()}

    def rate_for(self, day, overrides=None):
        """Fine per missed slot on ``day``: the day's override, else ``fine_rate``."""
        overrides = self.rate_map() if overrides is None else overrides
        return overrides.get(day, self.fine_rate)

    def iter_dates(self):
        """Yield every :class:`~datetime.date` in ``[start_date, end_date]``."""
        from datetime import timedelta

        current = self.start_date
        while current <= self.end_date:
            yield current
            current += timedelta(days=1)


class EventDayFine(models.Model):
    """A per-day fine rate for a multi-day event (overrides ``Event.fine_rate``)."""

    event = models.ForeignKey(Event, on_delete=models.CASCADE, related_name="day_fines")
    date = models.DateField()
    fine_rate = models.DecimalField(
        max_digits=10, decimal_places=2,
        help_text="Amount charged per missed required slot on this day.",
    )

    class Meta:
        ordering = ["date"]
        constraints = [
            models.UniqueConstraint(fields=["event", "date"], name="uniq_event_day_fine"),
        ]

    def __str__(self):
        return f"{self.event.name} {self.date}: {self.fine_rate}"

    def clean(self):
        if self.event_id and self.date and not (
            self.event.start_date <= self.date <= self.event.end_date
        ):
            raise ValidationError({"date": "The day must fall within the event's dates."})
        if self.fine_rate is not None and self.fine_rate < 0:
            raise ValidationError({"fine_rate": "A fine cannot be negative."})


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
        """True when this slot counts as attended (a scan inside its window = PRESENT)."""
        return self.status == self.Status.PRESENT


class Fine(models.Model):
    """A per-student, per-event fine ledger entry.

    This is a *ledger only* — there is no payment gateway.  Payments are recorded
    **per missed slot** (:class:`FineSlotPayment`) as the student hands cash to the
    treasurer; ``amount_paid`` is their sum and the fine is ``PAID`` once every missed
    slot is paid.  ``mark_paid`` pays all the remaining slots at once.  (Fines marked PAID
    before slot payments existed have no slot rows and are treated as paid in full.)
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
    amount_paid = models.DecimalField(
        max_digits=10, decimal_places=2, default=0,
        help_text="Sum of the slot payments (or the full amount for a fine paid in full).",
    )
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

    @property
    def balance(self):
        """What is still owed (never negative)."""
        return max(self.amount - self.amount_paid, 0)

    @property
    def is_partially_paid(self):
        return self.status != self.Status.PAID and self.amount_paid > 0

    def mark_paid(self, recorded_by=None, when=None):
        """Record that the rest of the fine was settled in cash with the treasurer."""
        from . import services

        services.pay_slots(self, recorded_by=recorded_by, when=when)
        return self


class FineSlotPayment(models.Model):
    """Cash received for ONE missed slot (a date + attendance type) of a fine."""

    fine = models.ForeignKey(Fine, on_delete=models.CASCADE, related_name="slot_payments")
    date = models.DateField()
    attendance_type = models.CharField(max_length=10, choices=AttendanceType.choices)
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    paid_at = models.DateTimeField(auto_now_add=True)
    recorded_by = models.ForeignKey(
        "accounts.User", on_delete=models.SET_NULL, blank=True, null=True,
        related_name="recorded_slot_payments",
    )

    class Meta:
        ordering = ["date", "attendance_type"]
        constraints = [
            models.UniqueConstraint(fields=["fine", "date", "attendance_type"], name="uniq_fine_slot_payment"),
        ]

    def __str__(self):
        return f"{self.fine_id} {self.date} {self.attendance_type}: {self.amount}"


@receiver(post_delete, sender=QRCode)
def _delete_qr_image(sender, instance, **kwargs):
    """Remove a deleted QR's PNG from storage (Cloudinary or local)."""
    if instance.image:
        instance.image.storage.delete(instance.image.name)
