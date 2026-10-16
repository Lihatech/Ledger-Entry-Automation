import os
import uuid
from datetime import datetime
from django.conf import settings
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle, Spacer, KeepInFrame
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

from apps.machines.models import Factory

def _xml_escape(text: str) -> str:
    """Escape special XML characters for safe use inside ReportLab Paragraph markup."""
    return str(text if text is not None else '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def _as_mapping_list(value):
    """Return only dictionary entries from JSONB arrays.

    Older inspection documents can contain null or malformed entries. ReportLab
    expects scalar values while building a table, so ignore those entries rather
    than failing the whole PDF download.
    """
    return [item for item in (value or []) if isinstance(item, dict)]


def _number(value, default=0.0):
    """Convert JSON numeric values without failing on blank legacy values."""
    try:
        return float(value) if value not in (None, '') else float(default)
    except (TypeError, ValueError):
        return float(default)


def get_factory_info(session=None):
    """
    Return (factory_name, factory_code) for reports strictly as per the
    company details configured by the user in the Company Details section.
    """
    # 1. Primary active factory configured by the user in Company Details
    factory = Factory.objects.filter(is_active=True).order_by('id').first() or Factory.objects.order_by('id').first()
    if factory and factory.name:
        code = factory.code or "".join([w[0] for w in factory.name.split() if w]).upper() or "FAC"
        return factory.name, code

    # 2. Check linked machine/plant factory if primary not present
    if session:
        target = session
        if hasattr(session, 'first') and callable(session.first):
            target = session.first()
        elif isinstance(session, (list, tuple)) and session:
            target = session[0]

        machine = getattr(target, 'machine', None)
        if not machine and hasattr(target, 'production_report'):
            machine = getattr(target.production_report, 'machine', None)

        if machine and getattr(machine, 'plant', None) and getattr(machine.plant, 'factory', None):
            linked_fac = machine.plant.factory
            if linked_fac and linked_fac.name:
                code = linked_fac.code or "".join([w[0] for w in linked_fac.name.split() if w]).upper() or "FAC"
                return linked_fac.name, code

    return "Company Name", "FAC"

def generate_first_piece_pdf(session, doc_data: dict) -> str:
    media_pdf_dir = os.path.join(settings.MEDIA_ROOT, 'pdf_reports')
    os.makedirs(media_pdf_dir, exist_ok=True)

    date_str = session.started_at.strftime('%Y-%m-%d') if getattr(session, 'started_at', None) else datetime.now().strftime('%Y-%m-%d')
    shift_str = f"Shift_{session.shift}" if getattr(session, 'shift', None) else "Shift_All"
    mc_code = session.machine.machine_code.replace('/', '_') if (hasattr(session, 'machine') and session.machine and session.machine.machine_code) else "MCH"
    part_no = session.part.part_number.replace('/', '_') if (hasattr(session, 'part') and session.part and session.part.part_number) else "PART"
    prefix = "Setup_Approval_Report" if getattr(session, 'is_setup_approval_only', False) else "FirstPiece_Report"
    sess_short = str(session.session_id)[:8] if getattr(session, 'session_id', None) else "00000000"
    file_name = f"{prefix}_{date_str}_{shift_str}_{mc_code}_{part_no}_{sess_short}.pdf"
    file_path = os.path.join(media_pdf_dir, file_name)
    # Build into a unique temporary path, then publish atomically. Multiple
    # clients may request the same report at the same time.
    temp_file_path = f"{file_path}.{uuid.uuid4().hex}.tmp"

    from reportlab.platypus import PageBreak

    page_width, page_height = landscape(A4)
    left_margin = 15
    right_margin = 15
    top_margin = 15
    bottom_margin = 15
    usable_width = page_width - left_margin - right_margin

    doc = SimpleDocTemplate(
        temp_file_path,
        pagesize=landscape(A4),
        rightMargin=right_margin,
        leftMargin=left_margin,
        topMargin=top_margin,
        bottomMargin=bottom_margin
    )

    styles = getSampleStyleSheet()

    # Styles
    title_style = ParagraphStyle('Title', fontName='Helvetica-Bold', fontSize=12, alignment=1)
    subtitle_style = ParagraphStyle('SubTitle', fontName='Helvetica-Bold', fontSize=9.5, alignment=1)
    doc_ref_style = ParagraphStyle('DocRef', fontName='Helvetica-Bold', fontSize=7, alignment=2)
    mmpl_style = ParagraphStyle('MMPL', fontName='Helvetica-Bold', fontSize=16, textColor=colors.white, alignment=1)
    
    # All report cells must be allowed to wrap inside their assigned column.
    # This is especially important for the narrow hourly columns and prevents
    # long labels from expanding the table beyond the landscape-A4 frame.
    cell_style = ParagraphStyle('Cell', fontName='Helvetica', fontSize=7, alignment=1, leading=8, wordWrap='CJK')
    cell_left = ParagraphStyle('CellLeft', fontName='Helvetica', fontSize=7, alignment=0, leading=8, wordWrap='CJK')
    bold_cell = ParagraphStyle('BoldCell', fontName='Helvetica-Bold', fontSize=7, alignment=1, leading=8, wordWrap='CJK')
    red_cell = ParagraphStyle('RedCell', fontName='Helvetica-Bold', fontSize=7, textColor=colors.red, alignment=1, leading=8, wordWrap='CJK')
    header_style = ParagraphStyle('Header', fontName='Helvetica-Bold', fontSize=7, alignment=1, leading=8, textColor=colors.HexColor('#1E293B'), wordWrap='CJK')
    # Measurements must remain readable as complete values. Descriptive text
    # may wrap, but numeric cells should not split values such as -100.00.
    numeric_cell = ParagraphStyle('NumericCell', fontName='Helvetica', fontSize=6.5, alignment=1, leading=7, splitLongWords=0)
    numeric_red_cell = ParagraphStyle('NumericRedCell', fontName='Helvetica-Bold', fontSize=6.5, leading=7, alignment=1, textColor=colors.red, splitLongWords=0)

    # Determine shift hours for layout (8 or 12)
    factory_hrs = 8
    if session and hasattr(session, 'machine') and session.machine and session.machine.plant and session.machine.plant.factory:
        factory_hrs = session.machine.plant.factory.shift_hours or 8
    
    try:
        shift_hrs = int(factory_hrs)
    except (TypeError, ValueError):
        shift_hrs = 8
    # The official F02 layout supports the configured 8-hour or 12-hour mode.
    # Keep invalid/legacy company values from causing a division-by-zero or an
    # unbounded table during PDF generation.
    if shift_hrs not in (8, 12):
        shift_hrs = 8

    inspector_name = session.finalized_by.get_full_name() if session.finalized_by else (session.supervisor.get_full_name() if session.supervisor else "Quality Inspector")
    operator_name = session.operator.get_full_name() if session.operator else "Operator User"
    final_time_str = session.finalized_at.strftime(f"%d %b %Y | Shift {session.shift or 'A'}") if session.finalized_at else datetime.now().strftime(f"%d %b %Y | Shift {session.shift or 'A'}")
    status_label = "PASSED" if session.status in ['finalized_passed', 'approved'] or session.is_setup_approved else ("COMPLETED" if session.status == 'completed' else "PENDING REVIEW")

    param_summary = _as_mapping_list(doc_data.get('parameter_summary'))
    measurements = _as_mapping_list(doc_data.get('measurements'))

    meas_map = {}
    for m in measurements:
        p_code = m.get('parameter_code')
        if p_code:
            if p_code not in meas_map:
                meas_map[p_code] = {'all_measurements': []}
            meas_map[p_code]['all_measurements'].append(m)

    elements = []
    
    fac_name, fac_code = get_factory_info(session)
    safe_fac_name = _xml_escape(fac_name)
    safe_fac_code = _xml_escape(fac_code)

    # Determine operation/process number dynamically
    op_name = "-"
    if session and hasattr(session, 'template') and session.template:
        if getattr(session.template, 'name', None):
            op_name = session.template.name.strip()
        elif getattr(session.template, 'version', None):
            op_name = f"OP-{session.template.version}"

    # 1. TOP HEADER (MMPL | Title | Doc Ref)
    header_data = [
        [
            Paragraph(safe_fac_code, mmpl_style),
            [Paragraph(safe_fac_name.upper(), title_style), Paragraph(f"1ST PIECE CUM IN-PROCESS INSPECTION REPORT : OPERATION: {_xml_escape(op_name)}", subtitle_style)],
            Paragraph(f"DOC REF: {safe_fac_code}/PRD/F02<br/>REV: 02 (15.8.2013)<br/>PAGE 1 OF 1", doc_ref_style)
        ]
    ]
    # Keep every report section inside the actual landscape-A4 frame.  The
    # previous fixed total of 820pt was wider than the available 811.89pt and
    # caused the left/right columns to be clipped in generated PDFs.
    header_table = Table(header_data, colWidths=[90, usable_width - 240, 150], hAlign='LEFT')
    header_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (0, 0), colors.black),
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('INNERGRID', (0, 0), (-1, -1), 1, colors.black),
        ('LEFTPADDING', (0, 0), (-1, -1), 2),
        ('RIGHTPADDING', (0, 0), (-1, -1), 2),
        ('TOPPADDING', (0, 0), (-1, -1), 3),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 3),
    ]))
    elements.append(header_table)

    # 2. META INFO (Process, Part, Operator, Machine, Date, Status)
    meta_data = [
        [
            Paragraph(f"OPERATION: <font name='Helvetica-Bold'>{_xml_escape(op_name)}</font>", cell_left),
            Paragraph(f"PART NAME &amp; NO: <font name='Helvetica-Bold'>{_xml_escape(session.part.part_number)} ({_xml_escape(session.part.part_name)})</font>", cell_left),
            Paragraph(f"INSPECTOR / OPERATOR: <font name='Helvetica-Bold'>{_xml_escape(operator_name)}</font>", cell_left)
        ],
        [
            Paragraph(f"MACHINE NO: <font name='Helvetica-Bold'>{_xml_escape(session.machine.machine_code)}</font>", cell_left),
            Paragraph(f"DATE &amp; SHIFT: <font name='Helvetica-Bold'>{_xml_escape(final_time_str)}</font>", cell_left),
            Paragraph(f"SETUP STATUS: <font name='Helvetica-Bold'>{_xml_escape(status_label)}</font>", cell_left)
        ]
    ]
    meta_table = Table(meta_data, colWidths=[150, usable_width - 330, 180], hAlign='LEFT')
    meta_table.setStyle(TableStyle([
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('INNERGRID', (0, 0), (-1, -1), 1, colors.black),
        ('LEFTPADDING', (0, 0), (-1, -1), 2),
        ('RIGHTPADDING', (0, 0), (-1, -1), 2),
        ('TOPPADDING', (0, 0), (-1, -1), 2),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 2),
        ('TEXTCOLOR', (0, 0), (-1, -1), colors.HexColor('#4B5563')),
    ]))
    elements.append(meta_table)

    # 3. MEASUREMENTS TABLE
    slot_headers = [Paragraph(f"{i}/HR", header_style) for i in range(1, shift_hrs + 1)]
    
    table_data = [
        [
            Paragraph("P.NO", header_style), Paragraph("NO", header_style), Paragraph("PARAMETER NAME", header_style),
            Paragraph("CLASS", header_style), Paragraph("SPECIFICATION", header_style), Paragraph("EVALUATION TECHNIQUE", header_style),
            Paragraph("SAMPLE FREQ", header_style), Paragraph("1ST #1", header_style), Paragraph("1ST #2", header_style), Paragraph("1ST #3", header_style),
            *slot_headers,
            Paragraph("REMA", header_style)
        ]
    ]

    for idx, p in enumerate(param_summary, 1):
        code = p.get('parameter_code', str(idx).zfill(2))
        p_info = meas_map.get(code, {})
        p_meas_list = p_info.get('all_measurements', [])
        
        fp1 = next((m for m in p_meas_list if m.get('inspection_type') == 'first_piece' and (m.get('trial_number') or 1) == 1), None)
        fp2 = next((m for m in p_meas_list if m.get('inspection_type') == 'first_piece' and m.get('trial_number') == 2), None)
        fp3 = next((m for m in p_meas_list if m.get('inspection_type') == 'first_piece' and m.get('trial_number') == 3), None)

        nom = _number(p.get('nominal', 0))
        ll = p.get('lower_limit')
        ul = p.get('upper_limit')
        unit = p.get('unit', 'mm')
        
        if ll is not None and ul is not None:
            spec = f"{nom} {unit} [{_number(ll):.2f} to {_number(ul):.2f}]"
        else:
            spec = f"{nom} {unit}"

        is_crit = p.get('is_critical', False)
        class_str = "CRITICAL" if is_crit else "-"
        method_str = p.get('measurement_technique') or p.get('evaluation_technique') or p.get('gauge_used') or "VERNIER CALIPER"
        sample_str = p.get('sample_size') or p.get('sample_frequency') or "5NOS/SHIFT"

        fmt_val = lambda m: (f"{float(m['measured_value']):.2f}" if isinstance(m.get('measured_value'), (int, float)) else str(m.get('measured_value', '-'))) if m else "-"
        fmt_para = lambda m: Paragraph(
            fmt_val(m),
            numeric_red_cell if (m and m.get('status') == 'out_of_spec') else numeric_cell,
        )

        hourly_slot_map = {}
        for hm in p_meas_list:
            if hm.get('inspection_type') == 'hourly' and hm.get('hourly_slot'):
                hourly_slot_map[hm.get('hourly_slot')] = hm

        hourly_cells = []
        for slot_i in range(1, shift_hrs + 1):
            hm = hourly_slot_map.get(slot_i)
            if hm and hm.get('measured_value') is not None:
                h_val = hm.get('measured_value')
                h_status = hm.get('status', 'ok')
                h_str = f"{float(h_val):.2f}" if isinstance(h_val, (int, float)) else str(h_val)
                hourly_cells.append(Paragraph(h_str, numeric_red_cell if h_status == 'out_of_spec' else numeric_cell))
            else:
                hourly_cells.append(Paragraph("-", numeric_cell))

        table_data.append([
            Paragraph("10.", bold_cell),
            Paragraph(str(idx).zfill(2), bold_cell),
            Paragraph(_xml_escape(p.get('parameter_name', code)), cell_left),
            Paragraph(_xml_escape(class_str), red_cell if is_crit else cell_style),
            Paragraph(_xml_escape(spec), bold_cell),
            Paragraph(_xml_escape(method_str), cell_style),
            Paragraph(_xml_escape(sample_str), cell_style),
            fmt_para(fp1),
            fmt_para(fp2),
            fmt_para(fp3),
            *hourly_cells,
            Paragraph("-", cell_style),
        ])

    base_widths = [22, 22, 90, 26, 65, 70, 45, 24, 24, 24]
    remark_width = 24
    remaining_slot_width = usable_width - (sum(base_widths) + remark_width)
    slot_width = remaining_slot_width / shift_hrs
    
    col_widths = base_widths + [slot_width] * shift_hrs + [remark_width]
    
    param_table = Table(table_data, colWidths=col_widths, repeatRows=1, hAlign='LEFT')
    param_table.setStyle(TableStyle([
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('INNERGRID', (0, 0), (-1, -1), 1, colors.black),
        ('LEFTPADDING', (0, 0), (-1, -1), 1),
        ('RIGHTPADDING', (0, 0), (-1, -1), 1),
        ('TOPPADDING', (0, 0), (-1, -1), 2),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 2),
        ('BACKGROUND', (10, 0), (10 + shift_hrs - 1, 0), colors.HexColor('#DCFCE7')),
    ]))
    elements.append(param_table)

    # 4. REACTION PLAN
    reaction_data = [[Paragraph("REACTION PLAN: <font color='#4B5563'>REJECT, REWORK, SEGREGATE, INFORM SUPERVISOR OR READJUST THE PROCESS</font>", ParagraphStyle('React', fontName='Helvetica-Bold', fontSize=7))]]
    reaction_table = Table(reaction_data, colWidths=[usable_width], hAlign='LEFT')
    reaction_table.setStyle(TableStyle([
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('PADDING', (0, 0), (-1, -1), 3),
        ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor('#F8FAFC')),
    ]))
    elements.append(reaction_table)
    elements.append(Spacer(1, 12))

    # 5. FOOTER SIGNATURES
    footer_data = [
        [
            Paragraph(f"<i>{_xml_escape(operator_name)}</i>", cell_style),
            Paragraph(f"<i>{_xml_escape(inspector_name)}</i>", cell_style),
            Paragraph("<i>Supervisor Sign</i>", cell_style)
        ],
        [
            '', '', ''
        ],
        [
            Paragraph("<b>OPERATOR SIGNATURE</b>", bold_cell),
            Paragraph("<b>QUALITY INSPECTOR SIGNATURE</b>", bold_cell),
            Paragraph("<b>SUPERVISOR SIGNATURE</b>", bold_cell)
        ]
    ]
    footer_table = Table(footer_data, colWidths=[usable_width / 3] * 3, hAlign='LEFT')
    footer_table.setStyle(TableStyle([
        ('VALIGN', (0, 0), (-1, -1), 'BOTTOM'),
        ('PADDING', (0, 0), (-1, -1), 2),
        ('LINEABOVE', (0, 1), (-1, 1), 0.6, colors.black),
    ]))
    elements.append(footer_table)

    # This official form is designed as a single-page report. Keep the
    # measurement table, reaction plan, and signatures together and shrink
    # only this body when unusual wrapping would otherwise create page 2.
    body_height = page_height - top_margin - bottom_margin - 90
    elements = elements[:2] + [KeepInFrame(usable_width, body_height, elements[2:], mode='shrink')]

    try:
        doc.build(elements)
        os.replace(temp_file_path, file_path)
    except Exception:
        if os.path.exists(temp_file_path):
            os.remove(temp_file_path)
        raise
    return f"media/pdf_reports/{file_name}"


def generate_daily_production_pdf(report) -> str:
    media_pdf_dir = os.path.join(settings.MEDIA_ROOT, 'pdf_reports')
    os.makedirs(media_pdf_dir, exist_ok=True)

    date_str = str(report.date) if getattr(report, 'date', None) else datetime.now().strftime('%Y-%m-%d')
    shift_str = f"Shift_{report.shift}" if getattr(report, 'shift', None) else "Shift_All"
    mc_code = report.machine.machine_code.replace('/', '_') if (hasattr(report, 'machine') and report.machine and report.machine.machine_code) else 'MCH'
    part_no = report.part.part_number.replace('/', '_') if (hasattr(report, 'part') and report.part and report.part.part_number) else 'PART'
    file_name = f"DailyProduction_Report_{date_str}_{shift_str}_{mc_code}_{part_no}.pdf"
    file_path = os.path.join(media_pdf_dir, file_name)

    doc = SimpleDocTemplate(
        file_path,
        pagesize=landscape(A4),
        rightMargin=20,
        leftMargin=20,
        topMargin=20,
        bottomMargin=20
    )

    styles = getSampleStyleSheet()

    title_style = ParagraphStyle('Title', fontName='Helvetica-Bold', fontSize=14, alignment=1)
    subtitle_style = ParagraphStyle('SubTitle', fontName='Helvetica-Bold', fontSize=10, alignment=1)
    doc_ref_style = ParagraphStyle('DocRef', fontName='Helvetica-Bold', fontSize=8, alignment=2)
    mmpl_style = ParagraphStyle('MMPL', fontName='Helvetica-Bold', fontSize=16, textColor=colors.white, alignment=1)
    cell_style = ParagraphStyle('Cell', fontName='Helvetica', fontSize=9, alignment=1)
    bold_cell = ParagraphStyle('BoldCell', fontName='Helvetica-Bold', fontSize=9, alignment=1)
    bold_left = ParagraphStyle('BoldLeft', fontName='Helvetica-Bold', fontSize=9, alignment=0)
    left_style = ParagraphStyle('LeftStyle', fontName='Helvetica', fontSize=9, alignment=0)

    elements = []
    
    fac_name, fac_code = get_factory_info(report)

    # 1. Header
    header_data = [
        [
            Paragraph(fac_code, mmpl_style),
            [Paragraph(fac_name.upper(), title_style), Paragraph("DAILY PRODUCTION REPORT : END OF DAY SUMMARY", subtitle_style)],
            Paragraph(f"DOC REF: {fac_code}/PRD/F08<br/>REV: 01 (12.8.2026)<br/>PAGE 1 OF 1", doc_ref_style)
        ]
    ]
    header_table = Table(header_data, colWidths=[100, 550, 150])
    header_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (0, 0), colors.black),
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('INNERGRID', (0, 0), (-1, -1), 1, colors.black),
        ('PADDING', (0, 0), (-1, -1), 6),
    ]))
    elements.append(header_table)
    elements.append(Spacer(1, 10))

    # 2. Metadata Grid
    op_name = report.operator.get_full_name().strip() if report.operator else '-'
    if not op_name:
        op_name = report.operator.username if report.operator else '-'

    meta_data = [
        [
            Paragraph(f"<b>DATE:</b> {report.date}", left_style),
            Paragraph(f"<b>MACHINE:</b> {report.machine.machine_code} ({report.machine.name})", left_style),
            Paragraph(f"<b>SHIFT:</b> {report.shift}", left_style),
        ],
        [
            Paragraph(f"<b>PART:</b> {report.part.part_number} ({report.part.part_name})", left_style),
            Paragraph(f"<b>OPERATION:</b> {report.operation or '-'}", left_style),
            Paragraph(f"<b>OPERATOR:</b> {op_name}", left_style),
        ]
    ]
    meta_table = Table(meta_data, colWidths=[266, 266, 268])
    meta_table.setStyle(TableStyle([
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('INNERGRID', (0, 0), (-1, -1), 1, colors.black),
        ('PADDING', (0, 0), (-1, -1), 6),
        ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor('#F8FAFC')),
    ]))
    elements.append(meta_table)
    elements.append(Spacer(1, 15))

    # 3. Production Summary Table
    prod_table_data = [
        [Paragraph("<font color='white'><b>PRODUCTION FIELD</b></font>", bold_cell), Paragraph("<font color='white'><b>VALUE / COUNT</b></font>", bold_cell), Paragraph("<font color='white'><b>REMARKS / STATUS</b></font>", bold_cell)],
        [Paragraph("Production Target", bold_left), Paragraph(str(report.production_target), cell_style), Paragraph("Target Shift Output", left_style)],
        [Paragraph("Jobs Completed", bold_left), Paragraph(str(report.jobs_completed), cell_style), Paragraph("Total Produced", left_style)],
        [Paragraph("Correct Jobs (Pass)", bold_left), Paragraph(str(report.correct_jobs), cell_style), Paragraph("Accepted Units", left_style)],
        [Paragraph("Incorrect Jobs (Rejections)", bold_left), Paragraph(str(report.incorrect_jobs), cell_style), Paragraph("Total Defective / Rejected", left_style)],
        [Paragraph("  ├ Customer Rejection (CR)", left_style), Paragraph(str(report.cr_count), cell_style), Paragraph("CR Quantity", left_style)],
        [Paragraph("  ├ Machine Rejection (MR)", left_style), Paragraph(str(report.mr_count), cell_style), Paragraph("MR Quantity", left_style)],
        [Paragraph("  └ Rework (RW)", left_style), Paragraph(str(report.rw_count), cell_style), Paragraph("RW Quantity", left_style)],
        [Paragraph("<b>PRODUCTION ACHIEVEMENT %</b>", bold_left), Paragraph(f"<b>{report.achievement_percentage}%</b>", bold_cell), Paragraph(f"<b>{'TARGET MET' if report.achievement_percentage >= 100 else 'UNDER TARGET'}</b>", bold_cell)],
    ]
    prod_table = Table(prod_table_data, colWidths=[300, 200, 300])
    prod_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#1E293B')),
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('INNERGRID', (0, 0), (-1, -1), 1, colors.black),
        ('PADDING', (0, 0), (-1, -1), 6),
        ('BACKGROUND', (0, -1), (-1, -1), colors.HexColor('#DCFCE7') if report.achievement_percentage >= 100 else colors.HexColor('#FEF3C7')),
    ]))
    elements.append(prod_table)
    elements.append(Spacer(1, 15))

    # 4. Remarks Box
    if report.remarks:
        rem_data = [[Paragraph(f"<b>OPERATOR REMARKS:</b> {report.remarks}", left_style)]]
        rem_table = Table(rem_data, colWidths=[800])
        rem_table.setStyle(TableStyle([
            ('BOX', (0, 0), (-1, -1), 1, colors.black),
            ('PADDING', (0, 0), (-1, -1), 6),
            ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor('#F1F5F9')),
        ]))
        elements.append(rem_table)
        elements.append(Spacer(1, 20))

    # 5. Signatures
    sig_data = [
        [Paragraph(f"<i>{op_name}</i>", cell_style), Paragraph("<i>Verified Inspector</i>", cell_style), Paragraph("<i>Verified Supervisor</i>", cell_style)],
        [Paragraph("---------------------------------------", cell_style), Paragraph("---------------------------------------", cell_style), Paragraph("---------------------------------------", cell_style)],
        [Paragraph("<b>OPERATOR SIGNATURE</b>", bold_cell), Paragraph("<b>QUALITY INSPECTOR SIGNATURE</b>", bold_cell), Paragraph("<b>SUPERVISOR SIGNATURE</b>", bold_cell)]
    ]
    sig_table = Table(sig_data, colWidths=[266, 266, 268])
    sig_table.setStyle(TableStyle([
        ('VALIGN', (0, 0), (-1, -1), 'BOTTOM'),
        ('PADDING', (0, 0), (-1, -1), 2),
    ]))
    elements.append(sig_table)

    doc.build(elements)
    return f"media/pdf_reports/{file_name}"


def generate_downtime_pdf(qs, date_str: str, shift_str: str) -> str:
    media_pdf_dir = os.path.join(settings.MEDIA_ROOT, 'pdf_reports')
    os.makedirs(media_pdf_dir, exist_ok=True)

    file_name = f"Downtime_Report_{date_str}_{shift_str}.pdf"
    file_path = os.path.join(media_pdf_dir, file_name)

    doc = SimpleDocTemplate(
        file_path,
        pagesize=landscape(A4),
        rightMargin=15,
        leftMargin=15,
        topMargin=15,
        bottomMargin=15
    )

    styles = getSampleStyleSheet()

    title_style = ParagraphStyle('Title', fontName='Helvetica-Bold', fontSize=14, alignment=1)
    subtitle_style = ParagraphStyle('SubTitle', fontName='Helvetica-Bold', fontSize=10, alignment=1)
    doc_ref_style = ParagraphStyle('DocRef', fontName='Helvetica-Bold', fontSize=8, alignment=2)
    cyan_header_style = ParagraphStyle('CyanHeader', fontName='Helvetica-Bold', fontSize=14, alignment=1)
    cell_style = ParagraphStyle('Cell', fontName='Helvetica', fontSize=7, alignment=1)
    bold_cell = ParagraphStyle('BoldCell', fontName='Helvetica-Bold', fontSize=7, alignment=1)

    elements = []
    
    fac_name, fac_code = get_factory_info(qs)

    # 1. Header Table (Hanuman Engineering Works / DOWN TIME REPORT / Doc Ref)
    header_data = [
        [
            Paragraph(f"<b>{fac_name.upper()}</b>", title_style),
            Paragraph("<b>DOWN TIME REPORT</b>", cyan_header_style),
            Paragraph(f"<b>FORMAT NO. :- {fac_code}/QF/MF-06</b><br/>REV. No./ Date :- 00 / 30.09.2026<br/><b>Shift:</b> " + str(shift_str), doc_ref_style)
        ]
    ]
    header_table = Table(header_data, colWidths=[200, 420, 190])
    header_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor('#B0E0E6')),  # Excel Cyan Color
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('INNERGRID', (0, 0), (-1, -1), 1, colors.black),
        ('PADDING', (0, 0), (-1, -1), 6),
    ]))
    elements.append(header_table)
    elements.append(Spacer(1, 6))

    # 2. Date Sub-Header Banner
    date_data = [[Paragraph(f"<b>DATE:</b> {date_str} &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; <b>SHIFT:</b> {shift_str}", ParagraphStyle('LeftDate', fontName='Helvetica-Bold', fontSize=9, alignment=0))]]
    date_table = Table(date_data, colWidths=[810])
    date_table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor('#E0F2FE')),
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('PADDING', (0, 0), (-1, -1), 4),
    ]))
    elements.append(date_table)
    elements.append(Spacer(1, 8))

    # 3. Main Data Table with Excel Merged Header Columns
    table_data = [
        [
            Paragraph("<b>Sr. No.</b>", bold_cell),
            Paragraph("<b>Machine No.</b>", bold_cell),
            Paragraph("<b>Operator Name</b>", bold_cell),
            Paragraph("<b>Target</b>", bold_cell),
            Paragraph("<b>Produced</b>", bold_cell),
            Paragraph("<b>Accepted / Actual</b>", bold_cell),
            Paragraph("<b>Rejection Summary</b>", bold_cell), "", "",
            Paragraph("<b>DOWN TIME IN MINUTES</b>", bold_cell), "", "", "", "", "", "", "", "",
            Paragraph("<b>Total Down Time (Min.)</b>", bold_cell),
            Paragraph("<b>Remarks</b>", bold_cell)
        ],
        [
            "", "", "", "", "", "",
            Paragraph("<b>CR</b>", bold_cell), Paragraph("<b>MR</b>", bold_cell), Paragraph("<b>RW</b>", bold_cell),
            Paragraph("<b>NO LOAD</b>", bold_cell), Paragraph("<b>NO OPERATOR</b>", bold_cell), Paragraph("<b>U/M</b>", bold_cell),
            Paragraph("<b>SETTING</b>", bold_cell), Paragraph("<b>INSP. WAIT</b>", bold_cell), Paragraph("<b>TOOL CHANGE</b>", bold_cell),
            Paragraph("<b>P/O</b>", bold_cell), Paragraph("<b>R/W</b>", bold_cell), Paragraph("<b>TOOL PROB</b>", bold_cell),
            "", ""
        ]
    ]

    total_downtime_sum = 0
    total_produced_sum = 0
    total_accepted_sum = 0

    for idx, obj in enumerate(qs, 1):
        prod = obj.production_report
        op_name = prod.operator.get_full_name().strip() if prod.operator else '-'
        if not op_name and prod.operator:
            op_name = prod.operator.username

        total_downtime_sum += obj.total_downtime
        total_produced_sum += prod.jobs_completed
        total_accepted_sum += prod.correct_jobs

        table_data.append([
            Paragraph(str(idx), cell_style),
            Paragraph(prod.machine.machine_code, bold_cell),
            Paragraph(op_name, cell_style),
            Paragraph(str(prod.production_target), cell_style),
            Paragraph(str(prod.jobs_completed), cell_style),
            Paragraph(str(prod.correct_jobs), cell_style),
            Paragraph(str(prod.cr_count), cell_style),
            Paragraph(str(prod.mr_count), cell_style),
            Paragraph(str(prod.rw_count), cell_style),
            Paragraph(str(obj.no_load), cell_style),
            Paragraph(str(obj.no_operator), cell_style),
            Paragraph(str(obj.um), cell_style),
            Paragraph(str(obj.setting), cell_style),
            Paragraph(str(obj.inspection_wait), cell_style),
            Paragraph(str(obj.tool_change), cell_style),
            Paragraph(str(obj.power_off), cell_style),
            Paragraph(str(obj.rework), cell_style),
            Paragraph(str(obj.tool_problem), cell_style),
            Paragraph(str(obj.total_downtime), bold_cell),
            Paragraph(obj.remarks or '-', cell_style)
        ])

    # Summary Row
    if len(qs) > 0:
        table_data.append([
            Paragraph("<b>TOTAL</b>", bold_cell), "", "", "",
            Paragraph(f"<b>{total_produced_sum}</b>", bold_cell),
            Paragraph(f"<b>{total_accepted_sum}</b>", bold_cell),
            "", "", "", "", "", "", "", "", "", "", "", "",
            Paragraph(f"<b>{total_downtime_sum} Min.</b>", bold_cell),
            ""
        ])

    col_widths = [25, 50, 65, 35, 40, 50, 25, 25, 25, 35, 45, 30, 40, 40, 45, 30, 30, 35, 55, 75]
    main_table = Table(table_data, colWidths=col_widths, repeatRows=2)

    ts = [
        ('BACKGROUND', (0, 0), (-1, 1), colors.HexColor('#B0E0E6')),
        ('BOX', (0, 0), (-1, -1), 1, colors.black),
        ('INNERGRID', (0, 0), (-1, -1), 0.5, colors.black),
        ('SPAN', (0, 0), (0, 1)),
        ('SPAN', (1, 0), (1, 1)),
        ('SPAN', (2, 0), (2, 1)),
        ('SPAN', (3, 0), (3, 1)),
        ('SPAN', (4, 0), (4, 1)),
        ('SPAN', (5, 0), (5, 1)),
        ('SPAN', (6, 0), (8, 0)),   # Rejection Summary span
        ('SPAN', (9, 0), (17, 0)),  # DOWN TIME IN MINUTES span
        ('SPAN', (18, 0), (18, 1)), # Total Down Time span
        ('SPAN', (19, 0), (19, 1)), # Remarks span
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('PADDING', (0, 0), (-1, -1), 3),
    ]

    if len(qs) > 0:
        summary_row_idx = len(table_data) - 1
        ts.extend([
            ('BACKGROUND', (0, summary_row_idx), (-1, summary_row_idx), colors.HexColor('#E2E8F0')),
            ('SPAN', (0, summary_row_idx), (3, summary_row_idx)),
        ])

    main_table.setStyle(TableStyle(ts))
    elements.append(main_table)

    doc.build(elements)
    return f"media/pdf_reports/{file_name}"


