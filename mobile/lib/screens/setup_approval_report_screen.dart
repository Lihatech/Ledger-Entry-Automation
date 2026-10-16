import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/company_provider.dart';
import '../providers/inspection_provider.dart';
import '../services/api_service.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter/foundation.dart';

/// Set Up Approval Reports Screen
///
/// Displays the official Setup Approval Report Sheet matching mobile card design:
///   - Top Header Grid: PROCESS NO, PART NAME & NO, INSPECTOR/OPERATOR, MACHINE NO, DATE & SHIFT, SETUP STATUS
///   - SECTION 1: PRODUCT PARAMETERS (QUALITY CHARACTERISTICS & DIMENSIONS)
///   - SECTION 2: PROCESS PARAMETERS (FIRST PIECE SETUP APPROVAL CHECKS)
///   - Columns: PARAMETER | SPECIFICATION | 1ST PC #1 | 1ST PC #2 | 1ST PC #3 | REMARK
///   - Reaction Plan & Signature Footer (OPERATOR, QUALITY INSPECTOR, SUPERVISOR)
class SetupApprovalReportScreen extends StatefulWidget {
  const SetupApprovalReportScreen({super.key});

  @override
  State<SetupApprovalReportScreen> createState() => _SetupApprovalReportScreenState();
}

class _SetupApprovalReportScreenState extends State<SetupApprovalReportScreen> {
  bool _isLoading = true;
  bool _isDownloadingPdf = false;
  DateTime? _selectedDate;
  String? _errorMessage;

  List<dynamic> _productParams = [];
  List<dynamic> _processParams = [];
  Map<String, Map<String, String>> _productResults = {};
  List<dynamic> _processParamEntries = [];
  Map<String, dynamic>? _setupApprovalData;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadReportData());
  }

  Future<void> _loadReportData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _setupApprovalData = null;
      _productResults = {};
      _processParamEntries = [];
    });

    final provider = Provider.of<InspectionProvider>(context, listen: false);
    var template = provider.selectedTemplate;
    final machine = provider.selectedMachine;

    try {
      final machineId = machine?['id'] as int? ?? 2;

      // Auto-fetch template if provider.selectedTemplate is null
      if (template == null || template['id'] == null) {
        var partNo = provider.selectedPart?['part_number'];
        if (partNo == null || partNo.toString().isEmpty) {
          final parts = await ApiService.getPartsByMachine(machineId);
          if (parts.isNotEmpty) {
            provider.selectPart(parts.first);
            partNo = parts.first['part_number'];
          } else {
            partNo = '1';
          }
        }
        final templates = await ApiService.getTemplatesByPart(partNo.toString());
        if (templates.isNotEmpty) {
          template = templates.first;
          provider.selectedTemplate = template;
        }
      }

      final templateId = (template != null && template['id'] != null) ? (template['id'] as int) : 1;

      _productParams = await ApiService.getParameters(templateId);
      _processParams = await ApiService.getProcessParameters(templateId);

      // Check for active or finalized inspection session document for this machine
      // Fix 3: Use first_piece_session_id so Setup Approval Report always shows
      // 1ST PC trial data (not hourly session data which has no trial_number).
      final dateStr = _selectedDate != null 
          ? "${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')}" 
          : null;

      final setupStatus = await ApiService.checkSetupApproved(machineId, date: dateStr);
      final reportSessionId = setupStatus['first_piece_session_id']
          ?? setupStatus['session_id'];

      if (reportSessionId != null) {
        final sessionDoc = await ApiService.getSessionDetail(reportSessionId.toString());
        if (sessionDoc != null) {
          _setupApprovalData = sessionDoc;
        }
      }

      _setupApprovalData ??= await ApiService.getSetupApprovalData(templateId, machineId, date: dateStr);

      if (_setupApprovalData != null && _setupApprovalData!['process_param_entries'] is List) {
        _processParamEntries = _setupApprovalData!['process_param_entries'] as List;
      }

      _productResults = {};

      // 1. Populate from backend session measurements
      // Fix 4: Null-safe trial_number mapping — preserve all 3 trial values.
      // Measurements with inspection_type='hourly' are ignored here (they belong
      // to the DailyProductionReport, not the SetupApproval F02 report).
      final measurements = _setupApprovalData?['process_param_entries'] as List? ?? [];
      for (final m in measurements) {
        final code = m['parameter_code']?.toString() ?? '';
        final name = m['parameter_name']?.toString() ?? '';
        
        // Setup Approval has trial_1, trial_2, trial_3
        if (code.isNotEmpty) _productResults.putIfAbsent(code, () => {});
        if (name.isNotEmpty) _productResults.putIfAbsent(name, () => {});

        final t1 = m['trial_1']?.toString() ?? '-';
        final t2 = m['trial_2']?.toString() ?? '-';
        final t3 = m['trial_3']?.toString() ?? '-';

        if (code.isNotEmpty) {
          _productResults[code]!['1'] = t1;
          _productResults[code]!['2'] = t2;
          _productResults[code]!['3'] = t3;
        }
        if (name.isNotEmpty) {
          _productResults[name]!['1'] = t1;
          _productResults[name]!['2'] = t2;
          _productResults[name]!['3'] = t3;
        }
      }

      // 2. Layer provider.recordedResults (only if inspection_type is first_piece)
      provider.recordedResults.forEach((code, val) {
        final inspType = val['inspection_type']?.toString() ?? 'first_piece';
        if (inspType == 'hourly') return; // skip hourly in this report
        final rawTrial = val['trial_number'];
        final trial = (rawTrial != null && rawTrial != 0)
            ? rawTrial.toString()
            : '1';
        final vStr = val['voice_raw_text']?.toString() ?? val['measured_value']?.toString() ?? '-';
        _productResults.putIfAbsent(code, () => {});
        _productResults[code]![trial] = vStr;
      });

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load Setup Approval Report: $e';
      });
    }
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF2563EB), 
              onPrimary: Colors.white,
              onSurface: Color(0xFF0F172A),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
      _loadReportData();
    }
  }

  Future<void> _downloadPDF() async {
    if (_setupApprovalData == null) return;
    
    final sessionId = _setupApprovalData!['id'] ?? _setupApprovalData!['session_id'];
    if (sessionId == null) return;
    
    setState(() => _isDownloadingPdf = true);
    
    try {
      final provider = Provider.of<InspectionProvider>(context, listen: false);
      final machineCode = provider.selectedMachine?['machine_code'] ?? provider.selectedMachine?['name'] ?? 'VMC-01';
      final partNumber = provider.selectedPart?['part_number'] ?? '1';
      final shift = _setupApprovalData!['shift']?.toString() ?? provider.shift;

      final filePath = await ApiService.downloadSessionPDF(
        sessionId.toString(),
        partNumber: partNumber.toString(),
        machineCode: machineCode.toString(),
        shift: shift.toString(),
      );
      
      setState(() => _isDownloadingPdf = false);
      if (mounted) {
        if (filePath != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(filePath == 'web_downloaded' ? '✅ PDF downloaded successfully!' : '✅ Official PDF Report downloaded successfully! Opening...'),
              backgroundColor: const Color(0xFF16A34A),
              duration: const Duration(seconds: 3),
            ),
          );
          if (filePath != 'web_downloaded') {
            OpenFilex.open(filePath);
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('❌ Failed to download PDF report. Please try again.'), backgroundColor: Colors.redAccent),
          );
        }
      }
    } catch (e) {
      setState(() => _isDownloadingPdf = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Error downloading PDF.'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final auth = Provider.of<AuthProvider>(context);

    final machineCode = provider.selectedMachine?['machine_code'] ?? provider.selectedMachine?['name'] ?? 'VMC-01';
    final partNumber = provider.selectedPart?['part_number'] ?? '1';
    final partName = provider.selectedPart?['part_name'] ?? 'poly v pulley';
    final processNo = provider.selectedTemplate?['version']?.toString() ?? '10';
    final inspectorName = _setupApprovalData?['inspector_name'] ?? auth.fullName ?? auth.username ?? 'Samruddhi Bartakke';
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    // Fix 5: Use backend started_at for report date (not DateTime.now())
    // This ensures the date shown matches the actual inspection date.
    final startedAtRaw = _setupApprovalData?['started_at']?.toString();
    final reportDate = (startedAtRaw != null && startedAtRaw.isNotEmpty)
        ? (DateTime.tryParse(startedAtRaw)?.toLocal() ?? DateTime.now())
        : DateTime.now();
    // Use shift from backend doc, then provider, then auth, then default 'I'
    final backendShift = _setupApprovalData?['shift']?.toString();
    final effectiveShift = backendShift?.isNotEmpty == true
        ? backendShift!
        : (provider.shift.isNotEmpty
            ? provider.shift
            : (auth.assignedShift != 'ALL' ? auth.assignedShift : 'I'));
    final dateStr = '${reportDate.day} ${months[reportDate.month]} ${reportDate.year} | Shift $effectiveShift';
    final status = _setupApprovalData?['status']?.toString().toUpperCase() ?? 'FINALIZED PASSED';

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Color(0xFF2563EB)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SET UP APPROVAL DAILY REPORT',
              style: TextStyle(
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.w900,
                fontSize: 14,
                letterSpacing: 0.5,
              ),
            ),
            Text(
              'Official First Piece & Process Setup Sheet',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 10),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month_rounded, color: Color(0xFF64748B)),
            tooltip: 'Select Date',
            onPressed: _pickDate,
          ),
          _isDownloadingPdf 
            ? const Center(child: Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFEAB308)))))
            : IconButton(
                icon: const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFEAB308)),
                tooltip: 'Download PDF',
                onPressed: _downloadPDF,
              ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF16A34A)),
            onPressed: _loadReportData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF2563EB)),
                  SizedBox(height: 16),
                  Text('Generating Official Set Up Report...', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                ],
              ),
            )
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 52),
                        const SizedBox(height: 12),
                        Text(_errorMessage!, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13), textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: _loadReportData,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('RETRY'),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white),
                        ),
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 10, spreadRadius: 1),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. BRANDING COMPANY HEADER
                        _buildCompanyHeaderBar(processNo),

                        // 2. TOP HEADER GRID MATCHING OFFICIAL REPORT
                        _buildTopReportHeader(processNo, partNumber, partName, inspectorName, machineCode, dateStr, status),

                        // 3. MAIN REPORT DATA TABLE (OFFICIAL 11-COLUMN FORM F02 GRID)
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Container(
                            width: 810,
                            color: Colors.white,
                            child: Table(
                              border: TableBorder.all(color: const Color(0xFF94A3B8), width: 1.0),
                              columnWidths: const {
                                0: FixedColumnWidth(35),   // P.NO
                                1: FixedColumnWidth(35),   // NO
                                2: FixedColumnWidth(180),  // PARAMETER NAME & DESCRIPTION
                                3: FixedColumnWidth(55),   // CLASS
                                4: FixedColumnWidth(130),  // SPECIFICATION
                                5: FixedColumnWidth(130),  // EVALUATION TECHNIQUE
                                6: FixedColumnWidth(80),   // SAMPLE FREQ
                                7: FixedColumnWidth(65),   // 1ST #1
                                8: FixedColumnWidth(65),   // 1ST #2
                                9: FixedColumnWidth(65),   // 1ST #3
                              },
                              children: [
                                // TABLE COLUMN HEADERS
                                _buildTableHeaderRow(),

                                // SECTION 1 BANNER: PRODUCT PARAMETER
                                _buildSectionBannerRow('PRODUCT PARAMETER'),

                                // SECTION 1 ROWS: PRODUCT PARAMETERS
                                ..._productParams.asMap().entries.map((e) => _buildProductRow(e.key, e.value)),

                                // SECTION 2 BANNER: PROCESS PARAMETER
                                _buildSectionBannerRow('PROCESS PARAMETER'),

                                // SECTION 2 ROWS: PROCESS PARAMETERS
                                ..._processParams.asMap().entries.map((e) => _buildProcessRow(e.key, e.value)),
                              ],
                            ),
                          ),
                        ),
                        
                        const SizedBox(height: 20),

                        // SIGNATURE / FOOTER BLOCK
                        _buildReportFooter(inspectorName),

                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
    );
  }

  // ── Company Branding Header Bar ─────────────────────────────────────────────
  Widget _buildCompanyHeaderBar(String processNo) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1.2),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            // MMPL Logo Box
            Container(
              width: 90,
              color: Colors.black,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Consumer<CompanyProvider>(
                builder: (context, company, _) {
                  return Text(
                    company.companyCode,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1.2),
                  );
                },
              ),
            ),
            Container(width: 1, color: Colors.black),
            // Title Center Box
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                alignment: Alignment.center,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Consumer<CompanyProvider>(
                      builder: (context, company, _) {
                        return Text(
                          company.companyName.toUpperCase(),
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Colors.black, letterSpacing: 0.5),
                        );
                      },
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'FIRST PIECE SETUP APPROVAL REPORT — PROCESS NO. $processNo',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 9.5, color: Color(0xFF1E3A8A)),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            Container(width: 1, color: Colors.black),
            // Document Ref Box
            Container(
              width: 100,
              padding: const EdgeInsets.all(4),
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Consumer<CompanyProvider>(
                    builder: (context, company, _) {
                      return Text('DOC REF: ${company.companyCode}/PRD/F02', style: const TextStyle(fontSize: 7.5, fontWeight: FontWeight.bold, color: Colors.black));
                    },
                  ),
                  const Text('REV: 02 (15.0.2013)', style: TextStyle(fontSize: 7.5, color: Color(0xFF64748B))),
                  const Text('PAGE 1 OF 1', style: TextStyle(fontSize: 7.5, fontWeight: FontWeight.bold, color: Colors.black)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Top Header Grid ────────────────────────────────────────────────────────
  Widget _buildTopReportHeader(
    String processNo,
    String partNumber,
    String partName,
    String inspectorName,
    String machineCode,
    String dateStr,
    String status,
  ) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          left: BorderSide(color: Colors.black, width: 1.2),
          right: BorderSide(color: Colors.black, width: 1.2),
          bottom: BorderSide(color: Colors.black, width: 1.2),
        ),
      ),
      child: Column(
        children: [
          // Row 1
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _headerBox('PROCESS NO: $processNo', isBold: true),
                ),
                Container(width: 1, color: Colors.black),
                Expanded(
                  flex: 7,
                  child: _headerBox('PART NAME & NO: $partNumber ($partName)', isBold: true),
                ),
                Container(width: 1, color: Colors.black),
                Expanded(
                  flex: 5,
                  child: _headerBox('INSPECTOR / OPERATOR: $inspectorName', isBold: true),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.black, thickness: 1),
          // Row 2
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: _headerBox('MACHINE NO: $machineCode', isBold: true),
                ),
                Container(width: 1, color: Colors.black),
                Expanded(
                  flex: 6,
                  child: _headerBox('DATE & SHIFT: $dateStr'),
                ),
                Container(width: 1, color: Colors.black),
                Expanded(
                  flex: 4,
                  child: _headerBox('SETUP STATUS: $status', isStatus: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerBox(String text, {bool isBold = false, bool isStatus = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: isStatus ? const Color(0xFFF0FDF4) : Colors.white,
      child: Text(
        text,
        style: TextStyle(
          color: isStatus ? const Color(0xFF166534) : Colors.black,
          fontWeight: isBold || isStatus ? FontWeight.bold : FontWeight.w600,
          fontSize: 10,
        ),
      ),
    );
  }

  // ── Table Column Headers Row (Official 10 Columns) ────────────────────────
  TableRow _buildTableHeaderRow() {
    return const TableRow(
      decoration: BoxDecoration(color: Color(0xFFE2E8F0)),
      children: [
        _HeaderCell('P.NO', width: 35),
        _HeaderCell('NO', width: 35),
        _HeaderCell('PARAMETER NAME & DESCRIPTION', width: 180, alignLeft: true),
        _HeaderCell('CLASS', width: 55),
        _HeaderCell('SPECIFICATION', width: 130),
        _HeaderCell('EVALUATION TECHNIQUE', width: 130),
        _HeaderCell('SAMPLE FREQ', width: 80),
        _HeaderCell('1ST #1', width: 65, color: Color(0xFF1E40AF)),
        _HeaderCell('1ST #2', width: 65, color: Color(0xFFB45309)),
        _HeaderCell('1ST #3', width: 65, color: Color(0xFF047857)),
      ],
    );
  }

  TableRow _buildSectionBannerRow(String title) {
    return TableRow(
      decoration: const BoxDecoration(color: Colors.white),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(
            title,
            style: const TextStyle(color: Color(0xFF1E3A8A), fontWeight: FontWeight.bold, fontSize: 10.5, letterSpacing: 0.5),
            overflow: TextOverflow.visible,
          ),
        ),
        for (int i = 0; i < 9; i++) const SizedBox.shrink(),
      ],
    );
  }

  // ── Product Parameter Row (Official 10 Columns) ─────────────────────────────
  TableRow _buildProductRow(int index, Map<String, dynamic> param) {
    final code = param['parameter_code']?.toString() ?? '';
    final name = param['parameter_name']?.toString() ?? code;
    final nominal = param['nominal_value'] ?? param['nominal'] ?? 0.0;
    final unit = param['unit']?.toString() ?? 'mm';
    final upper = param['upper_tolerance'] ?? param['upper_limit'] ?? 0.0;
    final lower = param['lower_tolerance'] ?? param['lower_limit'] ?? 0.0;
    final isCritical = param['is_critical'] == true || param['critical'] == true;
    final evalMethod = param['evaluation_technique']?.toString() ?? param['method']?.toString() ?? 'VERNIER CALIPER';
    final sampleFreq = param['sample_frequency']?.toString() ?? '5NOS/SHIFT';
    final itemNo = (index + 1).toString().padLeft(2, '0');

    final t1 = _productResults[code]?['1'] ?? _productResults[name]?['1'] ?? '-';
    final t2 = _productResults[code]?['2'] ?? _productResults[name]?['2'] ?? '-';
    final t3 = _productResults[code]?['3'] ?? _productResults[name]?['3'] ?? '-';

    return TableRow(
      decoration: const BoxDecoration(color: Colors.white),
      children: [
        _cell('10.', align: Alignment.center, isBold: true),
        _cell(itemNo, align: Alignment.center, isBold: true),
        Container(
          padding: const EdgeInsets.all(5),
          alignment: Alignment.centerLeft,
          child: Text(name, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 10.5)),
        ),
        _cell(isCritical ? 'CRITICAL' : '—', align: Alignment.center, isBold: isCritical, color: isCritical ? Colors.red : Colors.black),
        Container(
          padding: const EdgeInsets.all(5),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$nominal $unit', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 10)),
              Text('[$lower to $upper]', style: const TextStyle(color: Color(0xFF64748B), fontSize: 8.5, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        _cell(evalMethod.toUpperCase(), align: Alignment.center),
        _cell(sampleFreq, align: Alignment.center),
        _cellValueText(t1),
        _cellValueText(t2),
        _cellValueText(t3),
      ],
    );
  }

  // ── Process Parameter Row (Official 10 Columns) ─────────────────────────────
  TableRow _buildProcessRow(int index, Map<String, dynamic> pp) {
    final code = pp['parameter_code']?.toString() ?? '';
    final name = pp['parameter_name']?.toString() ?? '';
    final rawSpec = pp['specification']?.toString() ?? '-';
    final rawUnit = pp['unit']?.toString() ?? '';
    final evalMethod = pp['evaluation_technique']?.toString() ?? 'CHECKLIST / DISPLAY';
    final sampleFreq = '1ST PC ONLY';
    final itemNo = (index + 1).toString().padLeft(2, '0');

    final spec = rawSpec.replaceAll('RPM RPM', 'RPM').replaceAll('mm/rev mm/rev', 'mm/rev').replaceAll('Bar Bar', 'Bar');
    final unit = rawUnit.replaceAll('RPM RPM', 'RPM').replaceAll('mm/rev mm/rev', 'mm/rev').replaceAll('Bar Bar', 'Bar');
    final specDisplay = (unit.isNotEmpty && !spec.endsWith(unit)) ? '$spec $unit' : spec;

    final Map<String, Map<String, String>> entriesByKey = {};
    for (final entry in _processParamEntries) {
      final c = entry['parameter_code']?.toString() ?? '';
      final n = entry['parameter_name']?.toString() ?? '';
      final vals = {
        '1': (entry['trial_1'] != null && entry['trial_1'].toString().trim().isNotEmpty) ? entry['trial_1'].toString().trim() : '-',
        '2': (entry['trial_2'] != null && entry['trial_2'].toString().trim().isNotEmpty) ? entry['trial_2'].toString().trim() : '-',
        '3': (entry['trial_3'] != null && entry['trial_3'].toString().trim().isNotEmpty) ? entry['trial_3'].toString().trim() : '-',
      };
      if (c.isNotEmpty) entriesByKey[c] = vals;
      if (n.isNotEmpty) entriesByKey[n] = vals;
    }

    final t1 = entriesByKey[code]?['1'] ?? entriesByKey[name]?['1'] ?? _productResults[code]?['1'] ?? _productResults[name]?['1'] ?? '-';
    final t2 = entriesByKey[code]?['2'] ?? entriesByKey[name]?['2'] ?? _productResults[code]?['2'] ?? _productResults[name]?['2'] ?? '-';
    final t3 = entriesByKey[code]?['3'] ?? entriesByKey[name]?['3'] ?? _productResults[code]?['3'] ?? _productResults[name]?['3'] ?? '-';

    return TableRow(
      decoration: const BoxDecoration(color: Colors.white),
      children: [
        _cell('10.', align: Alignment.center, isBold: true),
        _cell(itemNo, align: Alignment.center, isBold: true),
        Container(
          padding: const EdgeInsets.all(5),
          alignment: Alignment.centerLeft,
          child: Text('[PROC] $name', style: const TextStyle(color: Color(0xFF1E40AF), fontWeight: FontWeight.bold, fontSize: 10)),
        ),
        _cell('PROC', align: Alignment.center, isBold: true, color: const Color(0xFF1E40AF)),
        Container(
          padding: const EdgeInsets.all(5),
          alignment: Alignment.center,
          child: Text(specDisplay, style: const TextStyle(color: Colors.black, fontSize: 9.5, fontWeight: FontWeight.w600)),
        ),
        _cell(evalMethod.toUpperCase(), align: Alignment.center),
        _cell(sampleFreq, align: Alignment.center),
        _cellValueText(t1),
        _cellValueText(t2),
        _cellValueText(t3),
      ],
    );
  }

  List<dynamic> _getProcessParamRowsList() {
    if (_processParams.isNotEmpty) return _processParams;
    if (_processParamEntries.isNotEmpty) {
      return _processParamEntries.map((e) => {
        'parameter_code': e['parameter_code'],
        'parameter_name': e['parameter_name'] ?? e['parameter_code'],
        'specification': '-',
      }).toList();
    }
    return [
      {'parameter_code': 'PR-01', 'parameter_name': 'Spindle Speed (OD Finish)', 'specification': '800 - 1000 RPM', 'unit': 'RPM'},
      {'parameter_code': 'PR-02', 'parameter_name': 'Feed Rate (OD Finish)', 'specification': '0.20 - 0.40 mm/rev', 'unit': 'mm/rev'},
      {'parameter_code': 'PR-03', 'parameter_name': 'Feed Rate (ID Rough)', 'specification': '0.10 - 0.35 mm/rev', 'unit': 'mm/rev'},
      {'parameter_code': 'PR-04', 'parameter_name': 'Resting Face Parallelity', 'specification': '0.02 Max.', 'unit': 'mm'},
      {'parameter_code': 'PR-05', 'parameter_name': 'Jaw Runout', 'specification': '0.02 Max.', 'unit': 'mm'},
      {'parameter_code': 'PR-06', 'parameter_name': 'Chuck Pressure', 'specification': '10 - 16 Bar', 'unit': 'Bar'},
    ];
  }

  Widget _cell(String text, {Alignment align = Alignment.centerLeft, bool isBold = false, Color color = Colors.black}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      alignment: align,
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          fontSize: 9,
        ),
      ),
    );
  }

  Widget _cellValueText(String val) {
    final isReject = val.contains('NO') || val.contains('REJECT') || val == '3940';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      alignment: Alignment.center,
      child: Text(
        val,
        style: TextStyle(
          color: isReject ? Colors.red : (val == '-' ? const Color(0xFF94A3B8) : Colors.black),
          fontWeight: isReject || val != '-' ? FontWeight.bold : FontWeight.normal,
          fontSize: 9.5,
        ),
      ),
    );
  }

  // ── Footer with Reaction Plan & Signatures ─────────────────────────────────
  Widget _buildReportFooter(String inspectorName) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1.2),
      ),
      child: Column(
        children: [
          // Reaction Plan
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            color: const Color(0xFFF8FAFC),
            child: const Text(
              'REACTION PLAN: REJECT, REWORK, SEGREGATE, INFORM SUPERVISOR OR READJUST THE PROCESS',
              style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 8.5),
            ),
          ),
          const Divider(height: 1, color: Colors.black, thickness: 1),

          // Signatures Row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(child: _sigCol('OPERATOR SIGNATURE', inspectorName)),
                Expanded(child: _sigCol('QUALITY INSPECTOR SIGNATURE', inspectorName)),
                Expanded(child: _sigCol('SUPERVISOR SIGNATURE', 'Supervisor Sign')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sigCol(String label, String name) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Text(
            name,
            style: const TextStyle(color: Colors.black, fontStyle: FontStyle.italic, fontWeight: FontWeight.w600, fontSize: 9.5),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          const SizedBox(height: 2),
          Container(height: 1, color: Colors.black54),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 7.5),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String title;
  final double width;
  final bool alignLeft;
  final Color? color;

  const _HeaderCell(this.title, {required this.width, this.alignLeft = false, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      alignment: alignLeft ? Alignment.centerLeft : Alignment.center,
      child: Text(
        title,
        style: TextStyle(
          color: color ?? const Color(0xFF334155),
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }
}
