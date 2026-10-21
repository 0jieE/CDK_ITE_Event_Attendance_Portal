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
)
from . import masterlist
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

    def get_queryset(self, request=None):
        return super().get_queryset(request).prefetch_related("day_fines")


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
    actions_template = "portal/students/partials/actions.html"
    order_by = ("student_number",)


@admin_required
def terms_view(request):
    """School years and their semesters in a single table (two Add buttons on top).

    Once events exist under a school year / semester it is *locked*: only the Super Admin
    sees its Edit / Delete buttons.
    """
    school_years = list(SchoolYear.objects.prefetch_related("semesters__events").order_by("-sy"))
    for sy in school_years:
        sy.sem_list = list(sy.semesters.all())
        for sem in sy.sem_list:
            sem.event_count = len(sem.events.all())
            sem.locked = sem.event_count > 0
        sy.locked = any(sem.locked for sem in sy.sem_list)
    context = {
        "active": "terms",
        "school_years": school_years,
        "is_super": request.user.is_superuser,
    }
    if is_htmx(request) and request.GET.get("partial") == "table":
        return render(request, "portal/terms/partials/table.html", context)
    return render(request, "portal/terms/list.html", context)


class _LockedWhenUsedSection(CrudSection):
    """Edit/delete are refused for non-Super-Admins once events exist (see terms_view)."""

    def _locked_response(self, request, pk):
        if request.user.is_superuser:
            return None
        obj = get_object_or_404(self.get_queryset(request), pk=pk)
        if not obj.has_events:
            return None
        return htmx_action_response(
            toast=f"{self.singular} “{obj}” already has events - only the Super Admin can change or delete it.",
            level="error", refresh_event=self.refresh_event, close_modal=True,
        )

    def update_view(self, request, pk):
        return self._locked_response(request, pk) or super().update_view(request, pk)

    def delete_view(self, request, pk):
        return self._locked_response(request, pk) or super().delete_view(request, pk)


class SchoolYearsSection(_LockedWhenUsedSection):
    section = "school_years"
    title = "School Years"
    singular = "School Year"
    model = SchoolYear
    form_class = SchoolYearForm
    table_template = "portal/terms/partials/table.html"
    order_by = ("-sy",)

    def list_view(self, request):
        return terms_view(request)       # one combined page; only add/edit/delete live here


class SemestersSection(_LockedWhenUsedSection):
    section = "semesters"
    title = "Semesters"
    singular = "Semester"
    model = Semester
    form_class = SemesterForm
    table_template = "portal/terms/partials/table.html"
    select_related = ("school_year",)
    order_by = ("-school_year__sy", "name")

    def list_view(self, request):
        return terms_view(request)


#: Declarative CRUD sections; the URLConf iterates this list.
SECTIONS = [
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

    if request.GET.get("format") == "csv":
        rows = [
            {
                "Student No.": log.student.student_number,
                "Student": log.student.user.get_full_name() or log.student.user.username,
                "Year": log.student.get_year_level_display(),
                "Section": log.student.section,
                "Event": log.event.name,
                "Date": log.date.isoformat(),
                "Type": log.get_attendance_type_display(),
                "Status": log.get_status_display(),
                "Scanned At": timezone.localtime(log.scanned_at).strftime("%Y-%m-%d %H:%M") if log.scanned_at else "",
                "Scanned By": log.scanned_by.user.get_full_name() if log.scanned_by else "",
            }
            for log in qs.order_by("-date", "event__name", "student__user__last_name")
        ]
        if not rows:
            rows = [{"Student No.": "", "Student": "", "Year": "", "Section": "", "Event": "", "Date": "",
                     "Type": "", "Status": "", "Scanned At": "", "Scanned By": ""}]
        return _csv_response(rows, "attendance_logs.csv")

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
    hasn't closed yet, ``Absent`` when it closed with no scan, else Present.
    """
    required = set(event.required_types or [])
    rates = event.rate_map()
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
        rows.append({"date": day, "cells": cells, "rate": rates.get(day, event.fine_rate)})
    return {"has_day_fines": bool(rates), "slot_headers": [slot_labels[s] for s in _SLOT_ORDER], "rows": rows}


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


# ---------------------------------------------------------------------------
# Student masterlist import + printable credentials
# ---------------------------------------------------------------------------
_PENDING_KEY = "masterlist_pending"
_CREDS_KEY = "student_credentials"


def _import_context(request, **extra):
    ctx = {
        "active": "students",
        "columns": masterlist.COLUMNS,
        "year_levels": Student.YearLevel.choices,
        "sections": _distinct_sections(),
    }
    ctx.update(extra)
    return ctx


@admin_required
def students_import_view(request):
    """Upload a masterlist (preview -> confirm); the adviser then prints the credentials."""
    if request.method != "POST":
        return render(request, "portal/students/import.html", _import_context(request))

    action = request.POST.get("action", "preview")

    if action == "confirm":
        rows = request.session.get(_PENDING_KEY)
        if not rows:
            messages.error(request, "Nothing to import - upload the file again.")
            return redirect("portal:students-import")
        # Re-validate: another import may have happened between preview and confirm.
        rows = masterlist.validate_rows(rows)
        credentials = masterlist.import_rows(rows)
        request.session.pop(_PENDING_KEY, None)
        request.session[_CREDS_KEY] = credentials
        counts = masterlist.summarize(rows)
        messages.success(
            request,
            f"Imported {len(credentials)} student(s); {counts['exists']} already existed and "
            f"{counts['error']} row(s) had errors and were skipped.",
        )
        return redirect("portal:students-credentials")

    upload = request.FILES.get("file")
    if not upload:
        messages.error(request, "Choose a .csv or .xlsx file first.")
        return redirect("portal:students-import")
    try:
        rows = masterlist.validate_rows(masterlist.parse_upload(upload))
    except masterlist.MasterlistError as exc:
        messages.error(request, str(exc))
        return redirect("portal:students-import")
    request.session[_PENDING_KEY] = rows
    return render(request, "portal/students/import_preview.html", _import_context(
        request, rows=rows, counts=masterlist.summarize(rows), filename=upload.name,
    ))


@admin_required
def students_import_template_view(request, fmt):
    if fmt == "xlsx":
        response = HttpResponse(
            masterlist.template_xlsx_bytes(),
            content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        )
        response["Content-Disposition"] = 'attachment; filename="student_masterlist_template.xlsx"'
        return response
    if fmt == "csv":
        response = HttpResponse(masterlist.template_csv_bytes(), content_type="text/csv; charset=utf-8")
        response["Content-Disposition"] = 'attachment; filename="student_masterlist_template.csv"'
        return response
    from django.http import Http404

    raise Http404


@admin_required
def students_credentials_view(request):
    """Printable username/password slips for the last import or bulk reset."""
    credentials = request.session.get(_CREDS_KEY) or []
    if request.GET.get("format") == "csv":
        rows = [
            {"Student No.": c["student_number"], "Name": c["name"], "Year & Section": c["year_section"],
             "Username": c["username"], "Password": c["password"]}
            for c in credentials
        ] or [{"Student No.": "", "Name": "", "Year & Section": "", "Username": "", "Password": ""}]
        return _csv_response(rows, "student_credentials.csv")
    if request.GET.get("clear") == "1" and request.method == "POST":
        request.session.pop(_CREDS_KEY, None)
        return redirect("portal:students-list")
    return render(request, "portal/students/slips.html", {
        "active": "students", "credentials": credentials,
    })


@admin_required
def students_credentials_reset_view(request):
    """Bulk reset: new random passwords for a Year / Section, then print them."""
    if request.method != "POST":
        return redirect("portal:students-import")
    qs = Student.objects.all()
    year = request.POST.get("year_level") or ""
    section = request.POST.get("section") or ""
    if year:
        qs = qs.filter(year_level=year)
    if section:
        qs = qs.filter(section=section)
    if request.POST.get("confirm") != "yes":
        messages.error(request, "Tick the confirmation box to reset passwords.")
        return redirect("portal:students-import")
    credentials = masterlist.reset_passwords(qs.order_by("year_level", "section", "user__last_name"))
    if not credentials:
        messages.warning(request, "No students match that Year / Section.")
        return redirect("portal:students-import")
    request.session[_CREDS_KEY] = credentials
    messages.success(request, f"Reset the password of {len(credentials)} student(s). Print the slips now - they are shown once.")
    return redirect("portal:students-credentials")
