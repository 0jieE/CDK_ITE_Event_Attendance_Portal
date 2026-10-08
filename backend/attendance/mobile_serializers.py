"""Serializers for the Flutter-facing (instructor + student) APIs.

These are scoped to the requesting user; nothing here exposes another
student's or instructor's data.
"""

from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password
from django.utils import timezone
from rest_framework import serializers

from .models import (
    AttendanceLog,
    Event,
    Fine,
    QRCode,
)


# ---------------------------------------------------------------------------
# Instructor — scanning
# ---------------------------------------------------------------------------
class ScanRequestSerializer(serializers.Serializer):
    """Body for ``POST /api/instructor/scan/``."""

    token = serializers.CharField(max_length=64)


class ScanResultSerializer(serializers.Serializer):
    """Response shape for a scan (success or already-recorded)."""

    created = serializers.BooleanField()
    detail = serializers.CharField()
    student_name = serializers.CharField()
    student_number = serializers.CharField()
    #: Student's photo so the instructor can compare it with the person scanned.
    student_photo = serializers.CharField(allow_null=True, required=False)
    event_name = serializers.CharField()
    attendance_type = serializers.CharField()
    attendance_type_display = serializers.CharField()
    date = serializers.DateField()
    status = serializers.CharField()
    scanned_at = serializers.DateTimeField()


# ---------------------------------------------------------------------------
# Student — QR generation
# ---------------------------------------------------------------------------
class QRGenerateSerializer(serializers.Serializer):
    """Body for ``POST /api/student/qr/generate/``.

    The QR is **per event-day** — only ``event`` and ``date`` are needed. The slot
    is decided at scan time from the event's time windows. Validates that the
    event is active, the date is within the event's range and **is today**: a
    student can never generate a QR in advance (the app only mutes other dates,
    this is the real enforcement).
    """

    event = serializers.PrimaryKeyRelatedField(queryset=Event.objects.all())
    date = serializers.DateField()

    def validate(self, attrs):
        event = attrs["event"]
        date = attrs["date"]

        if not event.is_active:
            raise serializers.ValidationError({"event": "Event is not active."})
        if not (event.start_date <= date <= event.end_date):
            raise serializers.ValidationError(
                {"date": f"Date must be within {event.start_date} – {event.end_date}."}
            )
        today = timezone.localdate()
        if date != today:
            raise serializers.ValidationError(
                {"date": f"You can only generate a QR for today ({today})."}
            )
        return attrs


class QRCodeMobileSerializer(serializers.ModelSerializer):
    """A student's daily QR — the token is all the app needs to render it."""

    image_url = serializers.SerializerMethodField()

    class Meta:
        model = QRCode
        fields = [
            "id",
            "token",
            "event",
            "date",
            "image_url",
        ]
        read_only_fields = fields

    def get_image_url(self, obj) -> str | None:
        if not obj.image:
            return None
        request = self.context.get("request")
        url = obj.image.url
        return request.build_absolute_uri(url) if request else url


# ---------------------------------------------------------------------------
# Student — profile / attendance / fines / balance
# ---------------------------------------------------------------------------
class StudentProfileSerializer(serializers.Serializer):
    """Own student profile."""

    id = serializers.IntegerField()
    student_number = serializers.CharField()
    full_name = serializers.CharField(source="user.get_full_name")
    first_name = serializers.CharField(source="user.first_name")
    middle_name = serializers.CharField(source="user.middle_name", allow_null=True)
    last_name = serializers.CharField(source="user.last_name")
    username = serializers.CharField(source="user.username")
    profile_image = serializers.SerializerMethodField()
    year_level = serializers.CharField()
    year_level_display = serializers.CharField(source="get_year_level_display")
    section = serializers.CharField()
    year_section = serializers.CharField()

    def get_profile_image(self, obj) -> str | None:
        return obj.user.get_profile_image_url("medium", request=self.context.get("request"))


class StudentAttendanceSerializer(serializers.ModelSerializer):
    event_name = serializers.CharField(source="event.name", read_only=True)
    attendance_type_display = serializers.CharField(
        source="get_attendance_type_display", read_only=True
    )

    class Meta:
        model = AttendanceLog
        fields = [
            "id",
            "event",
            "event_name",
            "date",
            "attendance_type",
            "attendance_type_display",
            "status",
            "scanned_at",
        ]
        read_only_fields = fields


class StudentFineSerializer(serializers.ModelSerializer):
    event_name = serializers.CharField(source="event.name", read_only=True)

    class Meta:
        model = Fine
        fields = [
            "id",
            "event",
            "event_name",
            "missed_slots",
            "amount",
            "status",
            "paid_at",
        ]
        read_only_fields = fields


class BalanceSerializer(serializers.Serializer):
    """Aggregated fines balance for ``GET /api/student/balance/``."""

    total_fines = serializers.DecimalField(max_digits=12, decimal_places=2)
    total_paid = serializers.DecimalField(max_digits=12, decimal_places=2)
    outstanding = serializers.DecimalField(max_digits=12, decimal_places=2)


class StudentProfileUpdateSerializer(serializers.Serializer):
    """Body for ``PATCH /api/student/profile/`` - the fields a student may edit.

    Student number, year level and section are managed by the adviser and are
    deliberately absent (any such keys in the request are ignored).
    """

    first_name = serializers.CharField(max_length=150, required=False)
    middle_name = serializers.CharField(
        max_length=150, required=False, allow_blank=True, allow_null=True
    )
    last_name = serializers.CharField(max_length=150, required=False)
    username = serializers.CharField(max_length=150, required=False)

    def validate_username(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Username cannot be blank.")
        user = self.context["user"]
        taken = (
            get_user_model().objects.filter(username__iexact=value)
            .exclude(pk=user.pk).exists()
        )
        if taken:
            raise serializers.ValidationError("A user with that username already exists.")
        return value

    def validate_first_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("First name cannot be blank.")
        return value

    def validate_last_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Last name cannot be blank.")
        return value

    def save(self, **kwargs):
        user = self.context["user"]
        for field, value in self.validated_data.items():
            if isinstance(value, str):
                value = value.strip()
            setattr(user, field, value)
        user.save(update_fields=list(self.validated_data) or None)
        return user


class StudentPasswordChangeSerializer(serializers.Serializer):
    """Body for ``POST /api/student/profile/password/``."""

    current_password = serializers.CharField(write_only=True, style={"input_type": "password"})
    new_password = serializers.CharField(write_only=True, style={"input_type": "password"})

    def validate_current_password(self, value):
        if not self.context["user"].check_password(value):
            raise serializers.ValidationError("Current password is incorrect.")
        return value

    def validate(self, attrs):
        user = self.context["user"]
        try:
            validate_password(attrs["new_password"], user)
        except Exception as exc:  # django ValidationError -> DRF field error list
            raise serializers.ValidationError({"new_password": list(getattr(exc, "messages", [str(exc)]))})
        if attrs["new_password"] == attrs["current_password"]:
            raise serializers.ValidationError(
                {"new_password": ["The new password must be different from the current one."]}
            )
        return attrs

    def save(self, **kwargs):
        user = self.context["user"]
        user.set_password(self.validated_data["new_password"])
        user.save(update_fields=["password"])
        return user
