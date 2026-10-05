"""Gunicorn settings (loaded automatically via ``-c gunicorn.conf.py``).

Every value can be overridden with an environment variable, so tuning needs no
rebuild. See DEPLOYMENT.md ("Worker count") for the reasoning.
"""

import multiprocessing
import os

# Render (and most PaaS) tell the app which port to listen on via $PORT.
bind = os.environ.get("GUNICORN_BIND") or f"0.0.0.0:{os.environ.get('PORT', '8000')}"

# Sync workers: (2 x CPU cores) + 1 is the classic rule, capped because each
# worker holds a Django process in RAM and a small VPS / demo laptop has few
# cores. Override with WEB_CONCURRENCY.
workers = int(
    os.environ.get("WEB_CONCURRENCY", min(2 * multiprocessing.cpu_count() + 1, 5))
)
# A few threads per worker let a slow request (report CSV) not block a scan.
threads = int(os.environ.get("GUNICORN_THREADS", 2))
timeout = int(os.environ.get("GUNICORN_TIMEOUT", 30))
graceful_timeout = 30
keepalive = 5

# Recycle workers periodically to bound any slow memory growth.
max_requests = 1000
max_requests_jitter = 100

# Docker: keep the worker heartbeat file in RAM, not on the container's disk.
worker_tmp_dir = "/dev/shm"

# Log to stdout/stderr so `docker compose logs` shows everything.
accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOG_LEVEL", "info")
