"""DRF permission classes implementing the system's RBAC.

All admin-side APIs in this phase require :class:`IsAdmin`.  The instructor and
student permissions are provided ready for the mobile phase (scanning / view
own data) but are not yet wired to any endpoint.
"""

from rest_framework.permissions import BasePermission, SAFE_METHODS


class IsAdmin(BasePermission):
    """Allow only authenticated Department Advisers (or Django superusers)."""

    message = "Only the Department Adviser (admin) may perform this action."

    def has_permission(self, request, view):
        user = request.user
        return bool(user and user.is_authenticated and (user.is_admin or user.is_superuser))


class IsInstructor(BasePermission):
    """Allow only authenticated instructors. (Reserved for the mobile phase.)"""

    message = "Only an assigned instructor may perform this action."

    def has_permission(self, request, view):
        user = request.user
        return bool(user and user.is_authenticated and user.is_instructor)


class IsStudent(BasePermission):
    """Allow only authenticated students. (Reserved for the mobile phase.)"""

    message = "Only a student may perform this action."

    def has_permission(self, request, view):
        user = request.user
        return bool(user and user.is_authenticated and user.is_student)


class IsAdminOrReadOnly(BasePermission):
    """Read access for any authenticated user; writes restricted to admins."""

    def has_permission(self, request, view):
        user = request.user
        if not (user and user.is_authenticated):
            return False
        if request.method in SAFE_METHODS:
            return True
        return bool(user.is_admin or user.is_superuser)
