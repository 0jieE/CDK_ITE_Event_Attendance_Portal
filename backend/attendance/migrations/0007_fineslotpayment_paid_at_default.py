import django.utils.timezone
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("attendance", "0006_fine_slot_payments"),
    ]

    operations = [
        migrations.AlterField(
            model_name="fineslotpayment",
            name="paid_at",
            field=models.DateTimeField(default=django.utils.timezone.now),
        ),
    ]
