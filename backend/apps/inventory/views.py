from decimal import Decimal, InvalidOperation
import logging

from django.db import transaction
from django.db.models import Prefetch
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.exceptions import ValidationError
from rest_framework.views import APIView

from apps.users.permissions import HasAccess
from .models import InventoryReceipt, InventoryDispatch, InventoryReceiptIntake
from .serializers import InventoryReceiptSerializer, InventoryReceiptSelectionSerializer

logger = logging.getLogger(__name__)


class InventoryReceiptListCreateView(generics.ListCreateAPIView):
    serializer_class = InventoryReceiptSerializer

    def get_serializer_class(self):
        if self.request.method == 'GET' and not self.request.user.has_access('inventory.view'):
            return InventoryReceiptSelectionSerializer
        return InventoryReceiptSerializer

    def get_queryset(self):
        qs = InventoryReceipt.objects.select_related('plant', 'plant__factory', 'created_by').prefetch_related(
            Prefetch('dispatch_events', queryset=InventoryDispatch.objects.select_related('dispatched_by'), to_attr='_prefetched_dispatch_events'),
            'intake_events__received_by',
        )
        if getattr(self.request.user, 'plant_id', None):
            qs = qs.filter(plant_id=self.request.user.plant_id)
        search = self.request.query_params.get('search', '').strip()
        if search:
            from django.db.models import Q
            qs = qs.filter(
                Q(company_name__icontains=search)
                | Q(challan_number__icontains=search)
                | Q(part_name__icontains=search)
                | Q(vehicle_number__icontains=search)
            )
        return qs

    def get_permissions(self):
        if self.request.method == 'POST':
            return [HasAccess('inventory.manage')]
        return [HasAccess(('inventory.view', 'production.daily.manage'))]

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    def create(self, request, *args, **kwargs):
        """Return useful validation details and capture them for diagnostics."""
        serializer = self.get_serializer(data=request.data)
        if not serializer.is_valid():
            fields = ','.join(str(key) for key in serializer.errors.keys())
            logger.warning('Inventory receipt validation failed fields=%s user=%s', fields, getattr(request.user, 'pk', None))
            try:
                import sentry_sdk
                with sentry_sdk.push_scope() as scope:
                    scope.set_tag('endpoint', 'inventory.receipts.create')
                    scope.set_tag('validation_fields', fields)
                    scope.set_extra('machine_step_count', len(request.data.get('machine_sequence_steps') or []))
                    sentry_sdk.capture_message('Inventory receipt validation failed', level='warning')
            except Exception:
                pass
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
        self.perform_create(serializer)
        headers = self.get_success_headers(serializer.data)
        return Response(serializer.data, status=status.HTTP_201_CREATED, headers=headers)


class InventoryReceiptDetailView(generics.RetrieveUpdateDestroyAPIView):
    serializer_class = InventoryReceiptSerializer

    def get_queryset(self):
        qs = InventoryReceipt.objects.select_related('plant', 'plant__factory', 'created_by').prefetch_related(
            Prefetch('dispatch_events', queryset=InventoryDispatch.objects.select_related('dispatched_by'), to_attr='_prefetched_dispatch_events'),
            'intake_events__received_by',
        )
        if getattr(self.request.user, 'plant_id', None):
            qs = qs.filter(plant_id=self.request.user.plant_id)
        return qs

    def get_permissions(self):
        return [HasAccess('inventory.manage' if self.request.method in ('PUT', 'PATCH', 'DELETE') else 'inventory.view')]

    def perform_update(self, serializer):
        # Serialize route edits with report submissions so a route cannot be
        # changed between the history check and the database write.
        with transaction.atomic():
            locked = InventoryReceipt.objects.select_for_update().get(pk=serializer.instance.pk)
            new_steps = serializer.validated_data.get('machine_sequence_steps', locked.machine_sequence_steps)
            if new_steps != locked.machine_sequence_steps and (
                locked.production_reports.filter(status='SUBMITTED').exists() or locked.dispatched_quantity
            ):
                raise ValidationError({'machine_sequence_steps': 'The machine sequence cannot change after production or dispatch history exists.'})
            serializer.instance = locked
            serializer.save()

    def destroy(self, request, *args, **kwargs):
        # A receipt is the source record for production and logistics history.
        # It may only be removed while it is still an unused entry mistake.
        with transaction.atomic():
            # Do not lock the view queryset: its nullable related-object
            # joins make PostgreSQL reject SELECT FOR UPDATE.
            receipts = InventoryReceipt.objects.select_for_update()
            if getattr(request.user, 'plant_id', None):
                receipts = receipts.filter(plant_id=request.user.plant_id)
            receipt = get_object_or_404(receipts, pk=kwargs['pk'])
            if receipt.production_reports.exists() or receipt.dispatch_events.exists() or receipt.intake_events.exists():
                return Response(
                    {
                        'detail': (
                            'This receipt cannot be deleted because production, incoming, or dispatch history exists. '
                            'Keep it as the audit record.'
                        )
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )
            receipt.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class InventoryReceiptDispatchView(APIView):
    def post(self, request, pk):
        raw_quantity = request.data.get('quantity')
        idempotency_key = str(request.data.get('idempotency_key') or '').strip() or None
        try:
            decimal_quantity = Decimal(str(raw_quantity))
        except (TypeError, ValueError, InvalidOperation):
            return Response({'quantity': ['Enter a valid whole-number dispatch quantity.']}, status=status.HTTP_400_BAD_REQUEST)
        if not decimal_quantity.is_finite() or decimal_quantity != decimal_quantity.to_integral_value():
            return Response({'quantity': ['Dispatch quantity must be a whole number.']}, status=status.HTTP_400_BAD_REQUEST)
        quantity = int(decimal_quantity)
        if quantity < 1:
            return Response({'quantity': ['Dispatch quantity must be at least 1.']}, status=status.HTTP_400_BAD_REQUEST)
        if idempotency_key and len(idempotency_key) > 64:
            return Response({'idempotency_key': ['Request key must be 64 characters or fewer.']}, status=status.HTTP_400_BAD_REQUEST)
        with transaction.atomic():
            receipts = InventoryReceipt.objects.select_for_update()
            if getattr(request.user, 'plant_id', None):
                receipts = receipts.filter(plant_id=request.user.plant_id)
            try:
                receipt = receipts.get(pk=pk)
            except InventoryReceipt.DoesNotExist:
                return Response({'detail': 'Receipt not found.'}, status=status.HTTP_404_NOT_FOUND)
            if idempotency_key:
                previous_dispatch = InventoryDispatch.objects.filter(idempotency_key=idempotency_key).select_related('receipt').first()
                if previous_dispatch:
                    if previous_dispatch.receipt_id != receipt.pk:
                        return Response({'idempotency_key': ['Request key has already been used for another receipt.']}, status=status.HTTP_409_CONFLICT)
                    return Response(InventoryReceiptSerializer(receipt).data, status=status.HTTP_200_OK)
            ready = max(receipt.completed_quantity - receipt.dispatched_quantity, 0)
            if quantity > ready:
                return Response({'quantity': [f'Only {ready} parts are ready to dispatch.']}, status=status.HTTP_400_BAD_REQUEST)
            receipt.dispatched_quantity += quantity
            receipt.last_dispatched_at = timezone.now()
            receipt.last_dispatched_by = request.user
            receipt.save(update_fields=['dispatched_quantity', 'last_dispatched_at', 'last_dispatched_by', 'updated_at'])
            InventoryDispatch.objects.create(
                receipt=receipt, quantity=quantity, idempotency_key=idempotency_key,
                dispatched_by=request.user,
            )
        return Response(InventoryReceiptSerializer(receipt).data)

    def get_permissions(self):
        return [HasAccess('inventory.manage')]


class InventoryReceiptIntakeView(APIView):
    """Record another physical arrival against an existing receipt."""

    def post(self, request, pk):
        raw_quantity = request.data.get('quantity')
        idempotency_key = str(request.data.get('idempotency_key') or '').strip() or None
        try:
            decimal_quantity = Decimal(str(raw_quantity))
        except (TypeError, ValueError, InvalidOperation):
            return Response({'quantity': ['Enter a valid whole-number incoming quantity.']}, status=status.HTTP_400_BAD_REQUEST)
        if not decimal_quantity.is_finite() or decimal_quantity != decimal_quantity.to_integral_value():
            return Response({'quantity': ['Incoming quantity must be a whole number.']}, status=status.HTTP_400_BAD_REQUEST)
        quantity = int(decimal_quantity)
        if quantity < 1:
            return Response({'quantity': ['Incoming quantity must be at least 1.']}, status=status.HTTP_400_BAD_REQUEST)
        if idempotency_key and len(idempotency_key) > 64:
            return Response({'idempotency_key': ['Request key must be 64 characters or fewer.']}, status=status.HTTP_400_BAD_REQUEST)

        with transaction.atomic():
            receipts = InventoryReceipt.objects.select_for_update()
            if getattr(request.user, 'plant_id', None):
                receipts = receipts.filter(plant_id=request.user.plant_id)
            try:
                receipt = receipts.get(pk=pk)
            except InventoryReceipt.DoesNotExist:
                return Response({'detail': 'Receipt not found.'}, status=status.HTTP_404_NOT_FOUND)

            if idempotency_key:
                previous_intake = InventoryReceiptIntake.objects.filter(idempotency_key=idempotency_key).select_related('receipt').first()
                if previous_intake:
                    if previous_intake.receipt_id != receipt.pk:
                        return Response({'idempotency_key': ['Request key has already been used for another receipt.']}, status=status.HTTP_409_CONFLICT)
                    return Response(InventoryReceiptSerializer(receipt).data, status=status.HTTP_200_OK)

            receipt.received_quantity += quantity
            from .services import reconcile_receipt_from_reports
            receipt.save(update_fields=['received_quantity', 'updated_at'])
            receipt = reconcile_receipt_from_reports(receipt)
            InventoryReceiptIntake.objects.create(
                receipt=receipt,
                quantity=quantity,
                idempotency_key=idempotency_key,
                received_by=request.user,
                vehicle_number=str(request.data.get('vehicle_number') or '').strip(),
                notes=str(request.data.get('notes') or '').strip(),
            )

        receipt = InventoryReceipt.objects.select_related('plant', 'plant__factory', 'created_by').prefetch_related(
            'dispatch_events__dispatched_by', 'intake_events__received_by'
        ).get(pk=receipt.pk)
        return Response(InventoryReceiptSerializer(receipt).data)

    def get_permissions(self):
        return [HasAccess('inventory.manage')]
