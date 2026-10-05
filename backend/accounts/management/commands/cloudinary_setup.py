"""Verify the Cloudinary credentials and create the system's upload folders.

    python manage.py cloudinary_setup

Creates (idempotently) ``<CLOUDINARY_FOLDER>`` and its sub-folders ``profiles``,
``qrcodes`` and ``branding``. Exits non-zero with a clear message when the
credentials are missing or rejected. With ``--if-configured`` it silently does
nothing when Cloudinary is not enabled (used by the container entrypoint).
"""

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

SUBFOLDERS = ("profiles", "qrcodes", "branding")


class Command(BaseCommand):
    help = "Check Cloudinary credentials and create the upload folders."

    def add_arguments(self, parser):
        parser.add_argument(
            "--if-configured",
            action="store_true",
            help="Do nothing (exit 0) when Cloudinary credentials are not set.",
        )

    def handle(self, *args, **options):
        if not settings.CLOUDINARY_ENABLED:
            if options["if_configured"]:
                self.stdout.write("Cloudinary not configured - using local media storage.")
                return
            missing = [
                k for k in ("CLOUDINARY_CLOUD_NAME", "CLOUDINARY_API_KEY", "CLOUDINARY_API_SECRET")
                if not getattr(settings, k)
            ]
            raise CommandError("Missing settings: " + ", ".join(missing))

        import cloudinary.api
        import cloudinary.exceptions

        try:
            cloudinary.api.ping()
        except cloudinary.exceptions.AuthorizationRequired as exc:
            raise CommandError(f"Cloudinary rejected the credentials: {exc}")
        except Exception as exc:
            raise CommandError(f"Could not reach Cloudinary: {exc}")
        self.stdout.write(self.style.SUCCESS(
            f"Connected to Cloudinary cloud '{settings.CLOUDINARY_CLOUD_NAME}'."))

        root = settings.CLOUDINARY_FOLDER.strip("/")
        for path in [root] + [f"{root}/{sub}" for sub in SUBFOLDERS]:
            try:
                cloudinary.api.create_folder(path)
                self.stdout.write(f"  folder ready: {path}")
            except cloudinary.exceptions.Error as exc:
                # Re-running is fine: Cloudinary reports an existing folder as an error.
                if "exist" in str(exc).lower():
                    self.stdout.write(f"  folder exists: {path}")
                else:
                    raise CommandError(f"Could not create folder '{path}': {exc}")
        self.stdout.write(self.style.SUCCESS("Cloudinary is ready."))
