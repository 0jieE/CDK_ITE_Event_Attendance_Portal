# Deployment guide

How to run the QR Attendance & Financial Management backend (Django + Gunicorn +
PostgreSQL + nginx) with Docker, and how to point the Flutter app at it.

```
 phone (Flutter APK) ─┐
 browser (/portal/)  ─┴─►  nginx :80/:443 ──► web (Gunicorn :8000, Django) ──► db (PostgreSQL)
                            │  serves /static/ and /media/ from shared volumes
```

## 1. Prerequisites

- Docker Engine 24+ with the Compose v2 plugin (`docker compose version`).
- A machine reachable by the phones/browsers (a VPS, or a laptop on the same Wi-Fi
  for the defense demo) and, for HTTPS, a domain name.
- For the app: Flutter SDK + Android SDK/JDK 17 (only on the machine that builds the APK).

## 2. First run

```bash
cd backend
cp .env.prod.example .env.prod        # .env.prod is gitignored
```

Edit `.env.prod` - at minimum set:

| Variable | What to put |
|----------|-------------|
| `SECRET_KEY` | `python -c "import secrets; print(secrets.token_urlsafe(64))"` |
| `ALLOWED_HOSTS` | the hostname/IP people use (keep `localhost`: the health check needs it) |
| `CSRF_TRUSTED_ORIGINS` | the public origin, e.g. `https://attendance.example.com` or `http://192.168.1.20` |
| `DATABASE_URL` | your managed PostgreSQL (e.g. Render's **External** URL + `?sslmode=require`) - or see "Local database" below |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | the Department Adviser login |
| `USE_HTTPS` | `True` for real HTTPS, `False` for a plain-HTTP demo (see §6) |

Then start everything:

```bash
docker compose --env-file .env.prod up -d --build
docker compose --env-file .env.prod ps          # all services should become "healthy"
docker compose --env-file .env.prod logs -f web # watch the entrypoint steps
```

> Always pass `--env-file .env.prod` (compose uses it to fill `${...}` values;
> the containers read the same file via `env_file`).

On every start the `web` entrypoint ([docker/entrypoint.sh](docker/entrypoint.sh)) does:

1. wait for PostgreSQL → 2. `migrate` → 3. `createcachetable` (throttle counters)
→ 4. `collectstatic` → 5. `seed_admin --if-missing` → 6. start Gunicorn.

Open `http://<host>/portal/login/` and sign in with `ADMIN_USERNAME` / `ADMIN_PASSWORD`.
Check liveness with `curl http://<host>/healthz/` → `{"status": "ok", "database": "ok"}`.

### Database: managed (default) vs local container

- **Managed (Render etc.)** - set `DATABASE_URL` in `.env.prod`. When Docker runs on your
  own machine use the provider's **External** URL with `?sslmode=require`; the *Internal*
  URL only resolves from inside the provider's network (use it once the web app itself runs there).
  No `db` container is started.
- **Local container** - remove `DATABASE_URL`, set `DB_NAME` / `DB_USER` / `DB_PASSWORD`, and add
  `--profile local-db` to every compose command (data lives in the `postgres_data` volume).

## 2b. Images on Cloudinary (profile photos + QR codes)

All uploaded images - student/instructor/admin **profile photos**, the generated **QR
PNGs** and the portal logo - are stored on **Cloudinary** in one folder, so they survive
redeploys and don't depend on the server's disk:

```
ite-attendance/
  profiles/   <random>.jpg          # profile photos (rotated, metadata stripped, max 1024px)
  qrcodes/    qr_<token>.png        # daily QR codes
  branding/   <logo>                # portal logo
```

1. In the [Cloudinary console](https://console.cloudinary.com) copy the **Cloud name**,
   **API key** (15 digits) and **API secret** into `.env.prod`:
   ```ini
   CLOUDINARY_CLOUD_NAME=your-cloud-name
   CLOUDINARY_API_KEY=123456789012345
   CLOUDINARY_API_SECRET=...
   CLOUDINARY_FOLDER=ite-attendance
   ```
2. `docker compose --env-file .env.prod up -d --build`. On start the entrypoint runs
   `cloudinary_setup`, which checks the credentials and creates the folders (re-runnable).
   Run it by hand any time: `docker compose --env-file .env.prod exec web python manage.py cloudinary_setup`.
3. QR codes created *before* Cloudinary was enabled only exist on the server's disk. Push
   them once: `docker compose --env-file .env.prod exec web python manage.py sync_media_to_cloudinary`
   (QRs are regenerated from their token; safe to re-run).

Without the three `CLOUDINARY_*` values the app falls back to local disk (`media_data` volume).
Photos are managed in the portal (**Users / Instructors / Students -> Add/Edit -> Profile
photo**); apps can also use `POST/DELETE /api/me/photo/`. Instructors see the student's
photo in the scan result.

## 3. The admin account

- Created automatically **once**, on the first start, from `ADMIN_*` in `.env.prod`.
- **Idempotent and non-destructive**: if the user already exists it is left
  untouched, so a password changed in the portal is *not* reset when the container restarts.
- The dev default (`Admin@12345`) is refused when `DEBUG=False`.
- Create/reset manually:
  ```bash
  docker compose --env-file .env.prod exec web python manage.py seed_admin --username adviser --password 'NewPassw0rd!'   # resets that user's password
  docker compose --env-file .env.prod exec web python manage.py createsuperuser              # extra Django superuser
  ```
  Instructors and students are created from the portal (**Instructors** / **Students**).

## 4. Where things live

| What | Where | Persistence |
|------|-------|-------------|
| Database | `postgres_data` volume (`/var/lib/postgresql/data`) | survives restarts/rebuilds |
| QR PNGs + portal logo | `media_data` volume → `/app/media` (web), served at `/media/` | survives restarts/rebuilds |
| Collected static files | `static_data` volume → `/app/staticfiles`, served at `/static/` by **nginx** | regenerated on each start |

Static files: in the compose stack **nginx** serves `/static/` and `/media/` from shared volumes
(`collectstatic` writes to one, nginx mounts it read-only). WhiteNoise is also enabled inside
the app, so static files still work when it runs without nginx (as on Render). Django itself is
not published on a host port in compose; reach it through nginx.

Volume housekeeping:

```bash
docker compose --env-file .env.prod down        # stop; KEEPS data
docker compose --env-file .env.prod down -v     # stop AND DELETE database + QR images  (!)
# backup the database
docker compose --env-file .env.prod exec db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > backup.sql
```

## 5. Gunicorn workers

Configured in [gunicorn.conf.py](gunicorn.conf.py), overridable without a rebuild:

- `WEB_CONCURRENCY` = number of worker processes. Default `min(2 × CPU cores + 1, 5)`.
  On a 1-2 vCPU server/laptop use **2-3**; each worker costs ~100-150 MB RAM.
- `GUNICORN_THREADS` (default 2) per worker; `GUNICORN_TIMEOUT` (default 30 s).
- Gunicorn serves WSGI. `core/asgi.py` exists if you ever want ASGI (`gunicorn -k uvicorn.workers.UvicornWorker core.asgi:application`);
  it is not needed for this app.

Optional **background fines recompute** (nightly Celery job) needs Redis + a worker:

```bash
docker compose --env-file .env.prod --profile celery up -d --build
```

Without it everything still works - the portal's *Calculate Fines* button computes synchronously.

## 6. HTTPS on / off (demo switch)

The single switch is **`USE_HTTPS`** in `.env.prod`. It controls the HTTP→HTTPS
redirect, `Secure` session/CSRF cookies and HSTS.

### Plain-HTTP demo (e.g. a laptop on the LAN)

```ini
USE_HTTPS=False
NGINX_CONF=nginx.conf
ALLOWED_HOSTS=localhost,127.0.0.1,192.168.1.20
CSRF_TRUSTED_ORIGINS=http://192.168.1.20
```

```bash
docker compose --env-file .env.prod up -d     # recreates web/nginx with the new env
```

Portal at `http://192.168.1.20/portal/`. Build the APK with cleartext allowed (§7).

### HTTPS terminated by nginx

1. Put `fullchain.pem` and `privkey.pem` in `backend/nginx/certs/` (gitignored), e.g.
   from Let's Encrypt: `certbot certonly --standalone -d attendance.example.com`
   then copy/symlink the files.
2. `.env.prod`:
   ```ini
   USE_HTTPS=True
   NGINX_CONF=nginx.ssl.conf
   ALLOWED_HOSTS=localhost,attendance.example.com
   CSRF_TRUSTED_ORIGINS=https://attendance.example.com
   SECURE_HSTS_SECONDS=300     # raise to 31536000 once you are sure HTTPS works
   ```
3. `docker compose --env-file .env.prod up -d`.

### HTTPS terminated *in front of* nginx (Cloudflare, ngrok, cloud LB, Caddy)

Keep `NGINX_CONF=nginx.conf`, set `USE_HTTPS=True`, `CSRF_TRUSTED_ORIGINS=https://<public host>`
and `NUM_PROXIES=2`. nginx forwards the terminator's `X-Forwarded-Proto: https` to Django.
Only do this if nginx is reachable *only* through that terminator.

> **Redirect loop / "CSRF verification failed" checklist:** `USE_HTTPS=True` but the
> site is actually served over HTTP → set `USE_HTTPS=False`. `CSRF_TRUSTED_ORIGINS` must
> match the exact origin (scheme + host + port) you type in the browser.
> HSTS is cached by browsers: keep `SECURE_HSTS_SECONDS` small while testing.

## 7. Flutter release APK

The API address is a **build-time constant**: `--dart-define=API_BASE_URL=<origin>`
(see `mobile/lib/config/api_config.dart`). Use the origin only - no trailing slash,
no `/api`. With no define it keeps the dev default so `flutter run` still works.

```bash
cd mobile
flutter pub get

# HTTPS server (recommended)
flutter build apk --release --dart-define=API_BASE_URL=https://attendance.example.com

# Plain-HTTP demo server (cleartext is allowed automatically because the URL is http://)
flutter build apk --release --dart-define=API_BASE_URL=http://192.168.1.20
```

Output: `mobile/build/app/outputs/flutter-apk/app-release.apk` - copy it to the phones
and install it (enable "install unknown apps").

- **Cleartext is derived from the URL you bake in.** An `https://` build blocks plain
  HTTP at the OS level (the secure default); an `http://` build sets
  `usesCleartextTraffic="true"` automatically (see `mobile/android/app/build.gradle.kts`).
  Debug/profile builds always allow it. If a device shows "Cleartext HTTP traffic not
  permitted", the APK was built for an `https://` URL but the server is plain HTTP -
  rebuild with the right `API_BASE_URL`.
- The APK is currently signed with the **debug key** (fine for a demo). For a real
  distribution create a keystore and a `signingConfig` in `mobile/android/app/build.gradle.kts`.
- The device must be able to reach the host (same Wi-Fi for a LAN demo; open the
  firewall port 80/443 on the host).
- Mobile apps are not subject to CORS; `CORS_ALLOWED_ORIGINS` only matters for browser clients.

## Deploy on Render

Render runs **one container per service** (no docker-compose, no nginx), so this path is
different from the compose stack above: the app serves its own static files (WhiteNoise),
listens on Render's `PORT`, allows Render's hostname automatically, and keeps images on
Cloudinary instead of a disk volume.

**1. Push the repo** to GitHub (the `render.yaml` blueprint lives at the repo root).

**2. Create the database** (if you don't have one): Render -> New -> PostgreSQL, same region
as the web service (the blueprint uses `singapore`). Copy its **Internal Database URL**.

**3. Create the service from the blueprint:** Render -> New -> **Blueprint** -> select this repo.
Render reads [`render.yaml`](../render.yaml) and asks for the values marked *sync: false*:

| Variable | Value |
|----------|-------|
| `DATABASE_URL` | the PostgreSQL **Internal** URL from step 2 |
| `ADMIN_PASSWORD` | strong password for the first-run Department Adviser |
| `CLOUDINARY_CLOUD_NAME` / `CLOUDINARY_API_KEY` / `CLOUDINARY_API_SECRET` | from the Cloudinary console |

`SECRET_KEY` is generated by Render. `DEBUG=False`, `USE_HTTPS=True`, `NUM_PROXIES=1` and
`WEB_CONCURRENCY=2` are preset (a small instance can't hold many workers).

**4. Deploy.** On each start the container runs migrations, `createcachetable`,
`collectstatic`, seeds the adviser (once) and creates the Cloudinary folders. Check
`https://<service>.onrender.com/healthz/` -> `{"status": "ok", "database": "ok"}`, then sign in
at `/portal/login/` as `adviser` (or your `ADMIN_USERNAME`).

**5. Point the app at it** (`https://` so cleartext stays blocked):
```bash
flutter build apk --release --dart-define=API_BASE_URL=https://<service>.onrender.com
```

Notes and caveats
- **Hostnames are automatic.** Render's `RENDER_EXTERNAL_HOSTNAME` is added to `ALLOWED_HOSTS`
  and `CSRF_TRUSTED_ORIGINS`. For a custom domain add it to `ALLOWED_HOSTS` and
  `CSRF_TRUSTED_ORIGINS=https://your.domain` (and raise `NUM_PROXIES` if a CDN sits in front).
- **Free plan sleeps** after inactivity, so the first request can take ~30-60 s. Use a paid
  instance for the defense day, or open the site a few minutes before. Free PostgreSQL
  instances can expire - check your plan before relying on it long-term.
- **No Redis/Celery** on this blueprint: the *Calculate Fines* button computes inline, and fines
  also refresh automatically whenever they are viewed.
- **Images** persist on Cloudinary. Without the `CLOUDINARY_*` values uploads would go to the
  container's ephemeral disk and disappear on every deploy.
- **Logs:** Render dashboard -> your service -> *Logs*. Typical issues: a missing
  `DATABASE_URL`/`ADMIN_PASSWORD` (the entrypoint fails fast and says which), or
  `DisallowedHost` when using a custom domain that isn't in `ALLOWED_HOSTS`.

## 8. Operations cheat sheet

```bash
docker compose --env-file .env.prod logs -f web nginx   # logs
docker compose --env-file .env.prod restart web          # restart the app
docker compose --env-file .env.prod up -d --build        # deploy new code
docker compose --env-file .env.prod exec web python manage.py check --deploy
docker compose --env-file .env.prod exec web python manage.py flushexpiredtokens   # prune blacklist
```

Run the tests locally (no Docker): `DATABASE_URL=sqlite:///test.sqlite3 python manage.py test`.

See [SECURITY.md](SECURITY.md) for what is protected and the one accepted limitation.
