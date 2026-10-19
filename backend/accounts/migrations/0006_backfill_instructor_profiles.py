from django.db import migrations


def backfill(apps, schema_editor):
    """Give every user flagged is_instructor an Instructor profile (users created on the
    Users page before the profile was created automatically had none)."""
    User = apps.get_model("accounts", "User")
    Instructor = apps.get_model("accounts", "Instructor")
    for user in User.objects.filter(is_instructor=True, instructor_profile__isnull=True):
        Instructor.objects.get_or_create(user=user)


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0005_remove_student_approval"),
    ]

    operations = [
        migrations.RunPython(backfill, migrations.RunPython.noop),
    ]
