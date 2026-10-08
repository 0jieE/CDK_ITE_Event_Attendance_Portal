"""
Django settings for the Hybrid QR-Code Based Attendance & Financial
Management System (ITE Department, Colegio de Kidapawan).

Configuration is read from a ``.env`` file via ``django-environ`` so that no
secret ever lives in source control.  See ``.env.example`` for the full list
of supported keys.
"""

from datetime import timedelta
from pathlib import Path

import environ
from celery.schedules import crontab
from django.core.exceptions import ImproperlyConfigured

# ---------------------------------------------------------------------------
# Paths & environment
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent.parent

env = environ.Env()

# Read .env if present (it is optional in production where real env vars win).
environ.Env.read_env(BASE_DIR / ".env")

# Secure by default: nothing is in debug mode unless DEBUG=True is set.
DEBUG = env.bool("DEBUG", default=False)

_INSECURE_DEV_KEY = "django-insecure-dev-only-key-do-not-use-in-production"
SECRET_KEY = env("SECRET_KEY", default=_INSECURE_DEV_KEY if DEBUG else None)
if not SECRET_KEY or (not DEBUG and SECRET_KEY.startswith("django-insecure")):
    raise ImproperlyConfigured(
        "SECRET_KEY must be set to a unique, secret value when DEBUG=False. "
        "Generate one with: python -c \"import secrets; print(secrets.token_urlsafe(64))\""
    )

ALLOWED_HOSTS = env.list("ALLOWED_HOSTS", default=["localhost", "127.0.0.1"])
if not DEBUG and "*" in ALLOWED_HOSTS:
    raise ImproperlyConfigured(
        "ALLOWED_HOSTS must list real hostnames (not '*') when DEBUG=False."
    )

# Required by Django >= 4 for HTTPS POSTs (login, HTMX) behind a reverse proxy,
# e.g. CSRF_TRUSTED_ORIGINS=https://attendance.example.com
CSRF_TRUSTED_ORIGINS = env.list("CSRF_TRUSTED_ORIGINS", default=[])

# Render injects the service's public hostname (e.g. my-app.onrender.com);
# allow and trust it automatically so no manual host configuration is needed.
_render_host = env("RENDER_EXTERNAL_HOSTNAME", default="")
if _render_host:
    if _render_host not in ALLOWED_HOSTS:
        ALLOWED_HOSTS.append(_render_host)
    _render_origin = f"https://{_render_host}"
    if _render_origin not in CSRF_TRUSTED_ORIGINS:
        CSRF_TRUSTED_ORIGINS.append(_render_origin)


# ---------------------------------------------------------------------------
# Applications
# ---------------------------------------------------------------------------
INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    # Third-party
    "rest_framework",
    "rest_framework_simplejwt.token_blacklist",
    "django_filters",
    "corsheaders",
    "drf_spectacular",
    # Local
    "accounts",
    "attendance",
    "portal",
]

# Web portal (session auth) login routing.
LOGIN_URL = "portal:login"
LOGIN_REDIRECT_URL = "portal:dashboard"
LOGOUT_REDIRECT_URL = "portal:login"

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

# WhiteNoise serves the collected static files straight from the app (needed on
# Render, which has no nginx; with the Docker/nginx setup nginx answers /static/
# first). Production only: ``runserver`` serves static files itself in DEBUG.
if not DEBUG:
    MIDDLEWARE.insert(
        MIDDLEWARE.index("django.middleware.security.SecurityMiddleware") + 1,
        "whitenoise.middleware.WhiteNoiseMiddleware",
    )

ROOT_URLCONF = "core.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
                "portal.context.sidebar_nav",
                "portal.context.ui_settings",
            ],
        },
    },
]

WSGI_APPLICATION = "core.wsgi.application"


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
# Prefer a single DATABASE_URL; fall back to discrete DB_* keys otherwise.
if env("DATABASE_URL", default=None):
    DATABASES = {"default": env.db("DATABASE_URL")}
else:
    DATABASES = {
        "default": {
            "ENGINE": env("DB_ENGINE", default="django.db.backends.postgresql"),
            "NAME": env("DB_NAME", default="qr_attendace"),
            "USER": env("DB_USER", default="postgres"),
            "PASSWORD": env("DB_PASSWORD", default=""),
            "HOST": env("DB_HOST", default="localhost"),
            "PORT": env("DB_PORT", default="5432"),
        }
    }


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------
AUTH_USER_MODEL = "accounts.User"

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]


# ---------------------------------------------------------------------------
# Internationalisation
# ---------------------------------------------------------------------------
LANGUAGE_CODE = "en-us"
TIME_ZONE = "Asia/Manila"
USE_I18N = True
USE_TZ = True


# ---------------------------------------------------------------------------
# Static & media
# ---------------------------------------------------------------------------
# Static files are collected into STATIC_ROOT (``collectstatic``) and served by
# nginx in production (no WhiteNoise); ``runserver`` serves them in dev.
# Generated QR PNGs and branding uploads live in MEDIA_ROOT, which is a Docker
# volume in production so they survive container restarts.  Both locations can
# be overridden so a container can point them at a mounted volume.
STATIC_URL = "static/"
STATIC_ROOT = Path(env("STATIC_ROOT", default=str(BASE_DIR / "staticfiles")))

MEDIA_URL = "media/"
MEDIA_ROOT = Path(env("MEDIA_ROOT", default=str(BASE_DIR / "media")))

# ---------------------------------------------------------------------------
# Media storage: Cloudinary (profile photos, QR PNGs, portal logo)
# ---------------------------------------------------------------------------
# With the three CLOUDINARY_* credentials set, every uploaded image is stored in
# the ``CLOUDINARY_FOLDER`` folder on Cloudinary (see core/storage.py). Without
# them (local dev) files fall back to MEDIA_ROOT on disk.
CLOUDINARY_CLOUD_NAME = env("CLOUDINARY_CLOUD_NAME", default="")
CLOUDINARY_API_KEY = env("CLOUDINARY_API_KEY", default="")
CLOUDINARY_API_SECRET = env("CLOUDINARY_API_SECRET", default="")
CLOUDINARY_FOLDER = env("CLOUDINARY_FOLDER", default="ite-attendance")
CLOUDINARY_ENABLED = bool(CLOUDINARY_CLOUD_NAME and CLOUDINARY_API_KEY and CLOUDINARY_API_SECRET)

if CLOUDINARY_ENABLED:
    import cloudinary

    cloudinary.config(
        cloud_name=CLOUDINARY_CLOUD_NAME,
        api_key=CLOUDINARY_API_KEY,
        api_secret=CLOUDINARY_API_SECRET,
        secure=True,
    )

STORAGES = {
    "default": {
        "BACKEND": (
            "core.storage.CloudinaryMediaStorage"
            if CLOUDINARY_ENABLED
            else "django.core.files.storage.FileSystemStorage"
        ),
    },
    "staticfiles": {"BACKEND": "whitenoise.storage.CompressedStaticFilesStorage"},
}

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"


# ---------------------------------------------------------------------------
# Django REST Framework
# ---------------------------------------------------------------------------
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": (
        "rest_framework_simplejwt.authentication.JWTAuthentication",
        "rest_framework.authentication.SessionAuthentication",
    ),
    "DEFAULT_PERMISSION_CLASSES": (
        "rest_framework.permissions.IsAuthenticated",
    ),
    "DEFAULT_PAGINATION_CLASS": "rest_framework.pagination.PageNumberPagination",
    "PAGE_SIZE": 20,
    # The report endpoints implement their own ``?format=csv`` export, so we
    # disable DRF's URL format override to avoid it hijacking that query param.
    "URL_FORMAT_OVERRIDE": None,
    "DEFAULT_FILTER_BACKENDS": (
        "django_filters.rest_framework.DjangoFilterBackend",
        "rest_framework.filters.SearchFilter",
        "rest_framework.filters.OrderingFilter",
    ),
    "DEFAULT_SCHEMA_CLASS": "drf_spectacular.openapi.AutoSchema",
    # --- Throttling -------------------------------------------------------
    # Global anon/user limits; the hot endpoints (login, refresh, scan) opt in
    # to the stricter ``scope`` rates below via ScopedRateThrottle.
    "DEFAULT_THROTTLE_CLASSES": (
        "rest_framework.throttling.AnonRateThrottle",
        "rest_framework.throttling.UserRateThrottle",
    ),
    "DEFAULT_THROTTLE_RATES": {
        "anon": env("THROTTLE_ANON", default="60/min"),
        "user": env("THROTTLE_USER", default="300/min"),
        # Brute-force protection for credential endpoints (per client IP).
        "login": env("THROTTLE_LOGIN", default="10/min"),
        "refresh": env("THROTTLE_REFRESH", default="30/min"),
        # An instructor scanning a queue of students (per instructor).
        "scan": env("THROTTLE_SCAN", default="120/min"),
        "photo": env("THROTTLE_PHOTO", default="10/min"),
        "password": env("THROTTLE_PASSWORD", default="5/min"),
        # Public student sign-ups (per client IP).
        "register": env("THROTTLE_REGISTER", default="5/hour"),
    },
    # How many reverse proxies sit in front of Django (nginx = 1). Lets DRF
    # derive the real client IP from X-Forwarded-For for throttling instead of
    # trusting a spoofable header. 0 = use REMOTE_ADDR directly (dev).
    "NUM_PROXIES": env.int("NUM_PROXIES", default=0),
}

# ---------------------------------------------------------------------------
# Cache — backs the throttle counters.
# ---------------------------------------------------------------------------
# Gunicorn runs several worker processes, and a per-process cache would give
# every worker its own counter (limits multiplied by the worker count).  In
# production the counters therefore live in the database cache table
# (``manage.py createcachetable`` runs from the container entrypoint).
if DEBUG:
    CACHES = {"default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"}}
else:
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.db.DatabaseCache",
            "LOCATION": "django_cache",
        }
    }

# ---------------------------------------------------------------------------
# SimpleJWT — short-lived access token, longer refresh, rotation + blacklist.
# ---------------------------------------------------------------------------
# The Flutter client silently refreshes on 401, so a short access lifetime costs
# nothing in UX.  Each refresh issues a NEW refresh token and blacklists the old
# one (``token_blacklist`` app), so a stolen refresh token is single-use.
# Periodically run ``manage.py flushexpiredtokens`` to prune the blacklist.
SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=env.int("JWT_ACCESS_MINUTES", default=30)),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=env.int("JWT_REFRESH_DAYS", default=7)),
    "ROTATE_REFRESH_TOKENS": True,
    "BLACKLIST_AFTER_ROTATION": True,
    "UPDATE_LAST_LOGIN": False,
}

SPECTACULAR_SETTINGS = {
    "TITLE": "QR Attendance & Financial Management API",
    "DESCRIPTION": (
        "Admin-side REST API for the Hybrid QR-Code Based Attendance and "
        "Financial Management System of the ITE Department, "
        "Colegio de Kidapawan."
    ),
    "VERSION": "1.0.0",
    "SERVE_INCLUDE_SCHEMA": False,
    # Two models share a ``status`` field name; give each enum a stable name.
    "ENUM_NAME_OVERRIDES": {
        "AttendanceStatusEnum": "attendance.models.AttendanceLog.Status",
        "FineStatusEnum": "attendance.models.Fine.Status",
    },
}


# ---------------------------------------------------------------------------
# CORS — allowlist only; CORS applies to the JSON API and nothing else
# ---------------------------------------------------------------------------
# The Flutter *mobile* app is a native client and is not subject to CORS. This
# only matters for browser clients on another origin (e.g. Flutter web), so the
# list can be empty.  The /portal/ pages are same-origin.
CORS_URLS_REGEX = r"^/api/.*$"
CORS_ALLOWED_ORIGINS = env.list("CORS_ALLOWED_ORIGINS", default=[])
CORS_ALLOW_ALL_ORIGINS = env.bool("CORS_ALLOW_ALL_ORIGINS", default=False)
if DEBUG:
    # Flutter web dev servers pick a random localhost port.
    CORS_ALLOWED_ORIGIN_REGEXES = [r"^http://(localhost|127\.0\.0\.1):\d+$"]
elif CORS_ALLOW_ALL_ORIGINS:
    raise ImproperlyConfigured(
        "CORS_ALLOW_ALL_ORIGINS must be False when DEBUG=False; "
        "list trusted origins in CORS_ALLOWED_ORIGINS instead."
    )


# ---------------------------------------------------------------------------
# HTTPS / security hardening (only when DEBUG=False)
# ---------------------------------------------------------------------------
# ``USE_HTTPS`` is the single switch for everything that assumes TLS. The demo
# server may be plain HTTP: set USE_HTTPS=False and the redirect, secure
# cookies and HSTS are all turned off (see DEPLOYMENT.md). With USE_HTTPS=True
# (the default) the site must really be served over HTTPS, either directly by
# nginx (nginx/nginx.ssl.conf) or by a TLS terminator in front of it.
USE_HTTPS = env.bool("USE_HTTPS", default=True)

# Trust the proxy's ``X-Forwarded-Proto`` header to decide request.is_secure().
# Only enable when ALL traffic reaches Django through nginx (it does in the
# Docker setup); otherwise a client could forge the header.
TRUST_PROXY_SSL_HEADER = env.bool("TRUST_PROXY_SSL_HEADER", default=not DEBUG)
if TRUST_PROXY_SSL_HEADER:
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

# Container/proxy health probes arrive over plain HTTP — never redirect them.
SECURE_REDIRECT_EXEMPT = [r"^healthz/$"]

if not DEBUG:
    SECURE_CONTENT_TYPE_NOSNIFF = True
    X_FRAME_OPTIONS = "DENY"
    SECURE_REFERRER_POLICY = "same-origin"

    SECURE_SSL_REDIRECT = USE_HTTPS
    SESSION_COOKIE_SECURE = USE_HTTPS
    CSRF_COOKIE_SECURE = USE_HTTPS
    SECURE_HSTS_SECONDS = env.int("SECURE_HSTS_SECONDS", default=31536000) if USE_HTTPS else 0
    # These two are domain-wide, hard-to-undo commitments: opt in deliberately.
    SECURE_HSTS_INCLUDE_SUBDOMAINS = env.bool("SECURE_HSTS_INCLUDE_SUBDOMAINS", default=False)
    SECURE_HSTS_PRELOAD = env.bool("SECURE_HSTS_PRELOAD", default=False)


# ---------------------------------------------------------------------------
# Celery (background fine calculation) — Redis broker/result backend
# ---------------------------------------------------------------------------
CELERY_BROKER_URL = env("CELERY_BROKER_URL", default="redis://localhost:6379/0")
CELERY_RESULT_BACKEND = env("CELERY_RESULT_BACKEND", default="redis://localhost:6379/1")

# When True, tasks run inline (no broker needed) — handy for tests/CI.
CELERY_TASK_ALWAYS_EAGER = env.bool("CELERY_TASK_ALWAYS_EAGER", default=False)
CELERY_TASK_EAGER_PROPAGATES = True

CELERY_TIMEZONE = TIME_ZONE
CELERY_TASK_TRACK_STARTED = True
# Fire-and-forget: we never retrieve task results, so don't use a result store.
CELERY_TASK_IGNORE_RESULT = True

# Fail fast (rather than hang) when the broker is unreachable, so the portal's
# synchronous fallback can kick in.
CELERY_TASK_PUBLISH_RETRY = False
CELERY_BROKER_CONNECTION_RETRY_ON_STARTUP = False
CELERY_BROKER_TRANSPORT_OPTIONS = {"socket_connect_timeout": 2}

# Periodic auto-recompute of fines for every active, already-started event.
# Runs nightly so each completed event-day is folded into the fines.
CELERY_BEAT_SCHEDULE = {
    "recompute-active-fines-nightly": {
        "task": "attendance.tasks.recompute_all_active_fines",
        "schedule": crontab(hour=23, minute=0),
    },
}
