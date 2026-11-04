"""
Models for Factory → Plant → Machine hierarchy.
"""

from django.db import models


class Factory(models.Model):
    """Top-level organisational unit : e.g. 'Liha Tech Plant 1'."""

    name          = models.CharField(max_length=100)
    code          = models.CharField(max_length=20, unique=True)   # e.g. FAC-01
    location      = models.CharField(max_length=200, blank=True)
    contact_email = models.EmailField(blank=True, default='')
    phone         = models.CharField(max_length=30, blank=True, default='')
    address       = models.TextField(blank=True, default='')
    gstin         = models.CharField(max_length=30, blank=True, default='')
    logo_url      = models.CharField(max_length=500, blank=True, default='')
    logo          = models.ImageField(upload_to='company_logos/', blank=True, null=True)
    industry_type = models.CharField(max_length=100, blank=True, default='Precision Component Manufacturing')
    shift_hours   = models.IntegerField(default=8)
    shift_1_start = models.TimeField(default='08:00:00')
    shift_2_start = models.TimeField(default='16:00:00')
    shift_3_start = models.TimeField(default='00:00:00')
    total_shifts_per_day = models.IntegerField(default=3)
    lunch_break_minutes = models.IntegerField(default=30)
    tea_break_minutes  = models.IntegerField(default=30)
    available_working_minutes = models.IntegerField(default=420)
    is_active     = models.BooleanField(default=True)
    created_at    = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table  = 'factories'
        ordering  = ['name']
        verbose_name_plural = 'Factories'

    def __str__(self):
        return f"{self.name} ({self.code})"

class Plant(models.Model):
    """A production plant / shop floor within a factory."""

    factory   = models.ForeignKey(Factory, on_delete=models.CASCADE, related_name='plants')
    name      = models.CharField(max_length=100)
    code      = models.CharField(max_length=20, unique=True)   # e.g. PLT-01
    shift_duration_hours = models.PositiveIntegerField(default=8)
    total_break_mins = models.PositiveIntegerField(default=60)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'plants'
        ordering = ['name']

    def __str__(self):
        return f"{self.name} : {self.factory.name}"


class Machine(models.Model):
    """A machine on the shop floor that produces inspectable parts."""

    class Status(models.TextChoices):
        ACTIVE      = 'active',      'Active'
        MAINTENANCE = 'maintenance', 'Under Maintenance'
        INACTIVE    = 'inactive',    'Inactive'

    plant          = models.ForeignKey(Plant, on_delete=models.SET_NULL, null=True, blank=True, related_name='machines')
    name           = models.CharField(max_length=100)
    machine_code   = models.CharField(max_length=30, unique=True)  # e.g. MCH-001
    machine_type   = models.CharField(max_length=100, blank=True)  # e.g. CNC Lathe
    manufacturer   = models.CharField(max_length=100, blank=True)
    model_number   = models.CharField(max_length=100, blank=True)
    status         = models.CharField(max_length=15, choices=Status.choices, default=Status.ACTIVE)

    # QR code value : scanned by Flutter app to quickly select machine
    qr_code        = models.CharField(max_length=100, unique=True, blank=True)

    is_active  = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'machines'
        ordering = ['machine_code']

    def __str__(self):
        plant_name = self.plant.name if self.plant else "No Plant"
        return f"{self.machine_code} : {self.name} ({plant_name})"

    def save(self, *args, **kwargs):
        # Auto-generate QR code value if not set
        if not self.qr_code:
            self.qr_code = self.machine_code
        super().save(*args, **kwargs)
