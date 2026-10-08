"""Flutter-facing APIs: instructor scanning + student self-service.

All endpoints reuse the existing models, JWT auth and RBAC permission classes.
Student endpoints are strictly scoped to ``request.user``'s own record.
"""

from decimal import Decimal

from django.db.models import Sum
from django.utils import timezone
from drf_spectacular.utils import OpenApiParameter, extend_schema
from rest_framework import generics, status
from rest_framework.exceptions import PermissionDenied
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView

from accounts.models import Instructor, Student
from accounts.permissions import IsInstructor, IsStudent

from .models import AttendanceLog, Event, Fine, QRCode
from .mobile_serializers import (
    BalanceSerializer,
    QRCodeMobileSerializer,
    QRGenerateSerializer,
    ScanRequestSerializer,
    ScanResultSerializer,
    StudentAttendanceSerializer,
    StudentFineSerializer,
    StudentPasswordChangeSerializer,
    StudentProfileSerializer,
    StudentProfileUpdateSerializer,
)
from . import services
from .serializers import AttendanceLogSerializer, EventSerializer

# Query parameters reused by several list endpoints.
_EVENT_PARAM = OpenApiParameter("event", int, description="Filter by event id")
_DATE_PARAM = OpenApiParameter("date", str, description="Filter by date (YYYY-MM-DD)")


# ===========================================================================
# Instructor APIs
# ===========================================================================
class InstructorEventsView(generics.ListAPIView):
    """Active events whose date range includes today (scannable right now)."""

    serializer_class = EventSerializer
    permission_classes = [IsInstructor]

    def get_queryset(self):
        today = timezone.localdate()
        return (
            Event.objects.filter(
                is_active=True, start_date__lte=today, end_date__gte=today
            )
            .select_related("semester__school_year")
            .order_by("start_date", "name")
        )


class InstructorScanView(APIView):
    """Validate a scanned **daily** QR token and record attendance.

    The QR no longer encodes a slot. The slot is decided here from the current
    time and the event's admin-set time windows: the scan records whichever
    required slot's window contains "now". Outside every window the scan is
    rejected (``OUTSIDE_WINDOW``) and the slot stays absent (auto-fined later).

    Distinct ``code`` values let the app show the right feedback:
    ``INVALID_TOKEN`` (404); ``EVENT_INACTIVE`` / ``EVENT_NOT_TODAY`` /
    ``STALE_QR`` / ``OUTSIDE_WINDOW`` (400); already-recorded (200); success (201).
    """

    permission_classes = [IsInstructor]
    # Per-instructor rate cap (``scan`` in DEFAULT_THROTTLE_RATES) — also slows
    # anyone trying to brute-force tokens with a stolen instructor account.
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "scan"

    @extend_schema(
        request=ScanRequestSerializer,
        responses={201: ScanResultSerializer, 200: ScanResultSerializer},
    )
    def post(self, request):
        in_ser = ScanRequestSerializer(data=request.data)
        in_ser.is_valid(raise_exception=True)
        token = in_ser.validated_data["token"]
        now = timezone.localtime()
        today = now.date()

        qr = (
            QRCode.objects.select_related("student__user", "event")
            .filter(token=token)
            .first()
        )
        if qr is None:
            return self._error("Invalid QR code — no matching record.", "INVALID_TOKEN", 404)

        event = qr.event
        if not event.is_active:
            return self._error("This event is not active.", "EVENT_INACTIVE", 400)
        if not (event.start_date <= today <= event.end_date):
            return self._error("This event is not running today.", "EVENT_NOT_TODAY", 400)
        if qr.date != today:
            return self._error(
                f"This QR code is dated {qr.date}, not today ({today}).",
                "STALE_QR", 400,
            )

        # Decide the slot from the current time against the event's windows.
        slot = event.slot_for_time(now.time())
        if slot is None:
            return self._error(
                "No attendance slot is open right now. Scanning is only allowed "
                "during the scheduled time windows.",
                "OUTSIDE_WINDOW", 400,
            )

        log = AttendanceLog.objects.filter(
            student=qr.student, event=event, date=qr.date, attendance_type=slot,
        ).first()

        # Already counted as attended → friendly response, not an error.
        if log and log.is_credited:
            return self._result(
                log, created=False,
                detail="Attendance was already recorded for this slot.",
                http_status=200, request=request,
            )

        # In-window scan = PRESENT (no LATE: outside the window is simply absent).
        instructor = Instructor.objects.filter(user=request.user).first()
        if log is None:
            log = AttendanceLog(
                student=qr.student, event=event, date=qr.date, attendance_type=slot,
            )
        log.status = AttendanceLog.Status.PRESENT
        log.scanned_at = timezone.now()
        log.scanned_by = instructor
        log.save()

        return self._result(
            log, created=True, detail="Attendance recorded.", http_status=201,
            request=request,
        )

    # -- helpers ------------------------------------------------------------
    def _result(self, log, *, created, detail, http_status, request=None):
        user = log.student.user
        payload = {
            "created": created,
            "detail": detail,
            "student_name": user.get_full_name() or user.username,
            "student_number": log.student.student_number,
            "student_photo": user.get_profile_image_url("medium", request=request),
            "event_name": log.event.name,
            "attendance_type": log.attendance_type,
            "attendance_type_display": log.get_attendance_type_display(),
            "date": log.date,
            "status": log.status,
            "scanned_at": log.scanned_at,
        }
        return Response(ScanResultSerializer(payload).data, status=http_status)

    def _error(self, detail, code, http_status):
        return Response({"detail": detail, "code": code}, status=http_status)


class InstructorScansView(generics.ListAPIView):
    """Recent scans recorded by the authenticated instructor."""

    serializer_class = AttendanceLogSerializer
    permission_classes = [IsInstructor]
    queryset = AttendanceLog.objects.none()  # real qs built per-request below

    @extend_schema(parameters=[_EVENT_PARAM, _DATE_PARAM])
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    def get_queryset(self):
        qs = AttendanceLog.objects.filter(
            scanned_by__user=self.request.user
        ).select_related("student__user", "event", "scanned_by__user")
        event = self.request.query_params.get("event")
        date = self.request.query_params.get("date")
        if event:
            qs = qs.filter(event_id=event)
        if date:
            qs = qs.filter(date=date)
        return qs.order_by("-scanned_at")


# ===========================================================================
# Student APIs (own data only)
# ===========================================================================
class StudentScopedMixin:
    """Resolve and enforce the requesting user's own Student record."""

    permission_classes = [IsStudent]

    def get_student(self):
        student = Student.objects.select_related("user").filter(
            user=self.request.user
        ).first()
        if student is None:
            raise PermissionDenied("No student profile is linked to this account.")
        if not student.is_approved:
            raise PermissionDenied("Your registration has not been approved yet.")
        return student


class StudentProfileView(StudentScopedMixin, APIView):
    """The authenticated student's own profile (read, and edit their own info)."""

    @extend_schema(responses=StudentProfileSerializer)
    def get(self, request):
        return Response(
            StudentProfileSerializer(self.get_student(), context={"request": request}).data
        )

    @extend_schema(request=StudentProfileUpdateSerializer, responses=StudentProfileSerializer)
    def patch(self, request):
        """Update name / username. Only ever touches ``request.user``."""
        student = self.get_student()
        ser = StudentProfileUpdateSerializer(
            data=request.data, partial=True, context={"user": request.user}
        )
        ser.is_valid(raise_exception=True)
        ser.save()
        student.refresh_from_db()
        student.user.refresh_from_db()
        return Response(
            StudentProfileSerializer(student, context={"request": request}).data
        )


class StudentPasswordView(StudentScopedMixin, APIView):
    """``POST /api/student/profile/password/`` - change own password."""

    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "password"

    @extend_schema(request=StudentPasswordChangeSerializer, responses={204: None})
    def post(self, request):
        self.get_student()
        ser = StudentPasswordChangeSerializer(data=request.data, context={"user": request.user})
        ser.is_valid(raise_exception=True)
        ser.save()
        return Response(status=status.HTTP_204_NO_CONTENT)


class StudentEventsView(StudentScopedMixin, generics.ListAPIView):
    """Active events that haven't ended yet (current + upcoming).

    ``?all=true`` returns **every** event - past, current and future - newest
    first (used by the history filter, which needs finished events too).
    """

    serializer_class = EventSerializer
    queryset = Event.objects.none()

    @extend_schema(parameters=[OpenApiParameter("all", bool, description="Include past events")])
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    def get_queryset(self):
        self.get_student()  # enforce ownership / profile presence
        qs = Event.objects.select_related("semester__school_year")
        if self.request.query_params.get("all", "").lower() in ("1", "true", "yes"):
            return qs.order_by("-start_date", "name")
        today = timezone.localdate()
        return qs.filter(is_active=True, end_date__gte=today).order_by("start_date", "name")


class StudentQRGenerateView(StudentScopedMixin, APIView):
    """Create (or fetch) the student's **daily** QR code for an event-day."""

    @extend_schema(request=QRGenerateSerializer, responses=QRCodeMobileSerializer)
    def post(self, request):
        student = self.get_student()
        ser = QRGenerateSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        qr, created = QRCode.objects.get_or_create(
            student=student,
            event=ser.validated_data["event"],
            date=ser.validated_data["date"],
        )
        data = QRCodeMobileSerializer(qr, context={"request": request}).data
        return Response(
            data,
            status=status.HTTP_201_CREATED if created else status.HTTP_200_OK,
        )


class StudentQRListView(StudentScopedMixin, generics.ListAPIView):
    """The student's own QR slots, filterable by event/date."""

    serializer_class = QRCodeMobileSerializer
    queryset = QRCode.objects.none()

    @extend_schema(parameters=[_EVENT_PARAM, _DATE_PARAM])
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    def get_queryset(self):
        student = self.get_student()
        qs = QRCode.objects.filter(student=student)
        event = self.request.query_params.get("event")
        date = self.request.query_params.get("date")
        if event:
            qs = qs.filter(event_id=event)
        if date:
            qs = qs.filter(date=date)
        return qs.order_by("date", "id")


class StudentAttendanceView(StudentScopedMixin, generics.ListAPIView):
    """The student's own attendance logs, filterable by event."""

    serializer_class = StudentAttendanceSerializer
    queryset = AttendanceLog.objects.none()

    @extend_schema(parameters=[_EVENT_PARAM])
    def get(self, request, *args, **kwargs):
        return super().get(request, *args, **kwargs)

    def get_queryset(self):
        student = self.get_student()
        qs = AttendanceLog.objects.filter(student=student).select_related("event")
        event = self.request.query_params.get("event")
        if event:
            qs = qs.filter(event_id=event)
        return qs.order_by("-date", "attendance_type")


class StudentFinesView(StudentScopedMixin, generics.ListAPIView):
    """The student's own fines."""

    serializer_class = StudentFineSerializer
    queryset = Fine.objects.none()

    def get_queryset(self):
        student = self.get_student()
        services.refresh_active_fines()  # keep fines current (rate-limited)
        return (
            Fine.objects.filter(student=student)
            .select_related("event")
            .order_by("-created_at")
        )


class StudentBalanceView(StudentScopedMixin, APIView):
    """Aggregated fines balance for the authenticated student."""

    @extend_schema(responses=BalanceSerializer)
    def get(self, request):
        student = self.get_student()
        services.refresh_active_fines()  # keep fines current (rate-limited)
        fines = Fine.objects.filter(student=student)

        def total(qs):
            return qs.aggregate(s=Sum("amount"))["s"] or Decimal("0.00")

        payload = {
            "total_fines": total(fines),
            "total_paid": total(fines.filter(status=Fine.Status.PAID)),
            "outstanding": total(fines.filter(status=Fine.Status.UNPAID)),
        }
        return Response(BalanceSerializer(payload).data)
