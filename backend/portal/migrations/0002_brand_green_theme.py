from django.db import migrations, models


def adopt_brand_theme(apps, schema_editor):
    """Move an install still on the *old default* (violet) to the new brand green.

    Anyone who deliberately picked another theme keeps it; so does a fresh
    install (its row is created later with the new default).
    """
    PortalSettings = apps.get_model("portal", "PortalSettings")
    PortalSettings.objects.filter(theme="violet").update(theme="brand")


class Migration(migrations.Migration):

    dependencies = [
        ('portal', '0001_initial'),
    ]

    operations = [
        migrations.AlterField(
            model_name='portalsettings',
            name='compact_sidebar',
            field=models.BooleanField(default=False, help_text='Start with the sidebar collapsed to icons (users can still toggle it).'),
        ),
        migrations.AlterField(
            model_name='portalsettings',
            name='theme',
            field=models.CharField(choices=[('brand', 'ITE Brand Green'), ('violet', 'Violet'), ('green', 'Forest Green'), ('blue', 'Blue'), ('teal', 'Teal'), ('crimson', 'Crimson'), ('slate', 'Slate')], default='brand', max_length=20),
        ),
        migrations.RunPython(adopt_brand_theme, migrations.RunPython.noop),
    ]
