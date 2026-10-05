"""Block until the configured database accepts connections (or give up)."""

import os
import sys
import time

import django

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "core.settings")
django.setup()

from django.db import connection  # noqa: E402
from django.db.utils import OperationalError  # noqa: E402

TIMEOUT = int(os.environ.get("DB_WAIT_TIMEOUT", 60))
deadline = time.monotonic() + TIMEOUT

while True:
    try:
        connection.ensure_connection()
        print("Database is ready.", flush=True)
        sys.exit(0)
    except OperationalError as exc:
        if time.monotonic() >= deadline:
            print(f"Database not reachable after {TIMEOUT}s: {exc}", file=sys.stderr)
            sys.exit(1)
        print("Waiting for database...", flush=True)
        time.sleep(2)
