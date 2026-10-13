from django.urls import path
from .views import InventoryReceiptListCreateView, InventoryReceiptDetailView, InventoryReceiptDispatchView


urlpatterns = [
    path('receipts/', InventoryReceiptListCreateView.as_view(), name='inventory-receipts'),
    path('receipts/<int:pk>/', InventoryReceiptDetailView.as_view(), name='inventory-receipt-detail'),
    path('receipts/<int:pk>/dispatch/', InventoryReceiptDispatchView.as_view(), name='inventory-receipt-dispatch'),
]
