"""Business logic kept out of the views.

* :func:`compute_fines_for_event` — idempotent fines calculator.
* :func:`build_dashboard` — top-level admin dashboard aggregates.
* :func:`attendance_report` / :func:`financial_report` — filterable summaries.
"""

import logging
from decimal import Decimal

from django.core.cache import cache
from django.db import transaction
from django.db.models import Count, DecimalField, Q, Sum
from django.db.models.functions import Coalesce
from django.utils import timezone

from accounts.models import Student

from .models import AttendanceLog, Event, Fine

logger = logging.getLogger(__name__)

# Statuses that count as "the student attended this slot".
CREDITED = (AttendanceLog.Status.PRESENT, AttendanceLog.Status.LATE)

# Cache key + default minimum gap for the on-view automatic fines refresh.
_REFRESH_KEY = "fines:last-refresh"
REFRESH_MIN_INTERVAL = 30  # seconds


def slot_has_elapsed(event, day, slot, now=None):
    """True once a required slot can no longer be scanned (so it may be fined).

    Fines are **per required attendance slot**, not per day: a slot on a past
    date has always elapsed, a slot on a future date never has, and a slot on
    *today* has elapsed only after its scan window has ended. A slot whose window
    is not configured is never treated as elapsed today.
    """
    now = now or timezone.localtime()
    today = now.date()
    if day < today:
        return True
    if day > today:
        return False
    _, end = event.slot_window(slot)
    return end is not None and end < now.time()


@transaction.atomic
def compute_fines_for_event(event, as_of=None, now=None):
    """Recompute every enrolled student's fine for ``event``.

    A *slot* is one ``(date, attendance_type)`` pair for a required type on a
    date within ``[start_date, end_date]``.  A slot is **missed** when it has
    *elapsed* (see :func:`slot_has_elapsed`) and there is no
    :class:`AttendanceLog` with status ``PRESENT`` or ``LATE`` for that
    student / event / date / type.  So the fine is ``missed slots x fine_rate``:
    per required attendance, never per day.

    **Only slots that are over are counted.** Past days count every required
    slot; today counts a slot only after its scan window has closed; future days
    count nothing. A student is therefore never fined for a slot that is still
    open or hasn't opened yet.  ``as_of`` (a date, default today) caps the dates
    considered; ``now`` (default: the current local time) is injectable for tests.

    The function is **idempotent**: running it repeatedly converges on the same
    numbers.  An already-``PAID`` fine is never silently overwritten - if a
    recompute disagrees with it, the fine is flagged via ``needs_review`` and
    its amount/status are left untouched.

    Returns a summary dict suitable for an API response.
    """
    now = now or timezone.localtime()
    if as_of is None:
        as_of = now.date()

    required_types = event.required_types or []
    # Coerce the rate to Decimal (it may arrive as a str on an unsaved instance).
    fine_rate = event.fine_rate if isinstance(event.fine_rate, Decimal) else Decimal(str(event.fine_rate))

    dates = [d for d in event.iter_dates() if d <= as_of]
    # The slots that are already over - identical for every student.
    elapsed_slots = [
        (d, t) for d in dates for t in required_types
        if slot_has_elapsed(event, d, t, now)
    ]

    # All credited (present/late) logs for this event, indexed for O(1) lookup.
    credited_keys = set(
        AttendanceLog.objects.filter(event=event, status__in=CREDITED).values_list(
            "student_id", "date", "attendance_type"
        )
    )
    # One query for every existing fine (avoids a query per student).
    existing = {f.student_id: f for f in Fine.objects.filter(event=event)}

    # Only approved students are enrolled: a pending/rejected sign-up is never fined.
    students = list(Student.objects.filter(approval_status=Student.ApprovalStatus.APPROVED))
    results = {"created": 0, "updated": 0, "flagged_for_review": 0, "fines": []}

    for student in students:
        # A student who signed up and was approved part-way through an event is only
        # accountable from their approval day on (admin-created students: all days).
        joined = timezone.localtime(student.reviewed_at).date() if student.reviewed_at else None
        missed = sum(
            1 for (d, t) in elapsed_slots
            if (joined is None or d >= joined) and (student.id, d, t) not in credited_keys
        )
        amount = (Decimal(missed) * fine_rate).quantize(Decimal("0.01"))

        fine = existing.get(student.id)

        if fine is None:
            # Don't create empty fines for students who missed nothing.
            if missed == 0:
                continue
            fine = Fine.objects.create(
                student=student,
                event=event,
                amount=amount,
                missed_slots=missed,
                status=Fine.Status.UNPAID,
            )
            results["created"] += 1
            results["fines"].append(fine.id)
            continue

        if fine.status == Fine.Status.PAID:
            # Never overwrite a paid fine; flag it if the numbers changed.
            if fine.missed_slots != missed or fine.amount != amount:
                if not fine.needs_review:
                    fine.needs_review = True
                    fine.save(update_fields=["needs_review", "updated_at"])
                    results["flagged_for_review"] += 1
            continue

        # Unpaid fine: safe to refresh in place.
        changed_fields = []
        if fine.missed_slots != missed:
            fine.missed_slots = missed
            changed_fields.append("missed_slots")
        if fine.amount != amount:
            fine.amount = amount
            changed_fields.append("amount")
        if changed_fields:
            changed_fields.append("updated_at")
            fine.save(update_fields=changed_fields)
            results["updated"] += 1
        results["fines"].append(fine.id)

    results["event"] = event.id
    results["as_of"] = as_of.isoformat()
    results["elapsed_days"] = len(dates)
    results["students_evaluated"] = len(students)
    results["slots_per_student"] = len(elapsed_slots)
    return results


def refresh_active_fines(min_interval=REFRESH_MIN_INTERVAL):
    """Recompute fines for every active, already-started event - automatically.

    Called whenever fines/financial data is *viewed* (portal Fines page,
    dashboard, financial report, the fines APIs and the student app), so the
    numbers are current without anyone pressing *Calculate Fines*. The work is
    rate-limited with a shared cache lock to at most once per ``min_interval``
    seconds across all workers, and a failure never breaks the page that asked.

    Returns the list of per-event summaries, or ``None`` if it was skipped.
    """
    if not cache.add(_REFRESH_KEY, 1, timeout=min_interval):
        return None
    try:
        now = timezone.localtime()
        events = Event.objects.filter(is_active=True, start_date__lte=now.date())
        return [compute_fines_for_event(event, now=now) for event in events]
    except Exception:  # never take the requesting page down
        cache.delete(_REFRESH_KEY)
        logger.exception("Automatic fines refresh failed")
        return None


# ---------------------------------------------------------------------------
# Aggregation helpers
# ---------------------------------------------------------------------------
_MONEY = DecimalField(max_digits=14, decimal_places=2)
_ZERO = Decimal("0.00")


def _money_sum(queryset, field, **filters):
    """Sum ``field`` over ``queryset`` (optionally filtered), never None."""
    if filters:
        queryset = queryset.filter(**filters)
    return queryset.aggregate(
        total=Coalesce(Sum(field, output_field=_MONEY), _ZERO, output_field=_MONEY)
    )["total"]


def _attendance_rate(log_qs):
    """Return the credited / total ratio (0–1) over an AttendanceLog queryset."""
    agg = log_qs.aggregate(
        total=Count("id"),
        credited=Count("id", filter=Q(status__in=CREDITED)),
    )
    total = agg["total"] or 0
    if not total:
        return 0.0
    return round(agg["credited"] / total, 4)


def build_dashboard():
    """Return the top-level admin dashboard aggregates."""
    refresh_active_fines()
    fines = Fine.objects.all()
    total_issued = _money_sum(fines, "amount")
    total_collected = _money_sum(fines, "amount", status=Fine.Status.PAID)
    total_outstanding = _money_sum(fines, "amount", status=Fine.Status.UNPAID)

    overall_rate = _attendance_rate(AttendanceLog.objects.all())

    per_event = []
    for event in Event.objects.select_related("semester__school_year").all():
        ev_fines = fines.filter(event=event)
        per_event.append(
            {
                "event_id": event.id,
                "event_name": event.name,
                "semester": str(event.semester),
                "attendance_rate": _attendance_rate(
                    AttendanceLog.objects.filter(event=event)
                ),
                "fines_issued": _money_sum(ev_fines, "amount"),
                "collected": _money_sum(ev_fines, "amount", status=Fine.Status.PAID),
                "outstanding": _money_sum(
                    ev_fines, "amount", status=Fine.Status.UNPAID
                ),
            }
        )

    return {
        "total_fines_issued": total_issued,
        "total_collected": total_collected,
        "total_outstanding": total_outstanding,
        "overall_attendance_rate": overall_rate,
        "events": per_event,
    }


def attendance_report(*, semester=None, event=None, date_from=None, date_to=None):
    """Filterable attendance summary, grouped per event.

    All filters are optional.  Returns plain dict/list data ready to be
    serialised to JSON or flattened to CSV.
    """
    events = Event.objects.select_related("semester__school_year").all()
    if semester is not None:
        events = events.filter(semester=semester)
    if event is not None:
        events = events.filter(pk=event)

    rows = []
    for ev in events:
        logs = AttendanceLog.objects.filter(event=ev)
        if date_from:
            logs = logs.filter(date__gte=date_from)
        if date_to:
            logs = logs.filter(date__lte=date_to)
        agg = logs.aggregate(
            total=Count("id"),
            present=Count("id", filter=Q(status=AttendanceLog.Status.PRESENT)),
            late=Count("id", filter=Q(status=AttendanceLog.Status.LATE)),
            absent=Count("id", filter=Q(status=AttendanceLog.Status.ABSENT)),
        )
        rows.append(
            {
                "event_id": ev.id,
                "event_name": ev.name,
                "semester": str(ev.semester),
                "start_date": ev.start_date,
                "end_date": ev.end_date,
                "total_logs": agg["total"] or 0,
                "present": agg["present"] or 0,
                "late": agg["late"] or 0,
                "absent": agg["absent"] or 0,
                "attendance_rate": _attendance_rate(logs),
            }
        )
    return rows


def financial_report(*, semester=None, event=None, date_from=None, date_to=None):
    """Filterable fines summary, grouped per event.

    ``date_from`` / ``date_to`` filter by the fine's creation date.
    """
    refresh_active_fines()
    events = Event.objects.select_related("semester__school_year").all()
    if semester is not None:
        events = events.filter(semester=semester)
    if event is not None:
        events = events.filter(pk=event)

    rows = []
    for ev in events:
        fines = Fine.objects.filter(event=ev)
        if date_from:
            fines = fines.filter(created_at__date__gte=date_from)
        if date_to:
            fines = fines.filter(created_at__date__lte=date_to)
        rows.append(
            {
                "event_id": ev.id,
                "event_name": ev.name,
                "semester": str(ev.semester),
                "fines_count": fines.count(),
                "total_issued": _money_sum(fines, "amount"),
                "collected": _money_sum(fines, "amount", status=Fine.Status.PAID),
                "outstanding": _money_sum(fines, "amount", status=Fine.Status.UNPAID),
                "unpaid_count": fines.filter(status=Fine.Status.UNPAID).count(),
                "paid_count": fines.filter(status=Fine.Status.PAID).count(),
            }
        )
    return rows
