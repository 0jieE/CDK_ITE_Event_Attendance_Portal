"""Department contributions in the portal: the per-contribution ledger, a student's statement,
recording (partial) payments, exemptions and the contribution add / edit / delete modals.

The rules live in :mod:`attendance.contributions`; these views only collect input and render.
"""

import uuid
from decimal import Decimal

from django.http import HttpResponse
from django.shortcuts import get_object_or_404, render
from django.urls import path, reverse

from accounts.models import Student
from attendance import contributions as contrib
from attendance.models import Contribution, ContributionPayment, Semester

from .crud import CrudSection
from .forms import ContributionForm, ContributionPaymentForm
from .mixins import admin_required, htmx_action_response

REFRESH = "refresh-contributions"


def _views():
    from . import views      # late import: views imports this module's section for its URL list

    return views


def _student_name(student):
    return student.user.get_full_name() or student.user.username


# ---------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------
@admin_required
def contributions_view(request):
    """*By Contribution* (a ledger of every student) or *By Student* (one student's statement).

    The semester filter defaults to the active semester, as on the Fines page.
    """
    views = _views()
    view = "student" if request.GET.get("view") == "student" else "contribution"
    semester = views._logs_semester(request)
    semester_id = str(semester.pk) if semester else ""
    semester_label = str(semester) if semester else "All semesters"

    contributions = Contribution.objects.select_related("semester__school_year")
    if semester:
        contributions = contributions.filter(semester=semester)
    contributions = list(contributions)

    base = {
        "active": "contributions",
        "view": view,
        "semester": semester,
        "semesters": Semester.objects.select_related("school_year").order_by("-school_year__sy", "name"),
        "contributions": contributions,
        "statuses": contrib.STATUS_CHOICES,
        "year_levels": Student.YearLevel.choices,
        "sections": views._distinct_sections(),
        "students": Student.objects.select_related("user").order_by("user__last_name", "user__first_name"),
    }

    if view == "student":
        f_student = request.GET.get("student") or ""
        student = (Student.objects.select_related("user").filter(pk=f_student).first()
                   if f_student.isdigit() else None)
        rows = contrib.for_student(student, semester) if student else []
        base.update({
            "filters": {"semester": semester_id, "student": str(student.pk) if student else ""},
            "student_obj": student,
            "rows": rows,
            "totals": {k: sum((r[k] for r in rows), Decimal("0.00")) for k in ("owed", "paid", "balance")},
            "print_title": _student_name(student) if student else "Contributions",
            "print_subtitle": " · ".join(b for b in [
                student.student_number if student else "", student.year_section if student else "",
                f"Contributions statement · {semester_label}"] if b),
        })
        return render(request, "portal/contributions/list.html", base)

    # --- By Contribution (ledger) ---
    by_id = {str(c.pk): c for c in contributions}
    contribution = by_id.get(request.GET.get("contribution") or "") or (contributions[0] if contributions else None)
    f_status = request.GET.get("status") or ""
    f_year = request.GET.get("year_level") or ""
    f_section = request.GET.get("section") or ""
    if f_status not in contrib.STATUS_LABELS:
        f_status = ""
    rows, summary = [], None
    overview = contrib.report(semester) if contributions else []
    if contribution:
        students = Student.objects.all()
        if f_year:
            students = students.filter(year_level=f_year)
        if f_section:
            students = students.filter(section=f_section)
        rows = contrib.ledger(contribution, students)
        if f_status:
            rows = [r for r in rows if r["status"] == f_status]
        summary = contrib.summarize(contribution)

    bits = [semester_label, contribution.name if contribution else ""]
    if f_status:
        bits.append(contrib.STATUS_LABELS[f_status])
    if f_year:
        bits.append(dict(Student.YearLevel.choices).get(f_year, f_year))
    if f_section:
        bits.append(f"Section {f_section}")
    base.update({
        "filters": {"semester": semester_id, "contribution": str(contribution.pk) if contribution else "",
                    "status": f_status, "year_level": f_year, "section": f_section},
        "contribution": contribution,
        "overview": overview,
        "overview_totals": contrib.totals(overview),
        "rows": rows,
        "summary": summary,
        "row_totals": {k: sum((r[k] for r in rows), Decimal("0.00")) for k in ("owed", "paid", "balance")},
        "print_title": f"Contributions — {contribution.name}" if contribution else "Contributions",
        "print_subtitle": " · ".join(b for b in bits if b),
    })
    return render(request, "portal/contributions/list.html", base)


# ---------------------------------------------------------------------------
# Payments and exemptions
# ---------------------------------------------------------------------------
def _student_from(request):
    raw = request.POST.get("student") or request.GET.get("student") or ""
    return get_object_or_404(Student.objects.select_related("user"), pk=raw) if raw.isdigit() else None


@admin_required
def contribution_pay_view(request, pk):
    """Modal: record cash from one student (defaults to the whole balance; less is a partial payment)."""
    contribution = get_object_or_404(Contribution.objects.select_related("semester__school_year"), pk=pk)
    student = _student_from(request)
    if student is None:
        return htmx_action_response(toast="Pick a student first.", level="error", close_modal=False)
    now = contrib.balance_of(contribution, student)
    ctx = {
        "contribution": contribution,
        "student": student,
        "standing": now,
        "payments": list(contribution.payments.filter(student=student).select_related("recorded_by")),
        "post_url": reverse("portal:contributions-pay", args=[pk]) + f"?student={student.pk}",
    }
    if request.method == "POST":
        form = ContributionPaymentForm(request.POST, balance=now["balance"])
        if form.is_valid():
            data = form.cleaned_data
            try:
                payment = contrib.record_payment(
                    contribution, student, data["amount"], recorded_by=request.user,
                    when=_views()._replay_time(request), note=data["note"], ref=data["ref"] or None,
                )
            except contrib.ContributionError as exc:
                form.add_error(None, str(exc))
            else:
                if payment is None:
                    return htmx_action_response(toast="That payment was already recorded.", level="warning",
                                                refresh_event=REFRESH)
                after = contrib.balance_of(contribution, student)
                done = " Fully paid." if after["status"] == contrib.PAID else f" Balance: ₱{after['balance']}."
                return htmx_action_response(
                    toast=f"Recorded ₱{payment.amount} from {student.student_number} for {contribution.name}.{done}",
                    refresh_event=REFRESH,
                )
        ctx["form"] = form
        return render(request, "portal/contributions/partials/pay_form.html", ctx, status=422)
    if now["balance"] > 0:
        ctx["form"] = ContributionPaymentForm(balance=now["balance"], initial={"ref": uuid.uuid4().hex})
    return render(request, "portal/contributions/partials/pay_form.html", ctx)


@admin_required
def contribution_payment_undo_view(request, pk):
    """Undo one payment (a mistake). Closes the payment modal if it was opened from there."""
    if request.method != "POST":
        return HttpResponse(status=405)
    payment = ContributionPayment.objects.select_related("student", "contribution").filter(pk=pk).first()
    if payment is None:                       # already undone (e.g. a second click)
        return htmx_action_response(toast="That payment was already undone.", level="warning",
                                    refresh_event=REFRESH)
    label = f"₱{payment.amount} from {payment.student.student_number} for {payment.contribution.name}"
    contrib.undo_payment(payment)
    return htmx_action_response(toast=f"Payment undone ({label}).", refresh_event=REFRESH)


@admin_required
def contribution_exempt_view(request, pk):
    """Exempt a student (the reason comes from the confirm prompt)."""
    if request.method != "POST":
        return HttpResponse(status=405)
    contribution = get_object_or_404(Contribution, pk=pk)
    student = _student_from(request)
    if student is None:
        return htmx_action_response(toast="Pick a student first.", level="error", close_modal=False)
    reason = (request.headers.get("HX-Prompt") or request.POST.get("reason") or "").strip()
    try:
        created = contrib.exempt(contribution, student, reason=reason, recorded_by=request.user)
    except contrib.ContributionError as exc:
        return htmx_action_response(toast=str(exc), level="error", refresh_event=REFRESH, close_modal=False)
    if not created:
        return htmx_action_response(toast="That student is already exempted.", level="warning",
                                    refresh_event=REFRESH, close_modal=False)
    return htmx_action_response(toast=f"{student.student_number} is exempted from {contribution.name}.",
                                refresh_event=REFRESH, close_modal=False)


@admin_required
def contribution_unexempt_view(request, pk):
    if request.method != "POST":
        return HttpResponse(status=405)
    contribution = get_object_or_404(Contribution, pk=pk)
    student = _student_from(request)
    if student is None or not contrib.unexempt(contribution, student):
        return htmx_action_response(toast="That student was not exempted.", level="warning",
                                    refresh_event=REFRESH, close_modal=False)
    return htmx_action_response(toast=f"{student.student_number} owes {contribution.name} again.",
                                refresh_event=REFRESH, close_modal=False)


# ---------------------------------------------------------------------------
# Add / edit / delete a contribution (modal CRUD)
# ---------------------------------------------------------------------------
class ContributionsSection(CrudSection):
    section = "contributions"
    title = "Contributions"
    singular = "Contribution"
    model = Contribution
    form_class = ContributionForm
    table_template = "portal/contributions/list.html"
    select_related = ("semester__school_year",)

    def list_view(self, request):
        return contributions_view(request)

    def delete_view(self, request, pk):
        contribution = get_object_or_404(Contribution, pk=pk)
        reason = contribution.delete_block_reason
        if reason:
            return htmx_action_response(toast=reason, level="error", refresh_event=self.refresh_event,
                                        close_modal=False)
        return super().delete_view(request, pk)

    def get_urls(self):
        return super().get_urls() + [
            path("contributions/<int:pk>/pay/", contribution_pay_view, name="contributions-pay"),
            path("contributions/<int:pk>/exempt/", contribution_exempt_view, name="contributions-exempt"),
            path("contributions/<int:pk>/unexempt/", contribution_unexempt_view, name="contributions-unexempt"),
            path("contributions/payments/<int:pk>/undo/", contribution_payment_undo_view,
                 name="contributions-payment-undo"),
        ]
