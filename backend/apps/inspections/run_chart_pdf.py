from io import BytesIO

from reportlab.graphics.shapes import Circle, Drawing, Line, PolyLine, Rect, String
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table
from xml.sax.saxutils import escape
from .run_chart_logic import warning_boundaries


def _chart_drawing(report, readings):
    width, height = 245 * mm, 112 * mm
    drawing = Drawing(width, height)
    left, right, bottom, top = 20 * mm, 8 * mm, 16 * mm, 8 * mm
    plot_w = width - left - right
    plot_h = height - bottom - top

    lower = float(report.lower_limit)
    upper = float(report.upper_limit)
    nominal = float(report.nominal_value)
    span = max(upper - lower, 0.001)
    min_y = lower - span * 0.15
    max_y = upper + span * 0.15

    def y(value):
        return bottom + ((value - min_y) / (max_y - min_y)) * plot_h

    warning_low, warning_high = map(float, warning_boundaries(
        report.lower_limit, report.nominal_value, report.upper_limit,
        getattr(report.parameter, 'measurement_type', 'dimensional'),
    ))
    bands = (
        (min_y, lower, '#EF4444'),
        (lower, warning_low, '#FEF08A'),
        (warning_low, warning_high, '#A3D63F'),
        (warning_high, upper, '#FEF08A'),
        (upper, max_y, '#EF4444'),
    )
    for band_low, band_high, color in bands:
        drawing.add(Rect(
            left, y(band_low), plot_w, y(band_high) - y(band_low),
            fillColor=colors.HexColor(color), strokeColor=None,
        ))

    # Use the same 30-row stop-light grid as the mobile run-chart view.
    for row in range(31):
        py = bottom + (row / 30) * plot_h
        drawing.add(Line(left, py, left + plot_w, py,
                         strokeColor=colors.HexColor('#334155'), strokeWidth=0.35))
    columns = max(33, len(readings))
    for column in range(columns + 1):
        px = left + (column / columns) * plot_w
        drawing.add(Line(px, bottom, px, bottom + plot_h,
                         strokeColor=colors.HexColor('#334155'), strokeWidth=0.35))

    for value, label, color in [
        (lower, 'LSL', '#DC2626'),
        (nominal, 'Nominal', '#2563EB'),
        (upper, 'USL', '#DC2626'),
    ]:
        py = y(value)
        drawing.add(Line(left, py, left + plot_w, py, strokeColor=colors.HexColor(color), strokeWidth=1.1 if label != 'Nominal' else 1.5))
        drawing.add(String(left + 2, py + 2, f'{label} {value:g}', fontSize=7, fillColor=colors.HexColor(color)))

    drawing.add(Line(left, bottom, left, bottom + plot_h, strokeColor=colors.HexColor('#0F172A'), strokeWidth=1))
    drawing.add(Line(left, bottom, left + plot_w, bottom, strokeColor=colors.HexColor('#0F172A'), strokeWidth=1))

    if readings:
        count = len(readings)
        points = []
        for index, reading in enumerate(readings):
            px = left + ((index + 0.5) / max(columns, 1)) * plot_w
            py = y(float(reading.measured_value))
            points.extend([px, py])
        if len(points) >= 4:
            drawing.add(PolyLine(points, strokeColor=colors.HexColor('#0F172A'), strokeWidth=1.5))
        zone_colors = {'green': '#16A34A', 'yellow': '#D97706', 'red': '#DC2626'}
        for index, reading in enumerate(readings):
            px = left + ((index + 0.5) / max(columns, 1)) * plot_w
            py = y(float(reading.measured_value))
            drawing.add(Circle(px, py, 2.6, fillColor=colors.HexColor(zone_colors[reading.zone]), strokeColor=colors.white, strokeWidth=0.7))
            drawing.add(String(px - 2, bottom - 10, str(reading.piece_number), fontSize=6, fillColor=colors.HexColor('#475569')))
        drawing.add(String(left, 3, 'Piece number', fontSize=7, fillColor=colors.HexColor('#475569')))
        drawing.add(String(left + plot_w - 34, 3, f'{len(readings)} readings', fontSize=7, fillColor=colors.HexColor('#475569')))
    else:
        drawing.add(String(left + plot_w / 2 - 35, bottom + plot_h / 2, 'No readings recorded', fontSize=10, fillColor=colors.HexColor('#64748B')))
    return drawing


def generate_run_chart_pdf(report):
    buffer = BytesIO()
    readings = list(report.readings.select_related('recorded_by').order_by('piece_number'))
    page_size = landscape(A4)
    page_width, page_height = page_size
    page_count = max(1, (len(readings) + 32) // 33)
    pdf = canvas.Canvas(buffer, pagesize=page_size)
    pdf.setTitle(f'Run Chart - {report.parameter_name}')

    for page_index in range(page_count):
        page_readings = readings[page_index * 33:(page_index + 1) * 33]
        left, right = 24, page_width - 24
        plot_left, plot_right = 54, right - 30
        header_top = page_height - 24
        header_bottom = page_height - 110
        grid_top, grid_bottom = page_height - 118, 125
        plot_width, plot_height = plot_right - plot_left, grid_top - grid_bottom
        thin = colors.HexColor('#111827')

        pdf.setStrokeColor(thin)
        pdf.setLineWidth(0.6)
        pdf.rect(left, header_bottom, right - left, header_top - header_bottom)
        for y_line in (header_top - 20, header_top - 43, header_top - 66, header_top - 89):
            pdf.line(left, y_line, right, y_line)
        header_cols = [left, 220, 330, 440, 565, 690, right]
        for x_line in header_cols[1:-1]:
            pdf.line(x_line, header_bottom, x_line, header_top)

        pdf.setFont('Helvetica-Bold', 9)
        pdf.drawString(left + 4, header_top - 14, 'SAPOTECH COMPONENTS PVT.')
        pdf.drawString(left + 4, header_top - 25, 'LTD.')
        pdf.setFont('Helvetica-Bold', 11)
        pdf.drawCentredString(385, header_top - 14, 'Run Chart (Stop Light Control Chart)')
        pdf.setFont('Helvetica', 7)
        pdf.drawString(575, header_top - 14, f'Page: {page_index + 1}/{page_count}')
        pdf.drawString(left + 4, header_top - 35, f'Part Name: {report.part.part_number} - {report.part.part_name}')
        pdf.drawString(225, header_top - 35, f'Characteristic: {report.parameter_name}')
        pdf.drawString(445, header_top - 35, f'Machine: {report.machine.machine_code} - {report.machine.name}')
        pdf.drawString(695, header_top - 35, 'Sample Freq: 100%')
        pdf.drawString(left + 4, header_top - 58, f'Operation: {report.template.name}')
        pdf.drawString(225, header_top - 58, f'Specification: {report.lower_limit} to {report.upper_limit} {report.unit}')
        pdf.drawString(445, header_top - 58, f'Date/Shift: {report.report_date} / {report.shift}')
        pdf.drawString(695, header_top - 58, f'Operator Name: {report.operator.display_name}')
        pdf.drawString(left + 4, header_bottom + 8, f'Lower Limit: {report.lower_limit} {report.unit}')
        pdf.drawString(225, header_bottom + 8, f'Mean Size: {report.nominal_value} {report.unit}')
        pdf.drawString(445, header_bottom + 8, f'Upper Limit: {report.upper_limit} {report.unit}')

        lower, nominal, upper = map(float, (report.lower_limit, report.nominal_value, report.upper_limit))
        span = max(upper - lower, 0.001)
        graph_min, graph_max = lower - span * 0.15, upper + span * 0.15
        warning_low, warning_high = map(float, warning_boundaries(
            report.lower_limit, report.nominal_value, report.upper_limit,
            getattr(report.parameter, 'measurement_type', 'dimensional'),
        ))
        def y(value):
            value = max(graph_min, min(graph_max, float(value)))
            return grid_bottom + ((value - graph_min) / (graph_max - graph_min)) * plot_height

        for low, high, fill in (
            (graph_min, lower, '#EF4444'), (lower, warning_low, '#FEF08A'),
            (warning_low, warning_high, '#A3D63F'), (warning_high, upper, '#FEF08A'),
            (upper, graph_max, '#EF4444'),
        ):
            pdf.setFillColor(colors.HexColor(fill))
            pdf.rect(plot_left, y(low), plot_width, y(high) - y(low), stroke=0, fill=1)

        pdf.setStrokeColor(thin)
        pdf.setLineWidth(0.35)
        for row in range(31):
            gy = grid_bottom + row * plot_height / 30
            pdf.line(plot_left, gy, plot_right, gy)
        for column in range(34):
            gx = plot_left + column * plot_width / 33
            pdf.line(gx, grid_bottom, gx, grid_top)
        pdf.setLineWidth(1.2)
        for value, color in ((lower, '#DC2626'), (nominal, '#111827'), (upper, '#DC2626')):
            pdf.setStrokeColor(colors.HexColor(color))
            pdf.line(plot_left, y(value), plot_right, y(value))
        pdf.setFillColor(colors.HexColor('#111827'))
        pdf.setFont('Helvetica', 6)
        pdf.drawCentredString(plot_left - 20, grid_bottom + plot_height / 2, 'IN MICRONS')

        pdf.setFillColor(colors.HexColor('#111827'))
        pdf.setFont('Helvetica-Bold', 7)
        pdf.setStrokeColor(colors.HexColor('#0F766E'))
        pdf.setLineWidth(1.1)
        for index, reading in enumerate(page_readings):
            px = plot_left + ((index + 0.5) / 33) * plot_width
            py = y(reading.measured_value)
            if index:
                pdf.line(previous_x, previous_y, px, py)
            zone_color = {'green': '#0F766E', 'yellow': '#D97706', 'red': '#B91C1C'}.get(reading.zone, '#0F766E')
            pdf.setStrokeColor(colors.HexColor(zone_color))
            pdf.setFillColor(colors.white)
            pdf.circle(px, py, 2.8, stroke=1, fill=1)
            value_label = f'{float(reading.measured_value):g}'
            pdf.setFillColor(colors.HexColor('#111827'))
            pdf.setFont('Helvetica-Bold', 5.5)
            value_width = pdf.stringWidth(value_label, 'Helvetica-Bold', 5.5)
            pdf.drawString(px - value_width / 2, py + 6, value_label)
            reason = str(getattr(reading, 'warning_reason', '') or '').strip()
            if reason:
                short_reason = reason if len(reason) <= 28 else f'{reason[:25]}...'
                label_width = min(150, max(30, len(short_reason) * 3.1 + 8))
                pdf.setFillColor(colors.white)
                pdf.setStrokeColor(colors.HexColor('#475569'))
                pdf.setLineWidth(0.35)
                pdf.roundRect(px + 3, py - 11, label_width, 9, 2, stroke=1, fill=1)
                pdf.setFillColor(colors.HexColor('#111827'))
                pdf.setFont('Helvetica-Bold', 5.5)
                pdf.drawString(px + 7, py - 8, short_reason)
            previous_x, previous_y = px, py

        # Zone labels and job-number row match the supplied official template.
        pdf.setFillColor(colors.HexColor('#111827'))
        pdf.setFont('Helvetica', 7)
        for index, reading in enumerate(page_readings):
            px = plot_left + ((index + 0.5) / 33) * plot_width
            pdf.drawCentredString(px, grid_bottom - 12, str(reading.piece_number))
        pdf.setFont('Helvetica-Bold', 7)
        pdf.drawString(left + 3, grid_bottom - 12, 'Job No.')
        pdf.setFont('Helvetica', 7)
        pdf.drawCentredString(plot_right + 14, grid_top - 18, 'Red Zone')
        pdf.drawCentredString(plot_right + 14, grid_top - 55, 'Yellow Zone')
        pdf.drawCentredString(plot_right + 14, grid_bottom + plot_height / 2, 'Green Zone')
        pdf.drawCentredString(plot_right + 14, grid_bottom + 35, 'Yellow Zone')
        pdf.drawCentredString(plot_right + 14, grid_bottom + 12, 'Red Zone')
        pdf.setStrokeColor(thin)
        pdf.rect(plot_left, grid_bottom - 20, plot_width, 20)
        pdf.rect(plot_right, grid_bottom, 30, plot_height)

        footer_top = 104
        pdf.rect(left, 28, right - left, footer_top - 28)
        pdf.line(left, 58, right, 58)
        pdf.line(310, 28, 310, footer_top)
        pdf.line(560, 28, 560, footer_top)
        pdf.setFont('Helvetica', 6)
        pdf.drawString(left + 4, footer_top - 10, 'Process Control Rules:')
        pdf.drawString(left + 4, footer_top - 20, '1. Check the first piece before production continues.')
        pdf.drawString(left + 4, footer_top - 30, '2. Stop production if any reading reaches the red zone.')
        pdf.drawString(left + 4, footer_top - 40, '3. Review the process when repeated readings enter the yellow zone.')
        pdf.drawString(315, footer_top - 10, 'Remarks:')
        pdf.drawCentredString(170, 39, f'Inspected By: {report.operator.display_name}')
        pdf.drawCentredString(435, 39, 'SCPL/FT/PRD -')
        pdf.drawCentredString(690, 39, 'Approved By: ____________________')
        pdf.showPage()

    pdf.save()
    buffer.seek(0)
    return buffer
