# QR Attendance & Financial Management — Backend

Backend data layer, RBAC, and **admin-side REST APIs** for the *Hybrid QR-Code
Based Attendance and Financial Management System* of the ITE Department,
Colegio de Kidapawan.

**Stack:** Python 3.13 · Django 5.1 · Django REST Framework · SimpleJWT ·
PostgreSQL 13 · drf-spectacular.

> ### ⚠️ Version compatibility (read before changing Python/Django/Postgres)
> These three versions are pinned together for a reason — they are the only
> mutually compatible combination on this machine:
>
> | Component | Pin | Why |
> |-----------|-----|-----|
> | **Python** | **3.13** | Django 5.1 doesn't support 3.14 — on 3.14 the Django admin crashes with `'super' object has no attribute 'dicts'` (a `copy(super())` change in CPython 3.14). |
> | **Django** | **5.1.x** | 5.2+ and 6.0 require **PostgreSQL 14+**; the installed Postgres is **13**. 5.1's minimum is PG13. |
> | **django-filter** | **24.3** | 25.x requires Django ≥ 5.2. |
> | **psycopg** | **3.x + psycopg-binary** | 64-bit wheels load the 64-bit `libpq` from the PostgreSQL 13 install. |
>
> To move to Django 5.2/6.0 LTS later, first **upgrade PostgreSQL to 14+**, then
> Python can be 3.13 or 3.14. Always rebuild `env/` with the chosen interpreter
> (`python -m venv env`) and `pip install -r requirements.txt`.

> **Status: feature-complete and deployable.** Data models + RBAC + admin REST APIs,
> the server-rendered admin portal, the instructor/student mobile APIs, the Flutter app
> (`../mobile`), Docker/Render deployment and a security-hardening pass are all done.
> Jump to: [Deploy on Render](#deploy-on-render) · [Docker](#deployment-docker) ·
> [Security](SECURITY.md) · [Tests](#tests).

---

## Project layout

```
backend/
  core/         # Django project: settings, urls, wsgi/asgi, Cloudinary storage, /healthz/
  accounts/     # custom User (+ profile photo), Instructor/Student, RBAC, auth, image tools
  attendance/   # SchoolYear, Semester, Event, QRCode, AttendanceLog, Fine
                #   + services (fines, dashboard, reports) + mobile APIs
  portal/       # server-rendered admin web portal (Templates + HTMX + Bootstrap)
  docker/       # container entrypoint (migrate, collectstatic, seed admin, ...)
  nginx/        # reverse-proxy configs for the docker-compose stack
  Dockerfile, docker-compose.yml, gunicorn.conf.py
  manage.py, requirements.txt
  .env          # local dev secrets (NOT committed) - copy from .env.example
  .env.prod     # Docker/prod secrets (NOT committed) - copy from .env.prod.example
../mobile/      # Flutter app (instructor + student)
../render.yaml  # Render blueprint
```

`accounts` owns identity/RBAC, `attendance` owns the domain, `portal` is the adviser's
web UI. `AUTH_USER_MODEL = accounts.User`.

---

## 1. Environment setup

```bash
cd backend
# the virtualenv lives in ./env
env/Scripts/activate          # Windows (PowerShell: env\Scripts\Activate.ps1)
pip install -r requirements.txt

cp .env.example .env          # then edit values
```

Configuration is read from `.env` via **django-environ**. Keys:

| Key | Meaning |
|-----|---------|
| `SECRET_KEY` | Django secret key |
| `DEBUG` | `True` / `False` |
| `ALLOWED_HOSTS` | comma-separated hosts |
| `DATABASE_URL` | e.g. `postgres://user:pass@localhost:5432/qr_attendace` |
| `DB_*` | discrete fallback used only when `DATABASE_URL` is unset |
| `CORS_ALLOWED_ORIGINS` | comma-separated browser origins allowed to call `/api/` (empty = none) |
| `CORS_ALLOW_ALL_ORIGINS` | dev only; **refused when `DEBUG=False`** |
| `USE_HTTPS` | `True` (default in prod) = HTTPS redirect, secure cookies, HSTS; `False` for a plain-HTTP demo |
| `CSRF_TRUSTED_ORIGINS` | full origins (with scheme) allowed to POST to the portal over a proxy |
| `CLOUDINARY_CLOUD_NAME` / `_API_KEY` / `_API_SECRET` / `_FOLDER` | image storage (profile photos, QR PNGs, logo); blank = local disk |
| `JWT_ACCESS_MINUTES` / `JWT_REFRESH_DAYS` | token lifetimes (30 min / 7 days) |
| `NUM_PROXIES`, `THROTTLE_*` | reverse-proxy depth and API rate limits |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | first-run Department Adviser (containers) |

Every production variable, with comments, is in [`.env.prod.example`](.env.prod.example).

`DEBUG` defaults to **False**. With `DEBUG=False` the app refuses to start unless
`SECRET_KEY` is set, `ALLOWED_HOSTS` has real hosts (no `*`) and CORS is an
allowlist. Production/Docker variables are in `.env.prod.example`; see
[Deployment](#deployment-docker).

> **Password URL-encoding:** in `DATABASE_URL`, special characters in the
> password must be percent-encoded (`@` → `%40`). If that's inconvenient, leave
> `DATABASE_URL` unset and use the discrete `DB_NAME` / `DB_USER` / … keys.

### Database

PostgreSQL is the configured engine. Create the database once:

```sql
CREATE DATABASE qr_attendace;
```

You can switch to SQLite for quick local work by setting
`DATABASE_URL=sqlite:///db.sqlite3` in `.env`.

---

## 2. Migrate, seed, run

```bash
python manage.py migrate
python manage.py seed_admin          # creates the Department-Adviser superuser
python manage.py runserver
python manage.py test                # security/isolation/throttling/fines/UI tests
```

`seed_admin` defaults to `admin / Admin@12345` (override with
`--username/--password`, or `ADMIN_USERNAME/ADMIN_PASSWORD`
env vars). **Change the password after first login.**

---

## 3. API docs

| URL | What |
|-----|------|
| `/api/docs/` | Swagger UI (interactive) |
| `/api/schema/` | raw OpenAPI 3 schema |
| `/admin/` | Django admin |

### Authentication

```http
POST /api/auth/login/      { "username": "...", "password": "..." }  -> { access, refresh }
POST /api/auth/refresh/    { "refresh": "..." }                      -> { access }
```

Access tokens last 30 min, refresh tokens 7 days, and **refresh tokens rotate**
(each `/api/auth/refresh/` returns a new `refresh` and blacklists the old one — clients
must store it). Login, refresh and scan are rate-limited (HTTP 429). Send
`Authorization: Bearer <access>` on every `/api/` call. **All admin
endpoints require the `IsAdmin` role.**

### Admin endpoints (all under `/api/`)

| Resource | Methods | Notes |
|----------|---------|-------|
| `users/` | CRUD | role flags; passwords hashed |
| `instructors/` | CRUD | creates linked user (`is_instructor`) |
| `students/` | CRUD | creates linked user (`is_student`); `?semester=&school_year=&approval_status=` |
| `students/{id}/approve/`, `students/{id}/reject/` | POST | approve / reject a self-registered student (reject takes optional `{"reason"}`) |
| `school-years/` | CRUD | |
| `semesters/` | CRUD | `?school_year=` |
| `events/` | CRUD | `?semester=&school_year=&is_active=`; validates dates + required_types |
| `attendance-logs/` | **read-only** | `?event=&student=&date=&attendance_type=&status=&date_from=&date_to=` |
| `fines/` | list/retrieve/update | `?event=&student=&status=&needs_review=` |
| `fines/calculate/` | POST | body `{ "event_id": N }` → runs the fines calculator |
| `fines/{id}/mark-paid/` | POST | records cash turned over to the treasurer |
| `dashboard/` | GET | totals + per-event breakdown |
| `reports/attendance/` | GET | `?semester=&event=&date_from=&date_to=`; `&format=csv` to download |
| `reports/financial/` | GET | same filters; `&format=csv` to download |

### Student sign-up & approval

Students can register themselves in the mobile app (**Create account**). The account is
created **inactive** with status `PENDING`, so it can't sign in or call any API until the
Department Adviser approves it under **Portal -> Approvals** (a badge in the sidebar and an
alert on the dashboard show how many are waiting).

* **Approve** activates the account. **Reject** keeps it inactive and stores an optional reason.
* A correct login for a pending/rejected student returns `403` with `code` =
  `PENDING_APPROVAL` / `REGISTRATION_REJECTED` (wrong credentials stay a generic `401`).
* Pending and rejected students are **never fined**; a student approved part-way through an event
  is accountable only from their approval day on (students added by the adviser: all days).
* Sign-ups are rate-limited per IP (`THROTTLE_REGISTER`, default `5/hour`). Deleting a rejected
  student (Portal -> Students) frees their username and student number for a new sign-up.
* **No email field exists anywhere:** accounts are username + password only.

### Mobile / system endpoints

| Endpoint | Who | Notes |
|----------|-----|-------|
| `GET /healthz/` | anyone | liveness + database check (200 / 503) for proxies and uptime monitors |
| `POST /api/auth/register/` | **anyone** | student self-sign-up (JSON or multipart with optional photo). Creates an **inactive, PENDING** account; rate-limited (5/hour/IP) |
| `GET /api/me/` | any user | identity, role flags and `profile_image` (used to route the app) |
| `POST/DELETE /api/me/photo/` | any user | set (multipart `image`) / remove **own** profile photo |
| `GET /api/instructor/events/` | instructor | active events running today |
| `POST /api/instructor/scan/` | instructor | scan a QR token; result includes `student_photo`. Rate-limited |
| `GET /api/instructor/scans/` | instructor | the instructor's own recent scans |
| `GET /api/student/profile/` | student | own profile incl. name, username, year/section, photo |
| `PATCH /api/student/profile/` | student | edit own first/middle/last name and username (student no., year, section are admin-only) |
| `POST /api/student/profile/password/` | student | change own password (current + new; Django validators; rate-limited) |
| `GET /api/student/events/` (`?all=true` for past events too), `attendance/` (`?event=`), `fines/`, `balance/` | student | own data only |
| `POST /api/student/qr/generate/` | student | create today's QR for an event - **today only** (other dates are rejected), once per event-day, idempotent |
| `GET /api/student/qr/` (`?event=&date=`) | student | list own QR codes (used to show an already-generated QR) |

---

## Deploy on Render

The repo root has a [`render.yaml`](../render.yaml) blueprint (Docker web service built from
`backend/Dockerfile`, health check `/healthz/`). The app serves its own static files
(WhiteNoise) and reads Render's `PORT` / hostname, so no nginx is needed; images live on
Cloudinary and the database is Render PostgreSQL. Short version:

1. **New -> Blueprint** on Render, pick this repo (it reads `render.yaml`).
2. Fill the prompted secrets: `DATABASE_URL` (Render Postgres **Internal** URL),
   `ADMIN_PASSWORD` and the three `CLOUDINARY_*` values.
3. Deploy. The container migrates, collects static files, seeds the adviser and creates the
   Cloudinary folders on every start. Open `https://<service>.onrender.com/portal/login/`.
4. Build the mobile APK against that URL:
   `flutter build apk --release --dart-define=API_BASE_URL=https://<service>.onrender.com`.

Full walkthrough, free-tier caveats and troubleshooting: [DEPLOYMENT.md](DEPLOYMENT.md#deploy-on-render).

---

## Deployment (Docker)

Production stack = **nginx → Gunicorn/Django → PostgreSQL** (+ optional Redis/Celery),
with static/media on named volumes, a `/healthz/` probe, throttling and HTTPS switch.

```bash
cp .env.prod.example .env.prod        # edit: SECRET_KEY, DB_PASSWORD, ADMIN_PASSWORD, hosts...
docker compose --env-file .env.prod up -d --build
```

* **[DEPLOYMENT.md](DEPLOYMENT.md)** — full guide: first run, admin seeding, volumes,
  worker count, HTTPS on/off, building the Flutter release APK.
* **[SECURITY.md](SECURITY.md)** — what is protected and the one accepted limitation.
* Files: `Dockerfile`, `docker-compose.yml`, `docker/entrypoint.sh`, `gunicorn.conf.py`,
  `nginx/nginx.conf` (HTTP) / `nginx/nginx.ssl.conf` (HTTPS).

---

## Admin Web Portal (Department Adviser)

A server-rendered portal (**Django Templates + HTMX + Bootstrap 5 + DataTables**)
for the **Department Adviser** — the client `is_admin` user. It does **not**
consume the DRF JSON API; it renders HTML directly and uses **Django session
auth** (separate from the mobile JWT layer).

### How it differs from Django `/admin/`
| | `/portal/` | `/admin/` |
|---|-----------|-----------|
| Audience | Department Adviser (client) | superuser / developer |
| Access rule | authenticated **`is_admin=True`** only | `is_staff`/superuser |
| Auth | Django sessions (portal login page) | Django admin login |
| Purpose | day-to-day management UI | low-level data/debug tool |

A bare superuser without `is_admin` is **not** allowed into the portal
(enforced by `portal.mixins.admin_required` / `AdminRequiredMixin`).

### Logging in
1. Seed/ensure an admin: `python manage.py seed_admin` → `admin` / `Admin@12345`
   (this user has `is_admin=True`).
2. Visit **`/portal/login/`** (the site root `/` redirects here) and sign in
   with **username** + password. Change the password after first use.

### Where each section lives (all under `/portal/`)
| Section | URL | Notes |
|---------|-----|-------|
| Dashboard | `/portal/` | cards + per-event table + collected-vs-outstanding chart |
| Users | `/portal/users/` | role flags, password set/reset |
| Instructors | `/portal/instructors/` | creates + links the `User` in one form |
| Students | `/portal/students/` | linked `User` + `student_number` + **year level & section** |
| School Years | `/portal/school_years/` | |
| Semesters | `/portal/semesters/` | select by School Year |
| Events | `/portal/events/` | dates + `required_types` multi-select; validates `end ≥ start` |
| Attendance Logs | `/portal/attendance_logs/` | **read-only**, filterable (event / student / **year** / **section** / date / type / status) |
| **Reports** (sidebar group) | — | collapsible nav group containing the three below |
| ↳ Attendance Report | `/portal/reports/attendance/` | filters + **Download CSV** + **Print** |
| ↳ Financial Report | `/portal/reports/financial/` | filters + **Download CSV** + **Print** |
| ↳ Fines | `/portal/fines/` | lives under Reports; see below |
| Settings | `/portal/settings/` | UI theme, light/dark mode, branding & logo |

#### Fines page (`/portal/fines/`)
Two toggle views plus the calculate/mark-paid workflow:
* **By Event** (default) — the fines ledger; filter by event / status / **year** / **section**;
  **Calculate Fines** (pick event → `compute_fines_for_event`) and per-row **Mark Paid**.
* **By Student** — pick a student **and** an event to see that student's **daily
  attendance grid**: one row per event-day with AM-IN / AM-OUT / PM-IN / PM-OUT
  columns — `–` when the slot isn't required, **Absent** when no scan exists,
  else **Present/Late** — plus the computed fine and a Mark-Paid action.

> **Students** now carry a **year level** (1st–4th) and a **section**; both are
> editable on the student form and drive the year/section filters above.

#### Settings & branding (`/portal/settings/`)
A singleton `PortalSettings` row (editable here or in Django admin) controls the
portal's appearance — applied site-wide via the `portal.context.ui_settings`
context processor:
* **Accent theme** — Violet (default), ITE Green, Blue, Teal, Crimson, Slate.
* **Light / Dark mode** — uses Bootstrap 5.3 `data-bs-theme`.
* **Branding** — title, subtitle, and an optional **logo upload** (stored under
  `MEDIA_ROOT/branding/`). If no logo is uploaded, the bundled **ITE Department
  seal** at `portal/static/portal/img/ite-logo.png` is used.
* **Compact sidebar** toggle.

Theme and mode **preview live** on the Settings page as you change them; click
**Save** to persist.

### Profile photos & image storage
Every user has an optional **profile photo** (`User.profile_image`), set from the portal
(Users / Instructors / Students forms) or by the user via `POST /api/me/photo/`. Photos are
normalised on save (rotated, metadata stripped, max 1024 px). They - together with the QR
PNGs and the portal logo - are stored on **Cloudinary** in the `ite-attendance/` folder
(`profiles/`, `qrcodes/`, `branding/`) when `CLOUDINARY_CLOUD_NAME/API_KEY/API_SECRET` are set,
else on local disk. See [DEPLOYMENT.md](DEPLOYMENT.md#2b-images-on-cloudinary-profile-photos--qr-codes).
The API returns `profile_image` on `/api/me/` and `/api/student/profile/`, and `student_photo`
in the instructor scan result so the instructor can compare faces.

### Look & feel (responsive)
* **Brand theme** — default accent is the ITE green `#41b422` (matches the seal). Solid
  buttons use dark ink on the green and text accents use a deeper green so contrast stays
  accessible; other palettes remain selectable in Settings.
* **Toggleable sidebar** — the ☰ button collapses it to an icon rail on desktop (choice is
  remembered per browser) and opens it as an off-canvas drawer on phones/tablets (backdrop,
  Esc and link-tap close it). *Settings → Compact sidebar* only sets the default.
* **Mobile responsive** — filters reflow to two columns, tables scroll horizontally, forms
  switch to a single column and open full-screen on phones.
* The design system lives in `portal/templates/portal/partials/style_theme.html` (shared by
  the app shell and the login page); layout/sidebar CSS and JS are in `base.html`.

### How it's built (for the next developer)
* **CRUD sections** are declarative: subclass `portal.crud.CrudSection`
  (model, form, table partial, ordering) and register it in
  `portal.views.SECTIONS` — list/add/edit/delete views and URLs auto-generate.
  Only a per-section `<section>/partials/table.html` differs; the page shell and
  modal form are shared (`portal/partials/`).
* **HTMX pattern:** Add/Edit open a Bootstrap modal via `hx-get` (form partial);
  `hx-post` saves and returns **204 + `HX-Trigger`** (toast + table-refresh +
  close-modal) on success, or re-renders the form (**422**) with errors. Delete
  uses `hx-confirm` → `hx-post` → refresh.
* All business logic is **reused** from `attendance.services`
  (`compute_fines_for_event`, `build_dashboard`, `attendance_report`,
  `financial_report`) — no duplication.

---

## Background processing (Celery + Redis)

Fine calculation runs in the background via **Celery** with **Redis** as the
broker.

* **Auto (nightly):** a Celery-Beat job — `attendance.tasks.recompute_all_active_fines`
  — recomputes fines for every **active, already-started** event each night
  (23:00, `CELERY_TIMEZONE`). Because only **elapsed event-days are counted**
  (see Domain notes), fines grow automatically as each event-day passes; nobody
  has to click anything.
* **On demand:** the portal **Calculate Fines** button enqueues
  `attendance.tasks.recompute_event_fines.delay(event_id)`.
* **Graceful fallback:** if Redis is unreachable, the button **computes
  synchronously** instead of failing — so the portal works with or without a
  running worker. (Set `CELERY_TASK_ALWAYS_EAGER=True` to force inline always.)

### Running it locally

```bash
# 1. A Redis server must be reachable at CELERY_BROKER_URL.
#    Windows options: Memurai (https://www.memurai.com), Redis via WSL, or
#    `docker run -p 6379:6379 redis`.
# 2. Worker  — on Windows use the solo pool (prefork isn't supported):
celery -A core worker -l info --pool=solo
# 3. Beat scheduler (nightly recompute):
celery -A core beat -l info
```

Config lives in `core/settings.py` under the `CELERY_` namespace; the app is
`core/celery.py` (loaded by `core/__init__.py`). No worker? Leave Redis off and
the synchronous fallback keeps things working.

---

## Domain notes

* **Events span a date range** (`start_date`…`end_date`) — multi-day events are
  supported. `required_types` is a JSON list of the four attendance slots
  (`AM_IN, AM_OUT, PM_IN, PM_OUT`) that are mandatory for the event.
* **Admin-set scan windows.** Each event carries a start/end time per slot
  (`am_in_start/end`, `am_out_start/end`, `pm_in_start/end`, `pm_out_start/end`).
  Every required slot must have a window; the same times apply to every day in
  the event's range. `Event.slot_for_time(t)` returns which required slot's
  window contains time `t`.
* **QR codes are per day.** A `QRCode` is unique per `(student, event, date)` —
  **one daily QR**, not one per slot. The slot is decided at *scan* time from
  the current time and the event's windows (see below). QR PNGs are generated
  from a secure random token on save. `AttendanceLog` stays unique per
  `(student, event, date, attendance_type)`.
* **Time-gated scanning.** `POST /api/instructor/scan/` resolves the slot via
  `Event.slot_for_time(now)`; an in-window scan records that slot as `PRESENT`.
  Scanning outside every window is rejected (`OUTSIDE_WINDOW`) — the slot stays
  absent and is auto-fined. There is **no LATE** (in-window = present, outside =
  absent).
* **Fines are a ledger only** (no payment gateway). `compute_fines_for_event`
  counts missed required slots × `fine_rate`, is **idempotent**, and never
  overwrites an already-`PAID` fine — it flags it (`needs_review`) instead.
  `mark-paid` simply records that cash reached the treasurer.
* **Fines are per required attendance slot, and only for slots that are over.**
  `compute_fines_for_event(event, as_of=None, now=None)` fines
  `missed slots x fine_rate`, where a slot is one `(date, required type)` pair.
  A slot counts as missed only once it has *elapsed*: every slot on a past day,
  today's slots only **after their scan window has ended** (a scan exactly at the
  window end is still valid), and nothing on future days. A student is never fined
  for a slot that is still open or hasn't opened. The portal's by-student grid
  shows such slots as **Pending**, not Absent.
* **Fines update automatically.** `services.refresh_active_fines()` recomputes every
  active, started event whenever fines are *viewed* - the portal Fines page,
  dashboard and financial report, `/api/fines/`, `/api/dashboard/`, the financial
  report and the student app's fines/balance. It is rate-limited to once per 30 s
  (shared cache lock across workers) and never breaks the page if it fails. The
  *Calculate Fines* button and the optional nightly Celery job still work.
  See [Background processing](#background-processing-celery--redis).

---

## Environment notes (this machine)

The `env/` virtualenv runs **64-bit Python 3.13** and talks to the local
**PostgreSQL 13** via `psycopg` + `psycopg-binary` (64-bit `libpq`). `check`,
migrations, the seed command, the admin, the DRF API and the web portal are all
verified working against the real database.

If `env/` ever breaks (e.g. its base interpreter is uninstalled), rebuild it:

```bash
# 64-bit Python 3.13 lives at %LOCALAPPDATA%\Programs\Python\Python313
"%LOCALAPPDATA%\Programs\Python\Python313\python.exe" -m venv env
env\Scripts\python -m pip install -r requirements.txt
```

See the **Version compatibility** box at the top before swapping any of
Python / Django / PostgreSQL — they are pinned as a set.

---

## Demo data

```bash
python manage.py seed_demo            # 24 students, 2 instructors, 3 events, attendance, fines, sign-ups
python manage.py seed_demo --clear    # remove exactly what it created
```

Creates clearly tagged demo accounts (`stud01`-`stud24`, `inst01`/`inst02`, password
`Demo-Pass-2026` unless `--password` is given), three events relative to *today* (finished /
running / upcoming), attendance for every elapsed slot, fines from the normal calculator (about
half of the finished event paid), plus pending and rejected sign-ups for the Approvals page.
It is repeatable (a re-run adds nothing) and never modifies existing users or events; existing
approved students only get attendance in the *demo* events. In Docker:
`docker compose --env-file .env.prod exec web python manage.py seed_demo`.

---

## Tests

```bash
DATABASE_URL=sqlite:///test.sqlite3 python manage.py test     # ~66 tests, no external services
```

Covers student data isolation, QR token handling, throttling + JWT rotation, `/healthz/`, the
per-slot fines calculator and its automatic refresh, portal pages/forms/theme, profile photos
and the Cloudinary storage (the Cloudinary SDK is mocked, so no credentials are needed).

---

## Status

All phases are **done**:
* **Admin APIs, RBAC, fines calculator** — Phase 1.
* **Admin web portal** (responsive, toggleable sidebar, ITE-green theme) — Phase 2.
* **Mobile APIs** + **Flutter app** (`../mobile`, instructor + student, profile photos) — Phase 3.
* **Deployment & hardening** (Docker, Render, throttling, HTTPS switch, `SECURITY.md`) — Phase 4.

Possible future work: a per-slot LATE threshold (currently in-window = Present, outside =
absent); per-date scan windows (currently one schedule per event); an in-app photo-upload
screen (the `/api/me/photo/` endpoint is ready).
