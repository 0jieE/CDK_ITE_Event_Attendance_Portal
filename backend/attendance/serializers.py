"""Serializers for the attendance & finance domain."""

from rest_framework import serializers

from accounts.models import Student
from accounts.serializers import UserSummarySerializer

from .models import (
    AttendanceLog,
    AttendanceType,
    Event,
    Fine,
    QRCode,
    Semester,
    SchoolYear,
)


class StudentRefSerializer(serializers.ModelSerializer):
    """Read-only student reference embedded by logs / fines / QR codes."""

    user = UserSummarySerializer(read_only=True)

    class Meta:
        model = Student
        fields = ["id", "student_number", "user"]
        read_only_fields = fields


class SchoolYearSerializer(serializers.ModelSerializer):
    class Meta:
        model = SchoolYear
        fields = ["id", "sy"]


class SemesterSerializer(serializers.ModelSerializer):
    school_year_label = serializers.CharField(source="school_year.sy", read_only=True)
    label = serializers.CharField(source="__str__", read_only=True)

    class Meta:
        model = Semester
        fields = ["id", "school_year", "school_year_label", "name", "label"]


class EventSerializer(serializers.ModelSerializer):
    semester_label = serializers.CharField(source="semester.__str__", read_only=True)

    class Meta:
        model = Event
        fields = [
            "id",
            "name",
            "semester",
            "semester_label",
            "start_date",
            "end_date",
            "fine_rate",
            "required_types",
            "is_active",
            "am_in_start", "am_in_end",
            "am_out_start", "am_out_end",
            "pm_in_start", "pm_in_end",
            "pm_out_start", "pm_out_end",
        ]

    def validate_required_types(self, value):
        if not isinstance(value, list) or not value:
            raise serializers.ValidationError(
                "Must be a non-empty list of attendance types."
            )
        valid = set(AttendanceType.values)
        invalid = [t for t in value if t not in valid]
        if invalid:
            raise serializers.ValidationError(
                f"Invalid attendance type(s): {invalid}. Valid values: {sorted(valid)}."
            )
        return value

    def validate(self, attrs):
        # Use existing instance values for any field not supplied on update.
        start = attrs.get("start_date", getattr(self.instance, "start_date", None))
        end = attrs.get("end_date", getattr(self.instance, "end_date", None))
        if start and end and end < start:
            raise serializers.ValidationError(
                {"end_date": "End date must be on or after the start date."}
            )
        return attrs


class AttendanceLogSerializer(serializers.ModelSerializer):
    """Read-only admin view of attendance logs (mobile creates them later)."""

    student = StudentRefSerializer(read_only=True)
    event_name = serializers.CharField(source="event.name", read_only=True)
    scanned_by_name = serializers.CharField(
        source="scanned_by.user.get_full_name", read_only=True, default=None
    )

    class Meta:
        model = AttendanceLog
        fields = [
            "id",
            "student",
            "event",
            "event_name",
            "date",
            "attendance_type",
            "scanned_at",
            "status",
            "scanned_by",
            "scanned_by_name",
        ]
        read_only_fields = fields


class QRCodeSerializer(serializers.ModelSerializer):
    """Read-only serializer for generated QR codes (admin inspection)."""

    student = StudentRefSerializer(read_only=True)
    event_name = serializers.CharField(source="event.name", read_only=True)

    class Meta:
        model = QRCode
        fields = [
            "id",
            "student",
            "event",
            "event_name",
            "date",
            "token",
            "image",
            "created_at",
        ]
        read_only_fields = fields


class FineSerializer(serializers.ModelSerializer):
    """Fines ledger serializer; only ``status`` is admin-editable here."""

    student = StudentRefSerializer(read_only=True)
    event_name = serializers.CharField(source="event.name", read_only=True)
    recorded_by_name = serializers.CharField(
        source="recorded_by.get_full_name", read_only=True, default=None
    )

    class Meta:
        model = Fine
        fields = [
            "id",
            "student",
            "event",
            "event_name",
            "amount",
            "missed_slots",
            "status",
            "paid_at",
            "recorded_by",
            "recorded_by_name",
            "needs_review",
            "created_at",
            "updated_at",
        ]
        read_only_fields = [
            "id",
            "student",
            "event",
            "event_name",
            "amount",
            "missed_slots",
            "paid_at",
            "recorded_by",
            "recorded_by_name",
            "needs_review",
            "created_at",
            "updated_at",
        ]


# ---------------------------------------------------------------------------
# Action / report serializers (used for request validation & API docs)
# ---------------------------------------------------------------------------
class FineCalculateSerializer(serializers.Serializer):
    """Request body for ``POST /api/fines/calculate/``."""

    event_id = serializers.IntegerField()

    def validate_event_id(self, value):
        if not Event.objects.filter(pk=value).exists():
            raise serializers.ValidationError("No event with that id.")
        return value


class ReportQuerySerializer(serializers.Serializer):
    """Query params shared by the attendance & financial report endpoints."""

    semester = serializers.IntegerField(required=False)
    event = serializers.IntegerField(required=False)
    date_from = serializers.DateField(required=False)
    date_to = serializers.DateField(required=False)
