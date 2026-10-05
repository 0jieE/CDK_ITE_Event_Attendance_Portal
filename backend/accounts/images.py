"""Profile-photo helpers: validation, normalisation and URL building.

Uploaded photos are validated, auto-rotated from EXIF, stripped of metadata
(EXIF/GPS) and downscaled to at most ``MAX_SIDE`` px before they ever reach
storage, so every photo is small, safe to display and free of location data.
"""

import io
import uuid

from django.core.exceptions import ValidationError
from django.core.files.base import ContentFile
from PIL import Image, ImageOps

MAX_UPLOAD_BYTES = 5 * 1024 * 1024        # 5 MB (matches nginx client_max_body_size)
MAX_PIXELS = 25_000_000                   # refuse decompression bombs
MAX_SIDE = 1024                           # longest side kept after processing
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}

#: Thumbnail presets (Cloudinary resizes on delivery; local files are served as-is).
SIZES = {
    "thumb": dict(width=96, height=96, crop="fill", gravity="face"),
    "medium": dict(width=256, height=256, crop="fill", gravity="face"),
}


def validate_image_file(upload):
    """Model/serializer validator: size, real image, allowed type, sane dimensions."""
    if upload is None or getattr(upload, "_committed", False):
        return  # already-stored file: nothing to check
    size = getattr(upload, "size", None)
    if size is not None and size > MAX_UPLOAD_BYTES:
        raise ValidationError("Image is too large (max 5 MB).")
    try:
        upload.seek(0)
        img = Image.open(upload)
        fmt = img.format
        width, height = img.size
        img.verify()
    except Exception:
        raise ValidationError("Upload a valid image file (JPG, PNG or WebP).")
    finally:
        try:
            upload.seek(0)
        except Exception:
            pass
    if fmt not in ALLOWED_FORMATS:
        raise ValidationError("Only JPG, PNG or WebP images are allowed.")
    if width * height > MAX_PIXELS:
        raise ValidationError("Image dimensions are too large.")


def normalise_image(upload):
    """Return a ``ContentFile`` named ``<random>.jpg``: rotated, metadata-free, <=1024px."""
    upload.seek(0)
    img = Image.open(upload)
    img = ImageOps.exif_transpose(img)           # honour phone-camera rotation
    if img.mode in ("RGBA", "LA", "P"):          # flatten transparency onto white
        img = img.convert("RGBA")
        background = Image.new("RGB", img.size, (255, 255, 255))
        background.paste(img, mask=img.getchannel("A"))
        img = background
    else:
        img = img.convert("RGB")
    img.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
    buffer = io.BytesIO()
    img.save(buffer, format="JPEG", quality=85, optimize=True)   # fresh file: no EXIF carried over
    return ContentFile(buffer.getvalue(), name=f"{uuid.uuid4().hex}.jpg")


def profile_upload_to(instance, filename):
    """Storage name for a profile photo: unguessable, extension-normalised."""
    return f"profiles/{uuid.uuid4().hex}.jpg"


def image_url(field_file, size=None, request=None):
    """Absolute URL for an ImageField file, optionally resized (``size`` in SIZES).

    Returns ``None`` when there is no image. With Cloudinary the resize happens
    on Cloudinary's side; with local storage the original is returned (made
    absolute with ``request`` when given).
    """
    if not field_file:
        return None
    storage = field_file.storage
    try:
        if size and hasattr(storage, "folder"):      # CloudinaryMediaStorage
            return storage.url(field_file.name, **SIZES[size])
        url = field_file.url
    except Exception:
        return None
    if request is not None and url.startswith("/"):
        return request.build_absolute_uri(url)
    return url
