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

from .models import AttendanceLog, AttendanceType, Event, Fine, FineSlotPayment

logger = logging.getLogger(__name__)

# Statuses that count as "the student attended this slot" (scan time is recorded on the log).
CREDITED = (AttendanceLog.Status.PRESENT,)

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
    :class:`AttendanceLog` with status ``PRESENT`` for that
    student / event / date / type.  So the fine is the sum, over the missed slots, of
    that day's rate (``Event.fine_rate`` unless the day has an ``EventDayFine``
    override): per required attendance, with a customisable rate per day.

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
    day_rates = event.rate_map() if event.pk else {}

    dates = [d for d in event.iter_dates() if d <= as_of]
    # The slots that are already over - identical for every student.
    elapsed_slots = [
        (d, t) for d in dates for t in required_types
        if slot_has_elapsed(event, d, t, now)
    ]

    # All credited (present) logs for this event, indexed for O(1) lookup.
    credited_keys = set(
        AttendanceLog.objects.filter(event=event, status__in=CREDITED).values_list(
            "student_id", "date", "attendance_type"
        )
    )
    # One query for every existing fine (avoids a query per student).
    existing = {
        f.student_id: f
        for f in Fine.objects.filter(event=event).annotate(
            paid_rows=Count("slot_payments"),
            paid_sum=Coalesce(Sum("slot_payments__amount"), Decimal("0.00"), output_field=_MONEY),
        )
    }

    students = list(Student.objects.all())
    results = {"created": 0, "updated": 0, "flagged_for_review": 0, "fines": []}

    for student in students:
        missed_on = [d for (d, t) in elapsed_slots if (student.id, d, t) not in credited_keys]
        missed = len(missed_on)
        amount = sum((day_rates.get(d, fine_rate) for d in missed_on), Decimal("0")).quantize(Decimal("0.01"))

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

        if fine.status == Fine.Status.PAID and not fine.paid_rows:
            # Paid in full before slot payments existed: never overwrite it, flag it if the
            # numbers changed.
            if fine.missed_slots != missed or fine.amount != amount:
                if not fine.needs_review:
                    fine.needs_review = True
                    fine.save(update_fields=["needs_review", "updated_at"])
                    results["flagged_for_review"] += 1
            continue

        # Unpaid / part-paid fine: safe to refresh in place. Slot payments are kept; the status
        # follows them (PAID once every missed slot is paid, back to UNPAID when a newly
        # missed slot adds to the amount).
        changed_fields = []
        if fine.missed_slots != missed:
            fine.missed_slots = missed
            changed_fields.append("missed_slots")
        if fine.amount != amount:
            fine.amount = amount
            changed_fields.append("amount")
        if fine.paid_rows:
            paid = fine.paid_sum.quantize(Decimal("0.01"))
            status = Fine.Status.PAID if amount > 0 and paid >= amount else Fine.Status.UNPAID
            for field, value in (
                ("amount_paid", paid),
                ("status", status),
                ("needs_review", paid > amount),
                ("paid_at", fine.paid_at if status == Fine.Status.PAID else None),
            ):
                if getattr(fine, field) != value:
                    setattr(fine, field, value)
                    changed_fields.append(field)
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


_SLOT_ORDER = [t.value for t in AttendanceType]


def missed_slot_details(student, event, now=None):
    """The slots this student has missed so far: ``[(date, slot, rate)]`` in date/slot order.

    Same rule as :func:`compute_fines_for_event` (a required slot that has elapsed with no
    credited scan), with the rate of that slot's day.
    """
    now = now or timezone.localtime()
    rates = event.rate_map()
    default_rate = event.fine_rate if isinstance(event.fine_rate, Decimal) else Decimal(str(event.fine_rate))
    credited = set(
        AttendanceLog.objects.filter(event=event, student=student, status__in=CREDITED)
        .values_list("date", "attendance_type")
    )
    required = [t for t in _SLOT_ORDER if t in (event.required_types or [])]
    out = []
    for day in event.iter_dates():
        if day > now.date():
            break
        for slot in required:
            if slot_has_elapsed(event, day, slot, now) and (day, slot) not in credited:
                out.append((day, slot, rates.get(day, default_rate)))
    return out


def sync_fine_payment(fine, recorded_by=None, when=None):
    """Recompute ``amount_paid`` / ``status`` / ``paid_at`` from the fine's slot payments."""
    paid = FineSlotPayment.objects.filter(fine=fine).aggregate(
        total=Coalesce(Sum("amount", output_field=_MONEY), _ZERO, output_field=_MONEY)
    )["total"]
    fine.amount_paid = paid
    complete = fine.amount > 0 and paid >= fine.amount
    if complete:
        if fine.status != Fine.Status.PAID or fine.paid_at is None:
            fine.paid_at = when or timezone.now()
        fine.status = Fine.Status.PAID
        if recorded_by is not None:
            fine.recorded_by = recorded_by
    else:
        fine.status = Fine.Status.UNPAID
        fine.paid_at = None
    fine.needs_review = paid > fine.amount
    fine.save(update_fields=["amount_paid", "status", "paid_at", "recorded_by", "needs_review", "updated_at"])
    return fine


@transaction.atomic
def pay_slots(fine, slots=None, recorded_by=None, when=None, now=None):
    """Record cash received for missed slots of ``fine``.

    ``slots`` is an iterable of ``(date, slot)`` pairs, or ``None`` for every slot that is
    still unpaid. Only slots that are currently *missed* can be paid; ``ValueError`` is
    raised otherwise. The fine's amount / missed count are refreshed first so the ledger is
    never a few minutes behind the attendance. Returns the number of slots paid.
    """
    if fine.status == Fine.Status.PAID and not fine.slot_payments.exists():
        return 0                                    # paid in full before slot payments existed
    details = missed_slot_details(fine.student, fine.event, now)
    fine.missed_slots = len(details)
    fine.amount = sum((rate for _, _, rate in details), Decimal("0")).quantize(Decimal("0.01"))
    already = set(fine.slot_payments.values_list("date", "attendance_type"))
    if slots is None:
        wanted = [(d, t, r) for d, t, r in details if (d, t) not in already]
    else:
        by_key = {(d, t): r for d, t, r in details}
        wanted = []
        for key in slots:
            key = (key[0], key[1])
            if key not in by_key:
                raise ValueError("That slot is not a missed slot of this fine.")
            if key not in already:
                wanted.append((key[0], key[1], by_key[key]))
    FineSlotPayment.objects.bulk_create(
        FineSlotPayment(fine=fine, date=d, attendance_type=t, amount=r, recorded_by=recorded_by)
        for d, t, r in wanted
    )
    fine.save(update_fields=["missed_slots", "amount", "updated_at"])
    sync_fine_payment(fine, recorded_by=recorded_by, when=when)
    return len(wanted)


@transaction.atomic
def unpay_slot(fine, day, slot):
    """Undo one slot payment (e.g. a mis-click). Returns True when a payment was removed."""
    removed, _ = FineSlotPayment.objects.filter(fine=fine, date=day, attendance_type=slot).delete()
    if removed:
        sync_fine_payment(fine)
    return bool(removed)


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


def _outstanding(fines):
    """What is still owed on the unpaid / part-paid fines (a PAID fine owes nothing)."""
    unpaid = fines.filter(status=Fine.Status.UNPAID)
    return _money_sum(unpaid, "amount") - _money_sum(unpaid, "amount_paid")


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
    total_collected = _money_sum(fines, "amount_paid")
    total_outstanding = _outstanding(fines)

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
                "collected": _money_sum(ev_fines, "amount_paid"),
                "outstanding": _outstanding(ev_fines),
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
        # Only scans are stored (a PRESENT row); absences are never recorded as rows, so
        # there is no meaningful "absent" count to report here.
        present = logs.filter(status=AttendanceLog.Status.PRESENT).count()
        rows.append(
            {
                "event_id": ev.id,
                "event_name": ev.name,
                "semester": str(ev.semester),
                "start_date": ev.start_date,
                "end_date": ev.end_date,
                "present": present,
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
                "collected": _money_sum(fines, "amount_paid"),
                "outstanding": _outstanding(fines),
                "unpaid_count": fines.filter(status=Fine.Status.UNPAID).count(),
                "paid_count": fines.filter(status=Fine.Status.PAID).count(),
            }
        )
    return rows
