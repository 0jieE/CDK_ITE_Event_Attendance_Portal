"""Web-portal views: authentication, dashboard, CRUD sections and the
custom Attendance-Logs / Fines / Reports pages.

All business logic is reused from ``attendance.services`` — nothing is
duplicated here.
"""

import csv
import logging

from django.conf import settings
from django.contrib import messages
from django.contrib.auth import authenticate, get_user_model, login, logout
from django.http import HttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.views.decorators.http import require_POST

from accounts.models import Instructor, Student
from attendance import services
from attendance.tasks import recompute_event_fines
from attendance.models import (
    AttendanceLog,
    AttendanceType,
    Event,
    Fine,
    SchoolYear,
    Semester,
)

from .crud import CrudSection
from .forms import (
    EventForm,
    FineCalculateForm,
    InstructorForm,
    PortalSettingsForm,
    SchoolYearForm,
    SemesterForm,
    StudentForm,
    UserForm,
)
from .mixins import (
    admin_required,
    htmx_action_response,
    is_htmx,
    is_portal_admin,
)
from .models import PortalSettings
from .theming import PALETTES

User = get_user_model()
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Authentication (Django sessions)
# ---------------------------------------------------------------------------
def login_view(request):
    """Session login for the Department Adviser (username + password)."""
    if is_portal_admin(request.user):
        return redirect("portal:dashboard")

    if request.method == "POST":
        identifier = (request.POST.get("identifier") or "").strip()
        password = request.POST.get("password") or ""

        user = authenticate(request, username=identifier, password=password)
        if user is None:
            messages.error(request, "Invalid credentials. Please try again.")
        elif not is_portal_admin(user):
            messages.error(request, "This portal is for the Department Adviser only.")
        else:
            login(request, user)
            messages.success(
                request, f"Welcome back, {user.get_full_name() or user.username}."
            )
            return redirect(request.GET.get("next") or "portal:dashboard")

    return render(request, "portal/auth/login.html")


def logout_view(request):
    """Log the admin out and return to the login page."""
    logout(request)
    messages.info(request, "You have been logged out.")
    return redirect("portal:login")


# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------
@admin_required
def dashboard_view(request):
    """Landing page: summary cards, per-event breakdown and a chart."""
    data = services.build_dashboard()
    context = {
        "active": "dashboard",
        "data": data,
        "pending_approvals": Student.objects.filter(
            approval_status=Student.ApprovalStatus.PENDING).count(),
        "chart_labels": [e["event_name"] for e in data["events"]],
        "chart_collected": [float(e["collected"]) for e in data["events"]],
        "chart_outstanding": [float(e["outstanding"]) for e in data["events"]],
    }
    return render(request, "portal/dashboard/index.html", context)


# ---------------------------------------------------------------------------
# CRUD sections
# ---------------------------------------------------------------------------
class EventsSection(CrudSection):
    section = "events"
    title = "Events"
    singular = "Event"
    model = Event
    form_class = EventForm
    table_template = "portal/events/partials/table.html"
    select_related = ("semester__school_year",)
    order_by = ("-start_date", "name")


class UsersSection(CrudSection):
    section = "users"
    title = "Users"
    singular = "User"
    model = User
    form_class = UserForm
    table_template = "portal/users/partials/table.html"
    order_by = ("last_name", "first_name")


class _LinkedUserSection(CrudSection):
    """Shared behaviour for Instructor/Student sections (delete linked user)."""

    select_related = ("user",)

    def perform_delete(self, instance):
        # Removing the user cascades to the profile row.
        instance.user.delete()


class InstructorsSection(_LinkedUserSection):
    section = "instructors"
    title = "Instructors"
    singular = "Instructor"
    model = Instructor
    form_class = InstructorForm
    table_template = "portal/instructors/partials/table.html"
    order_by = ("user__last_name", "user__first_name")


class StudentsSection(_LinkedUserSection):
    section = "students"
    title = "Students"
    singular = "Student"
    model = Student
    form_class = StudentForm
    table_template = "portal/students/partials/table.html"
    order_by = ("student_number",)


class SchoolYearsSection(CrudSection):
    section = "school_years"
    title = "School Years"
    singular = "School Year"
    model = SchoolYear
    form_class = SchoolYearForm
    table_template = "portal/school_years/partials/table.html"
    order_by = ("-sy",)


class SemestersSection(CrudSection):
    section = "semesters"
    title = "Semesters"
    singular = "Semester"
    model = Semester
    form_class = SemesterForm
    table_template = "portal/semesters/partials/table.html"
    select_related = ("school_year",)
    order_by = ("-school_year__sy", "name")


#: Declarative CRUD sections; the URLConf iterates this list.
SECTIONS = [
    UsersSection(),
    InstructorsSection(),
    StudentsSection(),
    SchoolYearsSection(),
    SemestersSection(),
    EventsSection(),
]


# ---------------------------------------------------------------------------
# Attendance Logs (read-only, filterable)
# ---------------------------------------------------------------------------
def _distinct_sections():
    """Sorted list of section labels currently in use (for filter dropdowns)."""
    return sorted(
        s for s in Student.objects.exclude(section="")
        .values_list("section", flat=True)
        .distinct()
    )


@admin_required
def attendance_logs_view(request):
    """Read-only, filterable list of attendance logs."""
    qs = AttendanceLog.objects.select_related(
        "student__user", "event", "scanned_by__user"
    )

    f_event = request.GET.get("event") or ""
    f_student = request.GET.get("student") or ""
    f_type = request.GET.get("attendance_type") or ""
    f_status = request.GET.get("status") or ""
    f_from = request.GET.get("date_from") or ""
    f_to = request.GET.get("date_to") or ""
    f_year = request.GET.get("year_level") or ""
    f_section = request.GET.get("section") or ""

    if f_event:
        qs = qs.filter(event_id=f_event)
    if f_student:
        qs = qs.filter(student_id=f_student)
    if f_type:
        qs = qs.filter(attendance_type=f_type)
    if f_status:
        qs = qs.filter(status=f_status)
    if f_from:
        qs = qs.filter(date__gte=f_from)
    if f_to:
        qs = qs.filter(date__lte=f_to)
    if f_year:
        qs = qs.filter(student__year_level=f_year)
    if f_section:
        qs = qs.filter(student__section=f_section)

    context = {
        "active": "attendance_logs",
        "objects": qs,
        "events": Event.objects.all(),
        "students": Student.objects.select_related("user").all(),
        "attendance_types": AttendanceType.choices,
        "statuses": AttendanceLog.Status.choices,
        "year_levels": Student.YearLevel.choices,
        "sections": _distinct_sections(),
        "filters": {
            "event": f_event, "student": f_student, "attendance_type": f_type,
            "status": f_status, "date_from": f_from, "date_to": f_to,
            "year_level": f_year, "section": f_section,
        },
    }
    if is_htmx(request) and request.GET.get("partial") == "table":
        return render(request, "portal/attendance_logs/partials/table.html", context)
    return render(request, "portal/attendance_logs/list.html", context)


# ---------------------------------------------------------------------------
# Student sign-up approvals
# ---------------------------------------------------------------------------
_APPROVAL_TABS = (Student.ApprovalStatus.PENDING, Student.ApprovalStatus.REJECTED)


def _approval_counts():
    return {s.value: Student.objects.filter(approval_status=s).count() for s in _APPROVAL_TABS}


@admin_required
def approvals_view(request):
    """Students who registered in the mobile app, waiting for (or denied) approval."""
    status = request.GET.get("status")
    if status not in {s.value for s in _APPROVAL_TABS}:
        status = Student.ApprovalStatus.PENDING.value
    partial = is_htmx(request) and request.GET.get("partial") == "table"
    ctx = {
        "active": "approvals",
        "status": status,
        "counts": _approval_counts(),
        "objects": Student.objects.select_related("user")
        .filter(approval_status=status).order_by("user__date_joined"),
        "oob": partial,        # only HTMX fragments carry the out-of-band badge update
    }
    template = "portal/approvals/partials/table.html" if partial else "portal/approvals/list.html"
    return render(request, template, ctx)


@admin_required
@require_POST
def approval_approve_view(request, pk):
    student = get_object_or_404(Student.objects.select_related("user"), pk=pk)
    student.approve(by=request.user)
    return htmx_action_response(
        toast=f"{student.user.get_full_name() or student.user.username} approved - they can sign in now.",
        refresh_event="refresh-approvals", close_modal=False,
    )


@admin_required
def approval_reject_view(request, pk):
    """Modal asking for an optional reason, then rejects the sign-up."""
    student = get_object_or_404(Student.objects.select_related("user"), pk=pk)
    if request.method == "POST":
        student.reject(by=request.user, reason=request.POST.get("reason", ""))
        return htmx_action_response(
            toast=f"{student.user.get_full_name() or student.user.username} rejected.",
            level="warning", refresh_event="refresh-approvals",
        )
    return render(request, "portal/approvals/partials/reject_form.html", {"student": student})


# ---------------------------------------------------------------------------
# Fines (list + Calculate + Mark-Paid)
# ---------------------------------------------------------------------------
# Fixed display order of the four daily slots.
_SLOT_ORDER = [
    AttendanceType.AM_IN,
    AttendanceType.AM_OUT,
    AttendanceType.PM_IN,
    AttendanceType.PM_OUT,
]
_STATUS_LABELS = dict(AttendanceLog.Status.choices)


def _build_attendance_grid(student, event):
    """Daily attendance detail for one student in one event.

    Returns a list of rows ``{date, cells:[{slot_label, value, kind}]}`` where
    each cell is ``–`` when the slot isn't required, ``Pending`` while the slot
    hasn't closed yet, ``Absent`` when it closed with no scan, else Present/Late.
    """
    required = set(event.required_types or [])
    now = timezone.localtime()
    logs = {
        (log.date, log.attendance_type): log.status
        for log in AttendanceLog.objects.filter(student=student, event=event)
    }
    slot_labels = dict(AttendanceType.choices)
    rows = []
    for day in event.iter_dates():
        cells = []
        for slot in _SLOT_ORDER:
            if slot not in required:
                cells.append({"value": "–", "kind": "na"})
            else:
                status = logs.get((day, slot))
                if status is None:
                    if services.slot_has_elapsed(event, day, slot, now):
                        cells.append({"value": "Absent", "kind": "absent"})
                    else:  # window still open / not opened yet: not a miss
                        cells.append({"value": "Pending", "kind": "pending"})
                else:
                    cells.append({"value": _STATUS_LABELS.get(status, status),
                                  "kind": status.lower()})
        rows.append({"date": day, "cells": cells})
    return {"slot_headers": [slot_labels[s] for s in _SLOT_ORDER], "rows": rows}


@admin_required
def fines_view(request):
    """Fines ledger. Two views: ``event`` (default ledger) and ``student``
    (daily attendance detail for one chosen student + event)."""
    services.refresh_active_fines()  # keep fines current (rate-limited)
    view = "student" if request.GET.get("view") == "student" else "event"
    partial = is_htmx(request) and request.GET.get("partial") == "table"

    base = {
        "active": "fines",
        "view": view,
        "events": Event.objects.all(),
        "statuses": Fine.Status.choices,
        "year_levels": Student.YearLevel.choices,
        "sections": _distinct_sections(),
        "students": Student.objects.select_related("user").all(),
    }

    if view == "student":
        f_student = request.GET.get("student") or ""
        f_event = request.GET.get("event") or ""
        student = Student.objects.select_related("user").filter(pk=f_student).first() if f_student else None
        event = Event.objects.filter(pk=f_event).first() if f_event else None
        grid = _build_attendance_grid(student, event) if student and event else None
        fine = (
            Fine.objects.filter(student=student, event=event).first()
            if student and event else None
        )
        base.update({
            "filters": {"student": f_student, "event": f_event},
            "student_obj": student, "event_obj": event,
            "grid": grid, "fine": fine,
        })
        template = "portal/fines/partials/by_student.html" if partial else "portal/fines/list.html"
        return render(request, template, base)

    # --- By Event (ledger) ---
    qs = Fine.objects.select_related("student__user", "event", "recorded_by")
    f_status = request.GET.get("status") or ""
    f_event = request.GET.get("event") or ""
    f_year = request.GET.get("year_level") or ""
    f_section = request.GET.get("section") or ""
    if f_status:
        qs = qs.filter(status=f_status)
    if f_event:
        qs = qs.filter(event_id=f_event)
    if f_year:
        qs = qs.filter(student__year_level=f_year)
    if f_section:
        qs = qs.filter(student__section=f_section)

    base.update({
        "objects": qs,
        "filters": {"status": f_status, "event": f_event,
                    "year_level": f_year, "section": f_section},
    })
    template = "portal/fines/partials/table.html" if partial else "portal/fines/list.html"
    return render(request, template, base)


@admin_required
def fines_calculate_view(request):
    """Modal to choose an event, then compute its fines.

    The work is enqueued as a **Celery background task**. If the broker (Redis)
    is unreachable, we fall back to computing synchronously so the portal keeps
    working without a running worker.
    """
    if request.method == "POST":
        form = FineCalculateForm(request.POST)
        if form.is_valid():
            event = form.cleaned_data["event"]
            ran_sync = settings.CELERY_TASK_ALWAYS_EAGER
            try:
                recompute_event_fines.delay(event.id)
            except Exception as exc:  # broker down → synchronous fallback
                logger.warning("Celery enqueue failed (%s); running inline.", exc)
                services.compute_fines_for_event(event)
                ran_sync = True

            if ran_sync:
                toast = f"Fines computed for “{event.name}”."
                return htmx_action_response(toast=toast, refresh_event="refresh-fines")
            # Truly queued: results land shortly when the worker finishes.
            toast = (
                f"Fine calculation for “{event.name}” started in the background. "
                "Refresh in a few seconds to see updated amounts."
            )
            return htmx_action_response(toast=toast, refresh_event="refresh-fines")
        status = 422
    else:
        form = FineCalculateForm()
        status = 200
    return render(
        request,
        "portal/fines/partials/calculate_form.html",
        {"form": form},
        status=status,
    )


@admin_required
def fines_mark_paid_view(request, pk):
    """Record that a fine was settled in cash with the treasurer."""
    fine = get_object_or_404(Fine, pk=pk)
    if request.method != "POST":
        return HttpResponse(status=405)
    if fine.status == Fine.Status.PAID:
        return htmx_action_response(
            toast="That fine is already marked paid.",
            level="warning",
            refresh_event="refresh-fines",
            close_modal=False,
        )
    fine.mark_paid(recorded_by=request.user)
    return htmx_action_response(
        toast=f"Marked paid: {fine.student.student_number} / {fine.event.name}.",
        refresh_event="refresh-fines",
        close_modal=False,
    )


# ---------------------------------------------------------------------------
# Reports (Attendance & Financial) — filters + CSV + print
# ---------------------------------------------------------------------------
def _report_filters(request):
    """Pull shared report filters from the querystring."""
    return {
        "semester": request.GET.get("semester") or None,
        "event": request.GET.get("event") or None,
        "date_from": request.GET.get("date_from") or None,
        "date_to": request.GET.get("date_to") or None,
    }


def _csv_response(rows, filename):
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = f'attachment; filename="{filename}"'
    if rows:
        writer = csv.DictWriter(response, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    return response


def _report_context(request, active):
    return {
        "active": f"reports_{active}",
        "report": active,
        "semesters": Semester.objects.select_related("school_year").all(),
        "events": Event.objects.all(),
        "filters": _report_filters(request),
    }


@admin_required
def report_attendance_view(request):
    rows = services.attendance_report(**_report_filters(request))
    if request.GET.get("format") == "csv":
        return _csv_response(rows, "attendance_report.csv")
    ctx = _report_context(request, "attendance")
    ctx["rows"] = rows
    return render(request, "portal/reports/attendance.html", ctx)


@admin_required
def report_financial_view(request):
    rows = services.financial_report(**_report_filters(request))
    if request.GET.get("format") == "csv":
        return _csv_response(rows, "financial_report.csv")
    ctx = _report_context(request, "financial")
    ctx["rows"] = rows
    return render(request, "portal/reports/financial.html", ctx)


# ---------------------------------------------------------------------------
# Settings (UI configuration)
# ---------------------------------------------------------------------------
@admin_required
def settings_view(request):
    """Configure portal branding, theme, light/dark mode and the logo."""
    settings_obj = PortalSettings.load()
    if request.method == "POST":
        form = PortalSettingsForm(
            request.POST, request.FILES, instance=settings_obj
        )
        if form.is_valid():
            form.save()
            messages.success(request, "Settings saved.")
            return redirect("portal:settings")
        messages.error(request, "Please correct the errors below.")
    else:
        form = PortalSettingsForm(instance=settings_obj)

    return render(request, "portal/settings/index.html", {
        "active": "settings",
        "form": form,
        "settings_obj": settings_obj,
        "palettes": PALETTES,
    })
