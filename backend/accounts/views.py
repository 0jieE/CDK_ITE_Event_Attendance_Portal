"""Admin-side viewsets for users, instructors and students.

All endpoints require :class:`accounts.permissions.IsAdmin`.
"""

from django_filters.rest_framework import DjangoFilterBackend
from rest_framework import filters, generics, serializers, status, viewsets
from rest_framework.parsers import FormParser, MultiPartParser
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.throttling import ScopedRateThrottle
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

from .images import validate_image_file
from .models import Instructor, Student, User
from .permissions import IsAdmin
from .serializers import (
    InstructorSerializer,
    MeSerializer,
    StudentSerializer,
    UserSerializer,
)


class ThrottledTokenObtainPairView(TokenObtainPairView):
    """``POST /api/auth/login/`` with a tight per-IP rate (brute-force guard)."""

    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "login"


class ThrottledTokenRefreshView(TokenRefreshView):
    """``POST /api/auth/refresh/`` — rotates (and blacklists) the refresh token."""

    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "refresh"


class MeView(generics.RetrieveAPIView):
    """Return the authenticated user's identity + role flags.

    Used by the mobile apps right after login to route to the correct
    interface (admin / instructor / student).
    """

    serializer_class = MeSerializer
    permission_classes = [IsAuthenticated]

    def get_object(self):
        return self.request.user


class PhotoUploadSerializer(serializers.Serializer):
    image = serializers.ImageField(validators=[validate_image_file])


class MyPhotoView(APIView):
    """``POST /api/me/photo/`` (multipart ``image``) sets, ``DELETE`` removes, the
    caller's own profile photo. Only ever touches ``request.user``."""

    permission_classes = [IsAuthenticated]
    parser_classes = [MultiPartParser, FormParser]
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "photo"

    def post(self, request):
        ser = PhotoUploadSerializer(data=request.data)
        ser.is_valid(raise_exception=True)
        user = request.user
        user.profile_image = ser.validated_data["image"]
        user.save(update_fields=["profile_image"])
        return Response(
            {"profile_image": user.get_profile_image_url("medium", request=request)},
            status=status.HTTP_201_CREATED,
        )

    def delete(self, request):
        user = request.user
        user.profile_image = None
        user.save(update_fields=["profile_image"])
        return Response(status=status.HTTP_204_NO_CONTENT)


class UserViewSet(viewsets.ModelViewSet):
    """CRUD for system users (any role)."""

    queryset = User.objects.all()
    serializer_class = UserSerializer
    permission_classes = [IsAdmin]
    filter_backends = [DjangoFilterBackend, filters.SearchFilter, filters.OrderingFilter]
    filterset_fields = ["is_admin", "is_instructor", "is_student", "is_active"]
    search_fields = ["username", "first_name", "middle_name", "last_name", "email"]
    ordering_fields = ["username", "last_name", "date_joined"]


class InstructorViewSet(viewsets.ModelViewSet):
    """CRUD for instructors; creates the linked user in the same request."""

    queryset = Instructor.objects.select_related("user").all()
    serializer_class = InstructorSerializer
    permission_classes = [IsAdmin]
    filter_backends = [filters.SearchFilter, filters.OrderingFilter]
    search_fields = [
        "user__username",
        "user__first_name",
        "user__last_name",
        "user__email",
    ]
    ordering_fields = ["user__last_name", "id"]


class StudentViewSet(viewsets.ModelViewSet):
    """CRUD for students; filterable by semester / school year.

    A student is linked to a semester/school-year through the events they have
    attendance for, so the filters below resolve via attendance logs.
    """

    queryset = Student.objects.select_related("user").all()
    serializer_class = StudentSerializer
    permission_classes = [IsAdmin]
    filter_backends = [DjangoFilterBackend, filters.SearchFilter, filters.OrderingFilter]
    search_fields = [
        "student_number",
        "user__username",
        "user__first_name",
        "user__last_name",
        "user__email",
    ]
    ordering_fields = ["student_number", "user__last_name"]

    def get_queryset(self):
        qs = super().get_queryset()
        params = self.request.query_params
        semester = params.get("semester")
        school_year = params.get("school_year")
        if semester:
            qs = qs.filter(attendance_logs__event__semester_id=semester).distinct()
        if school_year:
            qs = qs.filter(
                attendance_logs__event__semester__school_year_id=school_year
            ).distinct()
        return qs
