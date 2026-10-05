"""Django admin for the accounts app."""

from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin

from .models import Instructor, Student, User


@admin.register(User)
class UserAdmin(BaseUserAdmin):
    list_display = (
        "username",
        "get_full_name",
        "email",
        "role",
        "is_admin",
        "is_instructor",
        "is_student",
        "is_active",
    )
    list_filter = ("is_admin", "is_instructor", "is_student", "is_active", "is_staff")
    search_fields = ("username", "first_name", "middle_name", "last_name", "email")

    # Extend the default fieldsets with our custom fields.
    fieldsets = BaseUserAdmin.fieldsets + (
        ("Profile", {"fields": ("middle_name", "profile_image")}),
        ("System roles", {"fields": ("is_admin", "is_instructor", "is_student")}),
    )
    add_fieldsets = BaseUserAdmin.add_fieldsets + (
        ("Profile", {"fields": ("first_name", "middle_name", "last_name", "email", "profile_image")}),
        ("System roles", {"fields": ("is_admin", "is_instructor", "is_student")}),
    )


@admin.register(Instructor)
class InstructorAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "get_email")
    search_fields = ("user__username", "user__first_name", "user__last_name")

    @admin.display(description="Email")
    def get_email(self, obj):
        return obj.user.email


@admin.register(Student)
class StudentAdmin(admin.ModelAdmin):
    list_display = ("student_number", "user", "year_level", "section", "get_email")
    list_filter = ("year_level", "section")
    search_fields = ("student_number", "user__username", "user__last_name")

    @admin.display(description="Email")
    def get_email(self, obj):
        return obj.user.email
