"""Django admin for portal-level configuration."""

from django.contrib import admin

from .models import PortalSettings


@admin.register(PortalSettings)
class PortalSettingsAdmin(admin.ModelAdmin):
    list_display = ("__str__", "brand_title", "theme", "color_mode", "updated_at")

    def has_add_permission(self, request):
        # Singleton — only the one row may exist.
        return not PortalSettings.objects.exists()

    def has_delete_permission(self, request, obj=None):
        return False
