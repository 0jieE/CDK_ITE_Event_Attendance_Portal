"""Instructors can review attendance in every event (read-only roster per event-day)."""

import datetime
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import Instructor, Student, User

from .models import AttendanceLog, Event, SchoolYear, Semester

T = datetime.time
D = datetime.timedelta


def make_event(start, end, name="E", required=("AM_IN", "PM_OUT")):
    sy = SchoolYear.objects.get_or_create(sy="2026-2027")[0]
    sem = Semester.objects.get_or_create(school_year=sy, name="1st")[0]
    return Event.objects.create(
        name=name, semester=sem, start_date=start, end_date=end, fine_rate=Decimal("10"),
        required_types=list(required), am_in_start=T(7), am_in_end=T(8),
        am_out_start=T(11, 30), am_out_end=T(12), pm_in_start=T(13), pm_in_end=T(14),
        pm_out_start=T(16, 30), pm_out_end=T(17, 15))


def make_student(username, number, first, last, **kw):
    u = User.objects.create_user(username, password="x", is_student=True, first_name=first, last_name=last)
    return Student.objects.create(user=u, student_number=number, year_level="2", section="A", **kw)


def scan(student, event, day, slot, status="PRESENT"):
    AttendanceLog.objects.create(
        student=student, event=event, date=day, attendance_type=slot, status=status,
        scanned_at=timezone.make_aware(datetime.datetime.combine(day, T(7, 30))))


class InstructorAttendanceTests(TestCase):
    def setUp(self):
        self.today = timezone.localdate()
        iu = User.objects.create_user("inst", password="x", is_instructor=True)
        Instructor.objects.create(user=iu)
        self.client = APIClient()
        self.client.force_authenticate(iu)
        self.anna = make_student("anna", "S-1", "Anna", "Reyes")
        self.ben = make_student("ben", "S-2", "Ben", "Abad")

    def url(self, event, **q):
        res = self.client.get(reverse("instructor-event-attendance", args=[event.pk]), q)
        return res

    # --- permissions -----------------------------------------------------------
    def test_instructors_only(self):
        ev = make_event(self.today - D(days=2), self.today - D(days=1))
        for client, code in ((APIClient(), 401),):
            self.assertEqual(client.get(reverse("instructor-event-attendance", args=[ev.pk])).status_code, code)
        stu = APIClient()
        stu.force_authenticate(self.anna.user)
        self.assertEqual(stu.get(reverse("instructor-event-attendance", args=[ev.pk])).status_code, 403)
        self.assertEqual(stu.get(reverse("instructor-events"), {"all": "true"}).status_code, 403)
        adm = APIClient()
        adm.force_authenticate(User.objects.create_user("adm", password="x", is_admin=True, is_staff=True))
        self.assertEqual(adm.get(reverse("instructor-event-attendance", args=[ev.pk])).status_code, 403)

    def test_unknown_event_is_404(self):
        self.assertEqual(self.client.get(reverse("instructor-event-attendance", args=[9999])).status_code, 404)

    # --- events list -----------------------------------------------------------
    def test_events_all_includes_finished_and_upcoming_newest_first(self):
        old = make_event(self.today - D(days=20), self.today - D(days=19), "Old")
        now = make_event(self.today - D(days=1), self.today + D(days=1), "Now")
        fut = make_event(self.today + D(days=9), self.today + D(days=10), "Future")
        default = [e["name"] for e in self.client.get(reverse("instructor-events")).json()["results"]]
        self.assertEqual(default, ["Now"])                       # scanner list unchanged
        every = [e["name"] for e in self.client.get(reverse("instructor-events"), {"all": "true"}).json()["results"]]
        self.assertEqual(every, ["Future", "Now", "Old"])
        self.assertEqual({old.pk, now.pk, fut.pk}, {
            e["id"] for e in self.client.get(reverse("instructor-events"), {"all": "1"}).json()["results"]})

    # --- roster ------------------------------------------------------------------
    def test_finished_event_shows_present_and_absent_per_slot(self):
        ev = make_event(self.today - D(days=3), self.today - D(days=2))
        day = self.today - D(days=3)
        scan(self.anna, ev, day, "AM_IN")
        scan(self.anna, ev, day, "PM_OUT", status="LATE")
        scan(self.ben, ev, day, "AM_IN")
        data = self.url(ev, date=str(day)).json()
        self.assertEqual(data["date"], str(day))
        self.assertEqual(data["dates"], [str(day), str(day + D(days=1))])
        self.assertFalse(data["is_today"])
        self.assertEqual([s["type"] for s in data["slots"]], ["AM_IN", "PM_OUT"])
        self.assertEqual(data["slots"][0]["label"], "AM Time-In")
        self.assertEqual((data["slots"][0]["window_start"], data["slots"][0]["window_end"]), ("07:00:00", "08:00:00"))
        self.assertTrue(all(s["elapsed"] for s in data["slots"]))
        self.assertEqual((data["slots"][0]["present"], data["slots"][0]["absent"]), (2, 0))
        self.assertEqual((data["slots"][1]["present"], data["slots"][1]["absent"], data["slots"][1]["pending"]), (1, 1, 0))
        by_name = {s["full_name"]: s for s in data["students"]}
        self.assertEqual([c["status"] for c in by_name["Anna Reyes"]["slots"]], ["PRESENT", "LATE"])
        self.assertEqual((by_name["Anna Reyes"]["attended"], by_name["Anna Reyes"]["missed"]), (2, 0))
        self.assertEqual([c["status"] for c in by_name["Ben Abad"]["slots"]], ["PRESENT", "ABSENT"])
        self.assertEqual((by_name["Ben Abad"]["attended"], by_name["Ben Abad"]["missed"]), (1, 1))
        self.assertIsNotNone(by_name["Anna Reyes"]["slots"][0]["scanned_at"])
        self.assertIsNone(by_name["Ben Abad"]["slots"][1]["scanned_at"])

    def test_students_sorted_by_last_name_and_include_year_section_and_photo_key(self):
        ev = make_event(self.today - D(days=2), self.today - D(days=1))
        data = self.url(ev).json()
        self.assertEqual([s["full_name"] for s in data["students"]], ["Ben Abad", "Anna Reyes"])
        row = data["students"][0]
        self.assertEqual(row["year_section"], "2nd Year A")
        self.assertIn("photo", row)

    def test_future_day_is_all_pending_not_absent(self):
        ev = make_event(self.today + D(days=5), self.today + D(days=6))
        data = self.url(ev).json()
        self.assertEqual(data["date"], str(self.today + D(days=5)))        # upcoming -> first day
        self.assertFalse(any(s["elapsed"] for s in data["slots"]))
        for st in data["students"]:
            self.assertEqual({c["status"] for c in st["slots"]}, {"PENDING"})
            self.assertEqual(st["missed"], 0)
        self.assertEqual(data["slots"][0]["pending"], 2)

    def test_default_day_rules(self):
        d = datetime.timedelta
        running = make_event(self.today - d(days=1), self.today + d(days=1), "Running")
        self.assertEqual(self.url(running).json()["date"], str(self.today))
        self.assertTrue(self.url(running).json()["is_today"])
        finished = make_event(self.today - d(days=5), self.today - d(days=3), "Fin")
        self.assertEqual(self.url(finished).json()["date"], str(self.today - d(days=3)))   # last day

    def test_today_marks_only_closed_windows_absent(self):
        ev = make_event(self.today, self.today, required=("AM_IN", "AM_OUT", "PM_IN", "PM_OUT"))
        data = self.url(ev).json()
        now = timezone.localtime().time()
        for slot in data["slots"]:
            end = datetime.time.fromisoformat(slot["window_end"])
            self.assertEqual(slot["elapsed"], end < now, slot["type"])
            self.assertEqual(slot["absent"] > 0, slot["elapsed"])
            self.assertEqual(slot["pending"] > 0, not slot["elapsed"])

    def test_date_validation(self):
        ev = make_event(self.today - D(days=2), self.today - D(days=1))
        self.assertEqual(self.url(ev, date="nope").status_code, 400)
        res = self.url(ev, date=str(self.today + D(days=30)))
        self.assertEqual(res.status_code, 400)
        self.assertIn("within", str(res.json()["date"]))

    def test_pending_and_rejected_students_are_not_listed(self):
        ev = make_event(self.today - D(days=2), self.today - D(days=1))
        make_student("pen", "S-9", "Pen", "Ding", approval_status="PENDING")
        make_student("rej", "S-8", "Rej", "Ected", approval_status="REJECTED")
        names = [s["full_name"] for s in self.url(ev).json()["students"]]
        self.assertEqual(sorted(names), ["Anna Reyes", "Ben Abad"])

    def test_students_approved_after_the_day_are_not_enrolled_that_day(self):
        ev = make_event(self.today - D(days=4), self.today - D(days=1))
        late = make_student("late", "S-7", "Late", "Joiner")
        late.reviewed_at = timezone.now() - D(days=2)                      # approved 2 days ago
        late.save()
        early_day = str(self.today - D(days=4))
        names = [s["full_name"] for s in self.url(ev, date=early_day).json()["students"]]
        self.assertNotIn("Late Joiner", names)
        later_day = str(self.today - D(days=1))
        names = [s["full_name"] for s in self.url(ev, date=later_day).json()["students"]]
        self.assertIn("Late Joiner", names)

    def test_endpoint_is_read_only(self):
        ev = make_event(self.today - D(days=2), self.today - D(days=1))
        self.assertEqual(self.client.post(reverse("instructor-event-attendance", args=[ev.pk]), {}).status_code, 405)
        self.assertFalse(AttendanceLog.objects.exists())

    def test_single_day_event_and_event_with_no_students(self):
        Student.objects.all().delete()
        ev = make_event(self.today - D(days=1), self.today - D(days=1))
        data = self.url(ev).json()
        self.assertEqual(data["dates"], [str(self.today - D(days=1))])
        self.assertEqual(data["students"], [])
        self.assertEqual(data["slots"][0]["present"], 0)
