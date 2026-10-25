"""Use our branded admin site instead of Django's stock one (see core/admin_site.py)."""

from django.contrib.admin.apps import AdminConfig


class IteAdminConfig(AdminConfig):
    default_site = "core.admin_site.IteAdminSite"
