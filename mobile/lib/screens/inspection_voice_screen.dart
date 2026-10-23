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

class InspectionVoiceScreen extends StatefulWidget {
  const InspectionVoiceScreen({super.key});

  @override
  State<InspectionVoiceScreen> createState() => _InspectionVoiceScreenState();
}

class _InspectionVoiceScreenState extends State<InspectionVoiceScreen> {
  final _inputController = TextEditingController();
  final _audioRecorder = AudioRecorder();
  final _scrollController = ScrollController();

  bool _isRecording = false;
  bool _isProcessing = false;
  final bool _autoAdvance =
      true; // Auto-advance parameter-by-parameter after filling
  String _transcribedText = '';
  String? _inputError;
  Map<String, dynamic>? _lastResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentParam();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _audioRecorder.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCurrentParam() {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    if (_scrollController.hasClients && provider.parameters.isNotEmpty) {
      const itemWidth = 68.0;
      final targetOffset = (provider.currentParamIndex * itemWidth) - 100.0;
      _scrollController.animateTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  int _getParameterRule(Map<String, dynamic> param) {
    final type = (param['measurement_type'] ?? '').toString().toLowerCase();
    final name = (param['parameter_name'] ?? '').toString().toUpperCase();
    final unit = (param['unit'] ?? '').toString().toLowerCase();
    final tech = (param['measurement_technique'] ?? '').toString().toUpperCase();

    if (type == 'visual' ||
        unit == 'pass' ||
        unit == 'yes/no' ||
        unit == 'visual' ||
        name.contains('PLUG GAUGE') ||
        tech.contains('PLUGE GAUGE') ||
        tech.contains('PLUG GAUGE') ||
        tech.contains('VISUALLY')) return 2; // Rule 2: Visual (YES/NO)
    if (type == 'min_limit' || name.contains('MIN'))
      return 31; // Rule 3A: MIN Limit
    if (type == 'max_limit' || type == 'surface' || name.contains('MAX'))
      return 32; // Rule 3B: MAX Limit
    return 1; // Rule 1: Range
  }

  String _getVisualSpecText(Map<String, dynamic> param) {
    final code = (param['parameter_code'] ?? '').toString().toUpperCase();
    final nom =
        double.tryParse('${param['nominal_value']}')?.toStringAsFixed(2) ??
        '${param['nominal_value']}';
    final unit = param['unit'] ?? 'mm';

    if (code == 'CHA-01' || nom == '0.50' || nom == '0.5')
      return '0.5 x 45° Chamfer';
    if (code == 'CHM-01' || nom == '1.00' || nom == '1.0' || nom == '1')
      return '1.0 x 45° Chamfer';
    if (code == 'CHA-02' || nom == '2.00' || nom == '2.0' || nom == '2')
      return '2.0 x 45° Chamfer';

    return '$nom $unit (Master Spec)';
  }

  bool _isMeasurementPassing(
    Map<String, dynamic> param,
    Map<String, dynamic>? recorded,
  ) {
    if (recorded == null) return false;

    // Use recorded status as the primary source of truth
    final status = (recorded['status'] ?? '').toString().toLowerCase();
    if (status == 'ok' || status == 'pass' || recorded['is_pass'] == true) {
      return true;
    }
    if (status == 'out_of_spec' ||
        status == 'reject' ||
        recorded['is_pass'] == false) {
      return false;
    }

    final rule = _getParameterRule(param);
    final val = double.tryParse(
      '${recorded['measured_value'] ?? recorded['value']}',
    );
    if (val == null) return false;

    // Fallback if status is not explicitly set
    if (rule == 2) {
      return val >= 0.5;
    } else if (rule == 31) {
      final minVal = double.tryParse(
        '${param['lower_limit'] ?? param['nominal_value']}',
      );
      if (minVal != null) return val >= minVal;
    } else if (rule == 32) {
      final maxVal = double.tryParse(
        '${param['nominal_value'] ?? param['upper_limit']}',
      );
      if (maxVal != null) return val <= maxVal;
    } else {
      final ll = double.tryParse('${param['lower_limit']}');
      final ul = double.tryParse('${param['upper_limit']}');
      if (ll != null && ul != null) {
        return val >= ll && val <= ul;
      }
    }
    return true;
  }

  // Submit Spoken or Typed Value + Handle Auto-Advance
  Future<void> _submitSpokenOrTypedValue(String inputStr) async {
    if (inputStr.trim().isEmpty) {
      if (mounted) {
        setState(
          () => _inputError = 'Please enter a measurement before submitting.',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a measurement before submitting.'),
            backgroundColor: Color(0xFFD97706),
          ),
        );
      }
      return;
    }

    setState(() {
      _isProcessing = true;
      _inputError = null;
      _lastResult = null;
    });

    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final currentParam = provider.currentParameter;
    if (currentParam == null) return;

    final rule = _getParameterRule(currentParam);

    double? parsedVal;
    if (rule == 2) {
      final clean = inputStr.trim().toLowerCase();
      final hasNo = RegExp(r'\b(no|fail|reject|false|not ok|not good|out of spec|defective)\b', caseSensitive: false).hasMatch(clean) || clean == '0' || clean == '0.0';
      final hasYes = RegExp(r'\b(yes|pass|ok|true|good|accepted)\b', caseSensitive: false).hasMatch(clean) || clean == '1' || clean == '1.0';

      if (hasNo) {
        parsedVal = 0.0;
      } else if (hasYes) {
        parsedVal = 1.0;
      } else {
        parsedVal = double.tryParse(
          inputStr.replaceAll(RegExp(r'[^0-9.-]'), ''),
        );
      }
      _transcribedText = parsedVal != null && parsedVal >= 0.5
          ? 'YES (PASS)'
          : 'NO (REJECT)';
    } else {
      final parseResult = await ApiService.parseText(inputStr);
      if (parseResult['is_parseable'] == true &&
          parseResult['parsed_value'] != null) {
        parsedVal = (parseResult['parsed_value'] as num).toDouble();
        _transcribedText = parseResult['raw_text'] ?? inputStr;
      } else {
        parsedVal = double.tryParse(
          inputStr.replaceAll(RegExp(r'[^0-9.-]'), ''),
        );
        _transcribedText = inputStr;
      }
    }

    if (parsedVal == null) {
      setState(() => _isProcessing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not understand measurement. Please enter a valid number.',
            ),
            backgroundColor: Color(0xFFD97706),
          ),
        );
      }
      return;
    }

    final result = await provider.submitMeasurement(
      value: parsedVal,
      voiceRawText: _transcribedText,
    );

    if (!mounted) return;

    setState(() {
      _isProcessing = false;
      _lastResult = result;
      _inputController.clear();
    });

    // Dynamic completion check: trigger Submit/Review modal when 100% of parameters have recorded values
    final totalCount = provider.parameters.length;
    final recordedCount = provider.recordedResults.length;

    if (totalCount > 0 && recordedCount >= totalCount) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) {
        _showSubmitOrReviewModal();
      }
      return;
    }

    if (_autoAdvance && result != null) {
      await Future.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;

      if (provider.currentParamIndex < provider.parameters.length - 1) {
        provider.advanceToNext();
        setState(() {
          _lastResult = null;
        });
        _scrollToCurrentParam();
      } else {
        _showSubmitOrReviewModal();
      }
    }
  }

  bool _isSubmitModalOpen = false;

  void _showSubmitOrReviewModal() {
    if (_isSubmitModalOpen || !mounted) return;
    _isSubmitModalOpen = true;

    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final totalCount = provider.parameters.length;

    // Calculate OK & NOK counts
    int okCount = 0;
    int nokCount = 0;
    for (final p in provider.parameters) {
      final code = p['parameter_code'] ?? '';
      final res = provider.recordedResults[code];
      if (res != null) {
        if (_isMeasurementPassing(p, res)) {
          okCount++;
        } else {
          nokCount++;
        }
      }
    }

    final opName = provider.selectedTemplate?['name'] ?? 'Inspection Session';
    final partNo = provider.selectedPart?['part_number'] ?? 'Part';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF059669), width: 2),
        ),
        title: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Color(0xFFECFDF5),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF059669),
                size: 36,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'All Parameters Recorded!',
              style: TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '$opName · Part: $partNo',
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: Color(0xFF059669),
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$okCount OK',
                        style: const TextStyle(
                          color: Color(0xFF059669),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    width: 1,
                    height: 20,
                    color: const Color(0xFFCBD5E1),
                  ),
                  Row(
                    children: [
                      const Icon(
                        Icons.cancel,
                        color: Color(0xFFDC2626),
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$nokCount NOK',
                        style: const TextStyle(
                          color: Color(0xFFDC2626),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'All $totalCount parameters have been measured. Proceed to submit your inspection report or review values.',
              style: const TextStyle(color: Color(0xFF475569), fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    _isSubmitModalOpen = false;
                    Navigator.pop(ctx);
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => const SummaryScreen()),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF2563EB),
                    side: const BorderSide(color: Color(0xFF2563EB)),
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 4,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.search_rounded, size: 16),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'REVIEW READINGS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final res = await provider.submitBatchMeasurements();
                    if (res != null) {
                      _isSubmitModalOpen = false;
                      if (context.mounted) {
                        Navigator.pop(ctx);

                        // Operators (hourly): always go directly to Summary — no retrial.
                        // Inspectors (first_piece): show retrial modal only if a param failed.
                        final isFirstPiece =
                            provider.inspectionType == 'first_piece';
                        final isComplete = res['piece_complete'] == true;
                        final failedCodes =
                            (res['failed_codes'] as List?)
                                ?.map((e) => e.toString())
                                .toList() ??
                            [];

                        if (isFirstPiece) {
                          provider.recordTrialResult(
                            provider.trialNumber,
                            isComplete,
                            failedCodes,
                          );
                        }

                        if (!isFirstPiece || isComplete) {
                          // Operator: submit and done.
                          // Inspector all-pass: submit and done.
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SummaryScreen(),
                            ),
                          );
                        } else {
                          // Inspector only: some params failed → offer 1PC#2 / 1PC#3 corrective trial.
                          _showRetrialModal(res);
                        }
                      }
                    } else {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              provider.errorMessage?.isNotEmpty == true
                                  ? provider.errorMessage!
                                  : 'Failed to submit measurements. Please check connection and try again.',
                            ),
                            backgroundColor: Color(0xFFDC2626),
                            duration: Duration(seconds: 4),
                          ),
                        );
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF059669),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 4,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'SUBMIT REPORT',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ).then((_) {
      _isSubmitModalOpen = false;
    });
  }

  void _showRetrialModal(Map<String, dynamic> res) {
    if (!mounted) return;
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    // Use inspectionType as ground truth — it is always set by startSession().
    // Do NOT use auth.isInspector here: a role check alone cannot distinguish
    // whether the current session is first_piece or hourly.
    final isFirstPiece = provider.inspectionType == 'first_piece';

    final currentTrial = provider.trialNumber;
    final failedCount =
        res['failed_count'] ?? (res['failed_codes'] as List?)?.length ?? 1;
    final failedCodes =
        (res['failed_codes'] as List?)?.map((e) => e.toString()).toList() ?? [];

    final isMaxTrials = isFirstPiece && currentTrial >= 3;
    final nextTrial = currentTrial + 1;

    final modalTitle = isFirstPiece
        ? (isMaxTrials
              ? 'MAXIMUM TRIALS FAILED (3/3)'
              : '1ST PC #$currentTrial OUT OF SPEC')
        : 'HOURLY SLOT #${provider.hourlySlot} OUT OF SPEC';

    final modalMessage = isFirstPiece
        ? (isMaxTrials
              ? '3 consecutive First Piece trials have failed. Please notify quality supervisor for setup adjustment.'
              : '$failedCount parameter(s) failed specification limits in 1ST PC #$currentTrial trial.')
        : '$failedCount parameter(s) failed specification limits in Hourly Slot #${provider.hourlySlot}.';

    final buttonLabel = isFirstPiece
        ? 'START 1PC#$nextTrial'
        : 'RE-RECORD SLOT #${provider.hourlySlot}';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: isMaxTrials
                ? const Color(0xFFEF4444)
                : const Color(0xFFF59E0B),
            width: 2,
          ),
        ),
        title: Column(
          children: [
            Icon(
              isMaxTrials ? Icons.cancel_rounded : Icons.warning_amber_rounded,
              color: isMaxTrials
                  ? const Color(0xFFEF4444)
                  : const Color(0xFFF59E0B),
              size: 48,
            ),
            const SizedBox(height: 10),
            Text(
              modalTitle,
              style: TextStyle(
                color: isMaxTrials
                    ? const Color(0xFFEF4444)
                    : const Color(0xFFF59E0B),
                fontWeight: FontWeight.w900,
                fontSize: 16,
                letterSpacing: 0.8,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              modalMessage,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (failedCodes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'FAILED PARAMETERS:',
                      style: TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      failedCodes.join(', '),
                      style: const TextStyle(
                        color: Color(0xFFEF4444),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => const SummaryScreen()),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF94A3B8),
                    side: const BorderSide(color: Color(0xFF475569)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'VIEW SUMMARY',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              if (!isMaxTrials) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final template = provider.selectedTemplate;
                      if (template != null) {
                        if (isFirstPiece) {
                          final currentSessId = provider.sessionId;
                          await provider.loadParametersForRetrial(
                            template,
                            trial: nextTrial,
                            targetFailedCodes: failedCodes,
                          );
                          final started = await provider.startSession(
                            trial: nextTrial,
                            inspectionType: 'first_piece',
                            parentId: currentSessId,
                          );
                          if (started && mounted) {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const InspectionVoiceScreen(),
                              ),
                            );
                          }
                        } else {
                          await provider.loadParameters(
                            template,
                            isFirstPiece: false,
                            categoryFilter: 'product',
                          );
                          final started = await provider.startSession(
                            trial: 0,
                            hourlySlot: provider.hourlySlot,
                            inspectionType: 'hourly',
                          );
                          if (started && mounted) {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const InspectionVoiceScreen(),
                              ),
                            );
                          }
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 16),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        buttonLabel,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _showParameterGridModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Consumer<InspectionProvider>(
          builder: (context, provider, child) {
            final opName =
                provider.selectedTemplate?['name'] ?? 'Operation Parameters';
            final params = provider.parameters;

            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFCBD5E1),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.grid_view_rounded,
                          color: Color(0xFF2563EB),
                          size: 24,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                opName,
                                style: const TextStyle(
                                  color: Color(0xFF0F172A),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${params.length} Parameters configured',
                                style: const TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Color(0xFF64748B),
                          ),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFFE2E8F0)),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 1.05,
                          ),
                      itemCount: params.length,
                      itemBuilder: (context, index) {
                        final p = params[index];
                        final code = (p['parameter_code'] ?? '').toString();
                        final name =
                            p['parameter_name'] ?? 'Parameter ${index + 1}';
                        final nom = p['nominal_value'] ?? '-';
                        final unit = p['unit'] ?? 'mm';
                        final isCurrent = index == provider.currentParamIndex;

                        final recorded = provider.recordedResults[code];
                        final isRecorded = recorded != null;
                        final isPass =
                            isRecorded && _isMeasurementPassing(p, recorded);
                        final measuredVal = recorded != null
                            ? (recorded['measured_value'] ?? recorded['value'])
                            : null;

                        return InkWell(
                          onTap: () {
                            provider.goToParameter(index);
                            Navigator.pop(ctx);
                            _scrollToCurrentParam();
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? const Color(0xFFEFF6FF)
                                  : isRecorded
                                  ? (isPass
                                        ? const Color(0xFFECFDF5)
                                        : const Color(0xFFFEF2F2))
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isCurrent
                                    ? const Color(0xFF2563EB)
                                    : isRecorded
                                    ? (isPass
                                          ? const Color(0xFFA7F3D0)
                                          : const Color(0xFFFCA5A5))
                                    : const Color(0xFFE2E8F0),
                                width: isCurrent ? 1.5 : 1,
                              ),
                              boxShadow: [
                                if (isCurrent)
                                  const BoxShadow(
                                    color: Color(0x1A2563EB),
                                    blurRadius: 6,
                                    offset: Offset(0, 2),
                                  ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isCurrent
                                            ? const Color(0xFF2563EB)
                                            : const Color(0xFFF1F5F9),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        '#${index + 1}',
                                        style: TextStyle(
                                          color: isCurrent
                                              ? Colors.white
                                              : const Color(0xFF64748B),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 9,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    if (isRecorded)
                                      Icon(
                                        isPass
                                            ? Icons.check_circle_rounded
                                            : Icons.cancel_rounded,
                                        color: isPass
                                            ? const Color(0xFF059669)
                                            : const Color(0xFFDC2626),
                                        size: 15,
                                      )
                                    else
                                      const Icon(
                                        Icons.circle_outlined,
                                        color: Color(0xFF94A3B8),
                                        size: 13,
                                      ),
                                  ],
                                ),
                                Text(
                                  name,
                                  style: TextStyle(
                                    color: const Color(0xFF0F172A),
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.w600,
                                    fontSize: 11,
                                    height: 1.15,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  isRecorded
                                      ? '$measuredVal $unit'
                                      : '$nom $unit',
                                  style: TextStyle(
                                    color: isRecorded
                                        ? (isPass
                                              ? const Color(0xFF059669)
                                              : const Color(0xFFDC2626))
                                        : const Color(0xFF64748B),
                                    fontSize: 9.5,
                                    fontWeight: isRecorded
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _toggleVoiceRecording() async {
    if (_isRecording) {
      setState(() {
        _isRecording = false;
        _isProcessing = true;
      });

      try {
        final path = await _audioRecorder.stop();
        if (path != null && path.isNotEmpty) {
          final uploadSw = Stopwatch()..start();
          final e2eSw = Stopwatch()..start();

          final startResult = await ApiService.transcribeVoice(path);
          uploadSw.stop();

          final jobId = startResult['job_id'] as String?;
          if (jobId == null) {
            final directText = startResult['raw_text'] ?? startResult['text'];
            if (directText != null && (directText as String).isNotEmpty) {
              await _submitSpokenOrTypedValue(directText);
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('No speech detected. Please try again.'),
                  ),
                );
              }
            }
            return;
          }

          const pollInterval = Duration(seconds: 2);
          const maxWait = Duration(seconds: 60);
          final deadline = DateTime.now().add(maxWait);

          while (DateTime.now().isBefore(deadline)) {
            await Future.delayed(pollInterval);
            final pollRes = await ApiService.checkTranscriptionStatus(jobId);
            final st = pollRes['status'] as String? ?? 'processing';
            if (st == 'done') {
              final textResult = pollRes['raw_text'] ?? pollRes['text'];
              if (textResult != null && (textResult as String).isNotEmpty) {
                await _submitSpokenOrTypedValue(textResult);
              }
              break;
            } else if (st == 'failed') {
              break;
            }
          }
        }
      } catch (e) {
        debugPrint('Recording error: $e');
      } finally {
        if (mounted) {
          setState(() {
            _isProcessing = false;
            _isRecording = false;
          });
        }
      }
    } else {
      bool hasMicPermission = kIsWeb;
      if (!kIsWeb) {
        final status = await Permission.microphone.request();
        hasMicPermission = status.isGranted;
      }
      if (hasMicPermission) {
        if (await _audioRecorder.hasPermission()) {
          String path = '';
          if (!kIsWeb) {
            final tempDir = await getTemporaryDirectory();
            path = '${tempDir.path}/voice_input.m4a';
          }
          await _audioRecorder.start(const RecordConfig(), path: path);
          setState(() {
            _isRecording = true;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final param = provider.currentParameter;

    if (param == null) {
      return Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF059669),
                size: 64,
              ),
              const SizedBox(height: 16),
              const Text(
                'All parameters recorded!',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const SummaryScreen()),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF059669),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                icon: const Icon(Icons.assessment_rounded, color: Colors.white),
                label: const Text(
                  'VIEW SESSION SUMMARY',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isCritical = param['is_critical'] == true;
    final totalCount = provider.parameters.length;
    final currentIndex = provider.currentParamIndex + 1;
    final paramName = param['parameter_name'] ?? 'Parameter $currentIndex';
    final rule = _getParameterRule(param);
    final sampleInstruction = (param['sample_size'] ??
            param['sample_frequency'] ??
            param['sample'] ??
            '')
        .toString()
        .trim();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: const Color(0xFFE2E8F0), height: 1.0),
        ),
        leading: IconButton(
          icon: const Icon(Icons.grid_view_rounded, color: Color(0xFF2563EB)),
          tooltip: 'Parameter Grid Overview',
          onPressed: () => _showParameterGridModal(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              paramName,
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              provider.inspectionType == 'first_piece'
                  ? '1ST PC #${provider.trialNumber}${provider.trialNumber > 1 ? " (Corrective)" : ""} · Step $currentIndex of $totalCount'
                  : 'Step $currentIndex of $totalCount',
              style: const TextStyle(
                color: Color(0xFF2563EB),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.home_rounded, color: Color(0xFF2563EB)),
            tooltip: 'Go to Home',
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const AppHomeScreen()),
                (route) => false,
              );
            },
          ),
          IconButton(
            icon: const Icon(
              Icons.assessment_rounded,
              color: Color(0xFF2563EB),
            ),
            tooltip: 'View Summary',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SummaryScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Horizontal Scrollable Mini-Grid Progress Strip
              _buildMiniGridStrip(provider),

              const SizedBox(height: 14),

              // Parameter Card Header
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: isCritical
                        ? const Color(0xFFFCA5A5)
                        : const Color(0xFFE2E8F0),
                    width: isCritical ? 2 : 1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0A0F172A),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(child: _buildRuleBadge(rule)),
                        if (isCritical) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFFCA5A5),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: Color(0xFFDC2626),
                                  size: 12,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'CRITICAL',
                                  style: TextStyle(
                                    color: Color(0xFFDC2626),
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),

                    const SizedBox(height: 12),

                    Text(
                      paramName,
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    if (param['measurement_technique'] != null &&
                        param['measurement_technique']
                            .toString()
                            .isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.construction_rounded,
                            color: Color(0xFF64748B),
                            size: 13,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              'Tool / Tech: ${param['measurement_technique']}',
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 12,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],

                    if (sampleInstruction.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFECFDF5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFA7F3D0)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.rule_folder_rounded,
                              color: Color(0xFF047857),
                              size: 16,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: RichText(
                                text: TextSpan(
                                  style: const TextStyle(
                                    color: Color(0xFF065F46),
                                    fontSize: 12,
                                  ),
                                  children: [
                                    const TextSpan(
                                      text: 'Sample Size / Frequency: ',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    TextSpan(text: sampleInstruction),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 14),
                    const Divider(color: Color(0xFFE2E8F0), height: 1),
                    const SizedBox(height: 14),

                    _buildSpecSection(param, rule),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // Interactive Data Input Section
              _buildInputSection(provider, param, rule),

              const SizedBox(height: 16),

              if (_lastResult != null) ...[
                _buildResultBanner(_lastResult!),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniGridStrip(InspectionProvider provider) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ListView.builder(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        itemCount: provider.parameters.length,
        itemBuilder: (context, idx) {
          final item = provider.parameters[idx];
          final code = item['parameter_code'] ?? 'P${idx + 1}';
          final isFilled = provider.isParamFilled(code);
          final recorded = provider.recordedResults[code];
          final isPass = isFilled && _isMeasurementPassing(item, recorded);
          final isSelected = idx == provider.currentParamIndex;

          Color chipBg = Colors.white;
          Color borderCol = const Color(0xFFCBD5E1);
          Color textCol = const Color(0xFF0F172A);
          IconData icon = Icons.circle_outlined;
          Color iconCol = const Color(0xFF94A3B8);

          if (isFilled) {
            if (isPass) {
              chipBg = const Color(0xFFECFDF5);
              borderCol = const Color(0xFFA7F3D0);
              textCol = const Color(0xFF059669);
              icon = Icons.check_circle_rounded;
              iconCol = const Color(0xFF059669);
            } else {
              chipBg = const Color(0xFFFEF2F2);
              borderCol = const Color(0xFFFCA5A5);
              textCol = const Color(0xFFDC2626);
              icon = Icons.cancel_rounded;
              iconCol = const Color(0xFFDC2626);
            }
          } else if (isSelected) {
            chipBg = const Color(0xFFEFF6FF);
            borderCol = const Color(0xFF2563EB);
            textCol = const Color(0xFF2563EB);
            iconCol = const Color(0xFF2563EB);
          }

          if (isSelected && isFilled) {
            borderCol = const Color(0xFF2563EB);
          }

          return GestureDetector(
            onTap: () {
              provider.goToParameter(idx);
              setState(() => _lastResult = null);
              _scrollToCurrentParam();
            },
            child: Container(
              width: 64,
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              decoration: BoxDecoration(
                color: chipBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderCol, width: isSelected ? 2 : 1),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    (item['parameter_name'] ?? code).toString(),
                    style: TextStyle(
                      color: textCol,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Icon(icon, color: iconCol, size: 14),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRuleBadge(int rule) {
    Color bg;
    Color text;
    String label;

    if (rule == 2) {
      bg = const Color(0xFFF3E8FF);
      text = const Color(0xFF9333EA);
      label = 'Rule 2: Visual';
    } else if (rule == 31) {
      bg = const Color(0xFFFEF3C7);
      text = const Color(0xFFD97706);
      label = 'Rule 3A: Min Limit';
    } else if (rule == 32) {
      bg = const Color(0xFFE0F2FE);
      text = const Color(0xFF0284C7);
      label = 'Rule 3B: Max Limit';
    } else {
      bg = const Color(0xFFEFF6FF);
      text = const Color(0xFF2563EB);
      label = 'Rule 1: Range';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: text,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildSpecSection(Map<String, dynamic> param, int rule) {
    final unit = param['unit'] ?? 'mm';

    if (param['is_process_parameter'] == true) {
      final spec = param['specification'] ?? '—';
      final dataType = (param['data_type'] ?? 'numeric')
          .toString()
          .toUpperCase();
      final low = param['lower_limit'];
      final high = param['upper_limit'];
      final nom = param['nominal_value'];
      final mtype = (param['measurement_type'] ?? '').toString().toLowerCase();

      if (dataType != 'NUMERIC' ||
          (low == null && high == null && nom == null && mtype.isEmpty)) {
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFEEF2FF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFC7D2FE)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.settings_suggest_rounded,
                color: Color(0xFF4F46E5),
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PROCESS PARAMETER',
                      style: TextStyle(
                        color: Color(0xFF4F46E5),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      low != null && high != null
                          ? 'Spec: $spec  [$low – $high $unit]'
                          : 'Specification: $spec $unit',
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }
    }

    if (rule == 2) {
      final specText = _getVisualSpecText(param);
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF3E8FF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE9D5FF)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.remove_red_eye_rounded,
              color: Color(0xFF9333EA),
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'MASTER VISUAL SPECIFICATION',
                    style: TextStyle(
                      color: Color(0xFF9333EA),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    specText,
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (rule == 31) {
      final minVal = param['lower_limit'] ?? param['nominal_value'] ?? '0';
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFDE68A)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.vertical_align_bottom_rounded,
              color: Color(0xFFD97706),
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'RULE 3: MINIMUM LIMIT THRESHOLD',
                    style: TextStyle(
                      color: Color(0xFFD97706),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Must be ≥ $minVal $unit',
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (rule == 32) {
      final maxVal = param['nominal_value'] ?? param['upper_limit'] ?? '0';
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFE0F2FE),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFBAE6FD)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.vertical_align_top_rounded,
              color: Color(0xFF0284C7),
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'RULE 3: MAXIMUM LIMIT / ROUGHNESS',
                    style: TextStyle(
                      color: Color(0xFF0284C7),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Must be ≤ $maxVal $unit',
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      final nomVal =
          double.tryParse('${param['nominal_value']}')?.toStringAsFixed(2) ??
          '${param['nominal_value']}';
      final minVal =
          double.tryParse('${param['lower_limit']}')?.toStringAsFixed(2) ??
          '${param['lower_limit']}';
      final maxVal =
          double.tryParse('${param['upper_limit']}')?.toStringAsFixed(2) ??
          '${param['upper_limit']}';

      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildSpecItem(
            'Lower Limit',
            '$minVal $unit',
            const Color(0xFF475569),
          ),
          _buildSpecItem(
            'Nominal Target',
            '$nomVal $unit',
            const Color(0xFF2563EB),
          ),
          _buildSpecItem(
            'Upper Limit',
            '$maxVal $unit',
            const Color(0xFF475569),
          ),
        ],
      );
    }
  }

  Widget _buildSpecItem(String label, String value, Color col) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: col,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Widget _buildInputSection(
    InspectionProvider provider,
    Map<String, dynamic> param,
    int rule,
  ) {
    final isFilled = provider.isParamFilled(param['parameter_code']);
    final recorded = provider.recordedResults[param['parameter_code']];

    if (isFilled && recorded != null) {
      final isOk = _isMeasurementPassing(param, recorded);
      final displayVal = (rule == 2)
          ? (isOk ? 'YES (PASS)' : 'NO (REJECT)')
          : '${recorded['measured_value'] ?? recorded['value']} ${param['unit']}';

      final isQueued = recorded['status'] == 'queued';

      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isQueued
              ? const Color(0xFFFEF3C7)
              : (isOk ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isQueued
                ? const Color(0xFFFDE68A)
                : (isOk ? const Color(0xFFA7F3D0) : const Color(0xFFFCA5A5)),
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isQueued
                      ? Icons.hourglass_empty_rounded
                      : (isOk
                            ? Icons.check_circle_rounded
                            : Icons.cancel_rounded),
                  color: isQueued
                      ? const Color(0xFFD97706)
                      : (isOk
                            ? const Color(0xFF059669)
                            : const Color(0xFFDC2626)),
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  isQueued
                      ? 'PROCESSING...'
                      : (isOk
                            ? 'RECORDED: WITHIN SPEC'
                            : 'RECORDED: OUT OF SPEC'),
                  style: TextStyle(
                    color: isQueued
                        ? const Color(0xFFD97706)
                        : (isOk
                              ? const Color(0xFF059669)
                              : const Color(0xFFDC2626)),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              displayVal,
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  provider.recordedResults.remove(param['parameter_code']);
                  _lastResult = null;
                });
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF64748B),
                side: const BorderSide(color: Color(0xFFCBD5E1)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(
                Icons.edit_rounded,
                color: Color(0xFF64748B),
                size: 14,
              ),
              label: const Text(
                'Re-enter / Correct Value',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
              ),
            ),
          ],
        ),
      );
    }

    if (rule == 2) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0A0F172A),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          children: [
            const Text(
              'TAP VISUAL INSPECTION OUTCOME',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () => _submitSpokenOrTypedValue('1.0'),
                    icon: const Icon(
                      Icons.check_circle_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    label: const Text(
                      'YES (PASS)',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF059669),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () => _submitSpokenOrTypedValue('0.0'),
                    icon: const Icon(
                      Icons.cancel_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    label: const Text(
                      'NO (REJECT)',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    String hintText = 'Type measurement...';
    if (rule == 31) hintText = 'Type value (e.g. 3.35 for ≥ 3.30 MIN)...';
    if (rule == 32) hintText = 'Type roughness (e.g. 2.8 for ≤ 3.2 Ra)...';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: _isProcessing ? null : _toggleVoiceRecording,
            child: Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isRecording
                    ? const Color(0xFFDC2626)
                    : (_isProcessing
                          ? const Color(0xFFD97706)
                          : const Color(0xFF2563EB)),
                boxShadow: [
                  BoxShadow(
                    color:
                        (_isRecording
                                ? const Color(0xFFDC2626)
                                : const Color(0xFF2563EB))
                            .withValues(alpha: 0.25),
                    blurRadius: 16,
                    spreadRadius: 3,
                  ),
                ],
              ),
              child: Icon(
                _isRecording
                    ? Icons.stop_rounded
                    : (_isProcessing ? Icons.sync_rounded : Icons.mic_rounded),
                size: 42,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _isRecording
                ? 'Recording... Tap to evaluate & auto-advance'
                : (_isProcessing
                      ? 'Processing speech...'
                      : 'Tap Mic to Speak Reading'),
            style: const TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: InputDecoration(
                    hintText: hintText,
                    errorText: _inputError,
                    hintStyle: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 12.5,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFF2563EB),
                        width: 2,
                      ),
                    ),
                  ),
                  onChanged: (_) {
                    if (_inputError != null) {
                      setState(() => _inputError = null);
                    }
                  },
                  onSubmitted: (val) => _submitSpokenOrTypedValue(val),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _isProcessing
                    ? null
                    : () => _submitSpokenOrTypedValue(_inputController.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  'SUBMIT',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultBanner(Map<String, dynamic> result) {
    final isOk = result['status'] == 'ok';
    final msg =
        result['message'] ??
        (isOk ? 'Value within tolerance.' : 'Out of specification.');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isOk ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOk ? const Color(0xFFA7F3D0) : const Color(0xFFFCA5A5),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isOk ? Icons.check_circle_rounded : Icons.cancel_rounded,
            color: isOk ? const Color(0xFF059669) : const Color(0xFFDC2626),
            size: 24,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                color: isOk ? const Color(0xFF059669) : const Color(0xFFDC2626),
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
