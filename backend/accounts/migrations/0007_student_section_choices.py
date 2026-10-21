import re

from django.db import migrations, models

VALID = list("ABCDEFG")


def normalize(value):
    v = re.sub(r"\s+", " ", str(value or "")).strip().upper()
    if v in VALID:
        return v
    m = re.search(r"(?:^|[ \-_.])\d?([A-G])$", v) or re.fullmatch(r"\d([A-G])", v)
    return m.group(1) if m else ""


def clean_sections(apps, schema_editor):
    """Collapse the free-text sections ("a", " B ", "Section C", "1-D" ...) into A-G; anything
    that cannot be read as a section becomes blank (the adviser can set it from the list)."""
    Student = apps.get_model("accounts", "Student")
    for student in Student.objects.exclude(section="").only("id", "section"):
        fixed = normalize(student.section)
        if fixed != student.section:
            Student.objects.filter(pk=student.pk).update(section=fixed)


class Migration(migrations.Migration):

    # Each step commits on its own (PostgreSQL will not ALTER a table after data changes in
    # the same transaction when deferred constraint triggers are pending).
    atomic = False

    dependencies = [
        ("accounts", "0006_backfill_instructor_profiles"),
    ]

    operations = [
        migrations.RunPython(clean_sections, migrations.RunPython.noop),
        migrations.AlterField(
            model_name="student",
            name="section",
            field=models.CharField(
                blank=True, max_length=20,
                choices=[(None, "—"), ("A", "A"), ("B", "B"), ("C", "C"), ("D", "D"), ("E", "E"), ("F", "F"), ("G", "G")],
            ),
        ),
    ]
