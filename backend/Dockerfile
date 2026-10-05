# syntax=docker/dockerfile:1
FROM python:3.13-slim

ENV PYTHONPATH=/app \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first so this layer is cached until requirements.txt changes.
# (psycopg-binary / Pillow ship wheels, so no compiler or libpq-dev is needed.)
COPY requirements.txt .
RUN pip install -r requirements.txt

# Unprivileged user. The static/media dirs are created here, owned by that
# user, so the named Docker volumes mounted over them inherit the ownership.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /app --shell /usr/sbin/nologin app \
    && mkdir -p /app/staticfiles /app/media \
    && chown -R app:app /app

COPY --chown=app:app . .

# Normalise line endings (the repo is edited on Windows) and make it executable.
RUN sed -i 's/\r$//' docker/entrypoint.sh docker/wait_for_db.py \
    && chmod +x docker/entrypoint.sh

USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import os, urllib.request as u; u.urlopen(u.Request('http://127.0.0.1:%s/healthz/' % os.environ.get('PORT', '8000'), headers={'Host': 'localhost'}), timeout=4)" || exit 1

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["gunicorn", "core.wsgi:application", "-c", "gunicorn.conf.py"]
