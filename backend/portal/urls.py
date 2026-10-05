"""URLConf for the admin web portal (mounted at ``/portal/``)."""

from django.urls import path

from . import views

app_name = "portal"

urlpatterns = [
    path("", views.dashboard_view, name="dashboard"),
    path("login/", views.login_view, name="login"),
    path("logout/", views.logout_view, name="logout"),
    # Attendance logs (read-only)
    path("attendance_logs/", views.attendance_logs_view, name="attendance_logs-list"),
    # Fines
    path("fines/", views.fines_view, name="fines-list"),
    path("fines/calculate/", views.fines_calculate_view, name="fines-calculate"),
    path("fines/<int:pk>/mark-paid/", views.fines_mark_paid_view, name="fines-mark-paid"),
    # Reports
    path("reports/attendance/", views.report_attendance_view, name="reports-attendance"),
    path("reports/financial/", views.report_financial_view, name="reports-financial"),
    # Settings
    path("settings/", views.settings_view, name="settings"),
]

# Register every declarative CRUD section's URLs.
for section in views.SECTIONS:
    urlpatterns += section.get_urls()
