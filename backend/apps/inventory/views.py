from decimal import Decimal, InvalidOperation

from django.db import transaction
from django.db.models import Prefetch
from django.utils import timezone
from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.users.permissions import HasAccess
from .models import InventoryReceipt, InventoryDispatch, InventoryReceiptIntake
from .serializers import InventoryReceiptSerializer


class InventoryReceiptListCreateView(generics.ListCreateAPIView):
    serializer_class = InventoryReceiptSerializer

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
        return [HasAccess(('inventory.view', 'production.daily.manage', 'quality.inspections.record'))]

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)


class InventoryReceiptDetailView(generics.RetrieveUpdateAPIView):
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
        return [HasAccess('inventory.manage' if self.request.method in ('PUT', 'PATCH') else 'inventory.view')]


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
        with transaction.atomic():
            receipts = InventoryReceipt.objects.select_for_update()
            if getattr(request.user, 'plant_id', None):
                receipts = receipts.filter(plant_id=request.user.plant_id)
            try:
                receipt = receipts.get(pk=pk)
            except InventoryReceipt.DoesNotExist:
                return Response({'detail': 'Receipt not found.'}, status=status.HTTP_404_NOT_FOUND)
            if idempotency_key:
                previous_dispatch = receipt.dispatch_events.filter(idempotency_key=idempotency_key).first()
                if previous_dispatch:
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
        try:
            quantity = int(request.data.get('quantity'))
        except (TypeError, ValueError):
            return Response({'quantity': ['Enter a valid incoming quantity.']}, status=status.HTTP_400_BAD_REQUEST)
        if quantity < 1:
            return Response({'quantity': ['Incoming quantity must be at least 1.']}, status=status.HTTP_400_BAD_REQUEST)

        with transaction.atomic():
            receipts = InventoryReceipt.objects.select_for_update()
            if getattr(request.user, 'plant_id', None):
                receipts = receipts.filter(plant_id=request.user.plant_id)
            try:
                receipt = receipts.get(pk=pk)
            except InventoryReceipt.DoesNotExist:
                return Response({'detail': 'Receipt not found.'}, status=status.HTTP_404_NOT_FOUND)

            receipt.received_quantity += quantity
            accounted = receipt.completed_quantity + receipt.rework_quantity + receipt.rejected_quantity + receipt.in_process_quantity
            receipt.not_started_quantity = max(receipt.received_quantity - accounted, 0)
            receipt.save(update_fields=['received_quantity', 'not_started_quantity', 'updated_at'])
            InventoryReceiptIntake.objects.create(
                receipt=receipt,
                quantity=quantity,
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
