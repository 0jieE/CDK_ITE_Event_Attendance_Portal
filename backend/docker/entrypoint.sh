#!/bin/sh
# Container entrypoint: prepare the app, then exec the real command.
#
#   wait for DB -> migrate -> createcachetable -> collectstatic
#     -> seed the Department Adviser (idempotent) -> exec "$@" (Gunicorn)
#
# Worker containers (Celery) set RUN_SETUP=0 so only `web` runs the steps.
set -e

if [ "${RUN_SETUP:-1}" = "1" ]; then
    echo "==> Waiting for the database"
    python docker/wait_for_db.py

    echo "==> Applying migrations"
    python manage.py migrate --noinput

    echo "==> Creating the cache table (throttle counters)"
    python manage.py createcachetable

    echo "==> Collecting static files"
    python manage.py collectstatic --noinput

    echo "==> Ensuring the Department Adviser admin exists"
    python manage.py seed_admin --if-missing

    echo "==> Checking Cloudinary media storage"
    # Creates the upload folders when configured; never blocks startup if the
    # credentials are wrong - uploads would fail loudly until they are fixed.
    python manage.py cloudinary_setup --if-configured         || echo "WARNING: Cloudinary setup failed - check CLOUDINARY_* in .env.prod"
fi

echo "==> Starting: $*"
exec "$@"
