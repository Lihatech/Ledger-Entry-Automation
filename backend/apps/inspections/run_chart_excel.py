"""Generate the official stop-light run-chart workbook."""

from io import BytesIO
from math import ceil

import openpyxl
from PIL import Image, ImageDraw, ImageFont
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.drawing.image import Image as ExcelImage
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


def _add_reading_connections(ws, report, readings):
    """Render one aligned plot layer so points and line share coordinates."""
    if not readings:
        return

    # C:AI is the 33-column plotted area. These dimensions match the Excel
    # template's 13-character columns and 15-point chart rows closely enough
    # for the transparent line to sit on the cell centres.
    column_width = 91
    row_height = 20
    image = Image.new('RGB', (JOBS_PER_SHEET * column_width, 30 * row_height), 'white')
    draw = ImageDraw.Draw(image)

    lower = float(report.lower_limit)
    upper = float(report.upper_limit)
    span = max(upper - lower, 1e-12)
    color_map = {RED: '#EF4444', YELLOW: '#FEF08A', GREEN: '#A3D63F'}
    row_colors = [_zone_color_for_row(report, row) for row in range(30)]
    run_start = 0
    for row in range(1, 31):
        if row == 30 or row_colors[row] != row_colors[run_start]:
            start, end = run_start, row
            color = color_map[row_colors[run_start]]
            draw.rectangle(
                (0, start * row_height, JOBS_PER_SHEET * column_width, end * row_height),
                fill=color,
            )
            run_start = row
    for row in range(31):
        y = row * row_height
        draw.line((0, y, JOBS_PER_SHEET * column_width, y), fill='#111827', width=1)
    for column in range(JOBS_PER_SHEET + 1):
        x = column * column_width
        draw.line((x, 0, x, 30 * row_height), fill='#111827', width=1)

    nominal_row = int(round((upper - float(report.nominal_value)) / span * 29))
    draw.line(
        (0, (nominal_row + 1) * row_height, JOBS_PER_SHEET * column_width,
         (nominal_row + 1) * row_height),
        fill='#111827', width=3,
    )
    points = []
    for index, reading in enumerate(readings):
        row = _reading_row(report, reading.measured_value) - 7
        points.append((
            int((index + 0.5) * column_width),
            int((row + 0.5) * row_height),
        ))

    # Straight segments and markers are rendered in the same image, so they
    # cannot drift apart when Excel scales the image on screen.
    if len(points) > 1:
        draw.line(points, fill='#0F172A', width=3)
    marker_colors = {'green': '#0F766E', 'yellow': '#D97706', 'red': '#B91C1C'}
    for point, reading in zip(points, readings):
        radius = 5
        draw.ellipse(
            (point[0] - radius, point[1] - radius,
             point[0] + radius, point[1] + radius),
            fill='white', outline=marker_colors.get(str(reading.zone).lower(), '#0F766E'), width=2,
        )
    stream = BytesIO()
    image.save(stream, format='PNG')
    stream.seek(0)
    stream.name = 'run-chart-connections.png'
    excel_image = ExcelImage(stream)
    excel_image.width = JOBS_PER_SHEET * column_width
    excel_image.height = 30 * row_height
    ws.add_image(excel_image, 'C7')


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
        marker_colors = {'green': 'FF15803D', 'yellow': 'FFD97706', 'red': 'FFB91C1C'}
        marker.font = Font(
            name='Arial', size=11, bold=True,
            color=marker_colors.get(str(reading.zone).lower(), BLACK),
        )
        marker.alignment = Alignment(horizontal='center', vertical='center')

    _add_reading_connections(ws, report, readings)

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


def _add_reading_line_chart(ws, report, readings, anchor='C7', width=3000, height=900):
    """Embed the same stop-light graph style used by the mobile report.

    Excel's native chart canvas is opaque in several Excel versions, so a
    transparent ScatterChart can still hide the worksheet's coloured cells.
    Rendering the graph as a high-resolution image keeps the full red/yellow/
    green bands visible and makes the exported workbook match the mobile
    report reliably.
    """
    if not readings:
        return

    width, height = 3000, 900
    image = Image.new('RGB', (width, height), 'white')
    draw = ImageDraw.Draw(image)

    def font(size, bold=False):
        candidates = ('arialbd.ttf', 'Arial.ttf') if bold else ('arial.ttf',)
        for candidate in candidates:
            try:
                return ImageFont.truetype(candidate, size)
            except OSError:
                continue
        return ImageFont.load_default()

    left, top, right, bottom = 110, 45, width - 95, height - 90
    lower = float(report.lower_limit)
    nominal = float(report.nominal_value)
    upper = float(report.upper_limit)
    span = max(upper - lower, 1e-12)
    graph_min = lower - span * 0.15
    graph_max = upper + span * 0.15
    lower_mid, upper_mid = map(float, warning_boundaries(
        report.lower_limit, report.nominal_value, report.upper_limit,
        getattr(report.parameter, 'measurement_type', 'dimensional'),
    ))

    def y(value):
        value = max(graph_min, min(graph_max, float(value)))
        return int(bottom - ((value - graph_min) / (graph_max - graph_min)) * (bottom - top))

    # The bands run across the complete plot area, instead of being limited
    # to the right-side worksheet legend.
    bands = (
        (graph_min, lower, '#ef4444'),
        (lower, lower_mid, '#fde68a'),
        (lower_mid, upper_mid, '#bbf7d0'),
        (upper_mid, upper, '#fde68a'),
        (upper, graph_max, '#ef4444'),
    )
    for band_start, band_end, color in bands:
        draw.rectangle((left, y(band_end), right, y(band_start)), fill=color)

    # Light grid, followed by the three control lines.
    for index in range(11):
        grid_y = top + round(index * (bottom - top) / 10)
        draw.line((left, grid_y, right, grid_y), fill='#cbd5e1', width=2)
    count = max(len(readings), 1)
    for index in range(count):
        grid_x = left + round(index * (right - left) / max(count - 1, 1))
        draw.line((grid_x, top, grid_x, bottom), fill='#dbe4ee', width=1)
    draw.line((left, y(lower), right, y(lower)), fill='#dc2626', width=3)
    draw.line((left, y(upper), right, y(upper)), fill='#dc2626', width=3)
    draw.line((left, y(nominal), right, y(nominal)), fill='#111827', width=4)
    draw.rectangle((left, top, right, bottom), outline='#334155', width=3)

    # Straight segments and zone-coloured markers, matching the mobile graph.
    points = []
    for index, reading in enumerate(readings):
        x = left + round(index * (right - left) / max(count - 1, 1))
        points.append((x, y(reading.measured_value)))
    if len(points) > 1:
        draw.line(points, fill='#111827', width=4)
    point_colors = {'green': '#16a34a', 'yellow': '#d97706', 'red': '#dc2626'}
    radius = 9
    for point, reading in zip(points, readings):
        color = point_colors.get(str(reading.zone).lower(), '#111827')
        draw.ellipse((point[0] - radius, point[1] - radius,
                      point[0] + radius, point[1] + radius),
                     fill=color, outline='white', width=3)

    label_font = font(22)
    small_font = font(19)
    draw.text((left, 10), f'Lower limit: {_format_number(lower)}', fill='#dc2626', font=small_font)
    draw.text((right - 260, 10), f'Upper limit: {_format_number(upper)}', fill='#dc2626', font=small_font)
    draw.text((left, bottom + 22), 'Piece number', fill='#475569', font=label_font)
    draw.text((right - 260, bottom + 22), f'{len(readings)} saved readings', fill='#475569', font=label_font)
    for index, reading in enumerate(readings):
        x = left + round(index * (right - left) / max(count - 1, 1))
        draw.text((x - 12, bottom + 48), str(reading.piece_number), fill='#475569', font=small_font)

    stream = BytesIO()
    image.save(stream, format='PNG')
    stream.seek(0)
    stream.name = 'run-chart.png'
    excel_image = ExcelImage(stream)
    excel_image.width = width
    excel_image.height = height
    ws.add_image(excel_image, anchor)


def _build_expanded_mobile_sheet(ws, report, readings, page_number, page_count):
    """Build the expanded mobile-report view as a clean Excel report.

    This intentionally does not use the legacy worksheet grid. The graph is a
    dedicated section, followed by the same reading detail users see after
    expanding a completed report in the mobile app.
    """
    ws.title = 'Run Chart' if page_number == 1 else f'Run Chart {page_number}'
    ws.sheet_view.showGridLines = False
    ws.freeze_panes = 'A31'
    ws.print_area = 'A1:H48'
    ws.page_setup.orientation = ws.ORIENTATION_LANDSCAPE
    ws.page_setup.paperSize = ws.PAPERSIZE_A4
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    ws.page_setup.fitToWidth = 1
    ws.page_setup.fitToHeight = 0
    ws.page_margins.left = 0.25
    ws.page_margins.right = 0.25
    ws.page_margins.top = 0.35
    ws.page_margins.bottom = 0.35

    widths = {'A': 14, 'B': 26, 'C': 18, 'D': 20, 'E': 24, 'F': 24, 'G': 18, 'H': 18}
    for column, width in widths.items():
        ws.column_dimensions[column].width = width
    for row in range(1, 50):
        ws.row_dimensions[row].height = 20

    navy = 'FF0F172A'
    slate = 'FF475569'
    border = Side(style='thin', color='FFD7E0EA')
    header_fill = PatternFill('solid', fgColor='FFEFF4F8')
    label_fill = PatternFill('solid', fgColor='FFE2E8F0')
    title_font = Font(name='Arial', size=16, bold=True, color=navy)
    label_font = Font(name='Arial', size=10, bold=True, color=slate)
    value_font = Font(name='Arial', size=10, color=navy)

    ws.merge_cells('A1:H1')
    ws['A1'] = 'Completed Run Chart Report'
    ws['A1'].font = title_font
    ws['A1'].alignment = Alignment(horizontal='left', vertical='center')
    ws.row_dimensions[1].height = 30

    metadata = [
        ('A3', 'Machine', 'B3', f'{report.machine.machine_code} - {report.machine.name}', 'E3', 'Part', 'F3', f'{report.part.part_number} - {report.part.part_name}'),
        ('A4', 'Operation', 'B4', report.template.name, 'E4', 'Parameter', 'F4', f'{report.parameter_name} ({report.parameter_code})'),
        ('A5', 'Operator', 'B5', _display_name(report.operator), 'E5', 'Date / Shift', 'F5', f'{report.report_date} / Shift {report.shift}'),
        ('A6', 'Lower limit', 'B6', f'{_format_number(report.lower_limit)} {report.unit}', 'C6', 'Nominal', 'D6', f'{_format_number(report.nominal_value)} {report.unit}'),
        ('E6', 'Upper limit', 'F6', f'{_format_number(report.upper_limit)} {report.unit}', 'G6', 'Status', 'H6', 'Completed'),
    ]
    for label_cell, label, value_cell, value, label2_cell, label2, value2_cell, value2 in metadata:
        for cell_ref, text in ((label_cell, label), (value_cell, value), (label2_cell, label2), (value2_cell, value2)):
            ws[cell_ref] = _safe_excel_text(text)
            ws[cell_ref].border = Border(left=border, right=border, top=border, bottom=border)
            ws[cell_ref].alignment = Alignment(vertical='center', wrap_text=True)
        ws[label_cell].fill = label_fill
        ws[label2_cell].fill = label_fill
        ws[label_cell].font = label_font
        ws[label2_cell].font = label_font
        ws[value_cell].font = value_font
        ws[value2_cell].font = value_font
    for merge in ('B3:D3', 'F3:H3', 'B4:D4', 'F4:H4', 'B5:D5', 'F5:H5'):
        ws.merge_cells(merge)

    ws.merge_cells('A8:H8')
    ws['A8'] = 'Run Chart'
    ws['A8'].font = Font(name='Arial', size=13, bold=True, color=navy)
    ws['A8'].alignment = Alignment(vertical='center')
    _add_reading_line_chart(ws, report, readings, anchor='A9', width=1700, height=510)
    for row in range(9, 30):
        ws.row_dimensions[row].height = 22

    table_row = 31
    ws.merge_cells(start_row=table_row, start_column=1, end_row=table_row, end_column=8)
    ws.cell(table_row, 1, 'Readings')
    ws.cell(table_row, 1).font = Font(name='Arial', size=13, bold=True, color=navy)
    ws.cell(table_row, 1).alignment = Alignment(vertical='center')
    headers = ('Piece', 'Measured value', 'Deviation', 'Zone', 'Recorded at', 'Recorded by', 'Lower limit', 'Upper limit')
    for column, header in enumerate(headers, start=1):
        cell = ws.cell(table_row + 1, column, header)
        cell.font = Font(name='Arial', size=10, bold=True, color='FFFFFFFF')
        cell.fill = PatternFill('solid', fgColor=navy)
        cell.alignment = Alignment(horizontal='center', vertical='center', wrap_text=True)
        cell.border = Border(left=border, right=border, top=border, bottom=border)

    zone_fills = {
        'green': PatternFill('solid', fgColor='FFD1FAE5'),
        'yellow': PatternFill('solid', fgColor='FFFEF3C7'),
        'red': PatternFill('solid', fgColor='FFFECACA'),
    }
    for row_index, reading in enumerate(readings, start=table_row + 2):
        values = (
            reading.piece_number,
            float(reading.measured_value),
            float(reading.deviation),
            str(reading.zone).upper(),
            reading.recorded_at.strftime('%Y-%m-%d %H:%M:%S') if reading.recorded_at else '',
            _display_name(reading.recorded_by),
            float(report.lower_limit),
            float(report.upper_limit),
        )
        for column, value in enumerate(values, start=1):
            cell = ws.cell(row_index, column, value)
            cell.font = value_font
            cell.alignment = Alignment(horizontal='center' if column in (1, 2, 3, 4, 7, 8) else 'left', vertical='center')
            cell.border = Border(left=border, right=border, top=border, bottom=border)
            if column in (4,):
                cell.fill = zone_fills.get(str(reading.zone).lower(), PatternFill('solid', fgColor='FFFFFFFF'))
            if column in (2, 3, 7, 8):
                cell.number_format = '0.000000'
    ws.auto_filter.ref = f'A{table_row + 1}:H{table_row + 1 + len(readings)}'
    ws.print_area = f'A1:H{table_row + 1 + len(readings)}'


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
