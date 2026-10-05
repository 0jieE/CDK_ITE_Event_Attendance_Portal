# CDK ITE Event Attendance Portal

**Hybrid QR-Code Based Attendance and Financial Management System** for the ITE Department,
Colegio de Kidapawan.

Instructors scan students' daily QR codes during admin-set time windows; the system records
attendance per required slot, calculates fines per missed slot, and tracks cash turned over to
the treasurer. The Department Adviser manages everything from a responsive web portal; students
and instructors use one Flutter mobile app.

| Part | Folder | Stack |
|------|--------|-------|
| Backend API + admin web portal | [`backend/`](backend) | Django 5.1, DRF, SimpleJWT, PostgreSQL, HTMX + Bootstrap 5 |
| Mobile app (instructor + student) | [`mobile/`](mobile) | Flutter, `mobile_scanner`, `qr_flutter` |
| Deployment | [`render.yaml`](render.yaml), [`backend/docker-compose.yml`](backend/docker-compose.yml) | Docker, Gunicorn, nginx / WhiteNoise, Render |

## Features

- **Admin portal** (`/portal/`) - dashboard, users / instructors / students (with profile photos),
  school years, semesters, events, attendance logs, fines, attendance & financial reports (CSV +
  print), settings & theming. Mobile-friendly with a collapsible sidebar; default ITE green `#41b422`.
- **Daily QR + scan windows** - one QR per student per event-day; the slot is decided by the
  server from the scan time and the event's windows. Out-of-window scans are rejected.
- **Per-slot fines** - `missed required slots x fine rate`, counted only once a slot's window has
  closed; refreshed automatically whenever fines are viewed. Paid fines are never overwritten.
- **Mobile app** - instructors scan and see the student's photo; students see their QR, history,
  fines and balance.
- **Production-ready** - env-driven settings, JWT with rotation/blacklist, API throttling,
  HTTPS switch, `/healthz/`, images on Cloudinary, Docker and Render deployment. See
  [`backend/SECURITY.md`](backend/SECURITY.md) for what is protected and the one accepted limitation.

## Quick start (development)

```bash
cd backend
python -m venv env && env/Scripts/activate      # Python 3.13
pip install -r requirements.txt
cp .env.example .env                             # edit DATABASE_URL etc.
python manage.py migrate
python manage.py seed_admin                      # admin / Admin@12345 (dev only)
python manage.py runserver 0.0.0.0:8000          # portal at /portal/
```

```bash
cd mobile
flutter pub get
flutter run --dart-define=API_BASE_URL=http://<your-lan-ip>:8000
```

Run the tests: `cd backend && DATABASE_URL=sqlite:///test.sqlite3 python manage.py test`

## Deploy

- **Render** - New -> Blueprint -> this repo ([`render.yaml`](render.yaml)). Step-by-step in
  [`backend/DEPLOYMENT.md`](backend/DEPLOYMENT.md#deploy-on-render).
- **Docker (any server)** - `docker compose --env-file .env.prod up -d --build` from `backend/`
  (nginx + Gunicorn + PostgreSQL). Same guide.
- **Android APK** - `flutter build apk --release --dart-define=API_BASE_URL=https://<your-host>`.

## Documentation

| Doc | What |
|-----|------|
| [`backend/README.md`](backend/README.md) | Architecture, configuration, API reference, domain rules |
| [`backend/DEPLOYMENT.md`](backend/DEPLOYMENT.md) | Docker, Render, HTTPS on/off, Cloudinary, Flutter release build |
| [`backend/SECURITY.md`](backend/SECURITY.md) | Protections and accepted limitation |
| [`mobile/README.md`](mobile/README.md) | Flutter app structure and configuration |

## Secrets

Never commit `.env`, `.env.prod`, certificates or API keys - they are git-ignored. Use the
`*.example` templates and the hosting dashboard's environment variables.
