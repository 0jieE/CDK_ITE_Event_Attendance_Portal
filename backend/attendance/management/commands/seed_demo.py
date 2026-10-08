"""Seed realistic demo data for a defense / walkthrough.

    python manage.py seed_demo               # add (or top up) the demo data
    python manage.py seed_demo --clear       # remove everything this command created

What it creates (all clearly tagged, so ``--clear`` can remove exactly it):

* 2 instructors (``inst01``, ``inst02``) and ``--students`` approved students
  (``stud01`` ...; student numbers ``DEMO-001`` ...) across 1st-4th year, sections A/B
* 3 pending sign-ups (``pending01``-``03``) and 1 rejected one, for the Approvals page
* 3 events relative to *today*: a finished one, one running now, one upcoming
  ("Intramurals 2026", "ITE Tech Week 2026", "Foundation Day 2026")
* attendance logs for every elapsed slot of those events **and of any existing
  event** (every approved student is enrolled in every event, so the demo students
  get realistic history there too instead of looking absent everywhere). Existing
  approved students also get attendance in the *demo* events (never in real ones)
* fines computed with the normal calculator, about half of the finished event's paid

It never modifies or deletes your existing users, events or logs. Safe to re-run:
existing rows are reused and only missing ones are added.
"""

import datetime
import random

from django.contrib.auth.hashers import make_password
from django.core.management.base import BaseCommand
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from accounts.models import Instructor, Student, User
from attendance import services
from attendance.models import AttendanceLog, Event, Fine, SchoolYear, Semester

DEFAULT_PASSWORD = "Demo-Pass-2026"
STUDENT_PREFIX = "DEMO-"
INSTRUCTORS = [("inst01", "Ramon", "Villanueva"), ("inst02", "Cecilia", "Bautista")]
PENDING = [("pending01", "Carlo", "Navarro", "DEMO-P01", "1", "A"),
           ("pending02", "Bea", "Fernandez", "DEMO-P02", "2", "B"),
           ("pending03", "Jon", "Ramos", "DEMO-P03", "3", "A")]
REJECTED = ("rejected01", "Rica", "Dela Pena", "DEMO-R01", "1", "B", "Student number not found in the class list")
FIRST = ["Maria", "Juan", "Ana", "Mark", "Liza", "Paolo", "Angela", "Joshua", "Kristine", "Miguel",
         "Jasmine", "Rafael", "Camille", "Daniel", "Patricia", "Gabriel", "Nicole", "Adrian",
         "Bianca", "Carlos", "Denise", "Ethan", "Faith", "Gerald", "Hannah", "Ivan", "Julia", "Kevin"]
LAST = ["Santos", "Reyes", "Cruz", "Bautista", "Ocampo", "Garcia", "Mendoza", "Torres", "Flores",
        "Villanueva", "Ramos", "Aquino", "Castillo", "Dela Cruz", "Navarro", "Salazar", "Domingo",
        "Pascual", "Lopez", "Fernandez", "Gonzales", "Rivera", "Soriano", "Aguilar", "Manalo", "Tan",
        "Lim", "Sy"]

T = datetime.time
FOUR_SLOT = dict(
    required_types=["AM_IN", "AM_OUT", "PM_IN", "PM_OUT"],
    am_in_start=T(7, 0), am_in_end=T(8, 0), am_out_start=T(11, 30), am_out_end=T(12, 15),
    pm_in_start=T(13, 0), pm_in_end=T(13, 45), pm_out_start=T(16, 30), pm_out_end=T(17, 15),
)
TWO_SLOT = dict(
    required_types=["AM_IN", "PM_OUT"],
    am_in_start=T(7, 0), am_in_end=T(8, 0), pm_out_start=T(16, 30), pm_out_end=T(17, 15),
)


def demo_events(today):
    d = datetime.timedelta
    return [
        dict(name="Intramurals 2026", start_date=today - d(days=12), end_date=today - d(days=11),
             fine_rate=10, **FOUR_SLOT),
        dict(name="ITE Tech Week 2026", start_date=today - d(days=2), end_date=today + d(days=2),
             fine_rate=25, **TWO_SLOT),
        dict(name="Foundation Day 2026", start_date=today + d(days=10), end_date=today + d(days=11),
             fine_rate=30, **TWO_SLOT),
    ]


class Command(BaseCommand):
    help = "Seed (or --clear) realistic demo data: students, events, attendance, fines."

    def add_arguments(self, parser):
        parser.add_argument("--clear", action="store_true", help="Remove all demo data created by this command.")
        parser.add_argument("--students", type=int, default=24, help="How many approved demo students (default 24).")
        parser.add_argument("--password", default=DEFAULT_PASSWORD, help=f"Password for demo accounts (default {DEFAULT_PASSWORD}).")

    # ------------------------------------------------------------------ clear
    @transaction.atomic
    def clear(self):
        names = [e["name"] for e in demo_events(timezone.localdate())]
        events = Event.objects.filter(name__in=names)
        n_ev = events.count()
        events.delete()                                    # cascades logs / fines / QR codes
        usernames = [u[0] for u in INSTRUCTORS] + [p[0] for p in PENDING] + [REJECTED[0]]
        ids = list(User.objects.filter(
            Q(username__in=usernames) | Q(student_profile__student_number__startswith=STUDENT_PREFIX)
        ).values_list("pk", flat=True).distinct())
        n_users = len(ids)
        User.objects.filter(pk__in=ids).delete()   # cascades their logs/fines in any event
        self.stdout.write(self.style.SUCCESS(f"Removed {n_users} demo users and {n_ev} demo events (with their logs and fines)."))

    # ----------------------------------------------------------------- helpers
    def _user(self, username, first, last, pwd_hash, **flags):
        user, created = User.objects.get_or_create(
            username=username,
            defaults=dict(first_name=first, last_name=last, password=pwd_hash, **flags),
        )
        return user, created

    def _student(self, number, username, first, last, year, section, pwd_hash, status, active, adviser, reason=""):
        user, _ = self._user(username, first, last, pwd_hash, is_student=True, is_active=active)
        student, created = Student.objects.get_or_create(
            student_number=number,
            defaults=dict(user=user, year_level=year, section=section, approval_status=status),
        )
        if created and status != Student.ApprovalStatus.PENDING:
            # approved/rejected ~30 days ago: accountable for the whole demo period
            student.reviewed_at = timezone.now() - datetime.timedelta(days=30)
            student.reviewed_by = adviser
            student.rejection_reason = reason
            student.save(update_fields=["reviewed_at", "reviewed_by", "rejection_reason"])
        return student

    # ------------------------------------------------------------------ handle
    def handle(self, *args, **opts):
        if opts["clear"]:
            return self.clear()

        rng = random.Random(2026)             # deterministic: same data every run
        today = timezone.localdate()
        now = timezone.localtime()
        pwd_hash = make_password(opts["password"])   # hash once, reuse for every demo account
        adviser = User.objects.filter(is_admin=True).order_by("id").first()

        with transaction.atomic():
            # ---- school year / semester (reuse whatever exists) ------------------
            sy = SchoolYear.objects.order_by("-sy").first() or SchoolYear.objects.create(sy=f"{today.year}-{today.year + 1}")
            sem = Semester.objects.filter(school_year=sy).order_by("name").first() or Semester.objects.create(school_year=sy, name="1st")

            # ---- instructors ------------------------------------------------------
            instructors = []
            for username, first, last in INSTRUCTORS:
                user, _ = self._user(username, first, last, pwd_hash, is_instructor=True)
                instructors.append(Instructor.objects.get_or_create(user=user)[0])

            # ---- approved students ------------------------------------------------
            students, habits = [], {}
            for i in range(1, opts["students"] + 1):
                first, last = FIRST[(i * 7) % len(FIRST)], LAST[(i * 11) % len(LAST)]
                st = self._student(
                    f"{STUDENT_PREFIX}{i:03d}", f"stud{i:02d}", first, last,
                    str(1 + (i - 1) % 4), "A" if i % 3 else "B", pwd_hash,
                    Student.ApprovalStatus.APPROVED, True, adviser)
                students.append(st)
                habits[st.pk] = rng.choice([0.97, 0.92, 0.88, 0.82, 0.75, 0.66, 0.55])

            # ---- pending / rejected sign-ups (for the Approvals page) ---------------
            for username, first, last, number, year, section in PENDING:
                self._student(number, username, first, last, year, section, pwd_hash,
                              Student.ApprovalStatus.PENDING, False, adviser)
            u, f, l, number, year, section, reason = REJECTED
            self._student(number, u, f, l, year, section, pwd_hash, Student.ApprovalStatus.REJECTED, False, adviser, reason)

            # ---- events -------------------------------------------------------------
            events = []
            for spec in demo_events(today):
                name = spec.pop("name")
                ev, _ = Event.objects.get_or_create(name=name, defaults=dict(semester=sem, is_active=True, **spec))
                events.append(ev)
            # also give the demo students history in any other existing event
            demo_names = {e.name for e in events}
            events += list(Event.objects.exclude(name__in=demo_names).filter(start_date__lte=today))

            # Every approved student is enrolled in every event, so existing (non-demo)
            # approved students would be fined for the new demo events with no history.
            # Give them plausible attendance in the DEMO events only (not in real ones).
            others = list(Student.objects.filter(approval_status=Student.ApprovalStatus.APPROVED)
                          .exclude(student_number__startswith=STUDENT_PREFIX))
            for st in others:
                habits[st.pk] = 0.9

            # ---- attendance logs (bulk) ---------------------------------------------
            created_logs = 0
            for ev in events:
                cast = students + (others if ev.name in demo_names else [])
                have = set(AttendanceLog.objects.filter(event=ev, student__in=cast)
                           .values_list("student_id", "date", "attendance_type"))
                new = []
                for day in ev.iter_dates():
                    for slot in ev.required_types:
                        if not services.slot_has_elapsed(ev, day, slot, now):
                            continue
                        start, end = ev.slot_window(slot)
                        if start is None or end is None:
                            continue
                        span = (datetime.datetime.combine(day, end) - datetime.datetime.combine(day, start)).seconds
                        for st in cast:
                            # Every random draw happens BEFORE any skip, so a re-run consumes
                            # the generator identically and reproduces the same decisions.
                            attended = rng.random() < habits[st.pk]
                            when = datetime.datetime.combine(day, start) + datetime.timedelta(seconds=rng.randint(0, max(span, 1)))
                            scanner = rng.choice(instructors)
                            if not attended or (st.pk, day, slot) in have:
                                continue
                            new.append(AttendanceLog(
                                student=st, event=ev, date=day, attendance_type=slot,
                                status=AttendanceLog.Status.PRESENT,
                                scanned_at=timezone.make_aware(when),
                                scanned_by=scanner))
                AttendanceLog.objects.bulk_create(new)
                created_logs += len(new)

            # ---- fines (the real calculator) + some marked paid -----------------------
            for ev in events:
                services.compute_fines_for_event(ev, now=now)
            # Settle about half of the finished event's demo fines in cash. Which ones is a
            # fixed property of the student (even DEMO number = paid), NOT of what is
            # currently unpaid, so re-running converges instead of drifting.
            paid = 0
            finished = Event.objects.filter(name="Intramurals 2026").first()
            if finished and adviser:
                for fine in Fine.objects.filter(
                        event=finished, student__student_number__startswith=STUDENT_PREFIX
                ).select_related("student"):
                    should_be_paid = int(fine.student.student_number[len(STUDENT_PREFIX):]) % 2 == 0
                    if should_be_paid and fine.status != Fine.Status.PAID:
                        fine.mark_paid(recorded_by=adviser,
                                       when=now - datetime.timedelta(days=rng.randint(1, 8), hours=rng.randint(0, 6)))
                    elif not should_be_paid and fine.status == Fine.Status.PAID:
                        fine.status, fine.paid_at, fine.recorded_by = Fine.Status.UNPAID, None, None
                        fine.save(update_fields=["status", "paid_at", "recorded_by", "updated_at"])
                    paid += fine.status == Fine.Status.PAID

        self.stdout.write(self.style.SUCCESS(
            f"Demo data ready: {len(students)} students, {len(instructors)} instructors, "
            f"{len(PENDING)} pending + 1 rejected sign-up, {len(events)} events, "
            f"{created_logs} attendance logs added, {paid} fines marked paid."))
        self.stdout.write(f"All demo accounts use the password: {opts['password']}")
        self.stdout.write("Logins: stud01..stud%02d (students), inst01 / inst02 (instructors). Remove with: seed_demo --clear" % opts["students"])
