from decimal import Decimal


def warning_boundaries(lower, nominal, upper, measurement_type='dimensional'):
    lower, nominal, upper = map(lambda value: Decimal(str(value)), (lower, nominal, upper))
    if str(measurement_type or '').lower() in {'min_limit', 'max_limit'}:
        return lower, upper
    return (lower + nominal) / Decimal('2'), (nominal + upper) / Decimal('2')


def classify_value(value, lower, nominal, upper, measurement_type='dimensional'):
    value = Decimal(str(value))
    lower, nominal, upper = map(lambda item: Decimal(str(item)), (lower, nominal, upper))
    if value <= lower or value >= upper:
        return 'red'
    warning_low, warning_high = warning_boundaries(lower, nominal, upper, measurement_type)
    if value <= warning_low or value >= warning_high:
        return 'yellow'
    return 'green'
