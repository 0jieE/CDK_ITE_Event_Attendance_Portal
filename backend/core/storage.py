"""Cloudinary-backed Django file storage for user-uploaded images.

Everything the system stores - student/instructor/admin profile photos, the
generated QR PNGs and the portal logo - goes into **one Cloudinary folder** (by
default ``ite-attendance``), with a sub-folder per upload area::

    ite-attendance/profiles/<random>.jpg     # profile photos
    ite-attendance/qrcodes/qr_<token>.png    # daily QR codes
    ite-attendance/branding/<logo>.png       # portal logo

The name kept in the database is storage-agnostic (``profiles/<random>.jpg``);
the folder prefix is added here. That makes it safe to run without Cloudinary
(plain local files) in development and to move between the two.

Enabled automatically when ``CLOUDINARY_CLOUD_NAME`` / ``CLOUDINARY_API_KEY`` /
``CLOUDINARY_API_SECRET`` are set (see ``core/settings.py``).
"""

import io
import logging
import os
import posixpath
import urllib.request

import cloudinary
import cloudinary.api
import cloudinary.exceptions
import cloudinary.uploader
import cloudinary.utils
from django.conf import settings
from django.core.files.base import ContentFile
from django.core.files.storage import Storage
from django.utils.deconstruct import deconstructible

logger = logging.getLogger(__name__)


def _split_ext(name):
    base, ext = posixpath.splitext(name)
    return base, ext.lstrip(".").lower()


@deconstructible
class CloudinaryMediaStorage(Storage):
    """Store images in Cloudinary under ``<CLOUDINARY_FOLDER>/<name>``."""

    def __init__(self, folder=None):
        self._folder = folder

    # -- helpers ------------------------------------------------------------
    @property
    def folder(self):
        folder = self._folder
        if folder is None:
            folder = getattr(settings, "CLOUDINARY_FOLDER", "ite-attendance")
        return (folder or "").strip("/")

    def _public_id(self, name):
        """Cloudinary public id for a storage name (no extension, folder-prefixed)."""
        base, _ = _split_ext(name.replace("\\", "/").lstrip("/"))
        return f"{self.folder}/{base}" if self.folder else base

    # -- Storage API --------------------------------------------------------
    def _save(self, name, content):
        name = name.replace("\\", "/").lstrip("/")
        base, ext = _split_ext(name)
        public_id = self._public_id(name)
        asset_folder = posixpath.dirname(public_id)

        if hasattr(content, "seek"):
            content.seek(0)
        data = content.read() if hasattr(content, "read") else content
        options = dict(
            public_id=public_id,
            resource_type="image",
            overwrite=True,          # names are unique (random / token), so this is idempotent
            unique_filename=False,
            use_filename=False,
            invalidate=True,
        )
        try:
            # Dynamic-folder accounts organise the Media Library by ``asset_folder``.
            result = cloudinary.uploader.upload(io.BytesIO(data), asset_folder=asset_folder, **options)
        except cloudinary.exceptions.BadRequest as exc:
            if "asset_folder" not in str(exc):
                raise
            result = cloudinary.uploader.upload(io.BytesIO(data), **options)  # fixed-folder account

        fmt = (result.get("format") or ext or "jpg").lower()
        dirname = posixpath.dirname(name)
        stored = posixpath.join(dirname, f"{posixpath.basename(base)}.{fmt}")
        logger.info("Uploaded %s to Cloudinary (%s bytes)", public_id, result.get("bytes"))
        return stored

    def exists(self, name):
        # Names are unique per upload, so Django never needs to rename: report "free".
        return False

    def delete(self, name):
        if not name:
            return
        try:
            cloudinary.uploader.destroy(self._public_id(name), resource_type="image", invalidate=True)
        except Exception:  # never break a request because an old image couldn't be removed
            logger.warning("Could not delete %s from Cloudinary", name, exc_info=True)

    def url(self, name, **transform):
        """Public HTTPS URL; pass e.g. ``width=256, height=256, crop='fill'`` to resize."""
        _, ext = _split_ext(name)
        options = {"secure": True, "resource_type": "image"}
        if ext:
            options["format"] = ext
        if transform:
            # Resize/crop on Cloudinary's side (e.g. a 256px face-centred avatar);
            # the stored original is untouched.
            options["transformation"] = [dict(transform, quality="auto")]
        url, _ = cloudinary.utils.cloudinary_url(self._public_id(name), **options)
        return url

    def size(self, name):
        return int(cloudinary.api.resource(self._public_id(name)).get("bytes", 0))

    def _open(self, name, mode="rb"):
        with urllib.request.urlopen(self.url(name), timeout=15) as resp:  # noqa: S310 - Cloudinary https URL
            return ContentFile(resp.read(), name=os.path.basename(name))

    def listdir(self, path):
        raise NotImplementedError("Cloudinary storage does not support listing directories.")
