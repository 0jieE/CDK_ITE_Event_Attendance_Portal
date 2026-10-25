"""Write a full data backup (the same file the Django Administration backup button gives).

    python manage.py backup_db                 # ite-attendance-backup-<timestamp>.json
    python manage.py backup_db --output b.json
"""

from django.core.management.base import BaseCommand

from core import backup


class Command(BaseCommand):
    help = "Save all users, students, events, attendance and fines to a JSON file."

    def add_arguments(self, parser):
        parser.add_argument("--output", default=None, help="file to write (default: timestamped name)")

    def handle(self, *args, **options):
        path = options["output"] or backup.backup_filename()
        with open(path, "wb") as handle:
            handle.write(backup.build_backup())
        self.stdout.write(self.style.SUCCESS(f"Backup written to {path}"))
