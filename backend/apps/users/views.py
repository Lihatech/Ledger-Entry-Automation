"""
Views for the users app : auth, profile, user management.
"""

from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.permissions import IsAuthenticated, AllowAny
from rest_framework_simplejwt.views import TokenObtainPairView
from rest_framework_simplejwt.tokens import RefreshToken

from django.core.mail import send_mail
from django.utils.crypto import get_random_string
from django.conf import settings
from django.contrib.auth.tokens import default_token_generator
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.utils.http import urlsafe_base64_encode, urlsafe_base64_decode
from django.utils.encoding import force_bytes, force_str
from django.core.signing import TimestampSigner, BadSignature, SignatureExpired
from django.shortcuts import get_object_or_404
from django.utils.text import slugify
from django.db import transaction
from PIL import Image, UnidentifiedImageError

from .models import User, AccessRole, AccessEvent


def available_shift_values(user):
    """Return shifts valid for the user's current plant schedule."""
    plant = getattr(user, 'plant', None)
    shift_hours = getattr(plant, 'shift_duration_hours', None)
    if not shift_hours and plant and getattr(plant, 'factory', None):
        shift_hours = plant.factory.shift_hours
    shift_hours = shift_hours or 8

    shifts = [User.Shift.SHIFT_I, User.Shift.SHIFT_II]
    if shift_hours == 8:
        shifts.append(User.Shift.SHIFT_III)
    return shift_hours, set(shifts)
from .access import ACCESS_GROUPS, COMMON_ACCESS
from .serializers import (
    CustomTokenObtainPairSerializer,
    UserRegistrationSerializer,
    UserProfileSerializer,
    UserListSerializer,
    ChangePasswordSerializer,
    AccessRoleSerializer, AccessAssignmentSerializer, AccessEventSerializer,
)
from .permissions import HasAccess


class AccessCatalogView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return Response({'groups': [
            {'name': name, 'permissions': items}
            for name, items in ACCESS_GROUPS
        ], 'common': sorted(COMMON_ACCESS)})


class AccessRoleListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return Response(AccessRoleSerializer(AccessRole.objects.order_by('name'), many=True).data)

    @transaction.atomic
    def post(self, request):
        if not request.user.has_access('roles.manage'):
            return Response({'detail': 'Role management access required.'}, status=403)
        serializer = AccessRoleSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        slug = slugify(serializer.validated_data['name']).replace('-', '_')[:64]
        if not slug or AccessRole.objects.filter(slug=slug).exists():
            return Response({'name': 'Choose a unique role name.'}, status=400)
        role = serializer.save(slug=slug)
        AccessEvent.objects.create(actor=request.user, role=role, action='role_created',
                                   after={'name': role.name, 'permissions': role.permissions})
        return Response(AccessRoleSerializer(role).data, status=201)


class AccessRoleDetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, slug):
        return Response(AccessRoleSerializer(get_object_or_404(AccessRole, slug=slug)).data)

    @transaction.atomic
    def patch(self, request, slug):
        if not request.user.has_access('roles.manage'):
            return Response({'detail': 'Role management access required.'}, status=403)
        role = get_object_or_404(AccessRole, slug=slug)
        if role.slug == 'admin':
            return Response({'detail': 'The Admin role is protected.'}, status=400)
        before = {'name': role.name, 'permissions': role.permissions}
        serializer = AccessRoleSerializer(role, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        role = serializer.save()
        AccessEvent.objects.create(actor=request.user, role=role, action='role_updated',
                                   before=before, after={'name': role.name, 'permissions': role.permissions})
        return Response(AccessRoleSerializer(role).data)

    def delete(self, request, slug):
        if not request.user.has_access('roles.manage'):
            return Response({'detail': 'Role management access required.'}, status=403)
        role = get_object_or_404(AccessRole, slug=slug)
        if role.is_system or User.objects.filter(role=role.slug).exists():
            return Response({'detail': 'This role is in use or is a system role.'}, status=400)
        AccessEvent.objects.create(actor=request.user, action='role_deleted',
                                   before={'slug': role.slug, 'name': role.name, 'permissions': role.permissions})
        role.delete()
        return Response(status=204)


class UserAccessView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        if not request.user.has_access('users.view') and request.user.pk != pk:
            return Response({'detail': 'Account access required.'}, status=403)
        user = get_object_or_404(User, pk=pk)
        return Response({'role': user.role, 'access_grants': user.access_grants,
                         'access_denials': user.access_denials,
                         'permissions': sorted(user.effective_access())})

    @transaction.atomic
    def put(self, request, pk):
        if not request.user.has_access('users.manage'):
            return Response({'detail': 'Account management access required.'}, status=403)
        user = get_object_or_404(User.objects.select_for_update(), pk=pk)
        if user.pk == request.user.pk or user.is_superuser:
            return Response({'detail': 'This account cannot be reassigned here.'}, status=400)
        serializer = AccessAssignmentSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        role = serializer.validated_data['role']
        before = {'role': user.role, 'access_grants': user.access_grants,
                  'access_denials': user.access_denials}
        user.role = role.slug
        user.access_grants = sorted(set(serializer.validated_data['access_grants']))
        user.access_denials = sorted(set(serializer.validated_data['access_denials']))
        user.save(update_fields=['role', 'access_grants', 'access_denials'])
        AccessEvent.objects.create(actor=request.user, target_user=user, role=role,
                                   action='user_access_updated', before=before,
                                   after={'role': user.role, 'access_grants': user.access_grants,
                                          'access_denials': user.access_denials})
        return self.get(request, pk)


class AccessEventListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not request.user.has_access('roles.manage'):
            return Response({'detail': 'Role management access required.'}, status=403)
        qs = AccessEvent.objects.select_related('actor', 'target_user')
        if request.query_params.get('user'):
            qs = qs.filter(target_user_id=request.query_params['user'])
        return Response(AccessEventSerializer(qs[:100], many=True).data)


# ─── Login (JWT) ──────────────────────────────────────────────────────────
class LoginView(TokenObtainPairView):
    """
    POST /api/users/login/
    Returns access + refresh JWT tokens with embedded role info.
    """
    permission_classes = [AllowAny]
    serializer_class   = CustomTokenObtainPairSerializer

    # Inherits post() directly from TokenObtainPairView.


# ─── Logout ───────────────────────────────────────────────────────────────
class LogoutView(APIView):
    """
    POST /api/users/logout/
    Blacklists the refresh token to invalidate the session.
    """
    permission_classes = [IsAuthenticated]

    def post(self, request):
        refresh_token = request.data.get('refresh')
        if not refresh_token:
            return Response(
                {'error': 'Refresh token is required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            token = RefreshToken(refresh_token)
            token.blacklist()
            return Response({'message': 'Logged out successfully.'}, status=status.HTTP_200_OK)
        except Exception:
            return Response(
                {'error': 'Invalid or expired token.'},
                status=status.HTTP_400_BAD_REQUEST,
            )


# ─── Register ─────────────────────────────────────────────────────────────
class RegisterView(generics.CreateAPIView):
    """
    POST /api/users/register/
    Create a new user account with a configured role and access profile.
    """
    serializer_class   = UserRegistrationSerializer
    permission_classes = [HasAccess]
    access_key = 'users.create'


# ─── My Profile ───────────────────────────────────────────────────────────
class ProfileView(generics.RetrieveUpdateAPIView):
    """
    GET  /api/users/me/   → view own profile
    PUT  /api/users/me/   → update own profile
    PATCH /api/users/me/  → partial update
    """
    serializer_class   = UserProfileSerializer
    permission_classes = [IsAuthenticated]

    def get_object(self):
        return self.request.user


class UpdateMyShiftView(APIView):
    """POST /api/users/me/shift/ — change the current operator/inspector shift."""
    permission_classes = [IsAuthenticated]

    @transaction.atomic
    def post(self, request):
        user = request.user
        if user.role not in (User.Role.OPERATOR, User.Role.INSPECTOR):
            return Response(
                {'message': 'Only operators and inspectors can change their own shift.'},
                status=status.HTTP_403_FORBIDDEN,
            )

        requested_shift = str(request.data.get('shift') or '').strip().upper()
        if requested_shift not in {
            User.Shift.SHIFT_I,
            User.Shift.SHIFT_II,
            User.Shift.SHIFT_III,
        }:
            return Response(
                {'message': 'A valid shift (I, II, or III) is required.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        shift_hours, valid_shifts = available_shift_values(user)
        if requested_shift not in valid_shifts:
            return Response(
                {
                    'message': (
                        f'Shift {requested_shift} is not available for a {shift_hours}-hour schedule.'
                    ),
                    'shift_hours': shift_hours,
                    'available_shifts': sorted(valid_shifts),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        previous_shift = user.assigned_shift
        if previous_shift != requested_shift:
            user.assigned_shift = requested_shift
            user.save(update_fields=['assigned_shift', 'updated_at'])
            AccessEvent.objects.create(
                actor=user,
                target_user=user,
                action='self_shift_changed',
                before={'assigned_shift': previous_shift},
                after={'assigned_shift': requested_shift, 'shift_hours': shift_hours},
            )

        from .serializers import UserProfileSerializer
        return Response({
            'success': True,
            'message': f'Shift changed to {user.get_assigned_shift_display()}.',
            'assigned_shift': user.assigned_shift,
            'assigned_shift_display': user.get_assigned_shift_display(),
            'shift_hours': shift_hours,
            'available_shifts': sorted(valid_shifts),
            'user': UserProfileSerializer(user, context={'request': request}).data,
        }, status=status.HTTP_200_OK)


# ─── Profile Photo Upload ─────────────────────────────────────────────────────
class UpdateProfilePhotoView(APIView):
    """
    POST /api/users/me/photo/
    Upload or replace the logged-in user's profile photo.
    Expects multipart/form-data with field 'photo'.
    """
    permission_classes = [IsAuthenticated]

    def post(self, request):
        photo = request.FILES.get('photo')
        if not photo:
            return Response({'error': 'No photo file provided.'}, status=status.HTTP_400_BAD_REQUEST)

        # Validate file type
        allowed_types = ['image/jpeg', 'image/png', 'image/webp', 'image/gif']
        if photo.content_type not in allowed_types:
            return Response({'error': 'Only JPEG, PNG, WebP or GIF images are allowed.'}, status=status.HTTP_400_BAD_REQUEST)

        # Validate file size (max 5 MB)
        if photo.size > 5 * 1024 * 1024:
            return Response({'error': 'Photo must be smaller than 5 MB.'}, status=status.HTTP_400_BAD_REQUEST)

        try:
            image = Image.open(photo)
            image.verify()
            photo.seek(0)
        except (Image.DecompressionBombError, UnidentifiedImageError, OSError):
            return Response({'error': 'The uploaded profile image is invalid.'}, status=status.HTTP_400_BAD_REQUEST)

        user = request.user
        user.profile_photo = photo
        user.save(update_fields=['profile_photo'])

        serializer = UserProfileSerializer(user, context={'request': request})
        return Response({
            'success': True,
            'message': 'Profile photo updated.',
            'profile_photo_url': serializer.data.get('profile_photo_url'),
        }, status=status.HTTP_200_OK)


# ─── Change Password ──────────────────────────────────────────────────────
class ChangePasswordView(APIView):
    """POST /api/users/change-password/"""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = ChangePasswordSerializer(data=request.data, context={'request': request})
        if serializer.is_valid():
            serializer.save()
            
            # Send notification email
            user = request.user
            subject = "Your Password Has Been Changed"
            message = f"Hi {user.first_name or 'User'},\n\nThis is a confirmation that the password for your account has been successfully changed.\n\nIf you did not request this change, please contact an administrator immediately."
            from_email = getattr(settings, 'DEFAULT_FROM_EMAIL', 'noreply@example.com')
            try:
                send_mail(subject, message, from_email, [user.email], fail_silently=True)
            except Exception:
                pass

            return Response({'message': 'Password changed successfully.'})
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


# ─── User List (Supervisor / Admin) ───────────────────────────────────────
class UserListView(generics.ListCreateAPIView):
    """
    GET /api/users/                   → list all users
    POST /api/users/                  → create user
    """
    def get_permissions(self):
        if self.request.method == 'GET':
            return [IsAuthenticated()]
        return [HasAccess('users.create')]

    def get_serializer_class(self):
        if self.request.method == 'POST':
            return UserRegistrationSerializer
        return UserListSerializer

    def get_queryset(self):
        qs = User.objects.select_related('plant').all()
        role  = self.request.query_params.get('role')
        plant = self.request.query_params.get('plant')
        if role:
            qs = qs.filter(role=role)
        if plant:
            qs = qs.filter(plant_id=plant)
        return qs.order_by('-is_active', '-created_at')


# ─── User Detail (Supervisor / Admin) ─────────────────────────────────────
class UserDetailView(generics.RetrieveUpdateDestroyAPIView):
    """GET/PUT/PATCH/DELETE /api/users/<id>/"""
    serializer_class   = UserProfileSerializer
    queryset           = User.objects.all()

    def get_permissions(self):
        if self.request.method == 'DELETE':
            return [HasAccess('users.manage')]
        if self.request.method == 'GET':
            return [HasAccess('users.view')]
        return [HasAccess('users.manage')]

    def patch(self, request, *args, **kwargs):
        try:
            user_obj = self.get_object()
        except User.DoesNotExist:
            return Response({
                "success": False,
                "message": "User account not found."
            }, status=status.HTTP_404_NOT_FOUND)

        # Direct is_active toggle : bypass full serializer to avoid validation errors
        if 'is_active' in request.data:
            is_active_val = request.data['is_active']
            # Handle both JSON boolean and string representations
            if isinstance(is_active_val, str):
                is_active_val = is_active_val.lower() == 'true'
            previous_active = user_obj.is_active
            user_obj.is_active = bool(is_active_val)
            user_obj.save(update_fields=['is_active'])
            AccessEvent.objects.create(actor=request.user, target_user=user_obj,
                                       action='user_status_updated',
                                       before={'is_active': previous_active},
                                       after={'is_active': user_obj.is_active})

            from .serializers import UserListSerializer
            serializer = UserListSerializer(user_obj)
            return Response({
                "success": True,
                "action": "activated" if user_obj.is_active else "deactivated",
                "message": f"User account '{user_obj.username}' has been {'activated' if user_obj.is_active else 'deactivated'}.",
                "user": serializer.data
            }, status=status.HTTP_200_OK)

        # Direct assigned_shift update : fast shift rotation
        if 'assigned_shift' in request.data:
            shift_val = request.data['assigned_shift']
            if shift_val not in dict(User.Shift.choices):
                return Response({'assigned_shift': ['Invalid shift value.']}, status=status.HTTP_400_BAD_REQUEST)
            if shift_val != User.Shift.ALL:
                shift_hours, valid_shifts = available_shift_values(user_obj)
                if shift_val not in valid_shifts:
                    return Response({
                        'assigned_shift': [f'Shift {shift_val} is not valid for a {shift_hours}-hour schedule.']
                    }, status=status.HTTP_400_BAD_REQUEST)
            previous_shift = user_obj.assigned_shift
            user_obj.assigned_shift = shift_val
            user_obj.save(update_fields=['assigned_shift', 'updated_at'])
            AccessEvent.objects.create(
                actor=request.user,
                target_user=user_obj,
                action='shift_updated',
                before={'assigned_shift': previous_shift},
                after={'assigned_shift': shift_val},
            )
            from .serializers import UserListSerializer
            serializer = UserListSerializer(user_obj)
            return Response({
                "success": True,
                "action": "shift_updated",
                "message": f"User account '{user_obj.username}' reassigned to {user_obj.get_assigned_shift_display()}.",
                "user": serializer.data
            }, status=status.HTTP_200_OK)

        # Fallback: general partial update for other fields
        serializer = self.get_serializer(user_obj, data=request.data, partial=True)
        if serializer.is_valid():
            serializer.save()
            return Response({
                "success": True,
                "message": f"User account '{user_obj.username}' updated successfully.",
                "user": serializer.data
            }, status=status.HTTP_200_OK)
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

    def destroy(self, request, *args, **kwargs):
        try:
            user_to_delete = self.get_object()
        except User.DoesNotExist:
            return Response({
                "success": False,
                "message": "User account not found."
            }, status=status.HTTP_404_NOT_FOUND)

        # 1. Admin permission check
        if not request.user.has_access('users.manage'):
            return Response({
                "success": False,
                "message": "Only administrators can delete user accounts."
            }, status=status.HTTP_403_FORBIDDEN)

        # 2. Prevent self-deletion
        if user_to_delete.id == request.user.id:
            return Response({
                "success": False,
                "message": "You cannot delete your own active administrator account."
            }, status=status.HTTP_400_BAD_REQUEST)

        # 3. Check for protected historical inspection records / dependencies
        from apps.inspections.models import InspectionSession
        from apps.parts.models import Part, InspectionTemplate
        from django.db import transaction, IntegrityError
        from django.db.models import ProtectedError

        has_operated = InspectionSession.objects.filter(operator=user_to_delete).exists()
        has_supervised = InspectionSession.objects.filter(supervisor=user_to_delete).exists()
        has_finalized = InspectionSession.objects.filter(finalized_by=user_to_delete).exists()
        has_created_parts = Part.objects.filter(created_by=user_to_delete).exists()
        has_created_templates = InspectionTemplate.objects.filter(created_by=user_to_delete).exists()

        has_protected_history = (
            has_operated or has_supervised or has_finalized or
            has_created_parts or has_created_templates
        )

        if has_protected_history:
            # Conditional Deactivation (Soft Delete) to preserve historical inspection records
            user_to_delete.is_active = False
            user_to_delete.save()

            serializer = UserListSerializer(user_to_delete)
            return Response({
                "success": True,
                "action": "deactivated",
                "message": f"User account '{user_to_delete.username}' has historical inspection records and was deactivated instead.",
                "user": serializer.data
            }, status=status.HTTP_200_OK)

        # 4. Attempt hard deletion if no historical references found
        try:
            with transaction.atomic():
                user_id = user_to_delete.id
                username = user_to_delete.username
                user_to_delete.delete()

            return Response({
                "success": True,
                "action": "deleted",
                "message": f"User account '{username}' was deleted successfully.",
                "user": {"id": user_id, "username": username}
            }, status=status.HTTP_200_OK)

        except (ProtectedError, IntegrityError):
            user_to_delete.is_active = False
            user_to_delete.save()

            serializer = UserListSerializer(user_to_delete)
            return Response({
                "success": True,
                "action": "deactivated",
                "message": f"User account '{user_to_delete.username}' is referenced by protected data and was deactivated instead.",
                "user": serializer.data
            }, status=status.HTTP_200_OK)


# ─── Email Verification ───────────────────────────────────────────────────
class RequestEmailVerificationView(APIView):
    """
    POST /api/users/verify-email/request/
    Generates a token and sends a verification email.
    """
    permission_classes = [IsAuthenticated]

    def post(self, request):
        user = request.user
        
        if not user.email:
            return Response({"error": "User does not have an email address set."}, status=status.HTTP_400_BAD_REQUEST)
            
        if user.is_email_verified:
            return Response({"message": "Email is already verified."}, status=status.HTTP_200_OK)

        base_token = get_random_string(length=32)
        user.email_verification_token = base_token
        user.save(update_fields=['email_verification_token'])

        signer = TimestampSigner()
        signed_token = signer.sign(base_token)

        # Frontend verification URL
        frontend_url = getattr(settings, 'FRONTEND_URL', 'http://localhost:5173')
        verify_url = f"{frontend_url}/verify-email/{signed_token}"

        subject = "Verify your email address"
        message = f"Hi {user.first_name},\n\nPlease click the following link to verify your email address:\n{verify_url}\n\nIf you did not request this, please ignore this email."
        
        html_message = f"""
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden;">
            <div style="background-color: #2563eb; padding: 24px; text-align: center;">
                <h1 style="color: white; margin: 0; font-size: 24px; font-weight: 600;">Email Verification</h1>
            </div>
            <div style="padding: 32px 24px; background-color: #ffffff; color: #374151;">
                <p style="font-size: 16px; margin-top: 0;">Hi <strong>{user.first_name or 'User'}</strong>,</p>
                <p style="font-size: 16px; line-height: 1.5; margin-bottom: 24px;">
                    Thank you for joining us! To complete your profile setup, we just need to verify your email address.
                </p>
                <div style="text-align: center; margin: 32px 0;">
                    <a href="{verify_url}" style="background-color: #2563eb; color: #ffffff; padding: 12px 24px; text-decoration: none; border-radius: 6px; font-weight: 600; font-size: 16px; display: inline-block;">
                        Verify Email Address
                    </a>
                </div>
                <p style="font-size: 14px; color: #6b7280; margin-bottom: 8px;">
                    Or copy and paste this link into your browser:
                </p>
                <p style="font-size: 14px; color: #2563eb; word-break: break-all; margin-top: 0;">
                    <a href="{verify_url}" style="color: #2563eb;">{verify_url}</a>
                </p>
                <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 32px 0 24px;" />
                <p style="font-size: 12px; color: #9ca3af; margin: 0;">
                    If you did not request this email, you can safely ignore it.
                </p>
            </div>
        </div>
        """
        
        from_email = getattr(settings, 'DEFAULT_FROM_EMAIL', 'noreply@example.com')
        recipient_list = [user.email]

        try:
            send_mail(subject, message, from_email, recipient_list, fail_silently=False, html_message=html_message)
            return Response({"message": "Verification email sent successfully."}, status=status.HTTP_200_OK)
        except Exception as e:
            return Response({"error": f"Failed to send email: {str(e)}"}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class VerifyEmailView(APIView):
    """
    POST /api/users/verify-email/confirm/
    Validates token and marks email as verified.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        token = request.data.get('token')
        if not token:
            return Response({"error": "Token is required."}, status=status.HTTP_400_BAD_REQUEST)

        signer = TimestampSigner()
        try:
            # Token expires after 24 hours (86400 seconds)
            base_token = signer.unsign(token, max_age=86400)
        except SignatureExpired:
            return Response({"error": "Verification token has expired."}, status=status.HTTP_400_BAD_REQUEST)
        except BadSignature:
            return Response({"error": "Invalid verification token."}, status=status.HTTP_400_BAD_REQUEST)

        user = User.objects.filter(email_verification_token=base_token).first()
        if not user:
            return Response({"error": "Invalid verification token."}, status=status.HTTP_400_BAD_REQUEST)

        user.is_email_verified = True
        user.email_verification_token = None
        user.save(update_fields=['is_email_verified', 'email_verification_token'])

        return Response({"message": "Email verified successfully."}, status=status.HTTP_200_OK)


# ─── Forgot Password ──────────────────────────────────────────────────────
class ForgotPasswordRequestView(APIView):
    """
    POST /api/users/password-reset/request/
    Generates a password reset token and sends an email.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        email = request.data.get('email')
        if not email:
            return Response({"error": "Email is required."}, status=status.HTTP_400_BAD_REQUEST)

        user = User.objects.filter(email=email).first()
        if not user:
            # For security, do not reveal whether user exists
            return Response({"message": "If an account with that email exists, a password reset link has been sent."}, status=status.HTTP_200_OK)

        # Generate token
        token = default_token_generator.make_token(user)
        uid = urlsafe_base64_encode(force_bytes(user.pk))

        # Frontend reset URL
        frontend_url = getattr(settings, 'FRONTEND_URL', 'http://localhost:5173')
        reset_url = f"{frontend_url}/reset-password/{uid}/{token}"

        subject = "Reset Your Password"
        message = f"Hi {user.first_name or 'User'},\n\nPlease click the following link to reset your password:\n{reset_url}\n\nIf you did not request this, please ignore this email."
        
        html_message = f'''
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; border: 1px solid #e5e7eb; border-radius: 8px; overflow: hidden;">
            <div style="background-color: #2563eb; padding: 24px; text-align: center;">
                <h1 style="color: white; margin: 0; font-size: 24px; font-weight: 600;">Reset Your Password</h1>
            </div>
            <div style="padding: 32px 24px; background-color: #ffffff; color: #374151;">
                <p style="font-size: 16px; margin-top: 0;">Hi <strong>{user.first_name or 'User'}</strong>,</p>
                <p style="font-size: 16px; line-height: 1.5; margin-bottom: 24px;">
                    We received a request to reset your password. Click the button below to choose a new password.
                </p>
                <div style="text-align: center; margin: 32px 0;">
                    <a href="{reset_url}" style="background-color: #2563eb; color: #ffffff; padding: 12px 24px; text-decoration: none; border-radius: 6px; font-weight: 600; font-size: 16px; display: inline-block;">
                        Reset Password
                    </a>
                </div>
                <p style="font-size: 14px; color: #6b7280; margin-bottom: 8px;">
                    Or copy and paste this link into your browser:
                </p>
                <p style="font-size: 14px; color: #2563eb; word-break: break-all; margin-top: 0;">
                    <a href="{reset_url}" style="color: #2563eb;">{reset_url}</a>
                </p>
                <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 32px 0 24px;" />
                <p style="font-size: 12px; color: #9ca3af; margin: 0;">
                    If you did not request a password reset, you can safely ignore this email.
                </p>
            </div>
        </div>
        '''

        from_email = getattr(settings, 'DEFAULT_FROM_EMAIL', 'noreply@example.com')

        try:
            send_mail(subject, message, from_email, [user.email], fail_silently=False, html_message=html_message)
        except Exception:
            pass # Fail silently

        return Response({"message": "If an account with that email exists, a password reset link has been sent."}, status=status.HTTP_200_OK)


class ResetPasswordConfirmView(APIView):
    """
    POST /api/users/password-reset/confirm/
    Validates the token and updates the user's password.
    """
    permission_classes = [AllowAny]

    def post(self, request):
        uidb64 = request.data.get('uid')
        token = request.data.get('token')
        new_password = request.data.get('password')

        if not uidb64 or not token or not new_password:
            return Response({"error": "uid, token, and new password are required."}, status=status.HTTP_400_BAD_REQUEST)

        try:
            uid = force_str(urlsafe_base64_decode(uidb64))
            user = User.objects.get(pk=uid)
        except (TypeError, ValueError, OverflowError, User.DoesNotExist):
            user = None

        if user is not None and default_token_generator.check_token(user, token):
            try:
                validate_password(new_password, user=user)
            except ValidationError as e:
                return Response({"error": e.messages}, status=status.HTTP_400_BAD_REQUEST)

            user.set_password(new_password)
            user.save()
            return Response({"message": "Password has been reset successfully."}, status=status.HTTP_200_OK)
        else:
            return Response({"error": "Invalid or expired token."}, status=status.HTTP_400_BAD_REQUEST)
