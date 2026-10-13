from django.db import transaction
from django.utils import timezone
from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.permissions import IsAuthenticated

from apps.users.permissions import HasAccess
from .models import InventoryReceipt, InventoryDispatch
from .serializers import InventoryReceiptSerializer


class InventoryReceiptListCreateView(generics.ListCreateAPIView):
    serializer_class = InventoryReceiptSerializer

    def get_queryset(self):
        qs = InventoryReceipt.objects.all()
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
    queryset = InventoryReceipt.objects.all()
    serializer_class = InventoryReceiptSerializer

    def get_permissions(self):
        return [HasAccess('inventory.manage' if self.request.method in ('PUT', 'PATCH') else 'inventory.view')]


class InventoryReceiptDispatchView(APIView):
    def post(self, request, pk):
        quantity = request.data.get('quantity')
        try:
            quantity = int(quantity)
        except (TypeError, ValueError):
            return Response({'quantity': ['Enter a valid dispatch quantity.']}, status=status.HTTP_400_BAD_REQUEST)
        if quantity < 1:
            return Response({'quantity': ['Dispatch quantity must be at least 1.']}, status=status.HTTP_400_BAD_REQUEST)
        with transaction.atomic():
            receipt = InventoryReceipt.objects.select_for_update().get(pk=pk)
            ready = max(receipt.completed_quantity - receipt.dispatched_quantity, 0)
            if quantity > ready:
                return Response({'quantity': [f'Only {ready} parts are ready to dispatch.']}, status=status.HTTP_400_BAD_REQUEST)
            receipt.dispatched_quantity += quantity
            receipt.last_dispatched_at = timezone.now()
            receipt.last_dispatched_by = request.user
            receipt.save(update_fields=['dispatched_quantity', 'last_dispatched_at', 'last_dispatched_by', 'updated_at'])
            InventoryDispatch.objects.create(receipt=receipt, quantity=quantity, dispatched_by=request.user)
        return Response(InventoryReceiptSerializer(receipt).data)

    def get_permissions(self):
        return [HasAccess('inventory.manage')]
