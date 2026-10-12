import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import '../providers/auth_provider.dart';
import '../providers/inspection_provider.dart';
import '../services/api_service.dart';

/// SetupApprovalScreen - DEDICATED Setup Approval workflow with Voice Inspection.
///
/// Features:
///   - Voice Inspection / Hands-free speech entry for Process Parameters (Section 2)
///   - Per-field Mic buttons for 1PC#1, 1PC#2, 1PC#3 process parameter readings
///   - Sequential Voice Inspection Mode with auto-advance across all process params
///   - Section 1: Read-only Product Parameters from Master DB
///   - Section 2: Process Parameters from Master DB
class SetupApprovalScreen extends StatefulWidget {
  final Map<String, dynamic>? template;

  const SetupApprovalScreen({super.key, this.template});

  @override
  State<SetupApprovalScreen> createState() => _SetupApprovalScreenState();
}

class _SetupApprovalScreenState extends State<SetupApprovalScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  List<dynamic> _productParams = [];
  List<dynamic> _processParams = [];
  Map<String, Map<String, String>> _productResults = {};
  final Map<String, Map<String, TextEditingController>> _processControllers = {};

  late TabController _tabController;

  // Voice Inspection State
  final _audioRecorder = AudioRecorder();
  bool _isVoiceRecording = false;
  bool _isVoiceProcessing = false;
  String? _activeVoiceCode;
  String? _activeVoiceTrial;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  @override
  void dispose() {
    for (final trialMap in _processControllers.values) {
      for (final ctrl in trialMap.values) {
        ctrl.dispose();
      }
    }
    _tabController.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final template = widget.template ?? provider.selectedTemplate;
    if (template == null || template['id'] == null) {
      setState(() { _isLoading = false; _errorMessage = 'No active template selected.'; });
      return;
    }
    try {
      final templateId = template['id'] as int;
      _productParams = await ApiService.getParameters(templateId);
      _processParams = await ApiService.getProcessParameters(templateId);
      _processControllers.clear();
      for (final pp in _processParams) {
        final code = pp['parameter_code']?.toString() ?? '';
        if (code.isNotEmpty) {
          _processControllers[code] = {
            '1': TextEditingController(),
            '2': TextEditingController(),
            '3': TextEditingController(),
          };
        }
      }
      final machineId = provider.selectedMachine?['id'] as int?;
      if (machineId != null) {
        final existing = await ApiService.getSetupApprovalData(templateId, machineId);
        if (existing != null && existing['process_param_entries'] is List) {
          for (final entry in existing['process_param_entries'] as List) {
            final code = entry['parameter_code']?.toString() ?? '';
            if (_processControllers.containsKey(code)) {
              _processControllers[code]!['1']!.text = entry['trial_1']?.toString() ?? '';
              _processControllers[code]!['2']!.text = entry['trial_2']?.toString() ?? '';
              _processControllers[code]!['3']!.text = entry['trial_3']?.toString() ?? '';
            }
          }
        }
      }
      _productResults = {};
      provider.recordedResults.forEach((code, val) {
        final trial = val['trial_number']?.toString() ?? '1';
        _productResults.putIfAbsent(code, () => {});
        _productResults[code]![trial] = val['measured_value']?.toString() ?? '-';
      });

      // Populate Section 1 Product Parameters from backend inspection session details across 1PC#1, #2, #3
      final machineCode = provider.selectedMachine?['machine_code']?.toString();
      if (machineCode != null && machineCode.isNotEmpty) {
        final sessions = await ApiService.getSessions(machineCode: machineCode);
        for (final s in sessions) {
          final sId = s['session_id']?.toString() ?? s['id']?.toString() ?? '';
          final type = s['inspection_type']?.toString().toLowerCase() ?? '';
          if (sId.isNotEmpty && (type == 'first_piece' || type.contains('first'))) {
            final detail = await ApiService.getSessionDetail(sId);
            if (detail != null && detail['measurements'] is List) {
              for (final m in (detail['measurements'] as List)) {
                final code = m['parameter_code']?.toString() ?? '';
                final trial = (m['trial_number'] ?? detail['trial_number'] ?? 1).toString();
                final val = m['measured_value']?.toString() ?? m['value']?.toString() ?? '-';
                if (code.isNotEmpty) {
                  _productResults.putIfAbsent(code, () => {});
                  if (_productResults[code]![trial] == null || _productResults[code]![trial] == '-') {
                    _productResults[code]![trial] = val;
                  }
                }
              }
            }
          }
        }
      }
      setState(() => _isLoading = false);
    } catch (e) {
      setState(() { _isLoading = false; _errorMessage = 'Failed to load data: $e'; });
    }
  }

  // Voice Recording Logic
  Future<void> _toggleVoiceRecordingForField(String code, String trial) async {
    if (_isVoiceRecording) {
      setState(() {
        _isVoiceRecording = false;
        _isVoiceProcessing = true;
      });

      try {
        final path = await _audioRecorder.stop();
        if (path != null) {
          // Step 1 — upload audio, receive job_id immediately (< 0.5 s)
          final submitRes = await ApiService.transcribeVoice(path);

          String textResult = '';

          // Backward-compat: if server is old it still returns raw_text directly
          if (submitRes.containsKey('raw_text')) {
            textResult = (submitRes['raw_text'] ?? submitRes['text'] ?? '').toString();
          } else {
            // New async path — poll until done
            final jobId = submitRes['job_id'] as String?;
            if (jobId != null) {
              const pollInterval = Duration(seconds: 2);
              const maxWait      = Duration(seconds: 60);
              final deadline     = DateTime.now().add(maxWait);

              Map<String, dynamic> pollRes = {'status': 'processing'};
              while (DateTime.now().isBefore(deadline)) {
                await Future.delayed(pollInterval);
                pollRes = await ApiService.checkTranscriptionStatus(jobId);
                final st = pollRes['status'] as String? ?? 'processing';
                if (st == 'done' || st == 'failed') break;
              }

              if ((pollRes['status'] as String? ?? '') == 'done') {
                textResult = (pollRes['raw_text'] ?? pollRes['text'] ?? '').toString();
              }
            }
          }

          if (textResult.isNotEmpty) {
            final parsed = await ApiService.parseText(textResult);
            String valStr = '';
            if (parsed['is_parseable'] == true && parsed['parsed_value'] != null) {
              valStr = parsed['parsed_value'].toString();
            } else {
              valStr = textResult.trim();
            }

            if (_processControllers[code]?[trial] != null) {
              _processControllers[code]![trial]!.text = valStr;
            }

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('🎙️ Voice recorded for $code (1PC#$trial): "$valStr"'),
                  backgroundColor: const Color(0xFF10B981),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('No speech detected. Please try again.')),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('Voice recording error: $e');
      } finally {
        if (mounted) {
          setState(() {
            _isVoiceProcessing = false;
            _activeVoiceCode = null;
            _activeVoiceTrial = null;
          });
        }
      }
    } else {
      bool hasMicPermission = kIsWeb;
      if (!kIsWeb) {
        final status = await Permission.microphone.request();
        hasMicPermission = status.isGranted;
      }

      if (!hasMicPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission required for voice inspection.')),
          );
        }
        return;
      }

      try {
        final recordPath = kIsWeb ? '' : 'process_param_${code}_$trial.m4a';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
          path: recordPath,
        );

        setState(() {
          _isVoiceRecording = true;
          _activeVoiceCode = code;
          _activeVoiceTrial = trial;
        });
      } catch (e) {
        debugPrint('Failed to start recording: $e');
      }
    }
  }

  // Sequential Voice Mode for Process Parameters
  Future<void> _startSequentialVoiceMode() async {
    if (_processParams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No process parameters available for voice entry.')),
      );
      return;
    }

    int currentIdx = 0;
    int currentTrial = 1;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final param = _processParams[currentIdx];
            final code = param['parameter_code']?.toString() ?? '';
            final name = param['parameter_name']?.toString() ?? '';
            final spec = param['specification']?.toString() ?? '';
            final unit = param['unit']?.toString() ?? '';

            return AlertDialog(
              backgroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFF818CF8), width: 1.5),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF818CF8).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.mic_rounded, color: Color(0xFF818CF8), size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('VOICE INSPECTION', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                        Text('Process Parameters Voice Mode', style: TextStyle(color: Color(0xFF818CF8), fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(code, style: const TextStyle(color: Color(0xFF818CF8), fontWeight: FontWeight.bold, fontSize: 12)),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text('1PC#$currentTrial', style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 11)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14), textAlign: TextAlign.center),
                          if (spec.isNotEmpty) Text('Target Spec: $spec $unit', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Parameter ${currentIdx + 1} of ${_processParams.length}  •  Trial #$currentTrial',
                      style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _processControllers[code]?[currentTrial.toString()],
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        hintText: 'Speak or type reading...',
                        hintStyle: const TextStyle(color: Color(0xFF475569), fontSize: 13),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF818CF8))),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Exit Voice Mode', style: TextStyle(color: Color(0xFF64748B))),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    if (currentIdx < _processParams.length - 1) {
                      setDialogState(() {
                        currentIdx++;
                      });
                    } else if (currentTrial < 3) {
                      setDialogState(() {
                        currentIdx = 0;
                        currentTrial++;
                      });
                    } else {
                      Navigator.pop(dialogCtx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('🎉 Voice inspection completed for all process parameters!'), backgroundColor: Color(0xFF10B981)),
                      );
                    }
                  },
                  icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                  label: Text(currentIdx == _processParams.length - 1 && currentTrial == 3 ? 'FINISH' : 'NEXT'),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF818CF8), foregroundColor: Colors.white),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _submitSetupApproval() async {
    if (_processParams.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No process parameters configured for this operation.'),
        backgroundColor: Colors.orangeAccent, behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final emptyRequired = <String>[];
    for (final pp in _processParams) {
      if (pp['is_required'] == true) {
        final code = pp['parameter_code']?.toString() ?? '';
        if ((_processControllers[code]?['1']?.text.trim() ?? '').isEmpty) {
          emptyRequired.add(pp['parameter_name']?.toString() ?? code);
        }
      }
    }
    if (emptyRequired.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Required params missing for 1PC#1: ${emptyRequired.join(", ")}'),
        backgroundColor: Colors.orangeAccent, duration: const Duration(seconds: 4), behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() => _isSubmitting = true);
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final template = provider.selectedTemplate!;
    final machineId = provider.selectedMachine?['id'] as int? ?? 0;
    final partNumber = provider.selectedPart?['part_number']?.toString() ?? '';
    final inspectorName = auth.fullName ?? auth.username ?? 'Inspector';
    final entries = <Map<String, dynamic>>[];
    for (final pp in _processParams) {
      final code = pp['parameter_code']?.toString() ?? '';
      entries.add({
        'parameter_code': code,
        'parameter_name': pp['parameter_name'],
        'trial_1': _processControllers[code]?['1']?.text.trim() ?? '',
        'trial_2': _processControllers[code]?['2']?.text.trim() ?? '',
        'trial_3': _processControllers[code]?['3']?.text.trim() ?? '',
      });
    }
    await ApiService.submitSetupApproval(
      templateId: template['id'] as int,
      machineId: machineId,
      partNumber: partNumber,
      processParamEntries: entries,
      inspectorName: inspectorName,
    );
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    _showSuccessDialog();
  }

  void _showSuccessDialog() {
    showDialog(
      context: context, barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF10B981), width: 2)),
        title: const Column(children: [
          Icon(Icons.verified_rounded, color: Color(0xFF10B981), size: 52),
          SizedBox(height: 10),
          Text('SETUP APPROVAL\nSUBMITTED', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: 1.0), textAlign: TextAlign.center),
        ]),
        content: const Text('Process parameter readings for 1PC#1, 1PC#2 & 1PC#3 have been submitted.\n\nThe supervisor will be notified for Setup Approval review.', style: TextStyle(color: Colors.white70, fontSize: 13), textAlign: TextAlign.center),
        actions: [SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: () { Navigator.pop(ctx); Navigator.pop(context); },
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: const Text('CLOSE', style: TextStyle(fontWeight: FontWeight.bold)),
        ))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final auth = Provider.of<AuthProvider>(context);
    final machineName = provider.selectedMachine?['name'] ?? 'No Machine';
    final partNumber = provider.selectedPart?['part_number'] ?? '-';
    final partName = provider.selectedPart?['part_name'] ?? '-';
    final opName = provider.selectedTemplate?['name'] ?? 'Operation';
    final inspectorName = auth.fullName ?? auth.username ?? 'Inspector';
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_rounded, color: Color(0xFF38BDF8)), onPressed: () => Navigator.pop(context)),
        title: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.settings_suggest_rounded, color: Color(0xFF818CF8), size: 18),
          SizedBox(width: 8),
          Text('SET UP APPROVAL', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 0.8)),
        ]),
        actions: [IconButton(icon: const Icon(Icons.refresh_rounded, color: Color(0xFF38BDF8)), onPressed: _loadData)],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF818CF8),
          labelColor: const Color(0xFF818CF8),
          unselectedLabelColor: const Color(0xFF64748B),
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10),
          tabs: const [
            Tab(icon: Icon(Icons.straighten_rounded, size: 16), text: 'SECTION 1: PRODUCT'),
            Tab(icon: Icon(Icons.settings_rounded, size: 16), text: 'SECTION 2: PROCESS'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              CircularProgressIndicator(color: Color(0xFF818CF8)),
              SizedBox(height: 16),
              Text('Loading...', style: TextStyle(color: Colors.white70, fontSize: 13)),
            ]))
          : _errorMessage != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 52),
                  const SizedBox(height: 12),
                  Text(_errorMessage!, style: const TextStyle(color: Colors.white70, fontSize: 13), textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(onPressed: _loadData, icon: const Icon(Icons.refresh_rounded), label: const Text('RETRY'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38BDF8), foregroundColor: Colors.black)),
                ])))
              : Column(children: [
                  _buildHeaderBar(machineName, partNumber, partName, opName, inspectorName),
                  Expanded(child: TabBarView(controller: _tabController, children: [
                    _buildSection1ProductParams(),
                    _buildSection2ProcessParams(),
                  ])),
                  _buildSubmitBar(),
                ]),
    );
  }

  Widget _buildHeaderBar(String machine, String part, String partName, String op, String inspector) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFF0F172A),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(op, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13), overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text('$machine  -  $part ($partName)', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11), overflow: TextOverflow.ellipsis),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF818CF8).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF818CF8).withValues(alpha: 0.5)),
          ),
          child: Text('Inspector: $inspector', style: const TextStyle(color: Color(0xFF818CF8), fontSize: 10, fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }

  Widget _buildSection1ProductParams() {
    if (_productParams.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(32), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.info_outline_rounded, color: Color(0xFF38BDF8), size: 48),
        SizedBox(height: 12),
        Text('No product parameters found.', style: TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
        SizedBox(height: 8),
        Text('Complete at least one First PC Trial (1PC#1) to see measurements here.', style: TextStyle(color: Color(0xFF64748B), fontSize: 12), textAlign: TextAlign.center),
      ])));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildSectionHeader(icon: Icons.straighten_rounded, iconColor: const Color(0xFF38BDF8), title: 'SECTION 1 - PRODUCT PARAMETERS', subtitle: 'Read-only - From First PC Inspection Trials (1PC#1, 1PC#2, 1PC#3)', borderColor: const Color(0xFF38BDF8)),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF1E293B))),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(const Color(0xFF1E293B)),
                dataRowMinHeight: 46, dataRowMaxHeight: 60, horizontalMargin: 14, columnSpacing: 14,
                columns: const [
                  DataColumn(label: Text('PARAMETER', style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 10))),
                  DataColumn(label: Text('SPEC', style: TextStyle(color: Color(0xFF94A3B8), fontWeight: FontWeight.bold, fontSize: 10))),
                  DataColumn(label: Text('1PC#1', style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 10))),
                  DataColumn(label: Text('1PC#2', style: TextStyle(color: Color(0xFFF59E0B), fontWeight: FontWeight.bold, fontSize: 10))),
                  DataColumn(label: Text('1PC#3', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 10))),
                ],
                rows: _productParams.map((param) {
                  final code = param['parameter_code']?.toString() ?? '';
                  final name = param['parameter_name']?.toString() ?? '';
                  final nominal = param['nominal_value']?.toString() ?? '-';
                  final unit = param['unit']?.toString() ?? '';
                  final upper = param['upper_tolerance']?.toString() ?? '';
                  final lower = param['lower_tolerance']?.toString() ?? '';
                  final spec = '$nominal$unit ($lower/+$upper)';
                  final t1 = _productResults[code]?['1'] ?? '-';
                  final t2 = _productResults[code]?['2'] ?? '-';
                  final t3 = _productResults[code]?['3'] ?? '-';
                  return DataRow(cells: [
                    DataCell(Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(code, style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 11)),
                      Text(name, style: const TextStyle(color: Colors.white70, fontSize: 10)),
                    ])),
                    DataCell(Text(spec, style: const TextStyle(color: Color(0xFF64748B), fontSize: 10))),
                    DataCell(_prodCell(t1)),
                    DataCell(_prodCell(t2)),
                    DataCell(_prodCell(t3)),
                  ]);
                }).toList(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF38BDF8).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3))),
          child: const Row(children: [
            Icon(Icons.info_rounded, color: Color(0xFF38BDF8), size: 16), SizedBox(width: 8),
            Expanded(child: Text('Product parameter values are read-only - populated from actual First PC Inspection measurements.', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11))),
          ]),
        ),
      ]),
    );
  }

  Widget _prodCell(String value) {
    final isEmpty = value == '-' || value.isEmpty;
    return Text(value, style: TextStyle(color: isEmpty ? const Color(0xFF475569) : Colors.white, fontWeight: isEmpty ? FontWeight.normal : FontWeight.bold, fontSize: 11));
  }

  Widget _buildSection2ProcessParams() {
    if (_processParams.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(32), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.settings_rounded, color: Color(0xFF818CF8), size: 48),
        SizedBox(height: 12),
        Text('No process parameters configured for this operation.', style: TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
        SizedBox(height: 8),
        Text('A Quality Engineer must configure process parameters in the Master Setup first.', style: TextStyle(color: Color(0xFF64748B), fontSize: 12), textAlign: TextAlign.center),
      ])));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildSectionHeader(
          icon: Icons.settings_rounded,
          iconColor: const Color(0xFF818CF8),
          title: 'SECTION 2 - PROCESS PARAMETERS',
          subtitle: 'Inspector enters values for 1PC#1, 1PC#2, 1PC#3 - From Master Setup DB',
          borderColor: const Color(0xFF818CF8),
        ),
        const SizedBox(height: 14),

        // VOICE INSPECTION MODE BANNER
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF312E81), Color(0xFF4338CA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF818CF8), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF4338CA).withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.mic_rounded, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'VOICE INSPECTION FOR PROCESS PARAMS',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Hands-free speech entry for 1PC#1, 1PC#2 & 1PC#3',
                      style: TextStyle(color: Color(0xFFC7D2FE), fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _startSequentialVoiceMode,
                icon: const Icon(Icons.record_voice_over_rounded, size: 16),
                label: const Text('START VOICE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF818CF8),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),
        ..._processParams.map((pp) => _buildProcessParamRow(pp)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFF818CF8).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF818CF8).withValues(alpha: 0.3))),
          child: const Row(children: [
            Icon(Icons.settings_suggest_rounded, color: Color(0xFF818CF8), size: 16), SizedBox(width: 8),
            Expanded(child: Text('Enter or speak actual process settings verified during each trial setup. Checked by Supervisor during Setup Approval.', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11))),
          ]),
        ),
        const SizedBox(height: 80),
      ]),
    );
  }

  Widget _buildProcessParamRow(Map<String, dynamic> pp) {
    final code = pp['parameter_code']?.toString() ?? '';
    final name = pp['parameter_name']?.toString() ?? '';
    final spec = pp['specification']?.toString() ?? '';
    final unit = pp['unit']?.toString() ?? '';
    final isRequired = pp['is_required'] == true;
    final dataType = pp['data_type']?.toString() ?? 'numeric';
    final inputType = dataType == 'numeric' ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF1E293B))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: const Color(0xFF818CF8).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
            child: Text(code, style: const TextStyle(color: Color(0xFF818CF8), fontWeight: FontWeight.bold, fontSize: 10)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12), overflow: TextOverflow.ellipsis)),
          if (isRequired) const Text('* Required', style: TextStyle(color: Color(0xFFEF4444), fontSize: 10)),
        ]),
        if (spec.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Target: $spec${unit.isNotEmpty ? " $unit" : ""}', style: const TextStyle(color: Color(0xFF64748B), fontSize: 10)),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _buildTrialInput(code, '1', const Color(0xFF38BDF8), '1PC#1', inputType)),
          const SizedBox(width: 8),
          Expanded(child: _buildTrialInput(code, '2', const Color(0xFFF59E0B), '1PC#2', inputType)),
          const SizedBox(width: 8),
          Expanded(child: _buildTrialInput(code, '3', const Color(0xFF10B981), '1PC#3', inputType)),
        ]),
      ]),
    );
  }

  Widget _buildTrialInput(String code, String trial, Color color, String label, TextInputType inputType) {
    final ctrl = _processControllers[code]?[trial];
    if (ctrl == null) return const SizedBox.shrink();

    final isRecordingThis = _isVoiceRecording && _activeVoiceCode == code && _activeVoiceTrial == trial;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
          InkWell(
            onTap: _isVoiceProcessing ? null : () => _toggleVoiceRecordingForField(code, trial),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: isRecordingThis ? Colors.redAccent.withValues(alpha: 0.2) : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isRecordingThis ? Icons.stop_circle_rounded : Icons.mic_rounded,
                color: isRecordingThis ? Colors.redAccent : const Color(0xFF818CF8),
                size: 14,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl,
        keyboardType: inputType,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
        decoration: InputDecoration(
          hintText: isRecordingThis ? 'Listening...' : '-',
          hintStyle: TextStyle(color: isRecordingThis ? Colors.redAccent : const Color(0xFF475569), fontSize: 11),
          filled: true,
          fillColor: isRecordingThis ? Colors.redAccent.withValues(alpha: 0.1) : const Color(0xFF1E293B),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: isRecordingThis ? Colors.redAccent : color.withValues(alpha: 0.3))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: isRecordingThis ? Colors.redAccent : color.withValues(alpha: 0.3))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: isRecordingThis ? Colors.redAccent : color, width: 1.5)),
        ),
      ),
    ]);
  }

  Widget _buildSubmitBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: const BoxDecoration(color: Color(0xFF0F172A), border: Border(top: BorderSide(color: Color(0xFF1E293B)))),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _isSubmitting ? null : _submitSetupApproval,
          icon: _isSubmitting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.verified_rounded, size: 20),
          label: Text(_isSubmitting ? 'SUBMITTING...' : 'COMPLETE SETUP APPROVAL', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5)),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF818CF8), foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF4B5563),
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader({required IconData icon, required Color iconColor, required String title, required String subtitle, required Color borderColor}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: borderColor.withValues(alpha: 0.4))),
      child: Row(children: [
        Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: iconColor, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(color: iconColor, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 0.5)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(color: Color(0xFF64748B), fontSize: 10)),
        ])),
      ]),
    );
  }
}
