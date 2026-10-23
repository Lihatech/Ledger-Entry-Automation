import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/inspection_provider.dart';
import 'app_home_screen.dart';
import 'operation_hourly_slot_screen.dart';
import 'operation_select_screen.dart';

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  bool _isSubmitting = false;

  String _formatSpecSubtitle(Map<String, dynamic> param) {
    if (param['is_process_parameter'] == true) {
      return 'Spec: ${param['specification'] ?? '—'} ${param['unit'] ?? ''}';
    }

    final type = (param['measurement_type'] ?? '').toString().toLowerCase();
    final name = (param['parameter_name'] ?? '').toString().toUpperCase();

    if (type == 'visual') {
      return 'Spec: Visual Pass / Fail Check';
    }
    if (name.contains('MIN')) {
      return 'Spec: ≥ ${param['lower_limit']} ${param['unit']} (MINIMUM)';
    }
    if (type == 'surface' || name.contains('MAX')) {
      return 'Spec: ≤ ${param['upper_limit']} ${param['unit']} (MAXIMUM)';
    }
    return 'Spec: ${param['nominal_value']} ${param['unit']} [${param['lower_limit']} - ${param['upper_limit']}]';
  }

  String _formatRecordedValue(
    Map<String, dynamic> param,
    Map<String, dynamic> res,
  ) {
    if (param['is_process_parameter'] == true) {
      if (param['data_type'] == 'yes_no') {
        return (res['measured_value'] == 1.0 || res['status'] == 'ok')
            ? 'YES (PASS)'
            : 'NO (REJECT)';
      }
      return '${res['measured_value']} ${param['unit'] ?? ''}';
    }

    final type = (param['measurement_type'] ?? '').toString().toLowerCase();

    if (type == 'visual') {
      return (res['measured_value'] == 1.0 || res['status'] == 'ok')
          ? 'YES (PASS)'
          : 'NO (REJECT)';
    }
    return '${res['measured_value']} ${param['unit']}';
  }

  bool _isPass(Map<String, dynamic> param, Map<String, dynamic>? res) {
    if (res == null) return false;
    final st = (res['status'] ?? '').toString().toLowerCase();
    if (st == 'ok' || st == 'pass' || res['is_pass'] == true) return true;
    if (st == 'out_of_spec' || st == 'reject' || res['is_pass'] == false)
      return false;

    final val = double.tryParse('${res['measured_value'] ?? res['value']}');
    if (val == null) return false;

    final type = (param['measurement_type'] ?? '').toString().toLowerCase();
    final name = (param['parameter_name'] ?? '').toString().toUpperCase();

    if (type == 'visual') return val >= 0.5;
    if (name.contains('MIN')) {
      final minVal = double.tryParse(
        '${param['lower_limit'] ?? param['nominal_value']}',
      );
      if (minVal != null) return val >= minVal;
    }
    if (type == 'surface' || name.contains('MAX')) {
      final maxVal = double.tryParse(
        '${param['nominal_value'] ?? param['upper_limit']}',
      );
      if (maxVal != null) return val <= maxVal;
    }
    final ll = double.tryParse('${param['lower_limit']}');
    final ul = double.tryParse('${param['upper_limit']}');
    if (ll != null && ul != null) return val >= ll && val <= ul;

    return true;
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final auth = Provider.of<AuthProvider>(context);
    final results = provider.recordedResults;
    final isInspector = auth.isInspector;

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
        title: const Text(
          'Session Summary',
          style: TextStyle(
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
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
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Session Overview Card
              Container(
                padding: const EdgeInsets.all(16),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Part: ${provider.selectedPart?['part_number'] ?? '-'} (${provider.selectedPart?['part_name'] ?? provider.selectedPart?['part_number'] ?? '-'})',
                            style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: provider.inspectionType == 'first_piece'
                                ? const Color(0xFFEFF6FF)
                                : const Color(0xFFECFDF5),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: provider.inspectionType == 'first_piece'
                                  ? const Color(0xFFBFDBFE)
                                  : const Color(0xFFA7F3D0),
                            ),
                          ),
                          child: Text(
                            provider.inspectionType == 'first_piece'
                                ? '1ST PC #${provider.trialNumber}'
                                : 'SLOT ${provider.hourlySlot}/HR',
                            style: TextStyle(
                              color: provider.inspectionType == 'first_piece'
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFF059669),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Machine: ${provider.selectedMachine?['name'] ?? provider.selectedMachine?['machine_code'] ?? '—'}  •  Recorded: ${results.length} of ${provider.parameters.length} params',
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              const Text(
                'RECORDED PARAMETERS CHECKLIST',
                style: TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 10),

              Expanded(
                child: ListView.builder(
                  itemCount: provider.parameters.length,
                  itemBuilder: (context, index) {
                    final param = provider.parameters[index];
                    final code = param['parameter_code'];
                    final res = results[code];
                    final isRecorded = res != null;
                    final isOk = isRecorded && _isPass(param, res);

                    return Card(
                      color: Colors.white,
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: isRecorded
                              ? (isOk
                                    ? const Color(0xFFA7F3D0)
                                    : const Color(0xFFFCA5A5))
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                        title: Text(
                          '${param['parameter_name']}',
                          style: const TextStyle(
                            color: Color(0xFF0F172A),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          _formatSpecSubtitle(param),
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 12,
                          ),
                        ),
                        trailing: isRecorded
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: isOk
                                      ? const Color(0xFFECFDF5)
                                      : const Color(0xFFFEF2F2),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isOk
                                        ? const Color(0xFFA7F3D0)
                                        : const Color(0xFFFCA5A5),
                                  ),
                                ),
                                child: Text(
                                  '${_formatRecordedValue(param, res)} (${isOk ? 'OK' : 'FAIL'})',
                                  style: TextStyle(
                                    color: isOk
                                        ? const Color(0xFF059669)
                                        : const Color(0xFFDC2626),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                              )
                            : Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFBEB),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: const Color(0xFFFDE68A),
                                  ),
                                ),
                                child: const Text(
                                  'PENDING',
                                  style: TextStyle(
                                    color: Color(0xFFD97706),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 16),

              // Submit / Finalize Session Button
              ElevatedButton(
                onPressed: _isSubmitting
                    ? null
                    : () async {
                        if (provider.parameters.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                '❌ Cannot finalize: No inspection parameters were loaded for this session.',
                              ),
                              backgroundColor: Colors.redAccent,
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                          return;
                        }

                        setState(() {
                          _isSubmitting = true;
                        });

                        Map<String, dynamic>? finalResult;
                        if (isInspector) {
                          finalResult = await provider
                              .finalizeFirstPieceSession();
                        } else {
                          await provider.completeSession();
                        }

                        if (!mounted) return;

                        setState(() {
                          _isSubmitting = false;
                        });

                        _showCompletionDialog(provider, finalResult);
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      )
                    : Text(
                        isInspector
                            ? 'FINALIZE FIRST PIECE & GENERATE REPORT'
                            : 'SUBMIT HOURLY INSPECTION (SLOT ${provider.hourlySlot}/HR)',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCompletionDialog(
    InspectionProvider provider, [
    Map<String, dynamic>? finalResult,
  ]) {
    final results = provider.recordedResults;
    final totalParams = provider.parameters.length;
    int okCount = 0;
    int oocCount = 0;

    results.forEach((key, val) {
      final isOk = _isPass({'parameter_code': key}, val);
      if (isOk) {
        okCount++;
      } else {
        oocCount++;
      }
    });

    final templateName =
        provider.selectedTemplate?['name'] ??
        'Op ${provider.selectedTemplate?['version'] ?? 10} — Inspection';

    final isInspector = Provider.of<AuthProvider>(
      context,
      listen: false,
    ).isInspector;
    final isPassed =
        (finalResult?['status'] == 'finalized_passed') ||
        (oocCount == 0 && totalParams > 0 && results.isNotEmpty);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: isPassed ? const Color(0xFF059669) : const Color(0xFFDC2626),
            width: 1.5,
          ),
        ),
        title: Column(
          children: [
            Icon(
              isPassed
                  ? Icons.check_circle_rounded
                  : Icons.warning_amber_rounded,
              color: isPassed
                  ? const Color(0xFF059669)
                  : const Color(0xFFDC2626),
              size: 54,
            ),
            const SizedBox(height: 10),
            Text(
              isInspector
                  ? (isPassed
                        ? 'FIRST PIECE FINALIZED & PASSED!'
                        : 'FIRST PIECE FINALIZED (REJECTED)')
                  : 'HOURLY INSPECTION SUBMITTED!',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              templateName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF2563EB),
                fontSize: 13,
                fontWeight: FontWeight.w600,
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
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isPassed
                      ? const Color(0xFFECFDF5)
                      : const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isPassed
                        ? const Color(0xFFA7F3D0)
                        : const Color(0xFFFCA5A5),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        const Text(
                          'WITHIN SPEC',
                          style: TextStyle(
                            color: Color(0xFF059669),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$okCount / $totalParams',
                          style: const TextStyle(
                            color: Color(0xFF059669),
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      height: 24,
                      width: 1,
                      color: const Color(0xFFCBD5E1),
                    ),
                    Column(
                      children: [
                        const Text(
                          'OUT OF SPEC',
                          style: TextStyle(
                            color: Color(0xFFDC2626),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$oocCount / $totalParams',
                          style: const TextStyle(
                            color: Color(0xFFDC2626),
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                isInspector
                    ? (isPassed
                          ? 'Production line setup is approved. Operators may proceed with hourly manufacturing.'
                          : 'Setup parameters failed validation. Corrective trial required.')
                    : 'Hourly Slot ${provider.completedHourlySlots.isNotEmpty ? provider.completedHourlySlots.last : provider.hourlySlot}/HR recorded successfully into the digital F02 inspection ledger.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              provider.recordedResults.clear();
              provider.pendingBatchValues.clear();
              provider.parameters = [];
              provider.currentParamIndex = 0;
              if (!isInspector && provider.selectedTemplate != null) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OperationHourlySlotScreen(
                      template: provider.selectedTemplate!,
                      totalSlots: provider.shiftHours > 0
                          ? provider.shiftHours
                          : 8,
                      completedSlots: provider.completedHourlySlots.toList(),
                      activeSlot: provider.hourlySlot,
                    ),
                  ),
                  (route) => route.isFirst,
                );
              } else {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const OperationSelectScreen(),
                  ),
                  (route) => false,
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              elevation: 0,
            ),
            child: Text(
              isInspector ? 'CONTINUE TO OPERATIONS' : 'CONTINUE TO NEXT SLOT',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
