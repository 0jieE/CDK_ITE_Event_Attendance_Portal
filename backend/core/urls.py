"""URL configuration for the QR Attendance & Financial Management backend.

Admin-side REST API lives under ``/api/``.  Interactive docs (Swagger UI) are
served at ``/api/docs/`` via drf-spectacular.
"""

from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.shortcuts import redirect
from django.urls import include, path
from drf_spectacular.views import (
    SpectacularAPIView,
    SpectacularSwaggerView,
)
from rest_framework.routers import DefaultRouter

from accounts.views import (
    InstructorViewSet,
    MeView,
    MyPhotoView,
    StudentViewSet,
    ThrottledTokenObtainPairView,
    ThrottledTokenRefreshView,
    UserViewSet,
)
from attendance.views import (
    AttendanceLogViewSet,
    EventViewSet,
    FineViewSet,
    SchoolYearViewSet,
    SemesterViewSet,
    attendance_report,
    dashboard,
    financial_report,
)
from core.views import healthz
from attendance.mobile_views import (
    InstructorEventsView,
    InstructorScanView,
    InstructorScansView,
    StudentAttendanceView,
    StudentBalanceView,
    StudentEventsView,
    StudentFinesView,
    StudentProfileView,
    StudentQRGenerateView,
    StudentQRListView,
)

router = DefaultRouter()
router.register("users", UserViewSet, basename="user")
router.register("instructors", InstructorViewSet, basename="instructor")
router.register("students", StudentViewSet, basename="student")
router.register("school-years", SchoolYearViewSet, basename="schoolyear")
router.register("semesters", SemesterViewSet, basename="semester")
router.register("events", EventViewSet, basename="event")
router.register("attendance-logs", AttendanceLogViewSet, basename="attendancelog")
router.register("fines", FineViewSet, basename="fine")

api_patterns = [
    # JWT auth
    path("auth/login/", ThrottledTokenObtainPairView.as_view(), name="auth-login"),
    path("auth/refresh/", ThrottledTokenRefreshView.as_view(), name="auth-refresh"),
    # Current user (mobile routing after login)
    path("me/", MeView.as_view(), name="me"),
    path("me/photo/", MyPhotoView.as_view(), name="me-photo"),
    # --- Instructor (mobile) ---
    path("instructor/events/", InstructorEventsView.as_view(), name="instructor-events"),
    path("instructor/scan/", InstructorScanView.as_view(), name="instructor-scan"),
    path("instructor/scans/", InstructorScansView.as_view(), name="instructor-scans"),
    # --- Student (mobile, own data only) ---
    path("student/profile/", StudentProfileView.as_view(), name="student-profile"),
    path("student/events/", StudentEventsView.as_view(), name="student-events"),
    path("student/qr/generate/", StudentQRGenerateView.as_view(), name="student-qr-generate"),
    path("student/qr/", StudentQRListView.as_view(), name="student-qr-list"),
    path("student/attendance/", StudentAttendanceView.as_view(), name="student-attendance"),
    path("student/fines/", StudentFinesView.as_view(), name="student-fines"),
    path("student/balance/", StudentBalanceView.as_view(), name="student-balance"),
    # Dashboard & reports
    path("dashboard/", dashboard, name="dashboard"),
    path("reports/attendance/", attendance_report, name="report-attendance"),
    path("reports/financial/", financial_report, name="report-financial"),
    # CRUD routers
    path("", include(router.urls)),
    # API schema & docs
    path("schema/", SpectacularAPIView.as_view(), name="schema"),
    path("docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="docs"),
]

urlpatterns = [
    # Liveness/DB probe for the reverse proxy, Docker and uptime monitors.
    path("healthz/", healthz, name="healthz"),
    path("admin/", admin.site.urls),
    path("api/", include(api_patterns)),
    # Server-rendered admin web portal (Department Adviser, session auth).
    path("portal/", include("portal.urls")),
    # Convenience: send the site root to the portal.
    path("", lambda request: redirect("portal:dashboard")),
]

# Serve generated QR images / media during development.
if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
