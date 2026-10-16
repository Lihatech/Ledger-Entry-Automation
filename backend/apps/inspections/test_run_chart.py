from decimal import Decimal
from io import BytesIO

import openpyxl

from django.urls import reverse
from rest_framework.test import APITestCase

from apps.machines.models import Factory, Plant, Machine
from apps.parts.models import Part, InspectionTemplate, InspectionParameter
from apps.users.models import AccessRole, User

from .models import RunChartReport, RunChartReading


class RunChartAPITests(APITestCase):
    def setUp(self):
        role, _ = AccessRole.objects.update_or_create(
            slug='operator',
            defaults={
                'name': 'Operator',
                'permissions': ['quality.inspections.record'],
                'is_system': True,
            },
        )
        self.user = User.objects.create_user(
            username='run-chart-operator',
            email='operator@example.com',
            password='test-password',
            employee_id='RC-OP-1',
            role=role.slug,
        )
        self.client.force_authenticate(self.user)
        factory = Factory.objects.create(name='Factory', code='RC-FAC')
        plant = Plant.objects.create(factory=factory, name='Plant', code='RC-PLANT')
        self.machine = Machine.objects.create(
            plant=plant, name='CNC Lathe', machine_code='RC-CNC-01'
        )
        self.part = Part.objects.create(
            machine=self.machine,
            part_number='RC-PART-01',
            part_name='Run Chart Part',
            created_by=self.user,
        )
        self.template = InspectionTemplate.objects.create(
            part=self.part,
            name='OP-10 Turning',
            # Run Chart is piece-level 100% inspection and must support the
            # same published Master Database operations used for first-piece
            # inspection, not only hourly templates.
            inspection_type=InspectionTemplate.InspectionType.FIRST_PIECE,
            version=1,
            is_active=True,
            is_published=True,
            status=InspectionTemplate.Status.APPROVED,
            created_by=self.user,
        )
        self.parameter = InspectionParameter.objects.create(
            template=self.template,
            parameter_name='Bore Diameter',
            parameter_code='BD-01',
            unit='mm',
            nominal_value=Decimal('20.0000'),
            upper_tolerance=Decimal('0.0150'),
            lower_tolerance=Decimal('-0.0150'),
            is_critical=True,
            sequence_order=1,
        )

    def test_operator_can_open_report_and_append_piece_readings(self):
        operations = self.client.get(
            reverse('run-chart-operations', kwargs={'machine_id': self.machine.id})
        )
        self.assertEqual(operations.status_code, 200)
        self.assertEqual(operations.data[0]['id'], self.template.id)

        parameters = self.client.get(
            reverse('run-chart-parameters', kwargs={'template_id': self.template.id})
        )
        self.assertEqual(parameters.status_code, 200)
        self.assertEqual(parameters.data[0]['id'], self.parameter.id)

        opened = self.client.post(
            reverse('run-chart-open-report'),
            {
                'machine_id': self.machine.id,
                'template_id': self.template.id,
                'parameter_id': self.parameter.id,
                'shift': 'I',
            },
            format='json',
        )
        self.assertEqual(opened.status_code, 200)
        self.assertEqual(opened.data['next_piece_number'], 1)
        report_id = opened.data['report_id']

        first = self.client.post(
            reverse('run-chart-reading-create', kwargs={'report_id': report_id}),
            {'piece_number': 1, 'measured_value': 20.000},
            format='json',
        )
        self.assertEqual(first.status_code, 201)
        self.assertEqual(first.data['reading']['zone'], RunChartReading.Zone.GREEN)

        # Warning zones begin at the midpoint between nominal and each limit.
        # With a 19.985–20.015 tolerance, 20.008 is in the upper yellow zone.
        warning = self.client.post(
            reverse('run-chart-reading-create', kwargs={'report_id': report_id}),
            {'piece_number': 2, 'measured_value': 20.008},
            format='json',
        )
        self.assertEqual(warning.status_code, 201)
        self.assertEqual(warning.data['reading']['zone'], RunChartReading.Zone.YELLOW)

        second = self.client.post(
            reverse('run-chart-reading-create', kwargs={'report_id': report_id}),
            {'piece_number': 3, 'measured_value': 20.020},
            format='json',
        )
        self.assertEqual(second.status_code, 201)
        self.assertEqual(second.data['reading']['zone'], RunChartReading.Zone.RED)
        self.assertEqual(second.data['alert'], 'stop_process')

        self.assertEqual(RunChartReport.objects.count(), 1)
        self.assertEqual(RunChartReading.objects.count(), 3)
        self.assertEqual(
            list(RunChartReading.objects.values_list('piece_number', flat=True)),
            [1, 2, 3],
        )

    def test_piece_sequence_cannot_be_skipped_or_overwritten(self):
        opened = self.client.post(
            reverse('run-chart-open-report'),
            {
                'machine_id': self.machine.id,
                'template_id': self.template.id,
                'parameter_id': self.parameter.id,
                'shift': 'I',
            },
            format='json',
        )
        report_id = opened.data['report_id']
        skipped = self.client.post(
            reverse('run-chart-reading-create', kwargs={'report_id': report_id}),
            {'piece_number': 2, 'measured_value': 20.000},
            format='json',
        )
        self.assertEqual(skipped.status_code, 409)
        self.assertEqual(RunChartReading.objects.count(), 0)

    def test_pdf_download_contains_report(self):
        opened = self.client.post(
            reverse('run-chart-open-report'),
            {
                'machine_id': self.machine.id,
                'template_id': self.template.id,
                'parameter_id': self.parameter.id,
                'shift': 'I',
            },
            format='json',
        )
        response = self.client.get(
            reverse('run-chart-pdf', kwargs={'report_id': opened.data['report_id']})
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response['Content-Type'], 'application/pdf')

    def test_excel_download_matches_official_run_chart_layout(self):
        opened = self.client.post(
            reverse('run-chart-open-report'),
            {
                'machine_id': self.machine.id,
                'template_id': self.template.id,
                'parameter_id': self.parameter.id,
                'shift': 'I',
            },
            format='json',
        )
        report_id = opened.data['report_id']
        self.client.post(
            reverse('run-chart-reading-create', kwargs={'report_id': report_id}),
            {'piece_number': 1, 'measured_value': 20.000},
            format='json',
        )
        response = self.client.get(
            reverse('run-chart-xlsx', kwargs={'report_id': report_id})
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response['Content-Type'],
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        )
        content = b''.join(response.streaming_content)
        workbook = openpyxl.load_workbook(BytesIO(content), data_only=False)
        sheet = workbook['Run Chart']
        self.assertEqual(sheet['K2'].value, 'Run Chart  (Stop Light Control Chart)')
        self.assertIn('RC-PART-01', sheet['B3'].value)
        self.assertIn('Bore Diameter', sheet['K3'].value)
        self.assertEqual(sheet['C37'].value, 1)
        self.assertEqual(sheet['C21'].value, '●')
        self.assertEqual(sheet['C7'].fill.fgColor.rgb, 'FFFF0000')
        self.assertEqual(sheet['C11'].fill.fgColor.rgb, 'FFFFFF00')
        self.assertEqual(sheet['C15'].fill.fgColor.rgb, 'FFA8D348')
        self.assertIn('Sample Freq : 100%', sheet['AA3'].value)
        workbook.close()
