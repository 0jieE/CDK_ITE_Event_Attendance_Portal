"""Admin-side viewsets and function views for attendance & finance.

Everything here requires :class:`accounts.permissions.IsAdmin`.  Business logic
lives in :mod:`attendance.services`; the views only orchestrate.
"""

import csv

from django.http import HttpResponse
from django_filters.rest_framework import DjangoFilterBackend
from drf_spectacular.utils import OpenApiParameter, extend_schema
from rest_framework import filters, status, viewsets
from rest_framework.decorators import action, api_view, permission_classes
from rest_framework.response import Response

from accounts.permissions import IsAdmin

from . import services
from .filters import AttendanceLogFilter, EventFilter, FineFilter
from .models import (
    AttendanceLog,
    Event,
    Fine,
    Semester,
    SchoolYear,
)
from .serializers import (
    AttendanceLogSerializer,
    EventSerializer,
    FineCalculateSerializer,
    FineSerializer,
    ReportQuerySerializer,
    SchoolYearSerializer,
    SemesterSerializer,
)


class SchoolYearViewSet(viewsets.ModelViewSet):
    """CRUD for school years."""

    queryset = SchoolYear.objects.all()
    serializer_class = SchoolYearSerializer
    permission_classes = [IsAdmin]
    filter_backends = [filters.SearchFilter, filters.OrderingFilter]
    search_fields = ["sy"]
    ordering_fields = ["sy"]


class SemesterViewSet(viewsets.ModelViewSet):
    """CRUD for semesters; filterable by school_year."""

    queryset = Semester.objects.select_related("school_year").all()
    serializer_class = SemesterSerializer
    permission_classes = [IsAdmin]
    filter_backends = [DjangoFilterBackend, filters.OrderingFilter]
    filterset_fields = ["school_year", "name"]
    ordering_fields = ["name", "school_year__sy"]


class EventViewSet(viewsets.ModelViewSet):
    """CRUD for events; filterable by semester, school_year and is_active."""

    queryset = Event.objects.select_related("semester__school_year").all()
    serializer_class = EventSerializer
    permission_classes = [IsAdmin]
    filter_backends = [DjangoFilterBackend, filters.SearchFilter, filters.OrderingFilter]
    filterset_class = EventFilter
    search_fields = ["name"]
    ordering_fields = ["start_date", "end_date", "name"]


class AttendanceLogViewSet(viewsets.ReadOnlyModelViewSet):
    """Read-only admin access to attendance logs.

    (Logs are created by the instructor scanning API in a later phase.)
    """

    queryset = AttendanceLog.objects.select_related(
        "student__user", "event", "scanned_by__user"
    ).all()
    serializer_class = AttendanceLogSerializer
    permission_classes = [IsAdmin]
    filter_backends = [DjangoFilterBackend, filters.OrderingFilter]
    filterset_class = AttendanceLogFilter
    ordering_fields = ["date", "scanned_at", "status"]


class FineViewSet(viewsets.ModelViewSet):
    """List / retrieve / update fines, plus calculate and mark-paid actions.

    Create & destroy are intentionally disabled — fines are produced by the
    calculation service, not by hand.
    """

    http_method_names = ["get", "patch", "put", "post", "head", "options"]
    queryset = Fine.objects.select_related(
        "student__user", "event", "recorded_by"
    ).all()
    serializer_class = FineSerializer
    permission_classes = [IsAdmin]
    filter_backends = [DjangoFilterBackend, filters.OrderingFilter]
    filterset_class = FineFilter

    def list(self, request, *args, **kwargs):
        # Keep fines current without a manual "Calculate" (rate-limited).
        services.refresh_active_fines()
        return super().list(request, *args, **kwargs)
    ordering_fields = ["amount", "created_at", "status"]

    @extend_schema(request=FineCalculateSerializer, responses=dict)
    @action(detail=False, methods=["post"])
    def calculate(self, request):
        """Run the idempotent fines calculator for one event.

        Body: ``{"event_id": <int>}``.
        """
        serializer = FineCalculateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        event = Event.objects.get(pk=serializer.validated_data["event_id"])
        result = services.compute_fines_for_event(event)
        return Response(result, status=status.HTTP_200_OK)

    @extend_schema(request=None, responses=FineSerializer)
    @action(detail=True, methods=["post"], url_path="mark-paid")
    def mark_paid(self, request, pk=None):
        """Record that this fine was settled in cash with the treasurer."""
        fine = self.get_object()
        if fine.status == Fine.Status.PAID:
            return Response(
                {"detail": "Fine is already marked as paid."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        fine.mark_paid(recorded_by=request.user)
        return Response(self.get_serializer(fine).data, status=status.HTTP_200_OK)


# ---------------------------------------------------------------------------
# Dashboard & reports
# ---------------------------------------------------------------------------
@extend_schema(responses=dict)
@api_view(["GET"])
@permission_classes([IsAdmin])
def dashboard(request):
    """Top-level admin dashboard aggregates."""
    return Response(services.build_dashboard())


def _parse_report_query(request):
    """Validate shared report query params, returning kwargs for the service."""
    query = ReportQuerySerializer(data=request.query_params)
    query.is_valid(raise_exception=True)
    data = query.validated_data
    return {
        "semester": data.get("semester"),
        "event": data.get("event"),
        "date_from": data.get("date_from"),
        "date_to": data.get("date_to"),
    }


def _csv_response(rows, filename):
    """Render a list[dict] as a downloadable CSV response."""
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = f'attachment; filename="{filename}"'
    if rows:
        writer = csv.DictWriter(response, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    return response


_REPORT_PARAMS = [
    OpenApiParameter("semester", int, description="Semester id"),
    OpenApiParameter("event", int, description="Event id"),
    OpenApiParameter("date_from", str, description="ISO date (inclusive)"),
    OpenApiParameter("date_to", str, description="ISO date (inclusive)"),
    OpenApiParameter("format", str, description="Set to 'csv' for CSV export"),
]


@extend_schema(parameters=_REPORT_PARAMS, responses=dict)
@api_view(["GET"])
@permission_classes([IsAdmin])
def attendance_report(request):
    """Attendance summary per event. Add ``?format=csv`` to download CSV."""
    rows = services.attendance_report(**_parse_report_query(request))
    if request.query_params.get("format") == "csv":
        return _csv_response(rows, "attendance_report.csv")
    return Response({"results": rows})


@extend_schema(parameters=_REPORT_PARAMS, responses=dict)
@api_view(["GET"])
@permission_classes([IsAdmin])
def financial_report(request):
    """Fines summary per event. Add ``?format=csv`` to download CSV."""
    rows = services.financial_report(**_parse_report_query(request))
    if request.query_params.get("format") == "csv":
        return _csv_response(rows, "financial_report.csv")
    return Response({"results": rows})
