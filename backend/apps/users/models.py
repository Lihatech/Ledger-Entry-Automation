"""Custom User model with role-based access control."""

from django.contrib.auth.models import AbstractUser
from django.db import models
from .access import ACCESS_KEYS, MANAGE_IMPLIES_VIEW


class AccessRole(models.Model):
    slug = models.SlugField(max_length=64, unique=True)
    name = models.CharField(max_length=100, unique=True)
    permissions = models.JSONField(default=list)
    is_system = models.BooleanField(default=False)

    def __str__(self):
        return self.name


class AccessEvent(models.Model):
    actor = models.ForeignKey('users.User', null=True, on_delete=models.SET_NULL, related_name='access_changes_made')
    target_user = models.ForeignKey('users.User', null=True, on_delete=models.SET_NULL, related_name='access_changes_received')
    role = models.ForeignKey(AccessRole, null=True, on_delete=models.SET_NULL)
    action = models.CharField(max_length=40)
    before = models.JSONField(default=dict)
    after = models.JSONField(default=dict)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']


class User(AbstractUser):

    class Role(models.TextChoices):
        OPERATOR          = 'operator',           'Operator'
        SUPERVISOR        = 'supervisor',         'Supervisor'
        INSPECTOR         = 'inspector',          'Inspector'
        QUALITY_ENGINEER  = 'quality_engineer',   'Quality Engineer'
        CALIBRATOR        = 'calibrator',         'Calibrator'
        ADMIN             = 'admin',              'Admin'

    class Shift(models.TextChoices):
        SHIFT_I   = 'I',   'Shift I'
        SHIFT_II  = 'II',  'Shift II'
        SHIFT_III = 'III', 'Shift III'
        ALL       = 'ALL', 'All Shifts (Flexible)'

    # Core fields
    role = models.CharField(max_length=64, default=Role.OPERATOR)
    access_grants = models.JSONField(default=list, blank=True)
    access_denials = models.JSONField(default=list, blank=True)
    assigned_shift = models.CharField(
        max_length=10,
        choices=Shift.choices,
        default=Shift.ALL,
        help_text="Assigned working shift for the operator/inspector.",
    )
    employee_id = models.CharField(max_length=50, unique=True, null=True, blank=True)
    phone       = models.CharField(max_length=15, blank=True)

    # Verification fields
    is_email_verified = models.BooleanField(default=False)
    email_verification_token = models.CharField(max_length=100, null=True, blank=True)

    # Plant assignment (operators/supervisors belong to a plant)
    plant = models.ForeignKey(
        'machines.Plant',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='users',
    )

    # Profile
    profile_photo = models.ImageField(
        upload_to='profiles/',
        null=True,
        blank=True,
    )

    # Timestamps
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    # Use email as the login identifier
    USERNAME_FIELD  = 'username'
    REQUIRED_FIELDS = ['email', 'employee_id']

    class Meta:
        db_table   = 'users'
        ordering   = ['-created_at']
        verbose_name = 'User'
        verbose_name_plural = 'Users'

    def __str__(self):
        role_label = str(self.role).replace('_', ' ').title() if self.role else 'User'
        emp = f" ({self.employee_id})" if self.employee_id else ""
        return f"{self.get_full_name() or self.username}{emp} : {role_label}"

    @property
    def display_name(self):
        """Stable user label for live feeds and reports."""
        return self.get_full_name().strip() or self.username or f"User #{self.pk}"

    def effective_access(self):
        if not self.is_active:
            return set()
        if self.is_superuser:
            return ACCESS_KEYS
        role = AccessRole.objects.filter(slug=self.role).first()
        granted = set(role.permissions if role else ()) | set(self.access_grants)
        denials = set(self.access_denials)
        effective = granted - denials
        for manage_key, view_keys in MANAGE_IMPLIES_VIEW.items():
            if manage_key in effective:
                effective.update(view_keys - denials)
        return effective & ACCESS_KEYS

    def has_access(self, key):
        return key in self.effective_access()

    # ─── Role helpers ─────────────────────────────────────────
    @property
    def is_operator(self):
        return self.role == self.Role.OPERATOR

    @property
    def is_supervisor(self):
        return self.role == self.Role.SUPERVISOR

    @property
    def is_quality_engineer(self):
        return self.role == self.Role.QUALITY_ENGINEER

    @property
    def is_inspector(self):
        return self.role == self.Role.INSPECTOR

    @property
    def is_calibrator(self):
        return self.role == self.Role.CALIBRATOR

    @property
    def is_admin_user(self):
        return self.role == self.Role.ADMIN
