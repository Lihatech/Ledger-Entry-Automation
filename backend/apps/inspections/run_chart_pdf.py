from io import BytesIO

from reportlab.graphics.shapes import Circle, Drawing, Line, PolyLine, Rect, String
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle
from xml.sax.saxutils import escape
from .run_chart_logic import warning_boundaries


def _chart_drawing(report, readings):
    width, height = 245 * mm, 105 * mm
    drawing = Drawing(width, height)
    left, right, bottom, top = 18 * mm, 8 * mm, 16 * mm, 8 * mm
    plot_w = width - left - right
    plot_h = height - bottom - top

    values = [float(r.measured_value) for r in readings]
    lower = float(report.lower_limit)
    upper = float(report.upper_limit)
    nominal = float(report.nominal_value)
    all_values = values + [lower, upper, nominal]
    min_y, max_y = min(all_values), max(all_values)
    span = max(max_y - min_y, abs(nominal) * 0.001, 0.001)
    min_y -= span * 0.12
    max_y += span * 0.12

    def y(value):
        return bottom + ((value - min_y) / (max_y - min_y)) * plot_h

    warning_low, warning_high = map(float, warning_boundaries(
        report.lower_limit, report.nominal_value, report.upper_limit,
        getattr(report.parameter, 'measurement_type', 'dimensional'),
    ))
    drawing.add(Rect(left, y(lower), plot_w, y(warning_low) - y(lower), fillColor=colors.HexColor('#FEF3C7'), strokeColor=None))
    drawing.add(Rect(left, y(warning_low), plot_w, y(warning_high) - y(warning_low), fillColor=colors.HexColor('#DCFCE7'), strokeColor=None))
    drawing.add(Rect(left, y(warning_high), plot_w, y(upper) - y(warning_high), fillColor=colors.HexColor('#FEF3C7'), strokeColor=None))

    for value, label, color in [
        (lower, 'LSL', '#DC2626'),
        (nominal, 'Nominal', '#2563EB'),
        (upper, 'USL', '#DC2626'),
    ]:
        py = y(value)
        drawing.add(Line(left, py, left + plot_w, py, strokeColor=colors.HexColor(color), strokeWidth=1))
        drawing.add(String(left + 2, py + 2, f'{label} {value:g}', fontSize=7, fillColor=colors.HexColor(color)))

    drawing.add(Line(left, bottom, left, bottom + plot_h, strokeColor=colors.HexColor('#64748B')))
    drawing.add(Line(left, bottom, left + plot_w, bottom, strokeColor=colors.HexColor('#64748B')))

    if readings:
        count = len(readings)
        points = []
        for index, reading in enumerate(readings):
            px = left + (index / max(count - 1, 1)) * plot_w
            py = y(float(reading.measured_value))
            points.extend([px, py])
        if len(points) >= 4:
            drawing.add(PolyLine(points, strokeColor=colors.HexColor('#0F172A'), strokeWidth=1.5))
        zone_colors = {'green': '#16A34A', 'yellow': '#D97706', 'red': '#DC2626'}
        for index, reading in enumerate(readings):
            px = left + (index / max(count - 1, 1)) * plot_w
            py = y(float(reading.measured_value))
            drawing.add(Circle(px, py, 2.6, fillColor=colors.HexColor(zone_colors[reading.zone]), strokeColor=colors.white, strokeWidth=0.5))
        drawing.add(String(left, 3, f'Piece {readings[0].piece_number}', fontSize=7, fillColor=colors.HexColor('#475569')))
        drawing.add(String(left + plot_w - 34, 3, f'Piece {readings[-1].piece_number}', fontSize=7, fillColor=colors.HexColor('#475569')))
    else:
        drawing.add(String(left + plot_w / 2 - 35, bottom + plot_h / 2, 'No readings recorded', fontSize=10, fillColor=colors.HexColor('#64748B')))
    return drawing


def generate_run_chart_pdf(report):
    buffer = BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=landscape(A4),
        rightMargin=14 * mm,
        leftMargin=14 * mm,
        topMargin=12 * mm,
        bottomMargin=12 * mm,
        title=f'Run Chart - {report.parameter_name}',
    )
    styles = getSampleStyleSheet()
    readings = list(report.readings.select_related('recorded_by').order_by('piece_number'))
    operators = sorted({reading.recorded_by.display_name for reading in readings})
    operator_label = ', '.join(operators) if operators else report.operator.display_name
    story = [
        Paragraph(f'<b>Run Chart: {escape(str(report.parameter_name))}</b>', styles['Title']),
        Spacer(1, 4 * mm),
        Table(
            [
                ['Machine', report.machine.machine_code, 'Part', report.part.part_number, 'Operation', report.template.name],
                ['Date / Shift', f'{report.report_date} / {report.shift}', 'Unit', report.unit, 'Operators', operator_label],
                ['Lower limit', str(report.lower_limit), 'Nominal', str(report.nominal_value), 'Upper limit', str(report.upper_limit)],
            ],
            colWidths=[26 * mm, 48 * mm, 24 * mm, 48 * mm, 27 * mm, 58 * mm],
            style=[
                ('BACKGROUND', (0, 0), (0, -1), colors.HexColor('#E2E8F0')),
                ('BACKGROUND', (2, 0), (2, -1), colors.HexColor('#E2E8F0')),
                ('BACKGROUND', (4, 0), (4, -1), colors.HexColor('#E2E8F0')),
                ('FONTNAME', (0, 0), (-1, -1), 'Helvetica'),
                ('FONTNAME', (0, 0), (0, -1), 'Helvetica-Bold'),
                ('FONTNAME', (2, 0), (2, -1), 'Helvetica-Bold'),
                ('FONTNAME', (4, 0), (4, -1), 'Helvetica-Bold'),
                ('FONTSIZE', (0, 0), (-1, -1), 8),
                ('GRID', (0, 0), (-1, -1), 0.4, colors.HexColor('#CBD5E1')),
                ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ],
        ),
        Spacer(1, 4 * mm),
        _chart_drawing(report, readings),
        Spacer(1, 3 * mm),
    ]
    table_data = [['Piece', 'Measured value', 'Deviation', 'Zone', 'Recorded at', 'Recorded by']]
    for reading in readings:
        table_data.append([
            reading.piece_number,
            f'{reading.measured_value} {report.unit}',
            str(reading.deviation),
            reading.zone.upper(),
            reading.recorded_at.strftime('%Y-%m-%d %H:%M:%S'),
            reading.recorded_by.display_name,
        ])
    readings_table = Table(table_data, repeatRows=1, colWidths=[18 * mm, 36 * mm, 30 * mm, 22 * mm, 48 * mm, 55 * mm])
    readings_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#0F172A')),
        ('TEXTCOLOR', (0, 0), (-1, 0), colors.white),
        ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
        ('FONTSIZE', (0, 0), (-1, -1), 8),
        ('GRID', (0, 0), (-1, -1), 0.35, colors.HexColor('#CBD5E1')),
        ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, colors.HexColor('#F8FAFC')]),
        ('ALIGN', (0, 0), (3, -1), 'CENTER'),
    ]))
    story.append(readings_table)
    doc.build(story)
    buffer.seek(0)
    return buffer
