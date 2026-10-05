"""Background tasks for fine calculation (Celery + Redis).

* :func:`recompute_event_fines` — recompute one event's fines (enqueued by the
  portal's *Calculate Fines* action).
* :func:`recompute_all_active_fines` — nightly Celery-Beat job that recomputes
  every active, already-started event. Combined with the "only count elapsed
  dates" rule in :func:`attendance.services.compute_fines_for_event`, fines grow
  automatically as each event-day passes — no manual clicking required.
"""

from celery import shared_task
from celery.utils.log import get_task_logger
from django.utils import timezone

logger = get_task_logger(__name__)


@shared_task(name="attendance.tasks.recompute_event_fines")
def recompute_event_fines(event_id):
    """Recompute fines for a single event (by id)."""
    from .models import Event
    from .services import compute_fines_for_event

    event = Event.objects.filter(pk=event_id).first()
    if event is None:
        logger.warning("recompute_event_fines: event %s not found", event_id)
        return {"error": f"event {event_id} not found"}

    result = compute_fines_for_event(event)
    logger.info(
        "Recomputed fines for event %s (%s): %s created, %s updated",
        event_id, event.name, result["created"], result["updated"],
    )
    return result


@shared_task(name="attendance.tasks.recompute_all_active_fines")
def recompute_all_active_fines():
    """Recompute fines for every active event that has already started.

    Scheduled nightly by Celery Beat. Future-dated event-days are ignored by the
    service, so this only ever counts attendance days that have occurred.
    """
    from .models import Event
    from .services import compute_fines_for_event

    today = timezone.localdate()
    events = Event.objects.filter(is_active=True, start_date__lte=today)

    summaries = []
    for event in events:
        summaries.append(compute_fines_for_event(event, as_of=today))

    logger.info("Nightly recompute: processed %d active event(s)", len(summaries))
    return {"as_of": today.isoformat(), "events": len(summaries), "results": summaries}
