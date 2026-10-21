from django.db import migrations, models


def activate_latest(apps, schema_editor):
    """Mark the semester of the most recent event as the active one (if there is any event)."""
    Event = apps.get_model("attendance", "Event")
    Semester = apps.get_model("attendance", "Semester")
    latest = Event.objects.order_by("-start_date", "-id").first()
    if latest is not None:
        Semester.objects.filter(pk=latest.semester_id).update(is_active=True)


class Migration(migrations.Migration):

    # Each step commits on its own (PostgreSQL will not ALTER a table after data changes in
    # the same transaction when deferred constraint triggers are pending).
    atomic = False

    dependencies = [
        ("attendance", "0004_eventdayfine"),
    ]

    operations = [
        migrations.AddField(
            model_name="semester",
            name="is_active",
            field=models.BooleanField(
                default=False,
                help_text="The current semester: the default filter on the attendance pages and the "
                          "default semester of a new event. Only one semester is active at a time.",
            ),
        ),
        migrations.RunPython(activate_latest, migrations.RunPython.noop),
        migrations.AddConstraint(
            model_name="semester",
            constraint=models.UniqueConstraint(
                condition=models.Q(("is_active", True)), fields=("is_active",), name="uniq_active_semester",
            ),
        ),
    ]
