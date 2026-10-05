"""Profile photos, Cloudinary storage and the image APIs."""

import datetime
import io
import os
import shutil
import tempfile
from decimal import Decimal
from unittest import mock

import cloudinary
import cloudinary.exceptions
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.core.files.base import ContentFile
from django.core.files.uploadedfile import SimpleUploadedFile
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase, override_settings
from django.urls import reverse
from django.utils import timezone
from PIL import Image
from rest_framework.test import APIClient

from attendance.models import Event, QRCode, SchoolYear, Semester

from .images import MAX_SIDE, normalise_image, validate_image_file
from .models import Instructor, Student, User

TMP_MEDIA = tempfile.mkdtemp(prefix="test-media-")


def tearDownModule():
    shutil.rmtree(TMP_MEDIA, ignore_errors=True)


def png_bytes(size=(300, 200), color=(30, 160, 40), fmt="PNG"):
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, format=fmt)
    return buf.getvalue()


def upload(name="me.png", size=(300, 200), fmt="PNG"):
    return SimpleUploadedFile(name, png_bytes(size, fmt=fmt), content_type=f"image/{fmt.lower()}")


@override_settings(MEDIA_ROOT=TMP_MEDIA)
class ImageProcessingTests(TestCase):
    def test_validator_accepts_real_images_and_rejects_the_rest(self):
        validate_image_file(upload())                                   # ok
        with self.assertRaises(ValidationError):
            validate_image_file(SimpleUploadedFile("x.png", b"not an image"))
        with self.assertRaises(ValidationError):
            validate_image_file(SimpleUploadedFile("x.gif", png_bytes(fmt="GIF")))   # GIF not allowed
        big = SimpleUploadedFile("big.png", b"0" * (5 * 1024 * 1024 + 1))
        with self.assertRaises(ValidationError):
            validate_image_file(big)

    def test_normalise_downsizes_strips_exif_and_randomises_name(self):
        buf = io.BytesIO()
        img = Image.new("RGB", (3000, 2000), (10, 120, 30))
        exif = Image.Exif()
        exif[0x010F] = "SecretCameraMaker"
        img.save(buf, format="JPEG", exif=exif)
        out = normalise_image(SimpleUploadedFile("photo.jpg", buf.getvalue()))
        processed = Image.open(io.BytesIO(out.read()))
        self.assertEqual(processed.format, "JPEG")
        self.assertLessEqual(max(processed.size), MAX_SIDE)
        self.assertEqual(len(processed.getexif()), 0)                   # metadata stripped
        self.assertRegex(out.name, r"^[0-9a-f]{32}\.jpg$")

    def test_transparent_png_is_flattened_on_white(self):
        buf = io.BytesIO()
        Image.new("RGBA", (50, 50), (0, 0, 0, 0)).save(buf, format="PNG")
        out = normalise_image(SimpleUploadedFile("t.png", buf.getvalue()))
        px = Image.open(io.BytesIO(out.read())).getpixel((5, 5))
        self.assertGreater(min(px), 240)


@override_settings(MEDIA_ROOT=TMP_MEDIA)
class UserPhotoLifecycleTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user("pic", password="x", first_name="Ana", last_name="Reyes")

    def path(self, user):
        return os.path.join(TMP_MEDIA, user.profile_image.name)

    def test_upload_is_stored_under_profiles_with_random_name(self):
        self.user.profile_image = upload()
        self.user.save()
        self.user.refresh_from_db()
        self.assertRegex(self.user.profile_image.name, r"^profiles/[0-9a-f]{32}\.jpg$")
        self.assertTrue(os.path.isfile(self.path(self.user)))

    def test_replacing_and_clearing_removes_the_old_file(self):
        self.user.profile_image = upload()
        self.user.save()
        first = self.path(self.user)
        self.user.profile_image = upload("b.png", (80, 80))
        self.user.save()
        self.assertFalse(os.path.exists(first))                         # old one deleted
        second = self.path(self.user)
        self.assertTrue(os.path.isfile(second))
        self.user.profile_image = None
        self.user.save()
        self.assertFalse(os.path.exists(second))

    def test_deleting_the_user_removes_the_photo(self):
        self.user.profile_image = upload()
        self.user.save()
        p = self.path(self.user)
        self.user.delete()
        self.assertFalse(os.path.exists(p))

    def test_login_style_partial_saves_do_not_touch_the_photo(self):
        self.user.profile_image = upload()
        self.user.save()
        name = self.user.profile_image.name
        self.user.save(update_fields=["last_login"])
        self.user.refresh_from_db()
        self.assertEqual(self.user.profile_image.name, name)

    def test_avatar_helpers(self):
        self.assertIsNone(self.user.avatar_url)
        self.assertEqual(self.user.initials, "AR")
        self.user.profile_image = upload()
        self.user.save()
        self.assertIn("/profiles/", self.user.avatar_url)


@override_settings(MEDIA_ROOT=TMP_MEDIA)
class PhotoApiTests(TestCase):
    def setUp(self):
        cache.clear()
        self.user = User.objects.create_user("stu", password="x", is_student=True, first_name="Stu", last_name="Dent")
        self.student = Student.objects.create(user=self.user, student_number="S-1")
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_upload_then_me_and_profile_show_the_photo_then_delete(self):
        res = self.client.post(reverse("me-photo"), {"image": upload()}, format="multipart")
        self.assertEqual(res.status_code, 201)
        self.assertIn("/profiles/", res.json()["profile_image"])
        me = self.client.get(reverse("me")).json()
        self.assertIn("/profiles/", me["profile_image"])
        prof = self.client.get(reverse("student-profile")).json()
        self.assertEqual(prof["profile_image"], me["profile_image"])
        self.assertEqual(self.client.delete(reverse("me-photo")).status_code, 204)
        self.assertIsNone(self.client.get(reverse("me")).json()["profile_image"])

    def test_bad_uploads_are_rejected(self):
        for bad in (SimpleUploadedFile("a.png", b"junk"),
                    SimpleUploadedFile("a.gif", png_bytes(fmt="GIF"))):
            res = self.client.post(reverse("me-photo"), {"image": bad}, format="multipart")
            self.assertEqual(res.status_code, 400)

    def test_photo_endpoint_needs_login_and_only_touches_own_user(self):
        self.assertEqual(APIClient().post(reverse("me-photo")).status_code, 401)
        other = User.objects.create_user("other", password="x")
        self.client.post(reverse("me-photo"), {"image": upload()}, format="multipart")
        other.refresh_from_db()
        self.assertFalse(other.profile_image)

    def test_scan_result_carries_the_students_photo_for_the_instructor(self):
        self.user.profile_image = upload()
        self.user.save()
        today = timezone.localdate()
        sy = SchoolYear.objects.create(sy="2025-2026")
        sem = Semester.objects.create(school_year=sy, name="1st")
        ev = Event.objects.create(
            name="E", semester=sem, start_date=today, end_date=today, fine_rate=Decimal("10"),
            required_types=["AM_IN"], am_in_start=datetime.time(0, 0), am_in_end=datetime.time(23, 59, 59))
        qr = QRCode.objects.create(student=self.student, event=ev, date=today)
        ins = User.objects.create_user("ins", password="x", is_instructor=True)
        Instructor.objects.create(user=ins)
        c = APIClient()
        c.force_authenticate(ins)
        res = c.post(reverse("instructor-scan"), {"token": qr.token})
        self.assertEqual(res.status_code, 201)
        self.assertIn("/profiles/", res.json()["student_photo"])

    def test_admin_can_set_a_photo_through_the_users_api(self):
        admin = User.objects.create_user("adm", password="x", is_admin=True, is_staff=True)
        c = APIClient()
        c.force_authenticate(admin)
        res = c.post(reverse("user-list"), {
            "username": "newbie", "password": "Str0ng-Pass-123!", "first_name": "New",
            "profile_image_upload": upload(),
        }, format="multipart")
        self.assertEqual(res.status_code, 201, res.content)
        self.assertIn("/profiles/", res.json()["profile_image"])
        uid = res.json()["id"]
        res = c.patch(reverse("user-detail", args=[uid]), {"clear_profile_image": "true"}, format="multipart")
        self.assertEqual(res.status_code, 200)
        self.assertIsNone(res.json()["profile_image"])


@override_settings(MEDIA_ROOT=TMP_MEDIA)
class PortalPhotoFormTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create_user("adviser", password="x", is_admin=True, is_staff=True)
        self.client.force_login(self.admin)

    def test_student_form_shows_the_photo_control_and_multipart_encoding(self):
        html = self.client.get(reverse("portal:students-add")).content.decode()
        self.assertIn('type="file"', html)
        self.assertIn('name="profile_image"', html)
        self.assertIn('hx-encoding="multipart/form-data"', html)

    def _student_post(self, **extra):
        data = {"student_number": "2024-9", "year_level": "1", "section": "A",
                "username": "photo1", "first_name": "Pho", "last_name": "To",
                "email": "p@x.ph", "password": "Str0ng-Pass-123!", "is_active": "on"}
        data.update(extra)
        return self.client.post(reverse("portal:students-add"), data)

    def test_create_student_with_photo_edit_keep_then_remove(self):
        res = self._student_post(profile_image=upload())
        self.assertEqual(res.status_code, 204, res.content[:300])
        student = Student.objects.get(student_number="2024-9")
        name = student.user.profile_image.name
        self.assertRegex(name, r"^profiles/[0-9a-f]{32}\.jpg$")

        url = reverse("portal:students-edit", args=[student.pk])
        base = {"student_number": "2024-9", "year_level": "1", "section": "A",
                "username": "photo1", "first_name": "Pho", "last_name": "To", "is_active": "on"}
        self.assertEqual(self.client.post(url, base).status_code, 204)        # no file: keep photo
        student.user.refresh_from_db()
        self.assertEqual(student.user.profile_image.name, name)

        self.assertEqual(self.client.post(url, {**base, "profile_image-clear": "on"}).status_code, 204)
        student.user.refresh_from_db()
        self.assertFalse(student.user.profile_image)                          # removed
        self.assertFalse(os.path.exists(os.path.join(TMP_MEDIA, name)))

    def test_invalid_image_is_rejected_with_a_form_error(self):
        res = self._student_post(profile_image=SimpleUploadedFile("x.png", b"not an image"))
        self.assertEqual(res.status_code, 422)
        self.assertFalse(Student.objects.filter(student_number="2024-9").exists())

    def test_tables_render_avatars_and_initials(self):
        u = User.objects.create_user("t1", password="x", first_name="Tina", last_name="Cruz", is_student=True)
        Student.objects.create(user=u, student_number="T-1")
        html = self.client.get(reverse("portal:students-list")).content.decode()
        self.assertIn('class="av"', html)
        self.assertIn(">TC<", html)                                           # initials fallback


class CloudinaryStorageTests(TestCase):
    """The storage talks to Cloudinary through the SDK - mocked here."""

    def setUp(self):
        from core.storage import CloudinaryMediaStorage
        cloudinary.config(cloud_name="democloud", api_key="123", api_secret="secret", secure=True)
        self.storage = CloudinaryMediaStorage(folder="ite-attendance")

    def test_save_uploads_into_the_system_folder(self):
        with mock.patch("cloudinary.uploader.upload", return_value={"format": "jpg", "bytes": 10}) as up:
            name = self.storage.save("profiles/abc123.jpg", ContentFile(b"data"))
        self.assertEqual(name, "profiles/abc123.jpg")
        kwargs = up.call_args.kwargs
        self.assertEqual(kwargs["public_id"], "ite-attendance/profiles/abc123")
        self.assertEqual(kwargs["asset_folder"], "ite-attendance/profiles")
        self.assertTrue(kwargs["overwrite"])
        self.assertEqual(kwargs["resource_type"], "image")

    def test_qr_png_goes_to_the_qrcodes_subfolder(self):
        with mock.patch("cloudinary.uploader.upload", return_value={"format": "png", "bytes": 5}) as up:
            self.storage.save("qrcodes/qr_TOKEN.png", ContentFile(b"png"))
        self.assertEqual(up.call_args.kwargs["public_id"], "ite-attendance/qrcodes/qr_TOKEN")

    def test_fixed_folder_accounts_fall_back_without_asset_folder(self):
        calls = []

        def fake(file, **kw):
            calls.append(kw)
            if "asset_folder" in kw:
                raise cloudinary.exceptions.BadRequest("Unknown parameter asset_folder")
            return {"format": "jpg", "bytes": 1}

        with mock.patch("cloudinary.uploader.upload", side_effect=fake):
            self.storage.save("profiles/z.jpg", ContentFile(b"x"))
        self.assertEqual(len(calls), 2)
        self.assertNotIn("asset_folder", calls[1])

    def test_url_is_https_in_the_folder_and_can_resize_with_face_crop(self):
        plain = self.storage.url("profiles/abc.jpg")
        # The SDK adds the standard "v1" version placeholder for folder paths.
        self.assertEqual(plain, "https://res.cloudinary.com/democloud/image/upload/v1/ite-attendance/profiles/abc.jpg")
        thumb = self.storage.url("profiles/abc.jpg", width=96, height=96, crop="fill", gravity="face")
        self.assertIn("c_fill", thumb)
        self.assertIn("g_face", thumb)
        self.assertIn("w_96", thumb)
        self.assertTrue(thumb.endswith("ite-attendance/profiles/abc.jpg"))

    def test_delete_destroys_the_asset_and_never_raises(self):
        with mock.patch("cloudinary.uploader.destroy") as d:
            self.storage.delete("profiles/abc.jpg")
        self.assertEqual(d.call_args.args[0], "ite-attendance/profiles/abc")
        with mock.patch("cloudinary.uploader.destroy", side_effect=RuntimeError("net down")):
            self.storage.delete("profiles/abc.jpg")                           # swallowed

    def test_names_are_never_renamed_because_exists_is_false(self):
        self.assertFalse(self.storage.exists("profiles/anything.jpg"))


class CloudinarySetupCommandTests(TestCase):
    def test_not_configured_fails_clearly_or_skips_quietly(self):
        with override_settings(CLOUDINARY_ENABLED=False, CLOUDINARY_CLOUD_NAME="",
                               CLOUDINARY_API_KEY="", CLOUDINARY_API_SECRET=""):
            with self.assertRaisesMessage(CommandError, "CLOUDINARY_CLOUD_NAME"):
                call_command("cloudinary_setup")
            out = io.StringIO()
            call_command("cloudinary_setup", "--if-configured", stdout=out)
            self.assertIn("local media storage", out.getvalue())

    def test_creates_the_folder_tree_and_is_rerunnable(self):
        out = io.StringIO()
        with override_settings(CLOUDINARY_ENABLED=True, CLOUDINARY_CLOUD_NAME="c",
                               CLOUDINARY_FOLDER="ite-attendance"), \
                mock.patch("cloudinary.api.ping", return_value={"status": "ok"}), \
                mock.patch("cloudinary.api.create_folder") as cf:
            call_command("cloudinary_setup", stdout=out)
        made = [c.args[0] for c in cf.call_args_list]
        self.assertEqual(made, ["ite-attendance", "ite-attendance/profiles",
                                "ite-attendance/qrcodes", "ite-attendance/branding"])
        with override_settings(CLOUDINARY_ENABLED=True, CLOUDINARY_CLOUD_NAME="c"), \
                mock.patch("cloudinary.api.ping"), \
                mock.patch("cloudinary.api.create_folder",
                           side_effect=cloudinary.exceptions.Error("Folder already exists")):
            call_command("cloudinary_setup", stdout=io.StringIO())             # no crash

    def test_bad_credentials_give_a_clear_error(self):
        with override_settings(CLOUDINARY_ENABLED=True, CLOUDINARY_CLOUD_NAME="c"), \
                mock.patch("cloudinary.api.ping",
                           side_effect=cloudinary.exceptions.AuthorizationRequired("Invalid api_key")):
            with self.assertRaisesMessage(CommandError, "rejected the credentials"):
                call_command("cloudinary_setup")
