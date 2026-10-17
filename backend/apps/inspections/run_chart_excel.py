"""Generate the official stop-light run-chart workbook."""

from io import BytesIO
from math import ceil

import openpyxl
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.chart import ScatterChart, Reference, Series
from openpyxl.chart.shapes import GraphicalProperties
from openpyxl.drawing.spreadsheet_drawing import AnchorMarker, TwoCellAnchor
from .run_chart_logic import warning_boundaries


JOBS_PER_SHEET = 33
MAX_EXPORT_READINGS = 1000
RED = 'FFFF0000'
YELLOW = 'FFFFFF00'
GREEN = 'FFA8D348'
WHITE = 'FFFFFFFF'
BLACK = 'FF000000'

PROCESS_RULES = (
    'प्रोसेस कंट्रोल बाबतचे नियम (प्रोसेस कंट्रोल चार्ट रेग्युलेशन)\n'
    '1. First Piece ची साइज मिनिमम असावी. तसे नसल्यास साइज सेट करून प्रोसेस correct करून साइज मिन जॉब सेट करा.\n'
    '2. कोणत्याही एका जॉबच्या साइज लाल झोनमध्ये गेल्यास प्रोडक्शन थांबवा व सुपरवायझर कडून प्रोसेस correct करून घ्या.\n'
    '3. सलग पाच जॉब पैकी कोणतीही तीन जॉब पिवळ्या झोनमध्ये गेल्यास प्रोडक्शन थांबवा व सुपरवायझर कडून प्रोसेस correct करून घ्या.\n'
    '4. मशीन सेटिंग्स व टूल बदलानंतर साइज तीन जॉब तपासा. साइज कंट्रोल दिसेपर्यंत जॉब चालू ठेवू नका.\n'
    '5. एका प्लेटमध्ये एका पेक्षा अधिक जॉब असले तरी वरील नियम पाळणे.'
)


def _display_name(user):
    return (
        getattr(user, 'display_name', '')
        or getattr(user, 'get_full_name', lambda: '')()
        or getattr(user, 'username', '')
    )


def _company_name(report):
    plant = getattr(report.machine, 'plant', None)
    factory = getattr(plant, 'factory', None) if plant else None
    return (getattr(factory, 'name', '') or 'SAPOTECH COMPONENTS PVT. LTD.').upper()


def _safe_excel_text(value):
    text = str(value or '')
    return "'" + text if text.startswith(('=', '+', '-', '@')) else text


def _format_number(value):
    return f'{float(value):.6f}'.rstrip('0').rstrip('.')


def _reading_row(report, measured_value):
    """Map a measured value to the template's 15-up/15-down division grid."""
    value = float(measured_value)
    nominal = float(report.nominal_value)
    lower = float(report.lower_limit)
    upper = float(report.upper_limit)
    span = max(upper - lower, 1e-12)
    # The grid is a single numeric axis from lower to upper.  This keeps
    # asymmetric tolerances aligned with the Excel chart and mobile painter.
    row_index = int(round((upper - value) / span * 29))
    # Keep strictly in-spec values out of the red boundary rows.  A value on
    # or beyond a limit is allowed to occupy the red row itself.
    if value < upper:
        row_index = max(1, row_index)
    if value > lower:
        row_index = min(28, row_index)
    return 7 + max(0, min(29, row_index))


def _zone_color_for_row(report, row_index):
    """Return the dynamic display colour for one of the 30 chart rows."""
    if row_index in (0, 29):
        return RED
    lower = float(report.lower_limit)
    nominal = float(report.nominal_value)
    upper = float(report.upper_limit)
    span = max(upper - lower, 1e-12)
    value = upper - ((row_index + 0.5) / 30.0) * span
    lower_mid, upper_mid = map(float, warning_boundaries(
        report.lower_limit, report.nominal_value, report.upper_limit,
        getattr(report.parameter, 'measurement_type', 'dimensional'),
    ))
    if value <= lower or value >= upper:
        return RED
    if value <= lower_mid or value >= upper_mid:
        return YELLOW
    return GREEN


def _apply_border(ws, cell_range, side):
    for row in ws[cell_range]:
        for cell in row:
            cell.border = Border(left=side, right=side, top=side, bottom=side)


def _build_sheet(ws, report, readings, page_number, page_count):
    ws.title = 'Run Chart' if page_number == 1 else f'Run Chart {page_number}'
    ws.sheet_view.showGridLines = False
    ws.freeze_panes = None
    ws.print_area = 'A1:AJ42'
    ws.page_setup.orientation = ws.ORIENTATION_LANDSCAPE
    ws.page_setup.paperSize = ws.PAPERSIZE_A3
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    ws.page_setup.fitToWidth = 1
    ws.page_setup.fitToHeight = 1
    ws.page_margins.left = 0.236
    ws.page_margins.right = 0.236
    ws.page_margins.top = 0.315
    ws.page_margins.bottom = 0.315

    for column in range(1, 37):
        ws.column_dimensions[get_column_letter(column)].width = 13
    ws.column_dimensions['A'].width = 5
    # Every plotted job column must have the same width. The source template
    # uses narrow K/V columns for header alignment, but those columns are also
    # part of the 33-job chart grid and must not shrink there.
    ws.column_dimensions['AJ'].width = 9.43

    heights = {1: 7.15, 2: 31.9, 3: 22.15, 4: 22.15, 5: 22.15, 6: 7.15, 37: 22.15, 42: 37.5}
    for row in range(7, 37):
        heights[row] = 15
    for row in range(38, 42):
        heights[row] = 24
    for row, height in heights.items():
        ws.row_dimensions[row].height = height

    merges = [
        'B2:J2', 'K2:U2', 'V2:AI2',
        'B3:J3', 'K3:O3', 'P3:U3', 'V3:Z3', 'AA3:AI3',
        'B4:J4', 'K4:O4', 'P4:U4', 'V4:Z4', 'AA4:AI4',
        'B5:J5', 'K5:O5', 'P5:U5', 'V5:Z5', 'AA5:AI5',
        'A7:A36',
        'A37:B37', 'A38:U41', 'V38:AJ41',
        'B42:J42', 'K42:U42', 'V42:AJ42',
    ]
    thin = Side(style='thin', color=BLACK)
    medium = Side(style='medium', color=BLACK)
    _apply_border(ws, 'B2:AJ5', thin)
    _apply_border(ws, 'A7:AJ37', thin)
    _apply_border(ws, 'A38:AJ41', thin)
    _apply_border(ws, 'A42:AJ42', thin)
    for cell_range in merges:
        ws.merge_cells(cell_range)

    ws['B2'] = _safe_excel_text(_company_name(report))
    ws['K2'] = 'Run Chart  (Stop Light Control Chart)'
    ws['V2'] = f'Page : {page_number} / {page_count}'
    ws['B3'] = _safe_excel_text(f'Part Name : {report.part.part_number} - {report.part.part_name}')
    ws['K3'] = _safe_excel_text(f'Characteristic : {report.parameter_name}')
    ws['V3'] = _safe_excel_text(f'Machine: {report.machine.machine_code} - {report.machine.name}')
    ws['AA3'] = 'Sample Freq : 100%'
    ws['B4'] = _safe_excel_text(f'Operation : {report.template.name}')
    ws['K4'] = _safe_excel_text(f'Specification : {_format_number(report.lower_limit)} to {_format_number(report.upper_limit)} {report.unit}')
    ws['V4'] = f'Date/Shift: {report.report_date} / {report.shift}'
    ws['AA4'] = _safe_excel_text(f'Operator Name : {_display_name(report.operator)}')
    ws['B5'] = f'Lower Limit : {_format_number(report.lower_limit)} {report.unit}'
    ws['K5'] = f'Mean Size : {_format_number(report.nominal_value)} {report.unit}'
    ws['V5'] = f'Upper Limit : {_format_number(report.upper_limit)} {report.unit}'
    division = (float(report.upper_limit) - float(report.lower_limit)) / 30
    ws['AA5'] = f'1Div. = {_format_number(division)} {report.unit}'

    title_font = Font(name='Arial', size=14, bold=True)
    header_font = Font(name='Arial', size=10)
    ws['B2'].font = title_font
    ws['K2'].font = title_font
    for row in ws.iter_rows(min_row=2, max_row=5, min_col=2, max_col=35):
        for cell in row:
            if cell.coordinate not in {'B2', 'K2'}:
                cell.font = header_font
            cell.alignment = Alignment(vertical='center', horizontal='left')
    ws['K2'].alignment = Alignment(vertical='center', horizontal='center')
    ws['B2'].alignment = Alignment(vertical='center', horizontal='left')
    ws['AA5'].font = Font(name='Arial', size=10, bold=True)

    ws['A7'] = 'IN MICRONS'
    ws['A7'].font = Font(name='Arial', size=9, bold=True)
    ws['A7'].alignment = Alignment(horizontal='center', vertical='center', text_rotation=90)
    for index in range(15):
        ws.cell(7 + index, 2, 15 - index)
        ws.cell(22 + index, 2, index + 1)
    for row in range(7, 37):
        ws.cell(row, 2).font = Font(name='Arial', size=8)
        ws.cell(row, 2).alignment = Alignment(horizontal='center', vertical='center')

    # Match the bold black nominal line shown in the mobile report.
    for column in range(2, 37):
        ws.cell(21, column).border = Border(
            left=thin, right=thin, top=thin, bottom=medium
        )
        ws.cell(22, column).border = Border(
            left=thin, right=thin, top=medium, bottom=thin
        )

    row_colors = [_zone_color_for_row(report, row) for row in range(30)]
    for row, color in enumerate(row_colors, start=7):
        fill = PatternFill('solid', fgColor=color)
        for cell in ws.iter_rows(min_row=row, max_row=row, min_col=3, max_col=35):
            for item in cell:
                item.fill = fill

    # Merge and label the actual contiguous dynamic runs, not fixed template
    # ranges that become wrong when tolerances change.
    run_start = 0
    for row in range(1, 31):
        if row == 30 or row_colors[row] != row_colors[run_start]:
            start_excel, end_excel = 7 + run_start, 7 + row - 1
            cell_ref = f'AJ{start_excel}'
            if start_excel != end_excel:
                ws.merge_cells(f'AJ{start_excel}:AJ{end_excel}')
            color = row_colors[run_start]
            ws[cell_ref] = 'Red Zone' if color == RED else 'Yellow Zone' if color == YELLOW else 'Green Zone'
            ws[cell_ref].fill = PatternFill('solid', fgColor=color)
            ws[cell_ref].font = Font(name='Arial', size=9, italic=True)
            ws[cell_ref].alignment = Alignment(horizontal='center', vertical='center')
            run_start = row

    ws['A37'] = 'Job No.'
    ws['A37'].font = Font(name='Arial', size=10, bold=True)
    ws['A37'].alignment = Alignment(horizontal='center', vertical='center')
    for index, reading in enumerate(readings):
        column = 3 + index
        ws.cell(37, column, reading.piece_number)
        ws.cell(37, column).alignment = Alignment(horizontal='center', vertical='center')
        ws.cell(37, column).font = Font(name='Arial', size=8)
        marker = ws.cell(_reading_row(report, reading.measured_value), column)
        marker.value = '●'
        marker.font = Font(name='Arial', size=11, bold=True, color=BLACK)
        marker.alignment = Alignment(horizontal='center', vertical='center')

    _add_reading_line_chart(ws, report, readings)

    ws['A38'] = PROCESS_RULES
    ws['A38'].font = Font(name='Nirmala UI', size=9)
    ws['A38'].alignment = Alignment(horizontal='left', vertical='top', wrap_text=True)
    ws['V38'] = 'Remarks :'
    ws['V38'].font = Font(name='Arial', size=10)
    ws['V38'].alignment = Alignment(horizontal='left', vertical='top')
    ws['B42'] = _safe_excel_text(f'Inspected By: {_display_name(report.operator)}')
    ws['K42'] = 'SCPL/FT/PRD -  '
    ws['V42'] = 'Approved By: ____________________'
    for cell in ('B42', 'K42', 'V42'):
        ws[cell].font = Font(name='Arial', size=10)
        ws[cell].alignment = Alignment(horizontal='center', vertical='center')

    ws['B2'].border = Border(top=medium, bottom=thin, left=medium, right=thin)
    ws['AJ2'].border = Border(top=medium, bottom=thin, left=thin, right=medium)


def _add_reading_line_chart(ws, report, readings):
    """Overlay a transparent Excel line series on the 30-row cell grid."""
    if len(readings) < 2:
        return

    # Keep chart source data outside the printable A:AJ report area.
    x_column, y_column = 38, 39  # AL, AM
    for index, reading in enumerate(readings, start=1):
        ws.cell(index, x_column, index)
        ws.cell(index, y_column, float(reading.measured_value))
    ws.column_dimensions[get_column_letter(x_column)].hidden = True
    ws.column_dimensions[get_column_letter(y_column)].hidden = True

    chart = ScatterChart()
    chart.scatterStyle = 'lineMarker'
    chart.legend = None
    # The source values live in hidden helper columns so they do not disturb
    # the printable report. Excel must still plot hidden cells.
    chart.visible_cells_only = False
    chart.x_axis.scaling.min = 0.5
    chart.x_axis.scaling.max = JOBS_PER_SHEET + 0.5
    chart.y_axis.scaling.min = float(report.lower_limit)
    chart.y_axis.scaling.max = float(report.upper_limit)
    chart.x_axis.delete = True
    chart.y_axis.delete = True
    chart.graphicalProperties = GraphicalProperties(noFill=True)
    chart.plot_area.spPr = GraphicalProperties(noFill=True)

    x_values = Reference(ws, min_col=x_column, min_row=1, max_row=len(readings))
    y_values = Reference(ws, min_col=y_column, min_row=1, max_row=len(readings))
    series = Series(y_values, x_values)
    series.graphicalProperties.line.solidFill = BLACK[-6:]
    series.graphicalProperties.line.width = 22000
    series.marker.symbol = 'circle'
    series.marker.size = 5
    series.marker.graphicalProperties.solidFill = WHITE[-6:]
    series.marker.graphicalProperties.line.solidFill = BLACK[-6:]
    chart.series.append(series)
    # Anchor exactly to the plotted cell rectangle (C7:AI36), rather than
    # using a floating default-size chart that Excel renders as a small
    # selectable "Chart Area" box.
    chart.anchor = TwoCellAnchor(
        _from=AnchorMarker(col=2, row=6),
        to=AnchorMarker(col=35, row=36),
    )
    ws.add_chart(chart)


def generate_run_chart_xlsx(report):
    readings = list(
        report.readings.select_related('recorded_by').order_by('piece_number')
    )
    if len(readings) > MAX_EXPORT_READINGS:
        raise ValueError(f'Run chart export is limited to {MAX_EXPORT_READINGS} readings.')
    page_count = max(1, ceil(len(readings) / JOBS_PER_SHEET))
    workbook = openpyxl.Workbook()
    for page_index in range(page_count):
        worksheet = workbook.active if page_index == 0 else workbook.create_sheet()
        start = page_index * JOBS_PER_SHEET
        page_readings = readings[start:start + JOBS_PER_SHEET]
        _build_sheet(worksheet, report, page_readings, page_index + 1, page_count)

    buffer = BytesIO()
    workbook.save(buffer)
    workbook.close()
    buffer.seek(0)
    return buffer
