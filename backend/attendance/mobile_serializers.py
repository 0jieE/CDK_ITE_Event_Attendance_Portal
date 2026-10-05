"""Serializers for the Flutter-facing (instructor + student) APIs.

These are scoped to the requesting user; nothing here exposes another
student's or instructor's data.
"""

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

    The QR is now **per day** — only ``event`` and ``date`` are needed. The slot
    is decided at scan time from the event's time windows. Validates that the
    event is active and the date is within the event's range.
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
    email = serializers.EmailField(source="user.email")
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
