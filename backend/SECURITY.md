# Security notes

Hybrid QR-Code Based Attendance and Financial Management System - ITE
Department, Colegio de Kidapawan.

## Known, accepted limitation

**The system cannot prevent an instructor from manipulating scan time.**

Attendance is credited when an authenticated *instructor* submits a student's QR
token during a slot's time window. The server stamps `scanned_at` with its own
clock, so students and the network cannot forge the time - but a (trusted)
instructor decides *when* to scan and *whom* to scan. An instructor can
therefore scan a student who is not present, or hold scans until a window is
open. This is inherent to a scan-by-instructor design and is accepted by the
paper: the instructor is a trusted role. What the system does provide is
**accountability**: every log records `scanned_by`, and admins can review the
logs by instructor, event and date.

Related accepted trade-offs:

- A student can show their QR to someone else (it is a bearer token for that
  student, event and day). Mitigated by the token being valid for **one
  event-day only** (`STALE_QR` otherwise) and by instructors visually checking the
  name returned by each scan.
- `/api/docs/` (Swagger) is reachable without login. It only describes the API
  shape and exposes no data.
- Fines are a ledger; no payment gateway is involved, so there is no payment data
  to protect.

## What IS protected

| Area | Protection |
|------|------------|
| **Passwords** | Stored with Django's PBKDF2 hasher. All four Django password validators are enabled (similarity, minimum length, common-password, numeric-only). |
| **Authentication (API)** | JWT. Access token 30 min (`JWT_ACCESS_MINUTES`), refresh 7 days. **Refresh rotation + blacklist**: each refresh returns a new refresh token and invalidates the old one, so a stolen refresh token is single-use. |
| **Authentication (portal)** | Django sessions + CSRF; `Secure`/HTTP-only cookies and HSTS when `USE_HTTPS=True`. |
| **Brute force / abuse** | DRF throttling: `login` 10/min per IP, `refresh` 30/min per IP, `scan` 120/min per instructor, plus global `anon` 60/min and `user` 300/min. Counters live in a shared database cache so limits hold across all Gunicorn workers. `NUM_PROXIES` makes the real client IP (not nginx's) the throttle key. |
| **Role-based access** | Admin APIs require `IsAdmin`; scanning requires `IsInstructor`; mobile student endpoints require `IsStudent`. |
| **Student data isolation** | Every student endpoint resolves the student from `request.user` - never from a client-supplied id - and filters by it. A student cannot read another student's profile, QR codes, attendance, fines or balance, and cannot generate a QR for someone else. Covered by `attendance/tests.py` (`StudentIsolationTests`). |
| **QR token** | `secrets.token_urlsafe(32)` - 256 bits from the OS CSPRNG, unique-constrained. The QR image encodes *only* this opaque token; the student, event, date and slot are looked up **server-side** at scan time. Guessing is infeasible and is also rate-limited. |
| **Transport** | HTTPS redirect, HSTS, secure cookies, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: same-origin` when `DEBUG=False`. Android release builds built for an `https://` backend refuse cleartext HTTP at the OS level. |
| **Configuration** | `DEBUG=False` by default; the app refuses to start in production without a real `SECRET_KEY`, with `ALLOWED_HOSTS=*`, or with CORS allow-all. CORS is an explicit allowlist limited to `/api/`. |
| **Secrets** | `.env`, `.env.*` (except `*.example`) and TLS keys are gitignored and excluded from the Docker image. The admin account is created once from `ADMIN_PASSWORD`; the well-known development password is refused in production. |
| **Container** | Django runs as an unprivileged user; the database is not published to the host; Gunicorn is reachable only through nginx. |

## Student self-registration

- `POST /api/auth/register/` is public by design but **harmless until approved**: the account is
  created inactive (`is_active=False`, status `PENDING`), can't sign in, receive tokens or reach any
  endpoint, and can never be given an admin/instructor/staff role through sign-up.
- Abuse limits: rate-limited per client IP (`THROTTLE_REGISTER`, 5/hour), Django password
  validators, username / student-number uniqueness, validated photo uploads.
- The adviser decides: approval is the only way to activate a sign-up (editing a pending student in
  the portal cannot activate it). Pending/rejected students are excluded from fines.
- Login hints are limited: only someone who supplies the **correct** password is told the account is
  pending/rejected; wrong credentials get the same generic 401, so usernames can't be probed.
- Email is not stored at all (not needed: sign-in is username + password), so there is no
  personal email data to leak.

## Profile photos and Cloudinary

- **Validation:** uploads must be real JPG/PNG/WebP images up to 5 MB and 25 MP. Each
  photo is re-encoded server-side (auto-rotated, EXIF/GPS metadata stripped, max 1024 px),
  so no location data is ever stored or served.
- **Unguessable URLs:** photos are saved under random 128-bit names and QR PNGs under their
  token, in a Cloudinary folder with no public listing. Anyone with a photo URL can view
  that one image; there is no way to enumerate others.
- **Own data only:** `POST/DELETE /api/me/photo/` only ever touches `request.user` and is
  rate-limited (`THROTTLE_PHOTO`, default 10/min); admins manage anyone's photo via the
  portal/`/api/users/`.
- **Secrets:** the Cloudinary API secret lives only in `.env.prod` (gitignored). If it is
  ever pasted somewhere public, **regenerate it** in the Cloudinary console and update `.env.prod`.
- Old photos are deleted from Cloudinary when replaced/cleared or when the user is deleted.

## Operational reminders

- Rotate `SECRET_KEY`, `DB_PASSWORD` and `ADMIN_PASSWORD` for any real deployment
  and keep `.env.prod` out of version control.
- Run `python manage.py flushexpiredtokens` occasionally (cron, or via the
  Celery profile) to prune expired blacklisted refresh tokens.
- `python manage.py check --deploy` should report nothing except the two
  deliberate HSTS notes (`W005` include-subdomains, `W021` preload) - those are
  domain-wide commitments that should only be enabled knowingly
  (`SECURE_HSTS_INCLUDE_SUBDOMAINS`, `SECURE_HSTS_PRELOAD`).
- QR images under `/media/qrcodes/` are public *by URL*; their filenames contain
  the unguessable token and directory listing is disabled.

## Reporting

This is a capstone project. Report issues to the project maintainers.
