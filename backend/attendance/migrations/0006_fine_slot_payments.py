import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


def paid_fines_are_paid_in_full(apps, schema_editor):
    """Fines already marked PAID were settled in full: record that as amount_paid."""
    Fine = apps.get_model("attendance", "Fine")
    Fine.objects.filter(status="PAID").update(amount_paid=models.F("amount"))


class Migration(migrations.Migration):

    # Each step commits on its own (PostgreSQL will not ALTER a table after data changes in
    # the same transaction when deferred constraint triggers are pending).
    atomic = False

    dependencies = [
        ("attendance", "0005_semester_is_active"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="FineSlotPayment",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("date", models.DateField()),
                ("attendance_type", models.CharField(
                    choices=[("AM_IN", "AM Time-In"), ("AM_OUT", "AM Time-Out"),
                             ("PM_IN", "PM Time-In"), ("PM_OUT", "PM Time-Out")], max_length=10)),
                ("amount", models.DecimalField(decimal_places=2, max_digits=10)),
                ("paid_at", models.DateTimeField(auto_now_add=True)),
                ("fine", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE,
                                           related_name="slot_payments", to="attendance.fine")),
                ("recorded_by", models.ForeignKey(
                    blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL,
                    related_name="recorded_slot_payments", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["date", "attendance_type"]},
        ),
        migrations.AddConstraint(
            model_name="fineslotpayment",
            constraint=models.UniqueConstraint(fields=("fine", "date", "attendance_type"),
                                               name="uniq_fine_slot_payment"),
        ),
        migrations.AddField(
            model_name="fine",
            name="amount_paid",
            field=models.DecimalField(
                decimal_places=2, default=0, max_digits=10,
                help_text="Sum of the slot payments (or the full amount for a fine paid in full)."),
        ),
        migrations.RunPython(paid_fines_are_paid_in_full, migrations.RunPython.noop),
    ]
