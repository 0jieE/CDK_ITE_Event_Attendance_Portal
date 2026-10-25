"""Database backup and restore (Super Admin only, from Django Administration).

Why: the free PostgreSQL tier on Render is deleted after its trial period, and the free web
service has no shell to run ``dumpdata`` / ``loaddata``. So both directions are available from
the admin: **download** the data as one JSON file, and **restore** it into a fresh database
(deploy against a new database, log in as the Super Admin, upload the file).

What is saved: every row of ``accounts`` (users incl. password hashes, instructors, students),
``attendance`` (school years ... fines and slot payments) and ``portal`` (branding settings).
Images (profile photos, QR codes, the portal logo) live on Cloudinary and are referenced by
path, so they are not part of the file and survive a database loss.

Not saved on purpose: login sessions and JWT blacklists (everyone simply signs in again).
"""

import json
import os
import tempfile
from contextlib import contextmanager

from django.apps import apps
from django.core.management import call_command
from django.db import transaction
from django.db.models.signals import post_delete
from django.utils import timezone

BACKUP_APPS = ("accounts", "attendance", "portal")
MAX_RESTORE_BYTES = 50 * 1024 * 1024


class BackupError(Exception):
    """The uploaded file is not a usable backup."""


def backup_filename():
    return f"ite-attendance-backup-{timezone.localtime():%Y%m%d-%H%M}.json"


def build_backup():
    """The whole saved data set as JSON bytes (natural keys for permissions/groups)."""
    import io

    out = io.StringIO()
    call_command("dumpdata", *BACKUP_APPS, use_natural_foreign_keys=True, indent=1, stdout=out)
    return out.getvalue().encode("utf-8")


def summary():
    """Row counts shown on the backup page (what a backup taken now would contain)."""
    from accounts.models import Instructor, Student, User
    from attendance.models import AttendanceLog, Event, Fine, FineSlotPayment, QRCode, Semester

    return [
        ("Users", User.objects.count()),
        ("Students", Student.objects.count()),
        ("Instructors", Instructor.objects.count()),
        ("Semesters", Semester.objects.count()),
        ("Events", Event.objects.count()),
        ("Attendance logs", AttendanceLog.objects.count()),
        ("QR codes", QRCode.objects.count()),
        ("Fines", Fine.objects.count()),
        ("Fine slot payments", FineSlotPayment.objects.count()),
    ]


def validate_backup(raw):
    """Parse an uploaded backup and make sure it only touches our own tables."""
    if len(raw) > MAX_RESTORE_BYTES:
        raise BackupError("That file is too large to be a backup of this system.")
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise BackupError("That is not a valid backup file (it is not JSON).") from exc
    if not isinstance(data, list) or not data or not all(isinstance(o, dict) and "model" in o for o in data):
        raise BackupError("That is not a backup produced by this system.")
    models = {o["model"] for o in data}
    foreign = sorted(m for m in models if m.split(".")[0] not in BACKUP_APPS)
    if foreign:
        raise BackupError("The file contains data this restore will not touch: " + ", ".join(foreign[:5]))
    for label in models:
        try:
            apps.get_model(label)
        except (LookupError, ValueError) as exc:
            raise BackupError(f"Unknown record type in the file: {label}") from exc
    if "accounts.user" not in models:
        raise BackupError("The file has no users - refusing to restore it (that would lock everybody out).")
    return data


@contextmanager
def _images_kept():
    """Deleting rows normally deletes their image files from storage (Cloudinary).

    A restore must NOT do that: the backup still points at those images.
    """
    from accounts.models import User, _delete_profile_image
    from attendance.models import QRCode, _delete_qr_image

    post_delete.disconnect(_delete_profile_image, sender=User)
    post_delete.disconnect(_delete_qr_image, sender=QRCode)
    try:
        yield
    finally:
        post_delete.connect(_delete_profile_image, sender=User)
        post_delete.connect(_delete_qr_image, sender=QRCode)


def restore_backup(raw):
    """Replace ALL saved data with the contents of a backup file (all-or-nothing).

    Returns ``{"objects": n}``. On any error nothing is changed.
    """
    from accounts.models import User
    from attendance.models import SchoolYear
    from portal.models import PortalSettings

    data = validate_backup(raw)
    fd, path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(raw)
        with transaction.atomic(), _images_kept():
            # Cascades take the profiles, events, logs, QR codes, fines and payments with them.
            User.objects.all().delete()
            SchoolYear.objects.all().delete()
            PortalSettings.objects.all().delete()
            # ignorenonexistent: a backup from an older version may carry fields that no longer exist
            call_command("loaddata", path, ignorenonexistent=True, verbosity=0)
    except BackupError:
        raise
    except Exception as exc:  # noqa: BLE001 - surface any load problem as a readable error
        raise BackupError(f"The backup could not be restored (nothing was changed): {exc}") from exc
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    return {"objects": len(data)}
