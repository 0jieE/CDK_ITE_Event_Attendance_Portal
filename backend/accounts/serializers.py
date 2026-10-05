"""Serializers for users, instructors and students.

Instructor/Student endpoints create the linked :class:`User` in the same
request (nested ``user`` payload) and echo back readable user info — full
name and role — on read.
"""

from django.contrib.auth.password_validation import validate_password
from rest_framework import serializers

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
        fields = ["id", "username", "full_name", "email", "role", "profile_image"]
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
            "email",
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
            "email",
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
            "email",
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

    class Meta:
        model = Student
        fields = ["id", "student_number", "user"]

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
