"""Upload images that currently live only on local disk to Cloudinary.

    python manage.py sync_media_to_cloudinary

* **QR codes** are regenerated from their token (the PNG is a pure function of
  the token), so nothing local is needed and the same file name is kept.
* **Profile photos / the portal logo** are uploaded from ``MEDIA_ROOT`` when the
  local file still exists.

Safe to re-run (uploads overwrite the same public id).
"""

import os

from django.conf import settings
from django.core.files import File
from django.core.management.base import BaseCommand, CommandError

from accounts.models import User
from attendance.models import QRCode


class Command(BaseCommand):
    help = "Push existing local images (QR PNGs, photos, logo) to Cloudinary."

    def handle(self, *args, **options):
        if not settings.CLOUDINARY_ENABLED:
            raise CommandError("Cloudinary is not configured (set the CLOUDINARY_* variables).")
        storage = QRCode._meta.get_field("image").storage

        qr_done = 0
        for qr in QRCode.objects.exclude(image="").exclude(image__isnull=True).iterator():
            qr.generate_image(save=True)
            qr_done += 1
        self.stdout.write(f"QR codes uploaded: {qr_done}")

        def push_local(name):
            path = os.path.join(settings.MEDIA_ROOT, name)
            if not os.path.isfile(path):
                return False
            with open(path, "rb") as fh:
                storage.save(name, File(fh))
            return True

        photos = sum(
            push_local(u.profile_image.name)
            for u in User.objects.exclude(profile_image="").exclude(profile_image__isnull=True)
        )
        self.stdout.write(f"Profile photos uploaded from disk: {photos}")

        try:
            from portal.models import PortalSettings

            logo = PortalSettings.load().logo
            if logo and push_local(logo.name):
                self.stdout.write("Portal logo uploaded.")
        except Exception as exc:  # portal app optional here
            self.stdout.write(f"Logo skipped: {exc}")
        self.stdout.write(self.style.SUCCESS("Done."))
