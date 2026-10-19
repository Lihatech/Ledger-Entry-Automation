"""Shared plant shift and production-date resolution helpers."""

from datetime import time, timedelta

from django.utils import timezone

from .models import Factory


def _resolve_factory(*, machine=None, plant=None, factory=None):
    """Resolve the schedule belonging to a machine or plant."""
    if factory is not None:
        return factory
    if plant is None and machine is not None:
        plant = getattr(machine, 'plant', None)
    if plant is not None and getattr(plant, 'factory', None) is not None:
        return plant.factory
    return Factory.objects.filter(is_active=True).order_by('id').first() or Factory.objects.order_by('id').first()


def get_shift_configuration(*, machine=None, plant=None, factory=None):
    """Return normalized shift settings for the relevant production area."""
    resolved_factory = _resolve_factory(machine=machine, plant=plant, factory=factory)
    resolved_plant = plant or (getattr(machine, 'plant', None) if machine is not None else None)
    shift_hours = (
        getattr(resolved_factory, 'shift_hours', None)
        or getattr(resolved_plant, 'shift_duration_hours', None)
        or 8
    )
    shift_hours = 12 if int(shift_hours) == 12 else 8
    default_count = 2 if shift_hours == 12 else 3
    shift_count = int(getattr(resolved_factory, 'total_shifts_per_day', None) or default_count)
    shift_count = 2 if shift_hours == 12 else max(1, min(3, shift_count))
    return {
        'factory': resolved_factory,
        'plant': resolved_plant,
        'shift_hours': shift_hours,
        'shift_count': shift_count,
        'shift_1_start': getattr(resolved_factory, 'shift_1_start', None) or time(8, 0),
        'shift_2_start': getattr(resolved_factory, 'shift_2_start', None) or time(16, 0),
        'shift_3_start': getattr(resolved_factory, 'shift_3_start', None) or time(0, 0),
    }


def get_valid_shifts(*, machine=None, plant=None, factory=None):
    config = get_shift_configuration(machine=machine, plant=plant, factory=factory)
    return {'I', 'II'} if config['shift_count'] == 2 else {'I', 'II', 'III'}


def get_current_production_date_and_shift(timestamp=None, *, machine=None, plant=None, factory=None):
    """Return ``(production_date, shift)`` using the configured plant clock."""
    if timestamp is None:
        local_timestamp = timezone.localtime(timezone.now())
    elif timezone.is_naive(timestamp):
        local_timestamp = timezone.make_aware(timestamp, timezone.get_current_timezone())
    else:
        local_timestamp = timezone.localtime(timestamp)

    config = get_shift_configuration(machine=machine, plant=plant, factory=factory)
    starts = [config['shift_1_start'], config['shift_2_start']]
    if config['shift_count'] == 3:
        starts.append(config['shift_3_start'])
    minute = local_timestamp.hour * 60 + local_timestamp.minute
    start_minutes = [value.hour * 60 + value.minute for value in starts]

    if config['shift_count'] == 2:
        shift = 'I' if start_minutes[0] <= minute < start_minutes[1] else 'II'
    elif start_minutes[0] <= minute < start_minutes[1]:
        shift = 'I'
    elif start_minutes[1] <= minute < start_minutes[2]:
        shift = 'II'
    else:
        shift = 'III'

    production_date = local_timestamp.date()
    if minute < start_minutes[0]:
        production_date -= timedelta(days=1)
    return production_date, shift


def resolve_shift_context(*, requested_shift=None, assigned_shift=None, machine=None, timestamp=None):
    """Resolve a manual shift or the current scheduled shift.

    An explicit request remains a manual override.  If omitted, the company
    schedule and current plant time determine the shift.  Assigned shifts are
    retained as an authorization constraint.
    """
    production_date, current_shift = get_current_production_date_and_shift(
        timestamp, machine=machine
    )
    aliases = {'A': 'I', 'B': 'II', 'C': 'III'}
    requested = aliases.get(str(requested_shift or '').strip().upper(), str(requested_shift or '').strip().upper())
    assigned = aliases.get(str(assigned_shift or '').strip().upper(), str(assigned_shift or '').strip().upper())
    effective_shift = requested or current_shift
    error = None
    if effective_shift == 'ALL':
        effective_shift = current_shift
    if assigned and assigned != 'ALL' and effective_shift != assigned:
        error = 'The submitted shift does not match your assigned shift.'
    elif effective_shift not in get_valid_shifts(machine=machine):
        error = f'Shift {effective_shift} is not available for this plant schedule.'
    return {
        'production_date': production_date,
        'current_shift': current_shift,
        'shift': effective_shift,
        'manual': bool(requested),
        'error': error,
    }
