import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/inspection_provider.dart';
import '../services/api_service.dart';
import 'app_home_screen.dart';
import 'summary_screen.dart';

class PieceEntryFormScreen extends StatefulWidget {
  final int pieceNumber;
  final int attemptNumber;

  const PieceEntryFormScreen({
    super.key,
    this.pieceNumber = 1,
    this.attemptNumber = 1,
  });

  @override
  State<PieceEntryFormScreen> createState() => _PieceEntryFormScreenState();
}

class _PieceEntryFormScreenState extends State<PieceEntryFormScreen> {
  final Map<String, TextEditingController> _controllers = {};
  final AudioRecorder _audioRecorder = AudioRecorder();

  String? _activeRecordingCode;
  bool _isProcessingVoice = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  void _initControllers() {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    for (var param in provider.parameters) {
      final code = param['parameter_code']?.toString() ?? '';
      if (code.isNotEmpty) {
        final existingResult = provider.recordedResults[code];
        String initialText = '';
        if (existingResult != null &&
            existingResult['measured_value'] != null) {
          initialText = existingResult['measured_value'].toString();
        }
        _controllers[code] = TextEditingController(text: initialText);
        if (initialText.isNotEmpty) {
          final val = double.tryParse(initialText) ?? 0.0;
          provider.setPendingValue(code, val, initialText, method: 'form');
        }
      }
    }
  }

  @override
  void dispose() {
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    _audioRecorder.dispose();
    super.dispose();
  }

  int _getParameterRule(Map<String, dynamic> param) {
    final type = (param['measurement_type'] ?? '').toString().toLowerCase();
    final name = (param['parameter_name'] ?? '').toString().toUpperCase();

    if (type == 'visual') return 2;
    if (type == 'min_limit' || name.contains('MIN')) return 31;
    if (type == 'max_limit' || type == 'surface' || name.contains('MAX'))
      return 32;
    return 1;
  }

  String _formatSpecSubtitle(Map<String, dynamic> param) {
    final type = (param['measurement_type'] ?? '').toString().toLowerCase();
    final name = (param['parameter_name'] ?? '').toString().toUpperCase();
    final unit = param['unit'] ?? '';

    if (type == 'visual') return 'Spec: Visual Pass/Fail Check';
    if (type == 'min_limit' || name.contains('MIN')) {
      final minVal = param['lower_limit'] ?? param['nominal_value'] ?? '—';
      return 'Spec: ≥ $minVal $unit (MIN)';
    }
    if (type == 'max_limit' || type == 'surface' || name.contains('MAX')) {
      final maxVal = param['upper_limit'] ?? param['nominal_value'] ?? '—';
      return 'Spec: ≤ $maxVal $unit (MAX)';
    }

    if (param['is_process_parameter'] == true) {
      final spec = param['specification'] ?? '';
      if (spec.isNotEmpty && param['nominal_value'] == null)
        return 'Spec: $spec $unit';
      if (param['nominal_value'] != null) {
        final ll = param['lower_limit'] ?? '—';
        final ul = param['upper_limit'] ?? '—';
        return 'Spec: ${param['nominal_value']} $unit [$ll - $ul]';
      }
      return 'Process Parameter';
    }

    return 'Spec: ${param['nominal_value']} $unit [${param['lower_limit']} - ${param['upper_limit']}]';
  }

  Future<void> _recordVoiceForField(
    String code,
    Map<String, dynamic> param,
  ) async {
    if (_isProcessingVoice) return;

    if (_activeRecordingCode == code) {
      // Stop recording and process
      setState(() {
        _isProcessingVoice = true;
      });

      final e2eSw = Stopwatch()..start();
      try {
        final path = await _audioRecorder.stop();
        setState(() {
          _activeRecordingCode = null;
        });

        if (path != null) {
          final uploadSw = Stopwatch()..start();
          final submitRes = await ApiService.transcribeVoice(path);
          uploadSw.stop();

          String? rawText;
          Map<String, dynamic>? pollRes;
          if (submitRes.containsKey('raw_text')) {
            rawText = submitRes['raw_text'] ?? submitRes['text'];
          } else if (submitRes.containsKey('job_id')) {
            final jobId = submitRes['job_id'] as String;
            const pollInterval = Duration(seconds: 2);
            const maxWait = Duration(seconds: 60);
            final deadline = DateTime.now().add(maxWait);

            final pollSw = Stopwatch()..start();
            int pollCount = 0;
            pollRes = {'status': 'processing'};
            while (DateTime.now().isBefore(deadline)) {
              await Future.delayed(pollInterval);
              pollCount++;
              pollRes = await ApiService.checkTranscriptionStatus(jobId);
              final st = pollRes?['status'] as String? ?? 'processing';
              if (st == 'done' || st == 'failed') break;
            }
            pollSw.stop();
            e2eSw.stop();

            final timingMeta = pollRes?['timing'] as Map<String, dynamic>?;
            debugPrint('''
==================================================
[PERF CLIENT SUMMARY] Form Field Voice ($code):
  ├─ HTTP Upload Time  : ${uploadSw.elapsedMilliseconds} ms
  ├─ Polling Attempts  : $pollCount attempt(s)
  ├─ Polling Duration  : ${pollSw.elapsedMilliseconds} ms
  ├─ Backend Whisper   : ${timingMeta?['whisper_infer_ms'] ?? 'N/A'} ms
  ├─ Backend Total Exec: ${timingMeta?['total_backend_ms'] ?? 'N/A'} ms
  └─ TOTAL E2E LATENCY : ${e2eSw.elapsedMilliseconds} ms
==================================================
''');

            if (pollRes?['status'] == 'done') {
              rawText = pollRes?['raw_text'] ?? pollRes?['text'];
            }
          }

          if (rawText != null && rawText.isNotEmpty) {
            final rule = _getParameterRule(param);
            double? parsedVal;

            if (rule == 2 || param['data_type'] == 'yes_no') {
              final clean = rawText.trim().toLowerCase();
              if (['1', '1.0', 'yes', 'pass', 'ok', 'true'].contains(clean)) {
                parsedVal = 1.0;
              } else if ([
                '0',
                '0.0',
                'no',
                'fail',
                'reject',
                'false',
              ].contains(clean)) {
                parsedVal = 0.0;
              } else {
                parsedVal = double.tryParse(
                  rawText.replaceAll(RegExp(r'[^0-9.-]'), ''),
                );
              }
            } else {
              // 1. Check if backend already parsed the value during STT task
              if (pollRes?['parsed_value'] != null) {
                parsedVal = (pollRes!['parsed_value'] as num).toDouble();
              } else {
                // 2. Try direct local parse
                parsedVal = double.tryParse(
                  rawText.replaceAll(RegExp(r'[^0-9.-]'), ''),
                );
                if (parsedVal == null && rawText.isNotEmpty) {
                  final parseResult = await ApiService.parseText(rawText);
                  if (parseResult['is_parseable'] == true &&
                      parseResult['parsed_value'] != null) {
                    parsedVal = (parseResult['parsed_value'] as num).toDouble();
                  }
                }
              }
            }

            if (parsedVal != null) {
              _controllers[code]?.text = parsedVal.toString();
              Provider.of<InspectionProvider>(
                context,
                listen: false,
              ).setPendingValue(code, parsedVal, rawText, method: 'voice');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('🎤 Recognized "$rawText" → $parsedVal'),
                    backgroundColor: const Color(0xFF10B981),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Could not parse "$rawText". Please enter manually.',
                    ),
                    backgroundColor: const Color(0xFFF59E0B),
                  ),
                );
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Voice error for $code: $e');
      } finally {
        if (mounted) {
          setState(() {
            _isProcessingVoice = false;
            _activeRecordingCode = null;
          });
        }
      }
    } else {
      // Start recording
      bool hasMicPermission = kIsWeb;
      if (!kIsWeb) {
        final status = await Permission.microphone.request();
        hasMicPermission = status.isGranted;
      }
      if (hasMicPermission && await _audioRecorder.hasPermission()) {
        String path = '';
        if (!kIsWeb) {
          final tempDir = await getTemporaryDirectory();
          path = '${tempDir.path}/voice_$code.m4a';
        }
        await _audioRecorder.start(const RecordConfig(), path: path);
        setState(() {
          _activeRecordingCode = code;
        });
      }
    }
  }

  Future<void> _submitPieceForm() async {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    debugPrint(
      '[SUBMIT] _submitPieceForm() called. sessionId=${provider.sessionId}',
    );

    // ── Guard: session must exist ─────────────────────────────────────────
    if (provider.sessionId == null) {
      debugPrint(
        '[SUBMIT] ERROR: sessionId is null — cannot submit without an active session.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active session. Please restart the inspection.'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    // ── Validate: collect values from text fields into pendingBatchValues ──
    final missingCodes = <String>[];
    for (var param in provider.parameters) {
      final code = param['parameter_code']?.toString() ?? '';
      final isCarriedForward =
          provider.recordedResults[code]?['carried_forward'] == true ||
          (provider.recordedResults[code]?['status'] == 'ok' &&
              widget.attemptNumber > 1);

      if (!isCarriedForward) {
        final textVal = _controllers[code]?.text.trim() ?? '';
        if (textVal.isEmpty && !provider.pendingBatchValues.containsKey(code)) {
          debugPrint(
            '[SUBMIT] MISSING: $code — text empty, not in pendingBatch',
          );
          missingCodes.add(code);
        } else if (textVal.isNotEmpty) {
          final parsed = double.tryParse(textVal);
          if (parsed != null) {
            debugPrint(
              '[SUBMIT] setPendingValue: $code = $parsed (from text field)',
            );
            provider.setPendingValue(code, parsed, textVal, method: 'form');
          } else {
            debugPrint(
              '[SUBMIT] MISSING: $code — text "$textVal" is not a valid number',
            );
            missingCodes.add(code);
          }
        }
      }
    }

    if (missingCodes.isNotEmpty) {
      debugPrint(
        '[SUBMIT] Validation failed — ${missingCodes.length} missing: $missingCodes',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please fill all ${missingCodes.length} remaining fields before submitting.',
          ),
          backgroundColor: const Color(0xFFEF4444),
        ),
      );
      return;
    }

    debugPrint(
      '[SUBMIT] Validation passed. Pending values: ${provider.pendingBatchValues.keys.toList()}',
    );
    setState(() => _isSubmitting = true);

    // ── API call — ALWAYS reset _isSubmitting in finally ──────────────────
    try {
      debugPrint('[SUBMIT] Calling submitBatchMeasurements()...');
      final res = await provider.submitBatchMeasurements();
      debugPrint('[SUBMIT] submitBatchMeasurements() returned: $res');

      if (!mounted) return;

      if (res != null) {
        final bool complete = res['piece_complete'] == true;
        final int failedCount = res['failed_count'] ?? 0;
        final List<dynamic> failedCodes = res['failed_codes'] ?? [];
        debugPrint(
          '[SUBMIT] piece_complete=$complete failedCount=$failedCount failedCodes=$failedCodes',
        );

        if (complete) {
          debugPrint('[SUBMIT] All params passed — showing success modal.');
          _showSuccessModal();
        } else {
          debugPrint(
            '[SUBMIT] ${failedCodes.length} param(s) failed — showing failure modal.',
          );
          _showFailureModal(failedCount, failedCodes, res['results'] ?? []);
        }
      } else {
        debugPrint(
          '[SUBMIT] ERROR: submitBatchMeasurements returned null (API failure).',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Submission failed. Please check your network connection and try again.',
            ),
            backgroundColor: Color(0xFFEF4444),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('[SUBMIT] EXCEPTION in submitBatchMeasurements: $e');
      debugPrint('[SUBMIT] Stack trace: $stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Submission error: ${e.toString()}'),
            backgroundColor: const Color(0xFFEF4444),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      // ← CRITICAL: always reset _isSubmitting so button is never permanently disabled
      if (mounted) {
        setState(() => _isSubmitting = false);
        debugPrint('[SUBMIT] _isSubmitting reset to false.');
      }
    }
  }

  void _showSuccessModal() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF10B981), width: 1.5),
        ),
        title: Row(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              color: Color(0xFF10B981),
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'PC #${widget.pieceNumber} PASSED! 🎉',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'All parameters for 1ST PC #${widget.pieceNumber} are within specification!\n\nWhat would you like to do next?',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const AppHomeScreen()),
                (route) => false,
              );
            },
            child: const Text(
              'Home',
              style: TextStyle(color: Color(0xFF94A3B8)),
            ),
          ),
          if (widget.pieceNumber < 3)
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                final provider = Provider.of<InspectionProvider>(
                  context,
                  listen: false,
                );
                final nextPiece = widget.pieceNumber + 1;
                final template = provider.selectedTemplate;
                if (template != null) {
                  await provider.loadParameters(template);
                  final started = await provider.startSession(
                    trial: nextPiece,
                    inspectionType: 'first_piece',
                  );
                  if (started && mounted) {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PieceEntryFormScreen(
                          pieceNumber: nextPiece,
                          attemptNumber: 1,
                        ),
                      ),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text('Next Piece (PC #${widget.pieceNumber + 1})'),
            ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const SummaryScreen()),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.assessment_rounded, size: 18),
            label: const Text('View Summary'),
          ),
        ],
      ),
    );
  }

  void _showFailureModal(
    int failedCount,
    List<dynamic> failedCodes,
    List<dynamic> results,
  ) {
    final failedResults = results
        .where((r) => r['status'] == 'out_of_spec' || r['status'] == 'error')
        .toList();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
        ),
        title: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Color(0xFFEF4444),
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Attempt #${widget.attemptNumber}: $failedCount Failed',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The following parameter(s) failed specification validation in Attempt #${widget.attemptNumber}:',
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: failedResults.length,
                  itemBuilder: (context, idx) {
                    final item = failedResults[idx];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.5),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${item['parameter_code']} — Value: ${item['measured_value']}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item['message'] ?? 'Out of specification',
                            style: const TextStyle(
                              color: Color(0xFFF87171),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Attempt #${widget.attemptNumber + 1} will open only the failed parameter(s) for correction. All passed parameters are locked.',
                style: TextStyle(
                  color: Color(0xFF38BDF8),
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              final provider = Provider.of<InspectionProvider>(
                context,
                listen: false,
              );
              final currentSessionId = provider.sessionId;
              final template = provider.selectedTemplate;
              if (template != null) {
                await provider.loadParametersForRetrial(
                  template,
                  trial: widget.pieceNumber,
                );
                final started = await provider.startSession(
                  trial: widget.pieceNumber,
                  inspectionType: 'first_piece',
                  parentId: currentSessionId,
                );
                if (started && mounted) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PieceEntryFormScreen(
                        pieceNumber: widget.pieceNumber,
                        attemptNumber: widget.attemptNumber + 1,
                      ),
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(
              'Re-enter Failed (${failedResults.length}) → Attempt #${widget.attemptNumber + 1}',
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final partNumber = provider.selectedPart?['part_number'] ?? '—';
    final partName = provider.selectedPart?['part_name'] ?? 'No part selected';
    final machineCode = provider.selectedMachine?['machine_code'] ?? '—';

    final processParams = provider.parameters
        .where((p) => p['is_process_parameter'] == true)
        .toList();
    final productParams = provider.parameters
        .where((p) => p['is_process_parameter'] != true)
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '1ST PC #${widget.pieceNumber} Entry (Attempt #${widget.attemptNumber})',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            Text(
              '$partNumber ($partName) · $machineCode',
              style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.home_rounded, color: Color(0xFF38BDF8)),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                Icon(
                  widget.attemptNumber > 1
                      ? Icons.build_circle_rounded
                      : Icons.assignment_turned_in_rounded,
                  color: widget.attemptNumber > 1
                      ? const Color(0xFFF59E0B)
                      : const Color(0xFF10B981),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.attemptNumber == 1
                        ? 'Fill all Product & Process parameters for PC #${widget.pieceNumber} and tap Submit.'
                        : 'Attempt #${widget.attemptNumber}: Re-entering ${provider.parameters.length} failed field(s). Passed fields locked.',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Parameter Form List
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (processParams.isNotEmpty) ...[
                  _buildSectionHeader(
                    'PROCESS PARAMETERS (${processParams.length})',
                    Icons.precision_manufacturing_rounded,
                  ),
                  const SizedBox(height: 8),
                  ...processParams.map((p) => _buildParameterCard(p)),
                  const SizedBox(height: 20),
                ],
                if (productParams.isNotEmpty) ...[
                  _buildSectionHeader(
                    'PRODUCT PARAMETERS (${productParams.length})',
                    Icons.rule_rounded,
                  ),
                  const SizedBox(height: 8),
                  ...productParams.map((p) => _buildParameterCard(p)),
                ],
              ],
            ),
          ),

          // Bottom Submit Action Bar
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            child: SafeArea(
              child: ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submitPieceForm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 20),
                label: Text(
                  _isSubmitting
                      ? 'VALIDATING PIECE...'
                      : 'SUBMIT PC #${widget.pieceNumber} (ATTEMPT #${widget.attemptNumber})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF38BDF8), size: 18),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFF38BDF8),
            fontWeight: FontWeight.bold,
            fontSize: 13,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildParameterCard(Map<String, dynamic> param) {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final code = param['parameter_code']?.toString() ?? '';
    final name = param['parameter_name']?.toString() ?? code;
    final isCritical = param['is_critical'] == true;

    final existingResult = provider.recordedResults[code];
    final bool isCarriedForward =
        existingResult?['carried_forward'] == true ||
        (existingResult?['status'] == 'ok' && widget.attemptNumber > 1);
    final bool isFailedFromPrev = existingResult?['status'] == 'out_of_spec';

    final controller = _controllers[code] ?? TextEditingController();
    final isRecording = _activeRecordingCode == code;

    Color borderColor = const Color(0xFF1E293B);
    Color statusColor = const Color(0xFF64748B);
    String statusText = 'PENDING';

    if (isCarriedForward) {
      borderColor = const Color(0xFF10B981).withValues(alpha: 0.5);
      statusColor = const Color(0xFF10B981);
      statusText = 'PASSED (LOCKED)';
    } else if (isFailedFromPrev) {
      borderColor = const Color(0xFFEF4444);
      statusColor = const Color(0xFFEF4444);
      statusText = 'FAILED — RETRY';
    } else if (controller.text.isNotEmpty) {
      borderColor = const Color(0xFF2563EB);
      statusColor = const Color(0xFF38BDF8);
      statusText = 'FILLED';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$code — $name',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              if (isCritical)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'CRITICAL',
                    style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _formatSpecSubtitle(param),
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
          const SizedBox(height: 10),

          // Input field row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: !isCarriedForward && !_isProcessingVoice,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: TextStyle(
                    color: isCarriedForward
                        ? const Color(0xFF10B981)
                        : Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: InputDecoration(
                    hintText: isCarriedForward
                        ? 'Passed'
                        : 'Enter value (e.g. 25.02)',
                    hintStyle: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: isCarriedForward
                        ? const Color(0xFF1E293B).withValues(alpha: 0.5)
                        : const Color(0xFF1E293B),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (val) {
                    final d = double.tryParse(val);
                    if (d != null) {
                      provider.setPendingValue(code, d, val, method: 'form');
                    }
                    setState(() {});
                  },
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                onPressed: isCarriedForward || _isProcessingVoice
                    ? null
                    : () => _recordVoiceForField(code, param),
                style: IconButton.styleFrom(
                  backgroundColor: isRecording
                      ? const Color(0xFFEF4444)
                      : (isCarriedForward
                            ? const Color(0xFF334155)
                            : const Color(0xFF2563EB)),
                  padding: const EdgeInsets.all(12),
                ),
                icon: isRecording
                    ? const Icon(Icons.stop_rounded, color: Colors.white)
                    : const Icon(Icons.mic_rounded, color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
