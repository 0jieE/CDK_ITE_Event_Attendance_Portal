"""The branded Django Administration site (Super Admin only) with a Backup & restore page."""

from django.contrib import admin, messages
from django.core.exceptions import PermissionDenied
from django.http import HttpResponse
from django.shortcuts import redirect
from django.template.response import TemplateResponse
from django.urls import path

from . import backup


class IteAdminSite(admin.AdminSite):
    site_header = "ITE Attendance · Administration"
    site_title = "ITE Attendance admin"
    index_title = "Super Admin tools"

    def get_urls(self):
        urls = super().get_urls()
        custom = [path("backup/", self.admin_view(self.backup_view), name="backup")]
        return custom + urls          # before the catch-all app/model patterns

    def each_context(self, request):
        context = super().each_context(request)
        context["is_super_admin"] = request.user.is_superuser
        return context

    def backup_view(self, request):
        """Download a full backup, or restore one (POST). Super Admin only."""
        if not request.user.is_superuser:
            raise PermissionDenied("Only the Super Admin can back up or restore the database.")

        if request.method == "POST":
            action = request.POST.get("action")
            if action == "download":
                response = HttpResponse(backup.build_backup(), content_type="application/json")
                response["Content-Disposition"] = f'attachment; filename="{backup.backup_filename()}"'
                return response
            if action == "restore":
                upload = request.FILES.get("file")
                if request.POST.get("confirm", "").strip() != "RESTORE":
                    messages.error(request, 'Type RESTORE in the confirmation box to restore a backup.')
                elif not upload:
                    messages.error(request, "Choose the backup file first.")
                else:
                    try:
                        result = backup.restore_backup(upload.read())
                    except backup.BackupError as exc:
                        messages.error(request, str(exc))
                    else:
                        # the restore replaced every user, so this session may no longer be valid
                        messages.success(
                            request,
                            f"Restored {result['objects']} records from the backup. If you are asked to sign in "
                            "again, use the Super Admin account that existed when the backup was taken.",
                        )
                return redirect("admin:backup")

        context = dict(
            self.each_context(request),
            title="Backup & restore",
            counts=backup.summary(),
        )
        return TemplateResponse(request, "admin/backup.html", context)
