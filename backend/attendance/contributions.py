"""Department contributions: who owes what, recording payments, exemptions and summaries.

Rules (kept in one place so the portal, the reports and the student API agree):

* every student owes each contribution of a semester its full ``amount`` - unless exempted;
* payments are recorded one by one (partial payments add up) and never exceed what is still owed;
* a student who already paid something cannot be exempted (undo the payments first);
* a contribution's amount may not drop below what a student has already paid.
"""

from decimal import Decimal

from django.db import IntegrityError, transaction
from django.db.models import Sum
from django.utils import timezone

from accounts.models import Student

from .models import Contribution, ContributionExemption, ContributionPayment

ZERO = Decimal("0.00")
CENT = Decimal("0.01")

PAID, PARTIAL, UNPAID, EXEMPT = "PAID", "PARTIAL", "UNPAID", "EXEMPT"
STATUS_LABELS = {PAID: "Paid", PARTIAL: "Part-paid", UNPAID: "Unpaid", EXEMPT: "Exempt"}
STATUS_CHOICES = list(STATUS_LABELS.items())


def _status(owed, paid, exempt):
    if exempt:
        return EXEMPT
    if paid >= owed:
        return PAID
    return PARTIAL if paid > 0 else UNPAID


def money(value):
    """Two decimals always (SQLite sums come back as ``120`` instead of ``120.00``)."""
    return Decimal(value or 0).quantize(CENT)


def standing(contribution, paid, exempt):
    """``{owed, paid, balance, status}`` of one student for one contribution."""
    owed = ZERO if exempt else money(contribution.amount)
    paid = money(paid)
    return {
        "owed": owed,
        "paid": paid,
        "balance": max(owed - paid, ZERO),
        "status": _status(owed, paid, exempt),
    }


def _paid_by_student(contribution_ids):
    """``{(contribution_id, student_id): total paid}``."""
    rows = (ContributionPayment.objects.filter(contribution_id__in=contribution_ids)
            .values("contribution_id", "student_id").annotate(total=Sum("amount")))
    return {(r["contribution_id"], r["student_id"]): money(r["total"]) for r in rows}


def ledger(contribution, students=None):
    """One row per student for a contribution: the student, their standing and exemption reason."""
    if students is None:
        students = Student.objects.all()
    students = students.select_related("user").order_by("year_level", "section", "user__last_name",
                                                        "user__first_name", "student_number")
    paid = _paid_by_student([contribution.pk])
    exemptions = {e.student_id: e for e in contribution.exemptions.all()}
    rows = []
    for student in students:
        exemption = exemptions.get(student.pk)
        row = standing(contribution, paid.get((contribution.pk, student.pk)), exemption is not None)
        row.update({"student": student, "exemption": exemption})
        rows.append(row)
    return rows


def summarize(contribution, students_count=None):
    """Totals of one contribution across all students."""
    if students_count is None:
        students_count = Student.objects.count()
    exempt_ids = set(contribution.exemptions.values_list("student_id", flat=True))
    paid = {sid: total for (_, sid), total in _paid_by_student([contribution.pk]).items()}
    owing = students_count - len(exempt_ids)
    counts = {PAID: 0, PARTIAL: 0}
    collected = ZERO
    for sid, total in paid.items():
        if sid in exempt_ids:
            continue
        collected += total
        counts[_status(contribution.amount, total, False)] += 1
    expected = money(contribution.amount * owing)
    return {
        "contribution": contribution,
        "students": owing,
        "exempt_count": len(exempt_ids),
        "expected": expected,
        "collected": collected,
        "outstanding": max(expected - collected, ZERO),
        "paid_count": counts[PAID],
        "partial_count": counts[PARTIAL],
        "unpaid_count": max(owing - counts[PAID] - counts[PARTIAL], 0),
    }


def report(semester=None):
    """Summary rows for the financial report / dashboard (plain values, CSV-ready)."""
    qs = Contribution.objects.select_related("semester__school_year")
    if semester is not None:
        qs = qs.filter(semester=semester)
    students_count = Student.objects.count()
    rows = []
    for c in qs:
        s = summarize(c, students_count)
        rows.append({
            "contribution_id": c.pk,
            "contribution": c.name,
            "semester": str(c.semester),
            "amount": c.amount,
            "due_date": c.due_date,
            "students": s["students"],
            "exempt": s["exempt_count"],
            "expected": s["expected"],
            "collected": s["collected"],
            "outstanding": s["outstanding"],
            "paid_count": s["paid_count"],
            "partial_count": s["partial_count"],
            "unpaid_count": s["unpaid_count"],
        })
    return rows


def totals(rows):
    """Sum the money columns of :func:`report` rows."""
    return {k: sum((r[k] for r in rows), ZERO) for k in ("expected", "collected", "outstanding")}


def for_student(student, semester=None):
    """Every contribution with this student's standing and their payments (newest semester first)."""
    qs = Contribution.objects.select_related("semester__school_year").order_by(
        "-semester__school_year__sy", "-semester__name", "name")
    if semester is not None:
        qs = qs.filter(semester=semester)
    contributions = list(qs)
    ids = [c.pk for c in contributions]
    paid = _paid_by_student(ids)
    exempt = {e.contribution_id: e
              for e in ContributionExemption.objects.filter(contribution_id__in=ids, student=student)}
    payments = {}
    for p in (ContributionPayment.objects.filter(contribution_id__in=ids, student=student)
              .select_related("recorded_by")):
        payments.setdefault(p.contribution_id, []).append(p)
    rows = []
    for c in contributions:
        row = standing(c, paid.get((c.pk, student.pk)), c.pk in exempt)
        row.update({"contribution": c, "exemption": exempt.get(c.pk), "payments": payments.get(c.pk, [])})
        rows.append(row)
    return rows


def student_totals(student, semester=None):
    """``{total, paid, outstanding}`` of a student's contributions (exempt ones owe nothing)."""
    rows = for_student(student, semester)
    return {
        "total": sum((r["owed"] for r in rows), ZERO),
        "paid": sum((r["paid"] for r in rows), ZERO),
        "outstanding": sum((r["balance"] for r in rows), ZERO),
    }


# ---------------------------------------------------------------------------
# Changes
# ---------------------------------------------------------------------------
class ContributionError(ValueError):
    """A change the rules do not allow (the message is shown to the adviser)."""


def balance_of(contribution, student):
    paid = (ContributionPayment.objects.filter(contribution=contribution, student=student)
            .aggregate(t=Sum("amount"))["t"])
    exempt = ContributionExemption.objects.filter(contribution=contribution, student=student).exists()
    return standing(contribution, paid, exempt)


def record_payment(contribution, student, amount, *, recorded_by=None, when=None, note="", ref=None):
    """Record cash received. Returns the payment, or ``None`` when ``ref`` was already recorded."""
    amount = money(amount)
    if amount <= 0:
        raise ContributionError("The amount must be more than zero.")
    with transaction.atomic():
        # lock the contribution so two payments for the same student cannot both pass the check
        Contribution.objects.select_for_update().filter(pk=contribution.pk).first()
        if ref and ContributionPayment.objects.filter(ref=ref).exists():
            return None
        now = balance_of(contribution, student)
        if now["status"] == EXEMPT:
            raise ContributionError("This student is exempted from this contribution.")
        if now["balance"] <= 0:
            raise ContributionError("This contribution is already fully paid.")
        if amount > now["balance"]:
            raise ContributionError(f"That is more than the balance (₱{now['balance']}).")
        try:
            with transaction.atomic():
                return ContributionPayment.objects.create(
                    contribution=contribution, student=student, amount=amount,
                    paid_at=when or timezone.now(), note=note or "", recorded_by=recorded_by, ref=ref or None,
                )
        except IntegrityError:                 # the same ref arrived twice at once
            return None


def undo_payment(payment):
    payment.delete()


def exempt(contribution, student, *, reason="", recorded_by=None):
    """Exempt a student. Returns ``False`` when they were already exempted."""
    if ContributionPayment.objects.filter(contribution=contribution, student=student).exists():
        raise ContributionError("This student already paid something for this contribution - undo the "
                                "payments first if they should be exempted.")
    _, created = ContributionExemption.objects.get_or_create(
        contribution=contribution, student=student,
        defaults={"reason": (reason or "")[:255], "recorded_by": recorded_by},
    )
    return created


def unexempt(contribution, student):
    """Remove an exemption. Returns ``False`` when there was none."""
    deleted, _ = ContributionExemption.objects.filter(contribution=contribution, student=student).delete()
    return bool(deleted)


def semester_summary(semester=None):
    """Dashboard numbers: the contributions of a semester plus their totals."""
    rows = report(semester)
    return {"rows": rows, **totals(rows), "count": len(rows)}


__all__ = [
    "PAID", "PARTIAL", "UNPAID", "EXEMPT", "STATUS_LABELS", "STATUS_CHOICES", "ContributionError",
    "standing", "ledger", "summarize", "report", "totals", "for_student", "student_totals",
    "balance_of", "record_payment", "undo_payment", "exempt", "unexempt", "semester_summary",
]
