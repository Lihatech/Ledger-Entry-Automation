from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('machines', '0010_factory_shift_1_start_factory_shift_2_start_and_more'),
    ]

    operations = [
        migrations.AlterField(
            model_name='factory',
            name='logo',
            field=models.ImageField(blank=True, null=True, upload_to='company_logos/'),
        ),
    ]
