"""Operational endpoints that are not part of the product API."""

from django.db import connection
from django.http import JsonResponse
from django.views.decorators.cache import never_cache
from django.views.decorators.http import require_safe


@require_safe
@never_cache
def healthz(request):
    """``GET /healthz/`` — 200 when the app is up *and* the database answers.

    Deliberately unauthenticated and free of DRF throttling so proxies and
    uptime monitors can poll it. It reveals nothing beyond up/down.
    """
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except Exception:  # any DB failure means "not healthy"
        return JsonResponse({"status": "error", "database": "unavailable"}, status=503)
    return JsonResponse({"status": "ok", "database": "ok"})
