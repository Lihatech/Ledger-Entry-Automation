from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from django.utils import timezone
from django.db.models import Count, Q
from django.core.cache import cache
from datetime import datetime, timedelta

from apps.inspections.models import InspectionSession
from apps.users.permissions import HasAccess


class InspectionReportView(APIView):
    """
    GET /api/analytics/report/?from=2025-01-01&to=2025-01-31&machine=MCH-001
    Returns inspection statistics for a date range.
    """
    permission_classes = [HasAccess]
    access_key = 'quality.analytics.view'

    def get(self, request):
        from_date    = request.query_params.get('from')
        to_date      = request.query_params.get('to')
        machine_code = request.query_params.get('machine')

        # Cache analytics reports for 5 minutes : report data changes infrequently
        # and re-aggregating the full table on every request is expensive.
        cache_key = f"inspection_report_{from_date}_{to_date}_{machine_code or 'all'}"
        cached = cache.get(cache_key)
        if cached:
            return Response(cached)

        qs = InspectionSession.objects.all()
        if from_date:
            qs = qs.filter(started_at__date__gte=from_date)
        if to_date:
            qs = qs.filter(started_at__date__lte=to_date)
        if machine_code:
            qs = qs.filter(machine__machine_code=machine_code)

        stats = qs.aggregate(
            total=Count('id'),
            approved=Count('id', filter=Q(status__in=['approved', 'finalized_passed']) | Q(is_setup_approved=True)),
            pending=Count('id', filter=Q(status='pending_review')),
            ooc_count=Count('id', filter=Q(has_ooc=True)),
            critical_fails=Count('id', filter=Q(has_critical_fail=True)),
        )

        total = stats['total'] or 1
        stats['pass_rate'] = round((stats['approved'] / total) * 100, 2)

        result = {
            'filters': {
                'from_date':    from_date,
                'to_date':      to_date,
                'machine_code': machine_code,
            },
            'statistics': stats,
        }
        cache.set(cache_key, result, timeout=300)
        return Response(result)


class OOCTrendView(APIView):
    """
    GET /api/analytics/ooc-trend/?days=7&plant=1
    Returns daily out-of-spec count for trend chart on dashboard.
    """
    permission_classes = [HasAccess]
    access_key = 'quality.analytics.view'

    def get(self, request):
        days     = int(request.query_params.get('days', 7))
        plant_id = request.query_params.get('plant')
        today    = timezone.localdate()

        # Cache OOC trend for 5 minutes. The old implementation ran N×3 separate
        # DB queries (one count() call per metric per day). This version uses a
        # single annotated query and caches the result, so repeat requests are
        # served in < 1ms instead of 1-5 seconds.
        cache_key = f"ooc_trend_{days}_{plant_id or 'all'}"
        cached = cache.get(cache_key)
        if cached:
            return Response(cached)

        # Single aggregated query : replaces the previous per-day loop
        start_day = today - timedelta(days=days - 1)
        qs = InspectionSession.objects.filter(started_at__date__gte=start_day)
        if plant_id:
            qs = qs.filter(machine__plant_id=plant_id)

        stats = qs.values('started_at__date').annotate(
            total=Count('id'),
            ooc_count=Count('id', filter=Q(has_ooc=True)),
            approved=Count('id', filter=Q(status='approved')),
        ).order_by('started_at__date')

        # Build a lookup map so days with zero sessions are still included
        stats_map = {str(row['started_at__date']): row for row in stats}

        trend = []
        for i in range(days - 1, -1, -1):
            day = today - timedelta(days=i)
            row = stats_map.get(str(day), {})
            trend.append({
                'date':      day.isoformat(),
                'total':     row.get('total', 0),
                'ooc_count': row.get('ooc_count', 0),
                'approved':  row.get('approved', 0),
            })

        result = {'trend': trend, 'days': days}
        cache.set(cache_key, result, timeout=300)
        return Response(result)


class MachinePerformanceView(APIView):
    """
    GET /api/analytics/machine/<machine_id>/performance/?days=30
    OOC rate, inspection count, and pass rate for a specific machine.
    """
    permission_classes = [HasAccess]
    access_key = 'quality.live.view'

    def get(self, request, machine_id):
        days  = int(request.query_params.get('days', 30))
        since = timezone.now() - timedelta(days=days)

        qs = InspectionSession.objects.filter(
            machine_id=machine_id,
            started_at__gte=since,
        )
        total    = qs.count()
        approved = qs.filter(status='approved').count()
        ooc      = qs.filter(has_ooc=True).count()

        return Response({
            'machine_id':  machine_id,
            'days':        days,
            'total':       total,
            'approved':    approved,
            'ooc_count':   ooc,
            'pass_rate':   round((approved / total) * 100, 2) if total else 0,
            'ooc_rate':    round((ooc / total) * 100, 2) if total else 0,
        })


class OperatorStatsView(APIView):
    """
    GET /api/analytics/operator/<operator_id>/stats/?days=30
    Inspection count and OOC rate per operator.
    """
    permission_classes = [HasAccess]
    access_key = 'quality.analytics.view'

    def get(self, request, operator_id):
        days  = int(request.query_params.get('days', 30))
        since = timezone.now() - timedelta(days=days)

        qs    = InspectionSession.objects.filter(
            operator_id=operator_id,
            started_at__gte=since,
        )
        total    = qs.count()
        approved = qs.filter(status='approved').count()
        ooc      = qs.filter(has_ooc=True).count()

        return Response({
            'operator_id': operator_id,
            'days':        days,
            'total':       total,
            'approved':    approved,
            'ooc_count':   ooc,
            'pass_rate':   round((approved / total) * 100, 2) if total else 0,
        })


class ParameterOOCRateView(APIView):
    """
    GET /api/analytics/parameters/ooc-rate/?part=PN-001
    Which parameters fail most often? Fetched from PostgreSQL JSONB.
    """
    permission_classes = [HasAccess]
    access_key = 'quality.analytics.view'

    def get(self, request):
        part_number = request.query_params.get('part', '')

        # Query sessions and extract measurements from document_payload
        qs = InspectionSession.objects.all()
        if part_number:
            qs = qs.filter(part__part_number=part_number)

        # Aggregate OOC rates from JSONB measurements
        param_stats = {}
        for session in qs:
            measurements = session.document_payload.get('measurements', [])
            for m in measurements:
                code = m.get('parameter_code')
                if not code:
                    continue

                if code not in param_stats:
                    param_stats[code] = {
                        'parameter_code': code,
                        'name': m.get('parameter_name', code),
                        'total': 0,
                        'ooc_count': 0,
                    }

                param_stats[code]['total'] += 1
                if m.get('status') == 'out_of_spec':
                    param_stats[code]['ooc_count'] += 1

        # Calculate OOC rate and sort
        results = []
        for code, stats in param_stats.items():
            if stats['total'] > 0:
                stats['ooc_rate'] = round((stats['ooc_count'] / stats['total']) * 100, 2)
            else:
                stats['ooc_rate'] = 0.0
            results.append(stats)

        results.sort(key=lambda x: x['ooc_rate'], reverse=True)
        results = results[:20]  # Top 20

        return Response({'parameters': results})


class DailyCompletedReportsView(APIView):
    """
    GET /api/analytics/daily-completed-reports/
    Returns ONLY 100% completed daily reports (all required 11 inspection slots: 1PC#1..#3 + 1..8/HR).
    Excludes drafts, in-progress, pending, partially completed, or rejected sessions.
    """
    permission_classes = [HasAccess]
    access_key = 'production.daily.view'

    def get(self, request):
        start_date     = request.query_params.get('start_date') or request.query_params.get('from')
        end_date       = request.query_params.get('end_date') or request.query_params.get('to')
        machine_code   = request.query_params.get('machine')
        part_number    = request.query_params.get('part')
        shift          = request.query_params.get('shift')
        operator_name  = request.query_params.get('operator')
        inspector_name = request.query_params.get('inspector')

        qs = InspectionSession.objects.select_related(
            'machine', 'part', 'operator', 'supervisor', 'finalized_by'
        ).all()

        # Strict completion filter
        from django.db.models import F
        qs = qs.filter(
            Q(status__in=['completed', 'finalized_passed', 'approved']) |
            Q(is_setup_approved=True, hourly_unlocked_slot__gte=F('machine__plant__factory__shift_hours'))
        ).exclude(
            status__in=['draft', 'in_progress', 'pending_review', 'rejected', 'finalized_failed']
        )

        from apps.machines.models import Factory
        from datetime import datetime, timedelta
        
        factory = Factory.objects.first()
        shift_1_start = factory.shift_1_start if (factory and factory.shift_1_start) else None

        if start_date:
            if shift_1_start:
                try:
                    dt = datetime.strptime(start_date, '%Y-%m-%d')
                    dt = dt.replace(hour=shift_1_start.hour, minute=shift_1_start.minute)
                    qs = qs.filter(started_at__gte=dt)
                except ValueError:
                    qs = qs.filter(started_at__date__gte=start_date)
            else:
                qs = qs.filter(started_at__date__gte=start_date)
                
        if end_date:
            if shift_1_start:
                try:
                    dt = datetime.strptime(end_date, '%Y-%m-%d')
                    dt = dt + timedelta(days=1)
                    dt = dt.replace(hour=shift_1_start.hour, minute=shift_1_start.minute)
                    qs = qs.filter(started_at__lt=dt)
                except ValueError:
                    qs = qs.filter(started_at__date__lte=end_date)
            else:
                qs = qs.filter(started_at__date__lte=end_date)
                
        if machine_code:
            qs = qs.filter(machine__machine_code__icontains=machine_code.strip())
        if part_number:
            qs = qs.filter(part__part_number__icontains=part_number.strip())
        if shift:
            qs = qs.filter(shift=shift)
        if operator_name:
            qs = qs.filter(
                Q(operator__username__icontains=operator_name.strip()) |
                Q(operator__first_name__icontains=operator_name.strip()) |
                Q(operator__last_name__icontains=operator_name.strip())
            )
        if inspector_name:
            qs = qs.filter(
                Q(finalized_by__username__icontains=inspector_name.strip()) |
                Q(finalized_by__first_name__icontains=inspector_name.strip()) |
                Q(finalized_by__last_name__icontains=inspector_name.strip()) |
                Q(supervisor__username__icontains=inspector_name.strip()) |
                Q(supervisor__first_name__icontains=inspector_name.strip()) |
                Q(supervisor__last_name__icontains=inspector_name.strip())
            )

        # A daily card may be represented by the latest hourly session, while
        # the supervisor and inspector are recorded on the First Piece session.
        # Keep the First Piece identity available so names are not incorrectly
        # substituted with the operator name.
        first_piece_by_key = {}
        for row in qs.order_by('-started_at'):
            row_date = row.started_at.strftime('%d %b %Y') if row.started_at else ''
            row_key = (
                row_date,
                row.machine.machine_code if row.machine else '',
                row.part.part_number if row.part else '',
                row.shift,
            )
            if row.inspection_type == 'first_piece' and row_key not in first_piece_by_key:
                first_piece_by_key[row_key] = row

        seen_keys = set()
        reports = []
        for s in qs.order_by('-started_at'):
            date_str = s.started_at.strftime('%d %b %Y') if s.started_at else ''
            key = (date_str, s.machine.machine_code if s.machine else '', s.part.part_number if s.part else '', s.shift)
            if key in seen_keys:
                continue
            seen_keys.add(key)

            first_piece = first_piece_by_key.get(key)
            operator_full = (
                (s.operator.get_full_name() or s.operator.username).strip()
                if s.operator else '-'
            )
            supervisor_user = (first_piece.supervisor if first_piece else None) or s.supervisor
            inspector_user = (first_piece.finalized_by if first_piece else None) or s.finalized_by
            supervisor_full = (
                (supervisor_user.get_full_name() or supervisor_user.username).strip()
                if supervisor_user else '-'
            )
            inspector_full = (
                (inspector_user.get_full_name() or inspector_user.username).strip()
                if inspector_user else '-'
            )

            reports.append({
                'report_id': str(s.session_id),
                'session_id': str(s.session_id),
                'date': date_str,
                'raw_date': s.started_at.isoformat() if s.started_at else '',
                'machine': s.machine.machine_code if s.machine else '-',
                'part': f"{s.part.part_number} ({s.part.part_name})" if s.part and s.part.part_name else (s.part.part_number if s.part else '-'),
                'part_number': s.part.part_number if s.part else '',
                'shift': s.shift or 'A',
                'operator': operator_full,
                'supervisor': supervisor_full,
                'inspector': inspector_full,
                'status': 'Completed',
                'pdf_url': f"/api/inspections/{s.session_id}/pdf/",
            })

        return Response({'reports': reports})


class MonthlyOEEReportView(APIView):
    """
    GET /api/analytics/oee-report/export/?machine=VMC-19&year=2026&month=9
    Generates and returns the Monthly OEE Excel Report.
    """
    permission_classes = [HasAccess]
    access_key = 'quality.analytics.view'

    def get(self, request):
        machine_code = request.query_params.get('machine')
        year_str = request.query_params.get('year')
        month_str = request.query_params.get('month')

        if not all([machine_code, year_str, month_str]):
            return Response(
                {"error": "machine, year, and month parameters are required."},
                status=400
            )

        try:
            year = int(year_str)
            month = int(month_str)
        except ValueError:
            return Response(
                {"error": "year and month must be valid integers."},
                status=400
            )

        from apps.analytics.oee_excel_generator import generate_monthly_oee_excel
        from django.http import HttpResponse
        
        try:
            excel_buffer = generate_monthly_oee_excel(machine_code, year, month)
            
            response = HttpResponse(
                excel_buffer,
                content_type='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
            )
            filename = f"OEE_Report_{machine_code}_{year}_{month:02d}.xlsx"
            response['Content-Disposition'] = f'attachment; filename="{filename}"'
            return response
            
        except Exception as e:
            return Response({"error": f"Failed to generate report: {str(e)}"}, status=500)


class OEEDataAPIView(APIView):
    """
    GET /api/analytics/oee-report/data/?machine=VMC-19&year=2026&month=9
    Returns the calculated OEE data in JSON format for the frontend viewer.
    """
    permission_classes = [HasAccess]
    access_key = 'quality.analytics.view'

    def get(self, request):
        machine_code = request.query_params.get('machine')
        year_str = request.query_params.get('year')
        month_str = request.query_params.get('month')

        if not all([machine_code, year_str, month_str]):
            return Response(
                {"error": "machine, year, and month parameters are required."},
                status=400
            )

        try:
            year = int(year_str)
            month = int(month_str)
        except ValueError:
            return Response(
                {"error": "year and month must be valid integers."},
                status=400
            )
            
        from apps.inspections.models import DailyProductionReport
        from apps.machines.models import Machine
        from apps.parts.models import InspectionTemplate
        import calendar

        machine = Machine.objects.filter(machine_code=machine_code).first()
        reports = DailyProductionReport.objects.filter(
            machine__machine_code=machine_code,
            date__year=year,
            date__month=month,
            status=DailyProductionReport.Status.SUBMITTED
        ).select_related('downtime_report', 'part').order_by('date', 'shift')

        part_ids = {r.part_id for r in reports if r.part_id}
        templates = InspectionTemplate.objects.filter(part_id__in=part_ids)
        template_map = {}
        for t in templates:
            template_map[(t.part_id, t.name)] = t
            if (t.part_id, None) not in template_map:
                template_map[(t.part_id, None)] = t

        reports_dict = {}
        for r in reports:
            reports_dict[(r.date.day, r.shift)] = r
            
        num_days = calendar.monthrange(year, month)[1]

        default_available = 480
        total_shifts_per_day = 3
        if machine and machine.plant:
            if hasattr(machine.plant, 'factory') and machine.plant.factory:
                fac = machine.plant.factory
                if fac.shift_hours:
                    default_available = fac.shift_hours * 60
                if fac.total_shifts_per_day:
                    total_shifts_per_day = fac.total_shifts_per_day
            elif machine.plant.shift_duration_hours:
                default_available = machine.plant.shift_duration_hours * 60
                if machine.plant.shift_duration_hours > 0:
                    total_shifts_per_day = 24 // machine.plant.shift_duration_hours

        dynamic_shifts_list = ['I', 'II', 'III', 'IV'][:total_shifts_per_day]

        data = []
        import uuid
        from datetime import date
        for day in range(1, num_days + 1):
            date_obj = date(year, month, day)
            date_str = date_obj.strftime("%Y-%m-%d")
            
            for shift_val in dynamic_shifts_list:
                report = reports_dict.get((day, shift_val))
                
                available_time = default_available
                planned_downtime = 0
                cycle_time = 0.0
                
                if report:
                    planned_downtime = 60
                    if machine and machine.plant:
                        if hasattr(machine.plant, 'factory') and machine.plant.factory and machine.plant.factory.shift_hours:
                            fac = machine.plant.factory
                            planned_downtime = fac.lunch_break_minutes + fac.tea_break_minutes
                        elif machine.plant.shift_duration_hours:
                            planned_downtime = machine.plant.total_break_mins or 0
                            
                    if report.part_id:
                        template = template_map.get((report.part_id, report.operation)) or template_map.get((report.part_id, None))
                        if template and getattr(template, 'cycle_time_mins', 0) > 0:
                            cycle_time = template.cycle_time_mins
                else:
                    planned_downtime = 60
                    if machine and machine.plant:
                        if hasattr(machine.plant, 'factory') and machine.plant.factory and machine.plant.factory.shift_hours:
                            fac = machine.plant.factory
                            planned_downtime = fac.lunch_break_minutes + fac.tea_break_minutes
                        elif machine.plant.shift_duration_hours:
                            planned_downtime = machine.plant.total_break_mins or 0
                
                net_available = available_time - planned_downtime
                
                if report:
                    dt = getattr(report, 'downtime_report', None)
                    st = dt.setting if dt and dt.setting else 0
                    nl = dt.no_load if dt and dt.no_load else 0
                    no = dt.no_operator if dt and dt.no_operator else 0
                    mm = dt.um if dt and dt.um else 0
                    ow = dt.inspection_wait if dt and dt.inspection_wait else 0
                    pf = dt.power_off if dt and dt.power_off else 0
                    hidden = (dt.tool_change or 0) + (dt.rework or 0) + (dt.tool_problem or 0) if dt else 0
                    downtime_losses = dt.total_downtime if dt and dt.total_downtime else (st + nl + no + mm + ow + pf + hidden)
                    total_qty = report.jobs_completed or 0
                    rejection = report.incorrect_jobs or 0
                else:
                    st = nl = no = mm = ow = pf = downtime_losses = 0
                    total_qty = 0
                    rejection = 0
                
                operating_time = net_available - downtime_losses
                
                availability = operating_time / net_available if net_available > 0 else 0
                performance = (total_qty * cycle_time) / operating_time if operating_time > 0 else 0
                quality_rate = (total_qty - rejection) / total_qty if total_qty > 0 else 0
                oee = availability * performance * quality_rate
                
                data.append({
                    "id": report.id if report else str(uuid.uuid4()),
                    "shift": shift_val,
                    "date": date_str,
                    "available_time": available_time,
                    "planned_downtime": planned_downtime,
                    "net_available": net_available,
                    "downtime_losses": downtime_losses,
                    "downtimes": {
                        "st": st, "nl": nl, "no": no, "mm": mm, "ow": ow, "pf": pf
                    },
                    "operating_time": operating_time,
                    "availability": round(availability * 100, 2),
                    "total_qty": total_qty,
                    "cycle_time": round(cycle_time, 5),
                    "performance": round(performance * 100, 2),
                    "rejection": rejection,
                    "quality_rate": round(quality_rate * 100, 2),
                    "oee": round(oee * 100, 2)
                })

        return Response({
            "machine": machine_code,
            "month": month,
            "year": year,
            "month_name": calendar.month_name[month],
            "data": data
        })
