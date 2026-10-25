# CDK ITE Event Attendance System

**Hybrid QR-Code Based Attendance and Financial Management System** for the ITE Department,
Colegio de Kidapawan.

Students show a daily QR code; instructors scan it during admin-set time windows; the system records
attendance per required slot, calculates fines per missed slot, and tracks the cash the treasurer
receives. The Department Adviser runs everything from a web portal that installs and works like an app,
students and instructors each have their own mobile app, and everything keeps working with no
connection and syncs when it comes back.

## Who uses what

| Role | Uses | Does |
|------|------|------|
| **Super Admin** | Web portal + Django Administration (`/admin/`) | Everything the adviser does, plus creating advisers/other Super Admins and **database backup & restore** |
| **Department Adviser** | Web portal — installable as **ITE Adviser** | Instructors, students (masterlist import + printable credentials), school years / semesters, events, attendance logs, fines & payments, reports |
| **Instructor** | **ITE Instructors** app | Scan students' QR codes (also offline), review attendance in every event |
| **Student** | **ITE Students** app | Daily QR, attendance history, fines & balance, profile (accounts are issued by the adviser — no self sign-up) |

## Parts of the repository

| Part | Folder | Stack |
|------|--------|-------|
| Backend API + adviser web portal (PWA) | [`backend/`](backend) | Django 5.1, DRF, SimpleJWT, PostgreSQL, HTMX + Bootstrap 5, service worker |
| Student mobile app — "ITE Students" | [`mobile_student/`](mobile_student) | Flutter, `qr_flutter` |
| Instructor mobile app — "ITE Instructors" (QR scanning) | [`mobile_instructor/`](mobile_instructor) | Flutter, `mobile_scanner` |
| Deployment | [`render.yaml`](render.yaml), [`backend/docker-compose.yml`](backend/docker-compose.yml) | Docker, Gunicorn, nginx / WhiteNoise, Render |

The two mobile apps share the same API and have different Android IDs
(`ph.edu.cok.ite_instructors` and `ph.edu.cok.ite_attendance`), so both can be installed on one phone.
An instructor account cannot sign in to the student app and vice versa.

## Features

- **Adviser portal** (`/portal/`) — dashboard of the **active semester**, instructors, students, school
  years & semesters (one **active** semester drives the default filters), events, attendance logs
  (by event / by student), fines, attendance & financial reports (CSV + print with the ITE logo header),
  settings & theming. Phone-first: bottom navigation, swipe drawer, cards instead of tables, bottom-sheet forms.
- **Accounts** — no self sign-up. The adviser imports the **masterlist (CSV / Excel)**, gets generated
  usernames (student number) and passwords on **printable slips**, and students sign in to the app.
  Sections are a fixed list A–G.
- **Daily QR + scan windows** — one QR per student per event-day; the slot is decided by the server
  from the scan time and the event's windows; out-of-window scans are rejected.
- **One attendance log per slot** — enforced by the database, so two instructors (online, or both offline
  and syncing later) can never create a duplicate; the second scan simply answers "already recorded".
- **Fines** — `missed required slots × rate`, counted only once a slot's window has closed, with an
  optional **different rate for each day** of a multi-day event; refreshed automatically whenever fines
  are viewed. The treasurer records cash **slot by slot** (part-payments, undo, pay balance), and a
  student's **statement** can be printed. Records that already hold attendance or payments can be edited
  but never deleted.
- **Works offline** — the portal saves the pages you use and queues fine payments, the event Active
  switch and "Set active semester" while offline, replaying them (with the real time) when the
  connection returns. The **Install app** button adds it to the home screen.
  Both mobile apps can **sign in offline** (after one online sign-in) and keep their data on the phone;
  instructors scan offline and the scans upload automatically.
- **Admin tools** — branded Django Administration with **Backup & restore** (one JSON file you can load
  into a fresh database if the hosted one is ever lost); only the Super Admin can open it.
- **Production-ready** — env-driven settings, JWT with rotation/blacklist, API throttling, HTTPS switch,
  `/healthz/`, images on Cloudinary, Docker and Render deployment. See
  [`backend/SECURITY.md`](backend/SECURITY.md) for what is protected and the accepted limitations.

## Quick start (development)

**Backend + portal**
```bash
cd backend
python -m venv env && env/Scripts/activate      # Python 3.13
pip install -r requirements.txt
cp .env.example .env                             # edit DATABASE_URL etc.
python manage.py migrate
python manage.py seed_admin                      # adviser: admin / Admin@12345 (dev only)
python manage.py seed_superadmin --password CHANGE-ME   # Super Admin (also opens /admin/)
python manage.py seed_demo                       # optional demo students, events, attendance, fines
python manage.py runserver 0.0.0.0:8000          # portal at /portal/
```

**Mobile apps** (each is its own Flutter project)
```bash
cd mobile_student        # or mobile_instructor
flutter pub get
flutter run --dart-define=API_BASE_URL=http://<your-lan-ip>:8000
```

**Tests**
```bash
cd backend && DATABASE_URL=sqlite:///test.sqlite3 python manage.py test
cd mobile_student && flutter analyze && flutter test
cd mobile_instructor && flutter analyze && flutter test
```

## Deploy

- **Render** — New → Blueprint → this repo ([`render.yaml`](render.yaml)). Step-by-step in
  [`backend/DEPLOYMENT.md`](backend/DEPLOYMENT.md#deploy-on-render). Set `SUPERADMIN_PASSWORD` so the
  Super Admin is created (it is the only role that can use Django Administration and backups).
- **Docker (any server)** — `docker compose --env-file .env.prod up -d --build` from `backend/`
  (nginx + Gunicorn + PostgreSQL). Same guide.
- **Android APKs** — one per app:
  ```bash
  cd mobile_student    && flutter build apk --release --dart-define=API_BASE_URL=https://<your-host>
  cd mobile_instructor && flutter build apk --release --dart-define=API_BASE_URL=https://<your-host>
  ```

**Before a demo:** open Django Administration → *Backup & restore* → download a backup; open the portal
once online (it saves its pages for offline use); install both apps and sign in once with internet.

## Documentation

| Doc | What |
|-----|------|
| [`backend/README.md`](backend/README.md) | Architecture, configuration, API reference, domain rules, portal & offline details |
| [`backend/DEPLOYMENT.md`](backend/DEPLOYMENT.md) | Docker, Render, HTTPS on/off, Cloudinary, building the mobile apps, backups |
| [`backend/SECURITY.md`](backend/SECURITY.md) | Protections, offline copies, accepted limitations |
| [`backend/docs/database.dbml`](backend/docs/database.dbml) | Data schema for dbdiagram.io |
| [`mobile_student/README.md`](mobile_student/README.md) | Student app: features, offline sign-in & data, structure |
| [`mobile_instructor/README.md`](mobile_instructor/README.md) | Instructor app: scanning, offline scanning & sign-in, structure |

## Secrets

Never commit `.env`, `.env.prod`, `CREDENTIALS*`, database backups (`ite-attendance-backup-*.json`),
certificates or API keys — they are git-ignored. Use the `*.example` templates and the hosting
dashboard's environment variables.
