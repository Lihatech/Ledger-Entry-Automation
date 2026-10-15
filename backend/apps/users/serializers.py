"""
Serializers for the users app.
"""

from rest_framework import serializers
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer
from django.contrib.auth.password_validation import validate_password
from django.db import transaction
from .models import User, AccessRole, AccessEvent
from .access import ACCESS_KEYS


class UserRoleField(serializers.SlugRelatedField):
    """Accept role objects on input but serialize the User role slug safely."""

    def to_representation(self, value):
        if isinstance(value, str):
            return value
        return super().to_representation(value)


class AccessRoleSerializer(serializers.ModelSerializer):
    user_count = serializers.SerializerMethodField()

    class Meta:
        model = AccessRole
        fields = ['slug', 'name', 'permissions', 'is_system', 'user_count']
        read_only_fields = ['slug', 'is_system', 'user_count']

    def get_user_count(self, obj):
        return User.objects.filter(role=obj.slug).count()

    def validate_permissions(self, value):
        if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            raise serializers.ValidationError('Permissions must be a list of names.')
        unknown = set(value) - ACCESS_KEYS
        if unknown:
            raise serializers.ValidationError(f'Unknown permissions: {", ".join(sorted(unknown))}')
        return sorted(set(value))


class AccessAssignmentSerializer(serializers.Serializer):
    role = serializers.SlugRelatedField(slug_field='slug', queryset=AccessRole.objects.all())
    access_grants = serializers.ListField(child=serializers.CharField(), required=False, default=list)
    access_denials = serializers.ListField(child=serializers.CharField(), required=False, default=list)

    def validate(self, attrs):
        grants = set(attrs['access_grants'])
        denials = set(attrs['access_denials'])
        unknown = (grants | denials) - ACCESS_KEYS
        if unknown:
            raise serializers.ValidationError(f'Unknown permissions: {", ".join(sorted(unknown))}')
        if grants & denials:
            raise serializers.ValidationError('A permission cannot be both granted and denied.')
        return attrs


class AccessEventSerializer(serializers.ModelSerializer):
    actor_name = serializers.CharField(source='actor.username', read_only=True)
    target_name = serializers.CharField(source='target_user.username', read_only=True)

    class Meta:
        model = AccessEvent
        fields = ['id', 'actor_name', 'target_name', 'action', 'before', 'after', 'created_at']


# ─── JWT Custom Claims ─────────────────────────────────────────────────────
class CustomTokenObtainPairSerializer(TokenObtainPairSerializer):
    """Adds role, employee_id and full_name to the JWT payload."""

    @classmethod
    def get_token(cls, user):
        token = super().get_token(user)
        token['role']           = user.role
        token['assigned_shift'] = user.assigned_shift
        token['employee_id']    = user.employee_id
        token['full_name']      = user.get_full_name()
        token['plant_id']       = user.plant_id
        return token

    def validate(self, attrs):
        username = attrs.get(self.username_field, '')
        if username:
            user_obj = User.objects.filter(username__iexact=username).first()
            if user_obj:
                attrs[self.username_field] = user_obj.username

        data = super().validate(attrs)
        # Append extra user info to the login response
        data['user'] = {
            'id':                     self.user.id,
            'username':               self.user.username,
            'email':                  self.user.email,
            'is_email_verified':      self.user.is_email_verified,
            'full_name':              self.user.get_full_name(),
            'role':                   self.user.role,
            'assigned_shift':         self.user.assigned_shift,
            'assigned_shift_display': self.user.get_assigned_shift_display(),
            'employee_id':            self.user.employee_id,
            'plant_id':               self.user.plant_id,
            'permissions':            sorted(self.user.effective_access()),
        }
        return data


# ─── Registration ──────────────────────────────────────────────────────────
class UserRegistrationSerializer(serializers.ModelSerializer):
    password  = serializers.CharField(write_only=True)
    password2 = serializers.CharField(write_only=True, label='Confirm Password')
    role = UserRoleField(slug_field='slug', queryset=AccessRole.objects.all(), required=False)
    access_grants = serializers.ListField(child=serializers.CharField(), required=False, default=list, write_only=True)
    access_denials = serializers.ListField(child=serializers.CharField(), required=False, default=list, write_only=True)

    class Meta:
        model  = User
        fields = [
            'username', 'email', 'first_name', 'last_name',
            'employee_id', 'role', 'access_grants', 'access_denials', 'assigned_shift', 'phone', 'plant',
            'password', 'password2',
        ]

    def validate(self, attrs):
        if attrs['password'] != attrs['password2']:
            raise serializers.ValidationError({'password': 'Passwords do not match.'})
        actor = self.context['request'].user
        role = attrs.get('role') or AccessRole.objects.get(slug='operator')
        attrs['role'] = role
        grants = set(attrs['access_grants'])
        denials = set(attrs['access_denials'])
        if (role.slug != 'operator' or grants or denials) and not actor.has_access('users.manage'):
            raise serializers.ValidationError('Assigning roles or custom access requires account management access.')
        unknown = (grants | denials) - ACCESS_KEYS
        if unknown or grants & denials:
            raise serializers.ValidationError('Invalid access overrides.')
        return attrs

    @transaction.atomic
    def create(self, validated_data):
        validated_data.pop('password2')
        password = validated_data.pop('password')
        role = validated_data.pop('role')
        validated_data['role'] = role.slug
        user = User(**validated_data)
        user.set_password(password)
        user.save()
        AccessEvent.objects.create(
            actor=self.context['request'].user, target_user=user, role=role,
            action='user_created', after={'role': role.slug, 'access_grants': user.access_grants,
                                          'access_denials': user.access_denials},
        )
        return user


# ─── Profile ───────────────────────────────────────────────────────────────
class UserProfileSerializer(serializers.ModelSerializer):
    plant_name             = serializers.CharField(source='plant.name', read_only=True)
    profile_photo_url      = serializers.SerializerMethodField()
    assigned_shift_display = serializers.CharField(source='get_assigned_shift_display', read_only=True)
    permissions = serializers.SerializerMethodField()
    role_name = serializers.SerializerMethodField()

    def get_permissions(self, obj):
        return sorted(obj.effective_access())

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._role_cache = {}

    def get_role_name(self, obj):
        if obj.role not in self._role_cache:
            role = AccessRole.objects.only('name').filter(slug=obj.role).first()
            self._role_cache[obj.role] = role.name if role else obj.role
        return self._role_cache[obj.role]

    def get_profile_photo_url(self, obj):
        request = self.context.get('request')
        if obj.profile_photo and hasattr(obj.profile_photo, 'url'):
            return request.build_absolute_uri(obj.profile_photo.url) if request else obj.profile_photo.url
        return None

    class Meta:
        model  = User
        fields = [
            'id', 'username', 'email', 'is_email_verified', 'first_name', 'last_name',
            'employee_id', 'role', 'role_name', 'permissions', 'access_grants', 'access_denials',
            'assigned_shift', 'assigned_shift_display', 'phone', 'plant', 'plant_name',
            'profile_photo', 'profile_photo_url', 'is_active', 'date_joined', 'created_at',
        ]
        read_only_fields = ['id', 'username', 'date_joined', 'created_at', 'is_email_verified',
                            'role', 'role_name', 'permissions', 'access_grants', 'access_denials',
                            'assigned_shift', 'is_active']

    def update(self, instance, validated_data):
        new_email = validated_data.get('email', instance.email)
        if new_email != instance.email:
            instance.is_email_verified = False
            instance.email_verification_token = None
        return super().update(instance, validated_data)


# ─── User List (Admin view) ────────────────────────────────────────────────
class UserListSerializer(serializers.ModelSerializer):
    plant_name             = serializers.CharField(source='plant.name', read_only=True)
    assigned_shift_display = serializers.CharField(source='get_assigned_shift_display', read_only=True)
    role_name = serializers.SerializerMethodField()

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._role_cache = {}

    def get_role_name(self, obj):
        if obj.role not in self._role_cache:
            role = AccessRole.objects.only('name').filter(slug=obj.role).first()
            self._role_cache[obj.role] = role.name if role else obj.role
        return self._role_cache[obj.role]

    class Meta:
        model  = User
        fields = [
            'id', 'username', 'email', 'is_email_verified', 'phone', 'full_name', 'employee_id',
            'role', 'role_name', 'assigned_shift', 'assigned_shift_display', 'plant_name', 'is_active', 'created_at',
        ]

    full_name = serializers.SerializerMethodField()

    def get_full_name(self, obj):
        return obj.get_full_name()


# ─── Change Password ───────────────────────────────────────────────────────
class ChangePasswordSerializer(serializers.Serializer):
    old_password = serializers.CharField(write_only=True)
    new_password = serializers.CharField(write_only=True, validators=[validate_password])

    def validate_old_password(self, value):
        user = self.context['request'].user
        if not user.check_password(value):
            raise serializers.ValidationError('Old password is incorrect.')
        return value

    def save(self, **kwargs):
        user = self.context['request'].user
        user.set_password(self.validated_data['new_password'])
        user.save()
        return user
