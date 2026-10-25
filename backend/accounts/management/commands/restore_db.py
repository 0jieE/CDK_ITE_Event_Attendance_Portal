"""Restore a backup file, REPLACING all current data (see core/backup.py).

    python manage.py restore_db backup.json --yes
"""

from django.core.management.base import BaseCommand, CommandError

from core import backup


class Command(BaseCommand):
    help = "Replace all users, students, events, attendance and fines with a backup file."

    def add_arguments(self, parser):
        parser.add_argument("file")
        parser.add_argument("--yes", action="store_true", help="confirm that ALL current data is replaced")

    def handle(self, *args, **options):
        if not options["yes"]:
            raise CommandError("This replaces ALL current data. Re-run with --yes to confirm.")
        try:
            with open(options["file"], "rb") as handle:
                result = backup.restore_backup(handle.read())
        except (OSError, backup.BackupError) as exc:
            raise CommandError(str(exc))
        self.stdout.write(self.style.SUCCESS(f"Restored {result['objects']} records."))
