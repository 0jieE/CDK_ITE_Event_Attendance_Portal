"""ModelForms for the admin web portal.

A :class:`BootstrapModelForm` base auto-applies Bootstrap 5 classes so the
field-rendering template can stay generic across every section.
"""

import datetime
import json
from decimal import Decimal, InvalidOperation

from django import forms
from django.db import transaction
from django.contrib.auth import get_user_model
from django.contrib.auth.password_validation import validate_password

from accounts.images import validate_image_file
from accounts.models import Instructor, Student
from attendance.models import AttendanceType, Event, EventDayFine, SchoolYear, Semester

from .models import PortalSettings

User = get_user_model()


class BootstrapModelForm(forms.ModelForm):
    """Apply Bootstrap 5 control classes to every widget automatically."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        for field in self.fields.values():
            widget = field.widget
            if isinstance(widget, (forms.CheckboxInput, forms.CheckboxSelectMultiple)):
                # CheckboxSelectMultiple is NOT a Select subclass, so without this
                # branch it fell through to ``form-control`` below, which turns every
                # checkbox into an invisible full-width box (nothing looks selected).
                widget.attrs.setdefault("class", "form-check-input")
            elif isinstance(widget, (forms.Select, forms.SelectMultiple)):
                widget.attrs.setdefault("class", "form-select")
            else:
                existing = widget.attrs.get("class", "")
                widget.attrs["class"] = (existing + " form-control").strip()


class EventForm(BootstrapModelForm):
    """Create/edit an Event, including the multi-select ``required_types``."""

    required_types = forms.MultipleChoiceField(
        choices=AttendanceType.choices,
        widget=forms.CheckboxSelectMultiple,
        help_text="Attendance slots that are mandatory for this event.",
    )

    #: the 8 per-slot time-window fields
    TIME_FIELDS = [
        "am_in_start", "am_in_end",
        "am_out_start", "am_out_end",
        "pm_in_start", "pm_in_end",
        "pm_out_start", "pm_out_end",
    ]

    class Meta:
        model = Event
        fields = [
            "name",
            "semester",
            "start_date",
            "end_date",
            "fine_rate",
            "required_types",
            "is_active",
            "am_in_start", "am_in_end",
            "am_out_start", "am_out_end",
            "pm_in_start", "pm_in_end",
            "pm_out_start", "pm_out_end",
        ]
        widgets = {
            "start_date": forms.DateInput(
                attrs={"type": "date"}, format="%Y-%m-%d"
            ),
            "end_date": forms.DateInput(
                attrs={"type": "date"}, format="%Y-%m-%d"
            ),
            "am_in_start": forms.TimeInput(attrs={"type": "time"}, format="%H:%M"),
            "am_in_end": forms.TimeInput(attrs={"type": "time"}, format="%H:%M"),
            "am_out_start": forms.TimeInput(attrs={"type": "time"}, format="%H:%M"),
            "am_out_end": forms.TimeInput(attrs={"type": "time"}, format="%H:%M"),
            "pm_in_start": forms.TimeInput(attrs={"type": "time"}, format="%H:%M"),
            "pm_in_end": forms.TimeInput(attrs={"type": "time"}, format="%H:%M"),
            "pm_out_start": forms.TimeInput(attrs={"type": "time"}, format="%H:%M"),
            "pm_out_end": forms.TimeInput(attrs={"type": "time"}, format="%H:%M"),
        }
        labels = {
            "am_in_start": "AM-In start", "am_in_end": "AM-In end",
            "am_out_start": "AM-Out start", "am_out_end": "AM-Out end",
            "pm_in_start": "PM-In start", "pm_in_end": "PM-In end",
            "pm_out_start": "PM-Out start", "pm_out_end": "PM-Out end",
        }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Ensure native date inputs accept/echo ISO dates on edit.
        for name in ("start_date", "end_date"):
            self.fields[name].input_formats = ["%Y-%m-%d"]
        for name in self.TIME_FIELDS:
            self.fields[name].input_formats = ["%H:%M", "%H:%M:%S"]
        self.fields["fine_rate"].label = "Fine per missed slot"
        self.fields["fine_rate"].help_text = (
            "Default amount charged per missed slot. For a multi-day event you can set a "
            "different amount for each day below."
        )
        self.fields["am_in_start"].help_text = (
            "Set the scan window for each required slot. Scanning is only allowed "
            "inside these times; outside them the slot is marked absent."
        )

    # -- per-day fines (inputs named ``day_fine__YYYY-MM-DD``, built by JS) -------
    DAY_FINE_PREFIX = "day_fine__"
    supports_day_fines = True

    def _posted_day_fines(self):
        """``{date: raw string}`` from the submitted ``day_fine__*`` inputs."""
        out = {}
        for key, value in self.data.items():
            if key.startswith(self.DAY_FINE_PREFIX):
                out[key[len(self.DAY_FINE_PREFIX):]] = (value or "").strip()
        return out

    @property
    def day_fines_json(self):
        """Existing/typed per-day rates for the JS that renders the inputs."""
        if self.is_bound:
            return json.dumps({k: v for k, v in self._posted_day_fines().items() if v})
        if self.instance and self.instance.pk:
            return json.dumps({k: str(v) for k, v in self.instance.day_rates.items()})
        return "{}"

    def _clean_day_fines(self, start, end):
        rates = {}
        for raw_day, raw in self._posted_day_fines().items():
            if not raw:
                continue                                   # blank = use the default rate
            try:
                day = datetime.date.fromisoformat(raw_day)
                value = Decimal(raw)
            except (ValueError, InvalidOperation):
                self.add_error(None, f"Fine for {raw_day} must be a number.")
                continue
            if value < 0 or value.as_tuple().exponent < -2 or value >= Decimal("100000000"):
                self.add_error(None, f"Fine for {raw_day} must be zero or more, with at most 2 decimals.")
                continue
            if start and end and start <= day <= end:
                rates[day] = value
        return rates

    def clean(self):
        cleaned = super().clean()
        start, end = cleaned.get("start_date"), cleaned.get("end_date")
        if start and end and end < start:
            self.add_error("end_date", "End date must be on or after the start date.")
        self._day_rates = self._clean_day_fines(start, end)
        # A slot that isn't required has no scan window: drop any stale times so they
        # can't be saved (or trip validation) invisibly.
        required = set(cleaned.get("required_types") or [])
        for slot, (start_field, end_field) in Event.SLOT_TIME_FIELDS.items():
            if slot not in required:
                cleaned[start_field] = None
                cleaned[end_field] = None
        return cleaned

    def save(self, commit=True):
        before = None
        if self.instance.pk:
            before = (self.instance.fine_rate, self.instance.day_rates)
        with transaction.atomic():
            event = super().save(commit=commit)
            if commit:
                EventDayFine.objects.filter(event=event).delete()
                EventDayFine.objects.bulk_create(
                    EventDayFine(event=event, date=day, fine_rate=rate)
                    for day, rate in self._day_rates.items() if rate != event.fine_rate
                )
        if commit and before is not None:
            event.refresh_from_db()
            if before != (event.fine_rate, event.day_rates):
                # Rates changed: bring the existing fines in line right away.
                from attendance.services import compute_fines_for_event

                compute_fines_for_event(event)
        return event


# ---------------------------------------------------------------------------
# School year / Semester
# ---------------------------------------------------------------------------
class SchoolYearForm(BootstrapModelForm):
    class Meta:
        model = SchoolYear
        fields = ["sy"]
        widgets = {"sy": forms.TextInput(attrs={"placeholder": "e.g. 2025-2026"})}


class SemesterForm(BootstrapModelForm):
    class Meta:
        model = Semester
        fields = ["school_year", "name"]


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------
class UserForm(BootstrapModelForm):
    """Create/edit a user with role flags; password optional on edit."""

    password = forms.CharField(
        widget=forms.PasswordInput(render_value=False),
        required=False,
        help_text="Leave blank to keep the current password (required when creating).",
    )

    class Meta:
        model = User
        fields = [
            "username",
            "first_name",
            "middle_name",
            "last_name",
            "profile_image",
            "is_admin",
            "is_instructor",
            "is_student",
            "is_active",
        ]

    def clean_password(self):
        pwd = self.cleaned_data.get("password")
        if pwd:
            validate_password(pwd, self.instance)
        elif self.instance.pk is None:
            raise forms.ValidationError("Password is required when creating a user.")
        return pwd

    def clean_is_student(self):
        wanted = self.cleaned_data.get("is_student")
        has_profile = bool(self.instance.pk) and Student.objects.filter(user=self.instance).exists()
        if wanted and not has_profile:
            raise forms.ValidationError(
                "A student account needs a student number - add students on the Students page "
                "(or import a masterlist) instead."
            )
        return wanted

    def save(self, commit=True):
        user = super().save(commit=False)
        pwd = self.cleaned_data.get("password")
        if pwd:
            user.set_password(pwd)
        if commit:
            user.save()
        return user


# ---------------------------------------------------------------------------
# Instructors / Students — manage the linked User in the same form
# ---------------------------------------------------------------------------
class LinkedUserForm(BootstrapModelForm):
    """Base for profile models (Instructor/Student) that own a ``user``.

    Subclasses set ``role_flag`` (e.g. ``"is_instructor"``); the linked
    :class:`User` is created on add and updated on edit.
    """

    role_flag = None  # e.g. "is_instructor"

    username = forms.CharField(max_length=150)
    first_name = forms.CharField(max_length=150, required=False)
    middle_name = forms.CharField(max_length=150, required=False)
    last_name = forms.CharField(max_length=150, required=False)
    profile_image = forms.ImageField(
        required=False,
        label="Profile photo",
        validators=[validate_image_file],
        help_text="JPG, PNG or WebP, up to 5 MB. Shown to instructors when they scan.",
    )
    is_active = forms.BooleanField(required=False, initial=True, label="Active")
    password = forms.CharField(
        widget=forms.PasswordInput(render_value=False),
        required=False,
        help_text="Leave blank to keep current password (required when creating).",
    )

    #: order in which user fields appear before any model-specific fields
    user_field_order = [
        "profile_image", "username", "first_name", "middle_name", "last_name",
        "password", "is_active",
    ]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Pre-fill the user fields when editing an existing profile.
        if self.instance and self.instance.pk:
            u = self.instance.user
            self.fields["username"].initial = u.username
            self.fields["first_name"].initial = u.first_name
            self.fields["middle_name"].initial = u.middle_name
            self.fields["last_name"].initial = u.last_name
            self.fields["profile_image"].initial = u.profile_image
            self.fields["is_active"].initial = u.is_active

    def _current_user_pk(self):
        return self.instance.user_id if self.instance and self.instance.pk else None

    def clean_username(self):
        username = self.cleaned_data["username"]
        qs = User.objects.filter(username__iexact=username)
        if self._current_user_pk():
            qs = qs.exclude(pk=self._current_user_pk())
        if qs.exists():
            raise forms.ValidationError("A user with that username already exists.")
        return username

    def clean_password(self):
        pwd = self.cleaned_data.get("password")
        if pwd:
            validate_password(pwd)
        elif self.instance.pk is None:
            raise forms.ValidationError("Password is required when creating.")
        return pwd

    def _save_user(self):
        """Create or update the linked user, enforcing the role flag."""
        creating = self.instance.pk is None
        user = self.instance.user if not creating else User()
        user.username = self.cleaned_data["username"]
        user.first_name = self.cleaned_data.get("first_name", "")
        user.middle_name = self.cleaned_data.get("middle_name", "")
        user.last_name = self.cleaned_data.get("last_name", "")
        user.is_active = self.cleaned_data.get("is_active", True)
        image = self.cleaned_data.get("profile_image")
        if image is False:                 # "Remove photo" ticked
            user.profile_image = None
        elif image:                        # a new upload (None = keep the current one)
            user.profile_image = image
        setattr(user, self.role_flag, True)
        pwd = self.cleaned_data.get("password")
        if pwd:
            user.set_password(pwd)
        user.save()
        return user

    def save(self, commit=True):
        # All-or-nothing: a failure while saving the profile must not leave a user behind.
        with transaction.atomic():
            user = self._save_user()
            profile = super().save(commit=False)
            profile.user = user
            if commit:
                # Saving a user flagged is_instructor already created its Instructor row
                # (see accounts.models); reuse it instead of inserting a duplicate.
                existing = type(profile)._default_manager.filter(user=user).first()
                if existing is not None and profile.pk is None:
                    profile.pk = existing.pk
                    profile._state.adding = False
                profile.save()
        return profile


class InstructorForm(LinkedUserForm):
    role_flag = "is_instructor"

    field_order = LinkedUserForm.user_field_order

    class Meta:
        model = Instructor
        fields = []  # all editable fields are the declared user fields


class StudentForm(LinkedUserForm):
    role_flag = "is_student"

    class Meta:
        model = Student
        fields = ["student_number", "year_level", "section"]
        widgets = {
            "section": forms.TextInput(attrs={"placeholder": "e.g. A"}),
        }


# ---------------------------------------------------------------------------
# Fines — calculate action
# ---------------------------------------------------------------------------
class FineCalculateForm(forms.Form):
    """Pick the event whose fines should be (re)computed."""

    event = forms.ModelChoiceField(
        queryset=Event.objects.select_related("semester__school_year").all(),
        widget=forms.Select(attrs={"class": "form-select"}),
        help_text="Re-running is safe; paid fines are never overwritten.",
    )


# ---------------------------------------------------------------------------
# Portal UI settings
# ---------------------------------------------------------------------------
class PortalSettingsForm(BootstrapModelForm):
    """Edit the singleton :class:`PortalSettings` (branding + theme + logo)."""

    class Meta:
        model = PortalSettings
        fields = [
            "brand_title",
            "brand_subtitle",
            "theme",
            "color_mode",
            "logo",
            "compact_sidebar",
        ]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["logo"].help_text = (
            "PNG/JPG. Leave empty to use the bundled ITE Department seal."
        )
