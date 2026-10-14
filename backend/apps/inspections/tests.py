from django.test import TestCase
from rest_framework.test import APITestCase
from rest_framework import status
from django.contrib.auth import get_user_model
from apps.machines.models import Machine
from apps.parts.models import Part
from apps.inspections.models import DailyProductionReport, DowntimeReport

User = get_user_model()


class DowntimeReportTestCase(TestCase):
    def setUp(self):
        self.supervisor = User.objects.create_user(username='sup1', password='pass123', role='supervisor')
        self.operator1 = User.objects.create_user(username='sa', first_name='Sa', password='pass123', role='operator')
        self.operator2 = User.objects.create_user(username='shahid', first_name='Shahid', password='pass123', role='operator')

        self.machine1 = Machine.objects.create(machine_code='CNC-01', name='CNC Lathe 1', status='active')
        self.machine2 = Machine.objects.create(machine_code='CNC-02', name='CNC Lathe 2', status='active')

        self.part = Part.objects.create(machine=self.machine1, part_number='P-001', part_name='Shaft')

        # Submitted Production Report 1
        self.prod1 = DailyProductionReport.objects.create(
            date='2026-08-29',
            shift='General',
            machine=self.machine1,
            part=self.part,
            operator=self.operator1,
            production_target=60,
            jobs_completed=50,
            correct_jobs=45,
            incorrect_jobs=5,
            cr_count=2,
            mr_count=1,
            rw_count=2,
            status=DailyProductionReport.Status.SUBMITTED
        )

        # Submitted Production Report 2
        self.prod2 = DailyProductionReport.objects.create(
            date='2026-08-29',
            shift='General',
            machine=self.machine2,
            part=self.part,
            operator=self.operator2,
            production_target=70,
            jobs_completed=65,
            correct_jobs=60,
            incorrect_jobs=5,
            cr_count=1,
            mr_count=2,
            rw_count=2,
            status=DailyProductionReport.Status.SUBMITTED
        )

        # Draft Production Report (Should NOT appear in Downtime Reports)
        self.prod_draft = DailyProductionReport.objects.create(
            date='2026-08-29',
            shift='General',
            machine=self.machine1,
            part=self.part,
            operator=self.operator1,
            production_target=50,
            jobs_completed=10,
            correct_jobs=10,
            incorrect_jobs=0,
            status=DailyProductionReport.Status.DRAFT
        )

    def test_total_downtime_calculation(self):
        downtime = DowntimeReport.objects.create(
            production_report=self.prod1,
            no_load=10,
            no_operator=0,
            um=5,
            setting=10,
            inspection_wait=5,
            tool_change=8,
            power_off=0,
            rework=3,
            tool_problem=4,
            remarks='Tool replacement required'
        )
        self.assertEqual(downtime.total_downtime, 45)

    def test_one_to_one_constraint(self):
        DowntimeReport.objects.create(production_report=self.prod1, no_load=10)
        from django.db import IntegrityError
        with self.assertRaises(IntegrityError):
            DowntimeReport.objects.create(production_report=self.prod1, no_load=20)

    def test_negative_value_validation(self):
        from django.core.exceptions import ValidationError
        dt = DowntimeReport(production_report=self.prod2, no_load=-10)
        with self.assertRaises(ValidationError):
            dt.full_clean()


class DowntimeReportApiTestCase(APITestCase):
    def setUp(self):
        self.supervisor = User.objects.create_user(username='sup1', password='pass123', role='supervisor')
        self.operator1 = User.objects.create_user(username='sa', first_name='Sa', password='pass123', role='operator')
        self.operator2 = User.objects.create_user(username='shahid', first_name='Shahid', password='pass123', role='operator')

        self.machine1 = Machine.objects.create(machine_code='CNC-01', name='CNC Lathe 1', status='active')
        self.machine2 = Machine.objects.create(machine_code='CNC-02', name='CNC Lathe 2', status='active')

        self.part = Part.objects.create(machine=self.machine1, part_number='P-001', part_name='Shaft')

        self.prod1 = DailyProductionReport.objects.create(
            date='2026-08-29',
            shift='General',
            machine=self.machine1,
            part=self.part,
            operator=self.operator1,
            production_target=60,
            jobs_completed=50,
            correct_jobs=45,
            incorrect_jobs=5,
            cr_count=2,
            mr_count=1,
            rw_count=2,
            status=DailyProductionReport.Status.SUBMITTED
        )

        self.prod2 = DailyProductionReport.objects.create(
            date='2026-08-29',
            shift='General',
            machine=self.machine2,
            part=self.part,
            operator=self.operator2,
            production_target=70,
            jobs_completed=65,
            correct_jobs=60,
            incorrect_jobs=5,
            cr_count=1,
            mr_count=2,
            rw_count=2,
            status=DailyProductionReport.Status.SUBMITTED
        )

        self.prod_draft = DailyProductionReport.objects.create(
            date='2026-08-29',
            shift='General',
            machine=self.machine1,
            part=self.part,
            operator=self.operator1,
            production_target=50,
            jobs_completed=10,
            correct_jobs=10,
            status=DailyProductionReport.Status.DRAFT
        )

        self.client.force_authenticate(user=self.supervisor)

    def test_get_downtime_reports_excludes_drafts(self):
        url = '/api/inspections/downtime-reports/?date=2026-08-29&shift=General'
        response = self.client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data.get('results', response.data)
        # Should contain only 2 submitted reports, draft report is excluded
        self.assertEqual(len(results), 2)
        operators = [r['operator_name'] for r in results]
        self.assertIn('Sa', operators)
        self.assertIn('Shahid', operators)

    def test_operator_data_mapping_isolation(self):
        url = '/api/inspections/downtime-reports/?date=2026-08-29&shift=General'
        response = self.client.get(url)
        results = response.data.get('results', response.data)

        # Check row 1: CNC-01 must belong to Sa with 60 target
        row1 = next(r for r in results if r['machine_code'] == 'CNC-01')
        self.assertEqual(row1['operator_name'], 'Sa')
        self.assertEqual(row1['target'], 60)
        self.assertEqual(row1['produced'], 50)
        self.assertEqual(row1['accepted_actual'], 45)

        # Check row 2: CNC-02 must belong to Shahid with 70 target
        row2 = next(r for r in results if r['machine_code'] == 'CNC-02')
        self.assertEqual(row2['operator_name'], 'Shahid')
        self.assertEqual(row2['target'], 70)
        self.assertEqual(row2['produced'], 65)

    def test_bulk_save_downtime_entries(self):
        url = '/api/inspections/downtime-reports/bulk_save/'
        payload = [
            {
                "production_report_id": self.prod1.id,
                "no_load": 10,
                "no_operator": 0,
                "um": 5,
                "setting": 10,
                "inspection_wait": 5,
                "tool_change": 8,
                "power_off": 0,
                "rework": 3,
                "tool_problem": 4,
                "remarks": "Sa Downtime",
                "mark_completed": True
            },
            {
                "production_report_id": self.prod2.id,
                "no_load": 15,
                "no_operator": 5,
                "um": 0,
                "setting": 0,
                "inspection_wait": 0,
                "tool_change": 0,
                "power_off": 0,
                "rework": 0,
                "tool_problem": 0,
                "remarks": "Shahid Downtime",
                "mark_completed": True
            }
        ]
        response = self.client.post(url, payload, format='json')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        
        # Verify persisted calculations
        dt1 = DowntimeReport.objects.get(production_report=self.prod1)
        self.assertEqual(dt1.total_downtime, 45)
        self.assertEqual(dt1.status, 'COMPLETED')
        self.assertEqual(dt1.remarks, 'Sa Downtime')

        dt2 = DowntimeReport.objects.get(production_report=self.prod2)
        self.assertEqual(dt2.total_downtime, 20)
        self.assertEqual(dt2.status, 'COMPLETED')
        self.assertEqual(dt2.remarks, 'Shahid Downtime')

    def test_daily_report_retry_is_idempotent(self):
        payload = {
            'idempotency_key': 'mobile-retry-001',
            'date': '2026-08-30',
            'machine': self.machine1.id,
            'part': self.part.id,
            'operation': 'Facing',
            'shift': 'I',
            'jobs_completed': 10,
            'correct_jobs': 10,
            'incorrect_jobs': 0,
            'cr_count': 0,
            'mr_count': 0,
            'rw_count': 0,
        }
        first = self.client.post('/api/inspections/daily-production-reports/', payload, format='json')
        retry = self.client.post('/api/inspections/daily-production-reports/', payload, format='json')

        self.assertEqual(first.status_code, status.HTTP_201_CREATED)
        self.assertEqual(retry.status_code, status.HTTP_200_OK)
        self.assertEqual(first.data['id'], retry.data['id'])
        self.assertEqual(
            DailyProductionReport.objects.filter(idempotency_key='mobile-retry-001').count(),
            1,
        )
