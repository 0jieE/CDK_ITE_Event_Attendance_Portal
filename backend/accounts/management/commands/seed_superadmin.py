"""Create (or update) the Super Admin - the only role that can open Django Administration.

    python manage.py seed_superadmin --username superadmin --password SECRET
    python manage.py seed_superadmin --if-missing        # container entrypoint (env vars)

Reads ``SUPERADMIN_USERNAME`` (default ``superadmin``) and ``SUPERADMIN_PASSWORD``.
With ``--if-missing`` it is strictly idempotent and never touches an existing account, and
it silently does nothing when ``SUPERADMIN_PASSWORD`` is not set.
"""

import os

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError

User = get_user_model()


class Command(BaseCommand):
    help = "Create or update the Super Admin (portal + Django Administration)."

    def add_arguments(self, parser):
        parser.add_argument("--username", default=os.environ.get("SUPERADMIN_USERNAME") or "superadmin")
        parser.add_argument("--password", default=os.environ.get("SUPERADMIN_PASSWORD") or None)
        parser.add_argument(
            "--if-missing",
            action="store_true",
            help="Create only when missing (never modify an existing user); skip if no password is set.",
        )

    def handle(self, *args, **options):
        username, password = options["username"], options["password"]
        if options["if_missing"]:
            if not password:
                self.stdout.write("SUPERADMIN_PASSWORD not set - no Super Admin created.")
                return
            if User.objects.filter(username=username).exists():
                self.stdout.write(f"Super Admin '{username}' already exists - left unchanged.")
                return
        if not password:
            raise CommandError("Provide --password (or set SUPERADMIN_PASSWORD).")

        user, created = User.objects.get_or_create(username=username)
        user.is_superuser = True
        user.is_staff = True        # may open Django Administration
        user.is_admin = True        # and the portal
        user.is_active = True
        user.set_password(password)
        user.save()
        verb = "Created" if created else "Updated"
        self.stdout.write(self.style.SUCCESS(
            f"{verb} Super Admin '{username}' (portal + Django Administration)."))
