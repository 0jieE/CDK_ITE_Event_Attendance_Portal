"""Django admin for the accounts app."""

from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin

from .models import Instructor, Student, User


@admin.register(User)
class UserAdmin(BaseUserAdmin):
    list_display = (
        "username",
        "get_full_name",
        "role",
        "is_admin",
        "is_instructor",
        "is_student",
        "is_active",
    )
    list_filter = ("is_admin", "is_instructor", "is_student", "is_active", "is_staff")
    search_fields = ("username", "first_name", "middle_name", "last_name")

    # The stock UserAdmin fieldsets mention ``email``, which this model doesn't have.
    fieldsets = (
        (None, {"fields": ("username", "password")}),
        ("Profile", {"fields": ("first_name", "middle_name", "last_name", "profile_image")}),
        ("Permissions", {"fields": ("is_active", "is_staff", "is_superuser", "groups", "user_permissions")}),
        ("System roles", {"fields": ("is_admin", "is_instructor", "is_student")}),
        ("Important dates", {"fields": ("last_login", "date_joined")}),
    )
    add_fieldsets = (
        (None, {"classes": ("wide",), "fields": ("username", "password1", "password2")}),
        ("Profile", {"fields": ("first_name", "middle_name", "last_name", "profile_image")}),
        ("System roles", {"fields": ("is_admin", "is_instructor", "is_student")}),
    )


@admin.register(Instructor)
class InstructorAdmin(admin.ModelAdmin):
    list_display = ("id", "user")
    search_fields = ("user__username", "user__first_name", "user__last_name")


@admin.register(Student)
class StudentAdmin(admin.ModelAdmin):
    list_display = ("student_number", "user", "year_level", "section", "approval_status")
    list_filter = ("approval_status", "year_level", "section")
    search_fields = ("student_number", "user__username", "user__last_name")
