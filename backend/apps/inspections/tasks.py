"""
Celery Tasks for Inspection App.
Handles async measurement processing, Redis caching, and idempotency guarantees.

NOTE: Celery is intentionally NOT installed on Render (no broker available).
      This module provides the same public API but dispatches via Python threads.
      The @shared_task decorator is a no-op when celery is absent.
"""

import logging
import threading
import time

# Celery is optional : not installed on Render free tier.
# Provide a no-op @shared_task decorator so the module loads cleanly.
try:
    from celery import shared_task
    _CELERY_AVAILABLE = True
except ImportError:
    _CELERY_AVAILABLE = False
    def shared_task(*args, **kwargs):           # noqa: E302
        """No-op decorator : Celery not installed."""
        def decorator(func):
            return func
        return decorator if args and callable(args[0]) else decorator

from django.core.cache import cache
# M4 FIX: Import shared singleton : do NOT instantiate InspectionService() here.
# One instance is shared across views.py, tasks.py, and any future modules.
from .services import inspection_service as _service

logger = logging.getLogger(__name__)


def process_measurement_in_background(
    session_id: str,
    parameter_code: str,
    measured_value: float,
    voice_raw_text: str = '',
    method: str = 'voice',
    hourly_slot: int = None,
    inspection_type: str = None,
    idempotency_key: str = None,
) -> dict:
    """
    Executes the DB, Redis, and WebSocket write operations for a measurement recording.
    Caches the result under idempotency_key (30 min TTL) if provided.
    """
    t_start = time.perf_counter()
    try:
        result = _service.record_measurement(
            session_id=session_id,
            parameter_code=parameter_code,
            measured_value=measured_value,
            voice_raw_text=voice_raw_text,
            method=method,
            hourly_slot=hourly_slot,
            inspection_type=inspection_type,
        )
        duration_ms = (time.perf_counter() - t_start) * 1000
        result['process_duration_ms'] = round(duration_ms, 2)
        result['status_code'] = 200

        if idempotency_key:
            cache_key = f"idempotency_{idempotency_key}"
            cache.set(cache_key, result, timeout=1800)

        logger.info(
            "[PERF TASK] Executed record_measurement for %s (val: %s) in %.2f ms (key: %s)",
            parameter_code, measured_value, duration_ms, idempotency_key
        )
        return result
    except Exception as exc:
        duration_ms = (time.perf_counter() - t_start) * 1000
        
        # Differentiate between client-side issues (404/403/400) and server bugs (500)
        exc_str = str(exc)
        is_not_found = "matching query does not exist" in exc_str or "not found for part" in exc_str
        is_permission = isinstance(exc, PermissionError) or "locked against edits" in exc_str or "finalized and locked" in exc_str
        is_client_error = (
            is_not_found or
            is_permission or
            "First Piece Inspection is limited" in exc_str or
            "No active inspection template found" in exc_str or
            (isinstance(exc, ValueError) and "could not convert string to float" in exc_str)
        )
        
        status_code = 404 if is_not_found else (403 if is_permission else (400 if is_client_error else 500))
        
        err_res = {
            'error': exc_str,
            'status_code': status_code,
            'process_duration_ms': round(duration_ms, 2),
        }
        if idempotency_key:
            cache_key = f"idempotency_{idempotency_key}"
            cache.set(cache_key, err_res, timeout=1800)
            
        if is_client_error:
            logger.warning("Client error in measurement task for %s: %s", parameter_code, exc_str)
        else:
            logger.error("Error executing measurement task for %s: %s", parameter_code, exc_str, exc_info=True)
            
        return err_res


@shared_task(name="apps.inspections.tasks.record_measurement_task")
def record_measurement_task(
    session_id: str,
    parameter_code: str,
    measured_value: float,
    voice_raw_text: str = '',
    method: str = 'voice',
    hourly_slot: int = None,
    inspection_type: str = None,
    idempotency_key: str = None,
):
    """Celery task entry point."""
    return process_measurement_in_background(
        session_id=session_id,
        parameter_code=parameter_code,
        measured_value=measured_value,
        voice_raw_text=voice_raw_text,
        method=method,
        hourly_slot=hourly_slot,
        inspection_type=inspection_type,
        idempotency_key=idempotency_key,
    )


def dispatch_measurement_task_async(
    session_id: str,
    parameter_code: str,
    measured_value: float,
    voice_raw_text: str = '',
    method: str = 'voice',
    hourly_slot: int = None,
    inspection_type: str = None,
    idempotency_key: str = None,
):
    """
    Attempts to dispatch task to Celery worker; falls back to background daemon thread if Celery is not active.
    """
    try:
        record_measurement_task.delay(
            session_id=session_id,
            parameter_code=parameter_code,
            measured_value=measured_value,
            voice_raw_text=voice_raw_text,
            method=method,
            hourly_slot=hourly_slot,
            inspection_type=inspection_type,
            idempotency_key=idempotency_key,
        )
    except Exception as exc:
        logger.warning("Celery dispatch unavailable (%s), falling back to background thread.", exc)
        threading.Thread(
            target=process_measurement_in_background,
            kwargs={
                'session_id': session_id,
                'parameter_code': parameter_code,
                'measured_value': measured_value,
                'voice_raw_text': voice_raw_text,
                'method': method,
                'hourly_slot': hourly_slot,
                'inspection_type': inspection_type,
                'idempotency_key': idempotency_key,
            },
            daemon=True,
        ).start()
