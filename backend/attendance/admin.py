"""Django admin for the attendance & finance app."""

from django.contrib import admin

from .models import (
    AttendanceLog,
    Event,
    EventDayFine,
    Fine,
    QRCode,
    Semester,
    SchoolYear,
)


class _KeepRecordedDataMixin:
    """Never offer deleting a record whose attendance / fine payments would be lost with it."""

    def has_delete_permission(self, request, obj=None):
        if obj is not None and obj.delete_block_reason:
            return False
        return super().has_delete_permission(request, obj)

    def get_actions(self, request):
        actions = super().get_actions(request)
        actions.pop("delete_selected", None)        # the bulk action cannot check each record
        return actions


@admin.register(SchoolYear)
class SchoolYearAdmin(_KeepRecordedDataMixin, admin.ModelAdmin):
    list_display = ("id", "sy")
    search_fields = ("sy",)


@admin.register(Semester)
class SemesterAdmin(_KeepRecordedDataMixin, admin.ModelAdmin):
    list_display = ("id", "school_year", "name")
    list_filter = ("school_year", "name")
    search_fields = ("school_year__sy",)


class EventDayFineInline(admin.TabularInline):
    model = EventDayFine
    extra = 0


@admin.register(Event)
class EventAdmin(_KeepRecordedDataMixin, admin.ModelAdmin):
    inlines = [EventDayFineInline]
    list_display = (
        "name",
        "semester",
        "start_date",
        "end_date",
        "fine_rate",
        "is_active",
    )
    list_filter = ("is_active", "semester__school_year", "semester")
    search_fields = ("name",)
    date_hierarchy = "start_date"


@admin.register(QRCode)
class QRCodeAdmin(admin.ModelAdmin):
    list_display = ("id", "student", "event", "date", "token")
    list_filter = ("event", "date")
    search_fields = ("student__student_number", "token")
    readonly_fields = ("token", "image", "created_at")


@admin.register(AttendanceLog)
class AttendanceLogAdmin(admin.ModelAdmin):
    list_display = (
        "student",
        "event",
        "date",
        "attendance_type",
        "status",
        "scanned_at",
        "scanned_by",
    )
    list_filter = ("status", "attendance_type", "event", "date")
    search_fields = ("student__student_number",)
    date_hierarchy = "date"


@admin.register(Fine)
class FineAdmin(admin.ModelAdmin):
    list_display = (
        "student",
        "event",
        "amount",
        "missed_slots",
        "status",
        "needs_review",
        "paid_at",
        "recorded_by",
    )
    list_filter = ("status", "needs_review", "event")
    search_fields = ("student__student_number",)
    readonly_fields = ("created_at", "updated_at")
