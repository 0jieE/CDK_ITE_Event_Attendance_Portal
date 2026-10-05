"""Celery application for the QR Attendance backend.

Background processing (fine calculation) runs through this app with **Redis**
as the broker/result backend. Settings are read from Django under the
``CELERY_`` namespace; see ``core/settings.py``.
"""

import os

from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "core.settings")

app = Celery("core")
# All Celery config lives in Django settings, prefixed with CELERY_.
app.config_from_object("django.conf:settings", namespace="CELERY")
# Auto-discover tasks.py in every installed app.
app.autodiscover_tasks()


@app.task(bind=True)
def debug_task(self):
    """Trivial task to verify the worker is alive."""
    return f"OK from {self.request.id}"
