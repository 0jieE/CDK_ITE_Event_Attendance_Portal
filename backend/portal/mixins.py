"""Access control and HTMX helpers for the admin web portal.

The portal is for the **Department Adviser** (a client user with
``is_admin=True``) and uses Django *session* auth — entirely separate from the
mobile JWT layer.  Django's own ``/admin/`` remains the superuser/developer's
tool and is intentionally *not* reachable through these mixins.
"""

import json
from functools import wraps

from django.contrib import messages
from django.contrib.auth.views import redirect_to_login
from django.core.exceptions import PermissionDenied
from django.http import HttpResponse


def is_portal_admin(user):
    """True only for an authenticated Department Adviser (``is_admin``).

    Note: a bare Django superuser is **not** granted portal access here unless
    they also carry the ``is_admin`` flag — the portal is a client-role tool.
    """
    return bool(user and user.is_authenticated and getattr(user, "is_admin", False))


def admin_required(view_func):
    """Function-view decorator: allow only portal admins, else redirect/403."""

    @wraps(view_func)
    def _wrapped(request, *args, **kwargs):
        if not request.user.is_authenticated:
            return redirect_to_login(request.get_full_path())
        if not is_portal_admin(request.user):
            raise PermissionDenied("Department Adviser (admin) access only.")
        return view_func(request, *args, **kwargs)

    return _wrapped


class AdminRequiredMixin:
    """Class-based-view counterpart of :func:`admin_required`."""

    def dispatch(self, request, *args, **kwargs):
        if not request.user.is_authenticated:
            return redirect_to_login(request.get_full_path())
        if not is_portal_admin(request.user):
            raise PermissionDenied("Department Adviser (admin) access only.")
        return super().dispatch(request, *args, **kwargs)


# ---------------------------------------------------------------------------
# HTMX helpers
# ---------------------------------------------------------------------------
def is_htmx(request):
    """Was this request issued by HTMX?"""
    return request.headers.get("HX-Request") == "true"


def trigger_headers(*, toast=None, level="success", events=None):
    """Build an ``HX-Trigger`` header payload.

    ``toast`` shows a Bootstrap toast client-side; ``events`` is an iterable of
    additional client event names to fire (e.g. a table-refresh signal).
    """
    payload = {}
    if toast:
        payload["showToast"] = {"message": toast, "level": level}
    for event in events or []:
        payload[event] = True
    return {"HX-Trigger": json.dumps(payload)} if payload else {}


def htmx_action_response(*, toast=None, level="success", refresh_event=None,
                         close_modal=True, status=204):
    """Standard empty response for a successful HTMX create/update/delete.

    Fires a toast, optionally a table-refresh event, and (by default) closes
    the open modal — all via a single ``HX-Trigger`` header.
    """
    events = []
    if refresh_event:
        events.append(refresh_event)
    if close_modal:
        events.append("closeModal")
    headers = trigger_headers(toast=toast, level=level, events=events)
    return HttpResponse(status=status, headers=headers)


def push_message(request, toast, level="success"):
    """Mirror a portal toast into Django's messages framework (full-page)."""
    getattr(messages, level, messages.info)(request, toast)
