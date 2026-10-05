"""django-filter FilterSets for the attendance & finance endpoints."""

import django_filters as filters

from .models import AttendanceLog, Event, Fine


class EventFilter(filters.FilterSet):
    school_year = filters.NumberFilter(field_name="semester__school_year_id")
    start_after = filters.DateFilter(field_name="start_date", lookup_expr="gte")
    end_before = filters.DateFilter(field_name="end_date", lookup_expr="lte")

    class Meta:
        model = Event
        fields = ["semester", "school_year", "is_active"]


class AttendanceLogFilter(filters.FilterSet):
    date_from = filters.DateFilter(field_name="date", lookup_expr="gte")
    date_to = filters.DateFilter(field_name="date", lookup_expr="lte")

    class Meta:
        model = AttendanceLog
        fields = ["event", "student", "date", "attendance_type", "status"]


class FineFilter(filters.FilterSet):
    class Meta:
        model = Fine
        fields = ["event", "student", "status", "needs_review"]
