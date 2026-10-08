"""Serializers for users, instructors and students.

Instructor/Student endpoints create the linked :class:`User` in the same
request (nested ``user`` payload) and echo back readable user info — full
name and role — on read.
"""

from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, transaction
from rest_framework import serializers
from rest_framework.exceptions import PermissionDenied
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer

from .images import validate_image_file

from .models import Instructor, Student, User


class ProfileImageMixin:
    """Adds a read-only ``profile_image`` URL (256px) to a User serializer."""

    def get_profile_image(self, obj) -> str | None:
        return obj.get_profile_image_url("medium", request=self.context.get("request"))


class UserSummarySerializer(ProfileImageMixin, serializers.ModelSerializer):
    """Compact, read-only user representation embedded by other serializers."""

    full_name = serializers.CharField(source="get_full_name", read_only=True)
    profile_image = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = ["id", "username", "full_name", "role", "profile_image"]
        read_only_fields = fields


class MeSerializer(ProfileImageMixin, serializers.ModelSerializer):
    """Read-only identity payload for ``GET /api/me/`` (mobile routing)."""

    full_name = serializers.CharField(source="get_full_name", read_only=True)
    profile_image = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = [
            "id",
            "username",
            "full_name",
            "is_admin",
            "is_instructor",
            "is_student",
            "role",
            "profile_image",
        ]
        read_only_fields = fields


class UserSerializer(ProfileImageMixin, serializers.ModelSerializer):
    """Full CRUD serializer for ``/api/users/`` with proper password hashing.

    ``profile_image`` is read as a 256px URL; to change it, send a multipart
    request with ``profile_image_upload`` (or ``clear_profile_image=true``).
    """

    full_name = serializers.CharField(source="get_full_name", read_only=True)
    profile_image = serializers.SerializerMethodField()
    profile_image_upload = serializers.ImageField(
        write_only=True, required=False, validators=User._meta.get_field("profile_image").validators
    )
    clear_profile_image = serializers.BooleanField(write_only=True, required=False, default=False)
    password = serializers.CharField(
        write_only=True, required=False, style={"input_type": "password"}
    )

    class Meta:
        model = User
        fields = [
            "id",
            "username",
            "password",
            "first_name",
            "middle_name",
            "last_name",
            "full_name",
            "is_admin",
            "is_instructor",
            "is_student",
            "is_active",
            "role",
            "date_joined",
            "profile_image",
            "profile_image_upload",
            "clear_profile_image",
        ]
        read_only_fields = ["id", "date_joined", "full_name", "role"]

    def validate_password(self, value):
        validate_password(value)
        return value

    def _apply_image(self, validated_data):
        """Translate the write-only upload/clear fields into model changes."""
        upload = validated_data.pop("profile_image_upload", None)
        clear = validated_data.pop("clear_profile_image", False)
        if upload is not None:
            validated_data["profile_image"] = upload
        elif clear:
            validated_data["profile_image"] = None

    def create(self, validated_data):
        self._apply_image(validated_data)
        password = validated_data.pop("password", None)
        if not password:
            raise serializers.ValidationError(
                {"password": "Password is required when creating a user."}
            )
        user = User(**validated_data)
        user.set_password(password)
        user.save()
        return user

    def update(self, instance, validated_data):
        self._apply_image(validated_data)
        password = validated_data.pop("password", None)
        for attr, value in validated_data.items():
            setattr(instance, attr, value)
        if password:
            instance.set_password(password)
        instance.save()
        return instance


class _NestedUserSerializer(ProfileImageMixin, serializers.ModelSerializer):
    """Writable nested user used when creating instructors / students.

    Role flags are forced by the parent serializer, so they are not exposed
    here.  Password is required on create.
    """

    full_name = serializers.CharField(source="get_full_name", read_only=True)
    profile_image = serializers.SerializerMethodField()
    profile_image_upload = serializers.ImageField(
        write_only=True, required=False, validators=User._meta.get_field("profile_image").validators
    )
    password = serializers.CharField(
        write_only=True, required=False, style={"input_type": "password"}
    )

    class Meta:
        model = User
        fields = [
            "id",
            "username",
            "password",
            "first_name",
            "middle_name",
            "last_name",
            "full_name",
            "is_active",
            "role",
            "profile_image",
            "profile_image_upload",
        ]
        read_only_fields = ["id", "full_name", "role"]

    def validate_password(self, value):
        validate_password(value)
        return value


def _create_user_from_nested(user_data, *, role_flag):
    """Create a User from nested data, enforcing the given role flag."""
    password = user_data.pop("password", None)
    if not password:
        raise serializers.ValidationError(
            {"user": {"password": "Password is required."}}
        )
    upload = user_data.pop("profile_image_upload", None)
    if upload is not None:
        user_data["profile_image"] = upload
    user = User(**user_data)
    setattr(user, role_flag, True)
    user.set_password(password)
    user.save()
    return user


def _update_nested_user(user, user_data):
    """Apply a partial nested-user update, hashing the password if present."""
    password = user_data.pop("password", None)
    upload = user_data.pop("profile_image_upload", None)
    if upload is not None:
        user_data["profile_image"] = upload
    for attr, value in user_data.items():
        setattr(user, attr, value)
    if password:
        user.set_password(password)
    user.save()
    return user


class InstructorSerializer(serializers.ModelSerializer):
    """CRUD serializer that creates/links a User flagged ``is_instructor``."""

    user = _NestedUserSerializer()

    class Meta:
        model = Instructor
        fields = ["id", "user"]

    def create(self, validated_data):
        user = _create_user_from_nested(
            validated_data.pop("user"), role_flag="is_instructor"
        )
        return Instructor.objects.create(user=user, **validated_data)

    def update(self, instance, validated_data):
        user_data = validated_data.pop("user", None)
        if user_data:
            _update_nested_user(instance.user, user_data)
        return instance


class StudentSerializer(serializers.ModelSerializer):
    """CRUD serializer that creates/links a User flagged ``is_student``."""

    user = _NestedUserSerializer()

    approval_status = serializers.CharField(read_only=True)
    rejection_reason = serializers.CharField(read_only=True)

    class Meta:
        model = Student
        fields = ["id", "student_number", "user", "approval_status", "rejection_reason"]

    def create(self, validated_data):
        user = _create_user_from_nested(
            validated_data.pop("user"), role_flag="is_student"
        )
        return Student.objects.create(user=user, **validated_data)

    def update(self, instance, validated_data):
        user_data = validated_data.pop("user", None)
        if user_data:
            _update_nested_user(instance.user, user_data)
        instance.student_number = validated_data.get(
            "student_number", instance.student_number
        )
        instance.save()
        return instance


# ---------------------------------------------------------------------------
# Student self-registration (needs the Department Adviser's approval)
# ---------------------------------------------------------------------------
class StudentRegistrationSerializer(serializers.Serializer):
    """Body for the public ``POST /api/auth/register/``.

    Creates an **inactive** user + a ``PENDING`` student. Nothing can be done with
    the account until the adviser approves it in the portal.
    """

    student_number = serializers.CharField(max_length=50)
    first_name = serializers.CharField(max_length=150)
    middle_name = serializers.CharField(max_length=150, required=False, allow_blank=True)
    last_name = serializers.CharField(max_length=150)
    username = serializers.CharField(max_length=150)
    password = serializers.CharField(write_only=True, style={"input_type": "password"})
    year_level = serializers.ChoiceField(choices=Student.YearLevel.choices)
    section = serializers.CharField(max_length=20, required=False, allow_blank=True)
    profile_image = serializers.ImageField(required=False, validators=[validate_image_file])

    def validate_student_number(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Student number is required.")
        if Student.objects.filter(student_number__iexact=value).exists():
            raise serializers.ValidationError("A student with that number is already registered.")
        return value

    def validate_username(self, value):
        value = value.strip()
        if not value or " " in value:
            raise serializers.ValidationError("Username cannot be blank or contain spaces.")
        if User.objects.filter(username__iexact=value).exists():
            raise serializers.ValidationError("A user with that username already exists.")
        return value

    def validate_first_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("First name is required.")
        return value

    def validate_last_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Last name is required.")
        return value

    def validate(self, attrs):
        probe = User(
            username=attrs.get("username", ""),
            first_name=attrs.get("first_name", ""),
            last_name=attrs.get("last_name", ""),
        )
        try:
            validate_password(attrs["password"], probe)
        except DjangoValidationError as exc:
            raise serializers.ValidationError({"password": list(exc.messages)})
        return attrs

    def create(self, validated_data):
        image = validated_data.pop("profile_image", None)
        student_number = validated_data.pop("student_number")
        year_level = validated_data.pop("year_level")
        section = validated_data.pop("section", "").strip()
        password = validated_data.pop("password")
        try:
            with transaction.atomic():
                user = User(
                    username=validated_data["username"],
                    first_name=validated_data["first_name"],
                    middle_name=(validated_data.get("middle_name") or "").strip() or None,
                    last_name=validated_data["last_name"],
                    is_student=True,
                    is_active=False,            # cannot sign in until approved
                )
                user.set_password(password)
                if image is not None:
                    user.profile_image = image
                user.save()
                return Student.objects.create(
                    user=user,
                    student_number=student_number,
                    year_level=year_level,
                    section=section,
                    approval_status=Student.ApprovalStatus.PENDING,
                )
        except IntegrityError:        # lost a race for the username / student number
            raise serializers.ValidationError(
                {"username": ["That username or student number was just taken. Try again."]}
            )


class ApprovalAwareTokenObtainPairSerializer(TokenObtainPairSerializer):
    """Login that tells a not-yet-approved student *why* they can't sign in.

    Only someone who supplies the CORRECT password learns the account's state;
    wrong credentials still get the generic 401, so usernames can't be probed.
    """

    def validate(self, attrs):
        username = attrs.get(self.username_field)
        password = attrs.get("password")
        user = User.objects.filter(username=username).first()
        if user is not None and not user.is_active and password and user.check_password(password):
            student = Student.objects.filter(user=user).first()
            if student and student.approval_status == Student.ApprovalStatus.PENDING:
                raise PermissionDenied({
                    "detail": "Your account is waiting for approval by the Department Adviser. "
                              "You'll be able to sign in once it is approved.",
                    "code": "PENDING_APPROVAL",
                })
            if student and student.approval_status == Student.ApprovalStatus.REJECTED:
                reason = f" Reason: {student.rejection_reason}" if student.rejection_reason else ""
                raise PermissionDenied({
                    "detail": "Your registration was not approved by the Department Adviser." + reason,
                    "code": "REGISTRATION_REJECTED",
                })
        return super().validate(attrs)
