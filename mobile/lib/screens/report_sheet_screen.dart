import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:open_filex/open_filex.dart';

import '../providers/auth_provider.dart';
import '../providers/inspection_provider.dart';
import '../providers/company_provider.dart';
import '../services/api_service.dart';
import 'app_home_screen.dart';

class ReportSheetScreen extends StatefulWidget {
  final String? sessionId;
  final Map<String, dynamic>? template;

  const ReportSheetScreen({super.key, this.sessionId, this.template});

  @override
  State<ReportSheetScreen> createState() => _ReportSheetScreenState();
}

class _ReportSheetScreenState extends State<ReportSheetScreen> {
  bool _isLoading = true;
  bool _isDownloadingPdf = false;
  Map<String, dynamic>? _sessionDoc;
  List<dynamic> _machines = [];
  String? _selectedMachineCode;
  List<dynamic> _todaySessions = [];
  String? _activeSessionId;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _initData();
    // Auto-refresh live sheet every 3 seconds for real-time live view
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        _fetchLiveReport(showLoading: false);
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _initData() async {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final machines = await ApiService.getMachines();
    if (mounted) {
      setState(() {
        _machines = machines;
        _selectedMachineCode = provider.selectedMachine?['machine_code'] ??
            (machines.isNotEmpty ? (machines.first['machine_code'] ?? 'VMC-01') : 'VMC-01');
      });
      await _fetchLiveReport(showLoading: true);
    }
  }

  Future<void> _fetchLiveReport({bool showLoading = true}) async {
    if (showLoading && _sessionDoc == null) {
      setState(() => _isLoading = true);
    }

    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final code = _selectedMachineCode ?? provider.selectedMachine?['machine_code'] ?? 'VMC-01';

    try {
      if (widget.sessionId != null && widget.sessionId!.isNotEmpty && _activeSessionId == null) {
        _activeSessionId = widget.sessionId;
      }

      // Query sessions for the currently selected machine
      final sessions = await ApiService.getSessions(machineCode: code);
      if (sessions.isNotEmpty && mounted) {
        final todayISO = DateTime.now().toIso8601String().substring(0, 10);
        final now = DateTime.now();
        final todayLocal = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

        final matchingToday = sessions.where((s) {
          final startedAt = s['started_at']?.toString() ?? '';
          final sDate = startedAt.length >= 10 ? startedAt.substring(0, 10) : '';
          return sDate == todayISO || sDate == todayLocal;
        }).toList();

        final listToUse = matchingToday.isNotEmpty ? matchingToday : sessions;

        // Group by operation so user can toggle between OP 10, OP 20, OP 30
        final Map<String, dynamic> opMap = {};
        for (final s in listToUse) {
          final tid = s['template_id']?.toString() ?? s['template_version']?.toString() ?? s['session_id']?.toString() ?? '';
          if (tid.isNotEmpty && !opMap.containsKey(tid)) {
            opMap[tid] = s;
          }
        }
        final opsList = opMap.values.toList();

        dynamic targetSession;
        if (_activeSessionId != null) {
          targetSession = listToUse.firstWhere((s) => s['session_id'] == _activeSessionId, orElse: () => null);
        }
        if (targetSession == null && widget.template != null && widget.template!['id'] != null) {
          final reqTid = widget.template!['id'];
          targetSession = listToUse.firstWhere((s) => s['template_id'] == reqTid, orElse: () => null);
        }
        if (targetSession == null && opsList.isNotEmpty) {
          targetSession = opsList.first;
        }
        if (targetSession == null && listToUse.isNotEmpty) {
          targetSession = listToUse.first;
        }

        if (targetSession != null) {
          final sId = targetSession['session_id'];
          if (sId != null) {
            final doc = await ApiService.getSessionDetail(sId);
            if (doc != null && mounted) {
              setState(() {
                _sessionDoc = doc;
                _todaySessions = opsList;
                _activeSessionId = sId;
                _isLoading = false;
              });
              return;
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _sessionDoc = null;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[REPORT SHEET] Error fetching live report: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _downloadPdfReport() async {
    final sId = _sessionDoc?['session_id'] ?? widget.sessionId;
    if (sId == null || sId.toString().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active report session found to export PDF.'), backgroundColor: Colors.orangeAccent),
      );
      return;
    }

    setState(() => _isDownloadingPdf = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('⏳ Generating & Downloading official PDF report...'), backgroundColor: Color(0xFF0284C7)),
    );

    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final partNo = _sessionDoc?['part_number']?.toString() ?? provider.selectedPart?['part_number']?.toString();
    final mcCode = _sessionDoc?['machine_code']?.toString() ?? provider.selectedMachine?['machine_code']?.toString();
    final shift = _sessionDoc?['shift']?.toString() ?? provider.shift;

    final filePath = await ApiService.downloadSessionPDF(
      sId.toString(),
      partNumber: partNo,
      machineCode: mcCode,
      shift: shift,
    );

    if (mounted) {
      setState(() => _isDownloadingPdf = false);
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
  }

  void _navigateHome(BuildContext context, AuthProvider auth) {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    provider.resetForNextOperation();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const AppHomeScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final auth = Provider.of<AuthProvider>(context);

    final activeMachineCode = _selectedMachineCode ?? _sessionDoc?['machine_code'] ?? provider.selectedMachine?['machine_code'] ?? 'VMC-01';
    final partNumber = _sessionDoc?['part_number'] ?? provider.selectedPart?['part_number'] ?? '1';
    final partName = _sessionDoc?['part_name'] ?? provider.selectedPart?['part_name'] ?? 'poly v pulley';
    final operatorName = _sessionDoc?['operator_name'] ?? auth.fullName ?? auth.username ?? 'Operator';
    final shift = _sessionDoc?['shift'] ?? (auth.isShiftLocked ? auth.assignedShift : (provider.shift.isNotEmpty ? provider.shift : 'I'));
    final status = _sessionDoc?['status'] ?? 'IN_PROGRESS';

    // Parameters summary list
    final List<dynamic> parameters = _sessionDoc?['parameter_summary'] ?? provider.parameters;

    // Measurements array
    final List<dynamic> measurements = _sessionDoc?['measurements'] ?? [];

    // Map measurements by parameter_code
    final Map<String, List<dynamic>> measMap = {};
    for (var m in measurements) {
      final code = m['parameter_code']?.toString() ?? '';
      if (code.isNotEmpty) {
        measMap.putIfAbsent(code, () => []).add(m);
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9), // Light paper background
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: Text(
          'Live Report: $activeMachineCode',
          style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        actions: [
          if (_sessionDoc != null)
            IconButton(
              icon: _isDownloadingPdf
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD97706)))
                  : const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFD97706)),
              tooltip: 'Export Official PDF',
              onPressed: _isDownloadingPdf ? null : _downloadPdfReport,
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF16A34A)),
            tooltip: 'Refresh Live View',
            onPressed: () => _fetchLiveReport(showLoading: true),
          ),
          IconButton(
            icon: const Icon(Icons.home_rounded, color: Color(0xFF2563EB)),
            tooltip: 'Return Home',
            onPressed: () => _navigateHome(context, auth),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _fetchLiveReport(showLoading: false),
          color: const Color(0xFF2563EB),
          backgroundColor: Colors.white,
          child: Column(
            children: [
              // Machine Selector Strip (Light Theme Chips)
              if (_machines.isNotEmpty) ...[
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _machines.map((m) {
                        final mCode = m['machine_code']?.toString() ?? 'M';
                        final isSelected = mCode == activeMachineCode;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              mCode,
                              style: TextStyle(
                                color: isSelected ? Colors.white : const Color(0xFF334155),
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: const Color(0xFF2563EB),
                            backgroundColor: const Color(0xFFE2E8F0),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            onSelected: (selected) {
                              if (selected) {
                                setState(() {
                                  _selectedMachineCode = mCode;
                                  _sessionDoc = null;
                                });
                                _fetchLiveReport(showLoading: true);
                              }
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE2E8F0)),
              ],

              // Operation Selector Strip (when multiple operations exist for this machine)
              if (_todaySessions.length > 1) ...[
                Container(
                  color: const Color(0xFFF8FAFC),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Text(
                            'OPERATION:',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF64748B),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        ..._todaySessions.map((s) {
                          final sId = s['session_id']?.toString() ?? '';
                          final v = s['template_version']?.toString() ?? '';
                          final name = s['template_name']?.toString() ?? (v.isNotEmpty ? 'Op $v' : 'Op');
                          final isSelected = sId == _activeSessionId;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(
                                v.isNotEmpty ? 'OP $v: $name' : name,
                                style: TextStyle(
                                  color: isSelected ? Colors.white : const Color(0xFF334155),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                              selected: isSelected,
                              selectedColor: const Color(0xFF0D9488),
                              backgroundColor: const Color(0xFFE2E8F0),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              onSelected: (selected) {
                                if (selected) {
                                  setState(() {
                                    _activeSessionId = sId;
                                    _sessionDoc = null;
                                  });
                                  _fetchLiveReport(showLoading: true);
                                }
                              },
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE2E8F0)),
              ],

              Expanded(
                child: _isLoading && _sessionDoc == null
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFF2563EB)))
                    : _sessionDoc == null
                        ? SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(height: 40),
                                  const Icon(Icons.table_rows_rounded, color: Color(0xFF94A3B8), size: 64),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No Live Inspection Started Today ($activeMachineCode)',
                                    style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'No live report has been started for this machine today.',
                                    style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 24),
                                  ElevatedButton.icon(
                                    onPressed: () => _fetchLiveReport(showLoading: true),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF2563EB),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    ),
                                    icon: const Icon(Icons.refresh_rounded, size: 18),
                                    label: const Text('REFRESH SHEET', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Official White Paper Document Sheet Container
                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF475569), width: 1.5),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.08),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Header Row 1: Logo | Title | Document Info
                                      Container(
                                        decoration: const BoxDecoration(
                                          border: Border(bottom: BorderSide(color: Color(0xFF475569), width: 1.5)),
                                        ),
                                        child: Row(
                                          children: [
                                            // MMPL Black Box
                                            Container(
                                              width: 90,
                                              height: 54,
                                              color: Colors.black,
                                              alignment: Alignment.center,
                                              child: Consumer<CompanyProvider>(
                                                builder: (context, company, _) {
                                                  return Text(
                                                    company.companyCode,
                                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1.5),
                                                  );
                                                },
                                              ),
                                            ),
                                            Container(width: 1.5, height: 54, color: const Color(0xFF475569)),
                                            // Title Block
                                            Expanded(
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                child: Column(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Consumer<CompanyProvider>(
                                                      builder: (context, company, _) {
                                                        return Text(
                                                          company.companyName.toUpperCase(),
                                                          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5),
                                                          textAlign: TextAlign.center,
                                                        );
                                                      },
                                                    ),
                                                    const SizedBox(height: 2),
                                                    const Text(
                                                      '1ST PIECE CUM IN-PROCESS INSPECTION REPORT',
                                                      style: TextStyle(color: Color(0xFF1E293B), fontWeight: FontWeight.bold, fontSize: 10),
                                                      textAlign: TextAlign.center,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            Container(width: 1.5, height: 54, color: const Color(0xFF475569)),
                                            // Doc Ref Block
                                            Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              child: Column(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Consumer<CompanyProvider>(
                                                    builder: (context, company, _) {
                                                      return Text('DOC REF: ${company.companyCode}/PRD/F02', style: const TextStyle(color: Colors.black, fontSize: 8, fontWeight: FontWeight.bold));
                                                    },
                                                  ),
                                                  const Text('REV: 02 (15.8.2013)', style: TextStyle(color: Color(0xFF64748B), fontSize: 8)),
                                                  const SizedBox(height: 2),
                                                  const Text('LIVE VIEW', style: TextStyle(color: Color(0xFF7C3AED), fontWeight: FontWeight.w900, fontSize: 9)),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Header Row 2: Part | Operator | Machine
                                      Container(
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFF8FAFC),
                                          border: Border(bottom: BorderSide(color: Color(0xFF475569), width: 1.5)),
                                        ),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              flex: 3,
                                              child: RichText(
                                                text: TextSpan(
                                                  style: const TextStyle(color: Colors.black, fontSize: 11),
                                                  children: [
                                                    const TextSpan(text: 'PART NO: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                                    TextSpan(text: '$partNumber ($partName)', style: const TextStyle(fontWeight: FontWeight.w600)),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 4,
                                              child: RichText(
                                                text: TextSpan(
                                                  style: const TextStyle(color: Colors.black, fontSize: 11),
                                                  children: [
                                                    const TextSpan(text: 'OPERATOR: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                                    TextSpan(text: operatorName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            RichText(
                                              text: TextSpan(
                                                style: const TextStyle(color: Colors.black, fontSize: 11),
                                                children: [
                                                  const TextSpan(text: 'MACHINE: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                                  TextSpan(text: activeMachineCode, style: const TextStyle(fontWeight: FontWeight.w600)),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Data Matrix Table Grid (Clean White Document Grid)
                                      SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Table(
                                          border: TableBorder.all(color: const Color(0xFF94A3B8), width: 1.0),
                                          defaultColumnWidth: const IntrinsicColumnWidth(),
                                          children: [
                                            // Table Header Row
                                            TableRow(
                                              decoration: const BoxDecoration(color: Color(0xFFE2E8F0)),
                                              children: [
                                                const _HeaderCell('PARAMETER', width: 140, alignLeft: true),
                                                const _HeaderCell('SPECIFICATION', width: 130),
                                                const _HeaderCell('1ST PC #1', width: 90, color: Color(0xFF1E40AF)),
                                                const _HeaderCell('1ST PC #2', width: 90, color: Color(0xFFB45309)),
                                                const _HeaderCell('1ST PC #3', width: 90, color: Color(0xFF047857)),
                                                for (int i = 1; i <= provider.shiftHours; i++)
                                                  _HeaderCell('$i/HR', width: 65),
                                              ],
                                            ),

                                            // Table Data Rows
                                            ...parameters.map((param) {
                                              final code = param['parameter_code']?.toString() ?? 'P1';
                                              final name = param['parameter_name']?.toString() ?? code;
                                              final nominal = param['nominal'] ?? param['nominal_value'] ?? 0.0;
                                              final lower = param['lower_limit'] ?? 0.0;
                                              final upper = param['upper_limit'] ?? 0.0;
                                              final unit = param['unit']?.toString() ?? 'mm';
                                              final voicePrompt = param['voice_prompt']?.toString() ?? code.replaceAll('P', '');

                                              // Fetch measurements for this parameter
                                              final pMeas = measMap[code] ?? [];

                                              // 1st Piece measurements
                                              final fpMeas = pMeas.where((m) =>
                                                m['inspection_type'] == 'first_piece' ||
                                                (m['hourly_slot'] == null || m['hourly_slot'] == 0)
                                              ).toList();

                                              dynamic m1 = fpMeas.firstWhere((m) => (m['trial_number'] ?? 1) == 1, orElse: () => null);
                                              dynamic m2 = fpMeas.firstWhere((m) => m['trial_number'] == 2, orElse: () => null);
                                              dynamic m3 = fpMeas.firstWhere((m) => m['trial_number'] == 3, orElse: () => null);

                                              // Hourly measurements map by slot 1..8
                                              final Map<int, dynamic> hourlyMap = {};
                                              for (var m in pMeas) {
                                                if (m['inspection_type'] == 'hourly' && (m['hourly_slot'] ?? 0) > 0) {
                                                  hourlyMap[m['hourly_slot']] = m;
                                                }
                                              }

                                              return TableRow(
                                                children: [
                                                  // PARAMETER Cell
                                                  Container(
                                                    width: 140,
                                                    padding: const EdgeInsets.all(6),
                                                    alignment: Alignment.centerLeft,
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      mainAxisAlignment: MainAxisAlignment.center,
                                                      children: [
                                                        Text(name, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 11)),
                                                        if (voicePrompt.isNotEmpty)
                                                          Text('# "$voicePrompt"', style: const TextStyle(color: Color(0xFF6D28D9), fontSize: 9, fontStyle: FontStyle.italic, fontWeight: FontWeight.bold)),
                                                      ],
                                                    ),
                                                  ),

                                                  // SPECIFICATION Cell
                                                  Container(
                                                    width: 130,
                                                    padding: const EdgeInsets.all(6),
                                                    alignment: Alignment.center,
                                                    child: Column(
                                                      mainAxisAlignment: MainAxisAlignment.center,
                                                      children: [
                                                        Text('$nominal $unit', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 11)),
                                                        Text('[$lower to $upper]', style: const TextStyle(color: Color(0xFF64748B), fontSize: 9, fontWeight: FontWeight.w600)),
                                                      ],
                                                    ),
                                                  ),

                                                  // 1ST PC #1
                                                  _buildDocumentDataCell(m1, width: 90),
                                                  // 1ST PC #2
                                                  _buildDocumentDataCell(m2, width: 90),
                                                  // 1ST PC #3
                                                  _buildDocumentDataCell(m3, width: 90),

                                                  // 1/HR through 8/HR
                                                  for (int slot = 1; slot <= 8; slot++)
                                                    _buildDocumentDataCell(hourlyMap[slot], width: 65),
                                                ],
                                              );
                                            }),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 12),

                                // Real-Time Status & Shift Footer Bar
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFFCBD5E1)),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF16A34A),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'REAL-TIME LIVE VIEW ($activeMachineCode · STATUS: $status)',
                                          style: const TextStyle(color: Color(0xFF16A34A), fontWeight: FontWeight.bold, fontSize: 11),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Text(
                                        'Shift $shift · ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
                                        style: const TextStyle(color: Color(0xFF64748B), fontSize: 11, fontWeight: FontWeight.w600),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 16),

                                // Action Buttons Row: Export PDF | Refresh | Home
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFFD97706),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                        icon: _isDownloadingPdf
                                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                            : const Icon(Icons.picture_as_pdf_rounded, size: 18),
                                        label: const Text('EXPORT PDF', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                        onPressed: _isDownloadingPdf ? null : _downloadPdfReport,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF16A34A),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                        icon: const Icon(Icons.refresh_rounded, size: 18),
                                        label: const Text('REFRESH', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                        onPressed: () => _fetchLiveReport(showLoading: true),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(0xFF2563EB),
                                          side: const BorderSide(color: Color(0xFF2563EB)),
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                        icon: const Icon(Icons.home_rounded, size: 18),
                                        label: const Text('HOME', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                        onPressed: () => _navigateHome(context, auth),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                              ],
                            ),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDocumentDataCell(dynamic m, {required double width}) {
    if (m == null) {
      return Container(
        width: width,
        height: 48,
        alignment: Alignment.center,
        child: const Text('—', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
      );
    }

    final val = m['measured_value'];
    final status = m['status']?.toString();
    final isOoc = status == 'out_of_spec' || status == 'rejected' || status == 'ooc';

    if (val == null) {
      return Container(
        width: width,
        height: 48,
        alignment: Alignment.center,
        child: const Text('—', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
      );
    }

    final String displayVal = (val is num) ? (val).toStringAsFixed(3) : '$val';

    return Container(
      width: width,
      height: 48,
      color: isOoc ? const Color(0xFFFEE2E2) : Colors.transparent,
      alignment: Alignment.center,
      child: Text(
        displayVal,
        style: TextStyle(
          color: isOoc ? const Color(0xFFDC2626) : const Color(0xFF0F172A),
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
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
