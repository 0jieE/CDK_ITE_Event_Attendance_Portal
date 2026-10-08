"""Seed (or update) a single Department-Adviser admin superuser.

Usage::

    python manage.py seed_admin
    python manage.py seed_admin --username adviser --password secret

Reads sensible defaults from the environment so it can run unattended in CI:
``ADMIN_USERNAME``, ``ADMIN_PASSWORD``.

Container/production use (``--if-missing``) is strictly idempotent: the admin is
created only if it does not exist yet and an existing account (including a
password the adviser has since changed) is never touched. In that mode the
password must be supplied explicitly and the well-known dev default is refused.
"""

import os

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError

User = get_user_model()

DEV_DEFAULT_PASSWORD = "Admin@12345"


class Command(BaseCommand):
    help = "Create or update the seed admin (Department Adviser) superuser."

    def add_arguments(self, parser):
        parser.add_argument(
            "--username",
            default=os.environ.get("ADMIN_USERNAME", "admin"),
        )
        parser.add_argument(
            "--password",
            default=os.environ.get("ADMIN_PASSWORD") or DEV_DEFAULT_PASSWORD,
        )
        parser.add_argument(
            "--if-missing",
            action="store_true",
            help="Create the admin only if it does not exist; never modify an "
            "existing user. Requires a non-default password (safe to re-run).",
        )

    def handle(self, *args, **options):
        username = options["username"]
        password = options["password"]

        if options["if_missing"]:
            if User.objects.filter(username=username).exists():
                self.stdout.write(f"Admin '{username}' already exists - left unchanged.")
                return
            if not settings.DEBUG and password == DEV_DEFAULT_PASSWORD:
                raise CommandError(
                    "Refusing to create the admin with the default password. "
                    "Set ADMIN_PASSWORD to a strong, unique value."
                )

        user, created = User.objects.get_or_create(
            username=username,
        )
        user.is_admin = True
        user.is_staff = True
        user.is_superuser = True
        user.set_password(password)
        user.save()

        verb = "Created" if created else "Updated"
        self.stdout.write(
            self.style.SUCCESS(
                f"{verb} admin superuser '{username}' "
                "Remember to change the password."
            )
        )
