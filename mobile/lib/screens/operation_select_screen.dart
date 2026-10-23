import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/inspection_provider.dart';
import '../services/api_service.dart';
import 'app_home_screen.dart';
import 'inspection_voice_screen.dart';
import 'machine_select_screen.dart';
import 'operation_hourly_slot_screen.dart';
import 'parameter_list_screen.dart';

class OperationSelectScreen extends StatefulWidget {
  const OperationSelectScreen({super.key});

  @override
  State<OperationSelectScreen> createState() => _OperationSelectScreenState();
}

class _OperationSelectScreenState extends State<OperationSelectScreen> {
  List<dynamic> _templates = [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  Map<int, List<int>> _opCompletedSlots = {};
  Map<int, int> _opActiveSlots = {};

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final machineId = int.tryParse('${provider.selectedMachine?['id']}');
    if (machineId == null) return;

    try {
      final setupStatus = await ApiService.checkSetupApproved(machineId);
      final hasReport =
          setupStatus['has_today_report'] == true ||
          setupStatus['session_id'] != null;
      if (hasReport) {
        await provider.restoreActiveReportState(setupStatus);
      } else {
        await provider.resetSessionState();
      }
      await _loadTemplates();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🔄 Synced with server. Ready for new entries.'),
            backgroundColor: Color(0xFF10B981),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Refresh error: $e');
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _loadTemplates() async {
    try {
      final provider = Provider.of<InspectionProvider>(context, listen: false);
      final machineId = int.tryParse('${provider.selectedMachine?['id']}');
      if (machineId == null) {
        if (mounted) {
          setState(() {
            _templates = [];
            _isLoading = false;
          });
        }
        return;
      }

      await provider.fetchPendingRejections();

      Map<int, List<int>> opCompletedSlots = {};
      Map<int, int> opActiveSlots = {};
      try {
        final setupStatus = await ApiService.checkSetupApproved(machineId);
        if (setupStatus['has_today_report'] == true ||
            setupStatus['session_id'] != null) {
          await provider.restoreActiveReportState(setupStatus);
        } else {
          await provider.resetSessionState();
        }
        final List<dynamic> opsFromApi = setupStatus['operations'] ?? [];
        for (final op in opsFromApi) {
          final tid = op['template_id'] as int?;
          if (tid != null) {
            opCompletedSlots[tid] = List<int>.from(op['completed_slots'] ?? []);
            opActiveSlots[tid] = (op['active_slot'] ?? 1) as int;
          }
        }
      } catch (_) {}

      List<dynamic> rawTemplates = [];
      if (provider.selectedPart != null &&
          provider.selectedPart?['part_number'] != null) {
        rawTemplates = await ApiService.getTemplatesByPart(
          provider.selectedPart!['part_number'],
        );
      } else {
        rawTemplates = [];
      }

      final List<dynamic> sorted = List.from(rawTemplates);
      sorted.sort((a, b) {
        final vA = int.tryParse(a['version']?.toString() ?? '0') ?? 0;
        final vB = int.tryParse(b['version']?.toString() ?? '0') ?? 0;
        return vA.compareTo(vB);
      });

      if (mounted) {
        setState(() {
          _templates = sorted;
          _opCompletedSlots = opCompletedSlots;
          _opActiveSlots = opActiveSlots;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading templates: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _getOpTitle(int version) {
    return 'Operation $version';
  }

  Future<void> _startFpiTrial(
    Map<String, dynamic> template,
    int trialNumber,
  ) async {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final isInspector = auth.isInspector;
    final inspType = isInspector ? 'first_piece' : 'hourly';

    final key = InspectionProvider.operationKey(template, inspType);
    provider.switchActiveOperation(key);

    final parentId = (isInspector && trialNumber > 1)
        ? (provider.trialSessionIds[trialNumber - 1] ?? provider.sessionId)
        : null;

    if (trialNumber == 1 || !isInspector) {
      await provider.loadParameters(
        template,
        isFirstPiece: isInspector,
        categoryFilter: 'product',
      );
    } else {
      final failedCodes = provider.trialFailedCodes[trialNumber - 1];
      await provider.loadParametersForRetrial(
        template,
        trial: trialNumber,
        targetFailedCodes: failedCodes,
      );
    }

    if (provider.parameters.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ No parameters found to inspect for this trial.'),
            backgroundColor: Colors.orangeAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (provider.sessionId != null &&
        trialNumber == provider.trialNumber &&
        provider.inspectionType == inspType) {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const InspectionVoiceScreen()),
        );
      }
      return;
    }

    final started = await provider.startSession(
      trial: isInspector ? trialNumber : 0,
      hourlySlot: isInspector ? 0 : provider.hourlySlot,
      inspectionType: inspType,
      parentId: parentId,
    );
    if (started && mounted) {
      if (isInspector && trialNumber > 1) {
        final count = provider.parameters.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🎯 Corrective Trial 1ST PC #$trialNumber: Re-measuring $count failed parameter(s).',
            ),
            backgroundColor: const Color(0xFFD97706),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const InspectionVoiceScreen()),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to start session: ${provider.errorMessage ?? "Server error"}',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final auth = Provider.of<AuthProvider>(context);
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
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        title: Text(
          'Part: ${provider.selectedPart?['part_number'] ?? '—'}',
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
        ),
        actions: [
          IconButton(
            icon: _isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF2563EB),
                    ),
                  )
                : const Icon(Icons.refresh_rounded, color: Color(0xFF2563EB)),
            tooltip: 'Refresh / Sync with Server',
            onPressed: _isRefreshing ? null : _handleRefresh,
          ),
          IconButton(
            icon: const Icon(Icons.home_rounded, color: Color(0xFF64748B)),
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
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Selected Machine & Part Banner
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
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFDBEAFE)),
                      ),
                      child: const Icon(
                        Icons.build_circle_rounded,
                        color: Color(0xFF2563EB),
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            provider.selectedMachine?['name'] ?? 'Machine',
                            style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Code: ${provider.selectedMachine?['machine_code'] ?? ''}  •  Part: ${provider.selectedPart?['part_name'] ?? provider.selectedPart?['part_number'] ?? '-'}',
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const MachineSelectScreen(),
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF2563EB),
                        side: const BorderSide(color: Color(0xFFBFDBFE)),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text(
                        'CHANGE',
                        style: TextStyle(
                          color: Color(0xFF2563EB),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Active Supervisor Rejection Banner (If any session was rejected)
              if (provider.activeRejections.isNotEmpty) ...[
                const SizedBox(height: 16),
                ...provider.activeRejections.map((rej) {
                  final currentTrial = rej['trial_number'] ?? 1;
                  final nextTrial = currentTrial + 1;
                  final remark =
                      rej['rejection_reason'] ??
                      rej['supervisor_remark'] ??
                      'Correction required by supervisor.';
                  final List<dynamic> rejectedParams =
                      rej['rejected_parameters'] ?? [];

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFFCA5A5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: Color(0xFFDC2626),
                              size: 22,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '1ST PC #$currentTrial REJECTED BY SUPERVISOR',
                              style: const TextStyle(
                                color: Color(0xFFDC2626),
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Remark: "$remark"',
                          style: const TextStyle(
                            color: Color(0xFF451A03),
                            fontSize: 13,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        if (rejectedParams.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Targeted Re-entry Params: ${rejectedParams.join(", ")}',
                            style: const TextStyle(
                              color: Color(0xFFB45309),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFDC2626),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(double.infinity, 42),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            elevation: 0,
                          ),
                          icon: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                          ),
                          label: Text(
                            'START CORRECTIVE TRIAL (1ST PC #$nextTrial)',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          onPressed: () async {
                            List<dynamic> templates = _templates;
                            if (templates.isEmpty) {
                              final partNo = provider
                                  .selectedPart?['part_number']
                                  ?.toString();
                              if (partNo != null && partNo.isNotEmpty) {
                                templates = await ApiService.getTemplatesByPart(
                                  partNo,
                                );
                              }
                            }

                            if (templates.isNotEmpty) {
                              final targetTemplate = templates.first;
                              await provider.loadParameters(
                                targetTemplate,
                                targetRejectedCodes: rejectedParams,
                              );
                              final parentId = rej['session_id'] ?? rej['id'];
                              final started = await provider.startSession(
                                trial: nextTrial,
                                parentId: parentId,
                              );
                              if (started && context.mounted) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const InspectionVoiceScreen(),
                                  ),
                                );
                              } else if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Failed to start corrective session: ${provider.errorMessage ?? "Server error"}',
                                    ),
                                    backgroundColor: Colors.redAccent,
                                  ),
                                );
                              }
                            } else if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'No active template found for corrective trial.',
                                  ),
                                  backgroundColor: Colors.amber,
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  );
                }),
              ],

              if (isInspector) ...[
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'FIRST PIECE INSPECTION TRIALS',
                      style: TextStyle(
                        color: Color(0xFF475569),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFDBEAFE)),
                      ),
                      child: const Text(
                        '1PC ONLY',
                        style: TextStyle(
                          color: Color(0xFF2563EB),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _buildTrialLaunchCard(
                        1,
                        '1ST PC #1',
                        'Initial Setup',
                        const Color(0xFF2563EB),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildTrialLaunchCard(
                        2,
                        '1ST PC #2',
                        'Corrective',
                        const Color(0xFFD97706),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildTrialLaunchCard(
                        3,
                        '1ST PC #3',
                        'Final Check',
                        const Color(0xFF059669),
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 20),
              Text(
                isInspector
                    ? 'SELECT OPERATION FOR 1ST PIECE INSPECTION'
                    : 'SELECT PROCESS OPERATION TO INSPECT',
                style: const TextStyle(
                  color: Color(0xFF475569),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 12),

              _isLoading
                  ? const Expanded(
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF2563EB),
                        ),
                      ),
                    )
                  : Expanded(
                      child: RefreshIndicator(
                        onRefresh: _loadTemplates,
                        color: const Color(0xFF2563EB),
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _templates.length,
                          itemBuilder: (context, index) {
                            final t = _templates[index];
                            final version = t['version'];
                            final customName = t['name']?.toString().trim();
                            final title =
                                (customName != null && customName.isNotEmpty)
                                ? customName
                                : (version != null
                                      ? _getOpTitle(version)
                                      : 'Unnamed operation');
                            final paramCount =
                                t['configured_parameter_count'] ??
                                t['target_parameter_count'];
                            final cycleTimeMins = (t['cycle_time_mins'] is num)
                                ? (t['cycle_time_mins'] as num).toDouble()
                                : 0.0;
                            final isPublished =
                                t['is_published'] == true ||
                                t['is_active'] == true;

                            return Card(
                              color: Colors.white,
                              elevation: 0,
                              margin: const EdgeInsets.only(bottom: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: BorderSide(
                                  color: isPublished
                                      ? const Color(0xFFA7F3D0)
                                      : const Color(0xFFE2E8F0),
                                  width: isPublished ? 1.5 : 1,
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  if (isInspector) {
                                    _showInspectionTypeSelectionModal(
                                      context,
                                      t,
                                    );
                                  } else {
                                    final tid = t['id'] as int? ?? 0;
                                    final List<int> completedSlotsForOp =
                                        _opCompletedSlots[tid] ?? [];
                                    final int activeSlotForOp =
                                        _opActiveSlots[tid] ?? 1;
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            OperationHourlySlotScreen(
                                              template: t,
                                              totalSlots: provider.shiftHours,
                                              completedSlots:
                                                  completedSlotsForOp,
                                              activeSlot: activeSlotForOp,
                                            ),
                                      ),
                                    ).then((_) {
                                      _loadTemplates();
                                    });
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 20,
                                        backgroundColor: isPublished
                                            ? const Color(0xFFECFDF5)
                                            : const Color(0xFFF1F5F9),
                                        child: Text(
                                          '${index + 1}',
                                          style: TextStyle(
                                            color: isPublished
                                                ? const Color(0xFF059669)
                                                : const Color(0xFF2563EB),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    title,
                                                    style: const TextStyle(
                                                      color: Color(0xFF0F172A),
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 15,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                if (cycleTimeMins > 0) ...[
                                                  const SizedBox(width: 6),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 2,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                        0xFFF0FDF4,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            4,
                                                          ),
                                                      border: Border.all(
                                                        color: const Color(
                                                          0xFFBBF7D0,
                                                        ),
                                                      ),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        const Icon(
                                                          Icons.timer_outlined,
                                                          size: 10,
                                                          color: Color(
                                                            0xFF059669,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 3,
                                                        ),
                                                        Text(
                                                          '${cycleTimeMins.toStringAsFixed(1)} min',
                                                          style:
                                                              const TextStyle(
                                                                color: Color(
                                                                  0xFF059669,
                                                                ),
                                                                fontSize: 9,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                                if (isPublished) ...[
                                                  const SizedBox(width: 6),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 2,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                        0xFFECFDF5,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            4,
                                                          ),
                                                      border: Border.all(
                                                        color: const Color(
                                                          0xFFA7F3D0,
                                                        ),
                                                      ),
                                                    ),
                                                    child: const Text(
                                                      'DISPATCHED',
                                                      style: TextStyle(
                                                        color: Color(
                                                          0xFF059669,
                                                        ),
                                                        fontSize: 9,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Text(
                                                  isInspector
                                                      ? 'Type: ${t['inspection_type_display'] ?? t['inspection_type']}'
                                                      : 'Hourly • Slot ${_opActiveSlots[t['id'] ?? 0] ?? 1}/HR Active',
                                                  style: const TextStyle(
                                                    color: Color(0xFF64748B),
                                                    fontSize: 11,
                                                  ),
                                                ),
                                                const Text(
                                                  '•',
                                                  style: TextStyle(
                                                    color: Color(0xFF94A3B8),
                                                    fontSize: 11,
                                                  ),
                                                ),
                                                Text(
                                                  '⚡ $paramCount Params',
                                                  style: const TextStyle(
                                                    color: Color(0xFF2563EB),
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            if (!isInspector) ...[
                                              const SizedBox(height: 6),
                                              Builder(
                                                builder: (_) {
                                                  final tid =
                                                      t['id'] as int? ?? 0;
                                                  final done =
                                                      _opCompletedSlots[tid] ??
                                                      [];
                                                  final active =
                                                      _opActiveSlots[tid] ?? 1;
                                                  return Wrap(
                                                    spacing: 4,
                                                    runSpacing: 4,
                                                    children: List.generate(
                                                      provider.shiftHours > 8
                                                          ? 8
                                                          : provider.shiftHours,
                                                      (i) {
                                                        final s = i + 1;
                                                        final isDone = done
                                                            .contains(s);
                                                        final isAct =
                                                            s == active &&
                                                            !isDone;
                                                        return Container(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 5,
                                                                vertical: 2,
                                                              ),
                                                          decoration: BoxDecoration(
                                                            color: isDone
                                                                ? const Color(
                                                                    0xFFECFDF5,
                                                                  )
                                                                : isAct
                                                                ? const Color(
                                                                    0xFFEFF6FF,
                                                                  )
                                                                : const Color(
                                                                    0xFFF1F5F9,
                                                                  ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  4,
                                                                ),
                                                            border: Border.all(
                                                              color: isDone
                                                                  ? const Color(
                                                                      0xFFA7F3D0,
                                                                    )
                                                                  : isAct
                                                                  ? const Color(
                                                                      0xFF2563EB,
                                                                    )
                                                                  : const Color(
                                                                      0xFFE2E8F0,
                                                                    ),
                                                            ),
                                                          ),
                                                          child: Text(
                                                            isDone
                                                                ? '✓$s'
                                                                : isAct
                                                                ? '▶$s'
                                                                : '🔒$s',
                                                            style: TextStyle(
                                                              fontSize: 9,
                                                              color: isDone
                                                                  ? const Color(
                                                                      0xFF059669,
                                                                    )
                                                                  : isAct
                                                                  ? const Color(
                                                                      0xFF2563EB,
                                                                    )
                                                                  : const Color(
                                                                      0xFF94A3B8,
                                                                    ),
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                            ),
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      const Icon(
                                        Icons.arrow_forward_ios_rounded,
                                        color: Color(0xFF2563EB),
                                        size: 16,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrialLaunchCard(
    int trialNum,
    String title,
    String subtitle,
    Color color,
  ) {
    final provider = Provider.of<InspectionProvider>(context);
    final status =
        provider.trialStatuses[trialNum] ??
        (trialNum == 1 ? 'pending' : 'locked');
    final isPassed = status == 'passed';
    final isFailed = status == 'failed';
    final isNotNeeded = status == 'not_needed';
    final isLocked = status == 'locked';

    Color cardBorderColor = color.withValues(alpha: 0.4);
    Color iconColor = color;
    IconData icon = Icons.verified_rounded;
    String btnText = 'START #$trialNum';
    Color btnColor = color;
    bool isActionable = true;

    if (isPassed) {
      cardBorderColor = const Color(0xFFA7F3D0);
      iconColor = const Color(0xFF059669);
      icon = Icons.check_circle_rounded;
      btnText = 'PASSED';
      btnColor = const Color(0xFF059669);
      isActionable = false;
    } else if (isNotNeeded) {
      cardBorderColor = const Color(0xFFE2E8F0);
      iconColor = const Color(0xFF94A3B8);
      icon = Icons.remove_circle_outline_rounded;
      btnText = 'NOT NEEDED';
      btnColor = const Color(0xFF94A3B8);
      isActionable = false;
    } else if (isLocked) {
      cardBorderColor = const Color(0xFFE2E8F0);
      iconColor = const Color(0xFF94A3B8);
      icon = Icons.lock_rounded;
      btnText = 'LOCKED';
      btnColor = const Color(0xFF94A3B8);
      isActionable = false;
    } else if (isFailed) {
      cardBorderColor = const Color(0xFFFECACA);
      iconColor = const Color(0xFFDC2626);
      icon = Icons.error_outline_rounded;
      btnText = 'FAILED';
      btnColor = const Color(0xFFDC2626);
      isActionable = false;
    } else {
      // Pending / Unlocked to start
      final failedCount = provider.trialFailedCodes[trialNum - 1]?.length;
      if (trialNum > 1 && failedCount != null && failedCount > 0) {
        btnText = 'RE-CHECK ($failedCount)';
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cardBorderColor,
          width: isActionable ? 1.5 : 1,
        ),
      ),
      child: Column(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              color: isActionable ? color : const Color(0xFF64748B),
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 9),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                if (isLocked) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '🔒 1ST PC #$trialNum is only unlocked if 1ST PC #${trialNum - 1} has out-of-spec readings.',
                      ),
                      backgroundColor: const Color(0xFFD97706),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  return;
                }
                if (isPassed) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '✅ 1ST PC #$trialNum is already completed and passed.',
                      ),
                      backgroundColor: const Color(0xFF059669),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  return;
                }
                if (isNotNeeded) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'ℹ️ Setup is already passed. Corrective trial is not needed.',
                      ),
                      backgroundColor: Color(0xFF2563EB),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  return;
                }
                final t = _templates.isNotEmpty ? _templates.first : null;
                if (t != null) {
                  _startFpiTrial(t, trialNum);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('No active template found to start trial.'),
                      backgroundColor: Colors.orangeAccent,
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: btnColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 4),
                minimumSize: Size.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                elevation: 0,
              ),
              child: Text(
                btnText,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showInspectionTypeSelectionModal(
    BuildContext context,
    Map<String, dynamic> template,
  ) {
    final opTitle = template['name'] ?? _getOpTitle(template['version'] ?? 10);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                opTitle,
                style: const TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                'Select Inspection Type',
                style: TextStyle(
                  color: Color(0xFF2563EB),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 22),

              // 1) PRODUCT PARAMETERS BUTTON
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.pop(ctx);
                  final provider = Provider.of<InspectionProvider>(
                    context,
                    listen: false,
                  );
                  provider.selectedTemplate = template;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ParameterListScreen(
                        template: template,
                        initialCategory: 'product',
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFBFDBFE)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.straighten_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Product Parameters',
                              style: TextStyle(
                                color: Color(0xFF0F172A),
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'First Piece Inspection — Quality Dimensions',
                              style: TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: Color(0xFF2563EB),
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // 2) PROCESS PARAMETERS BUTTON
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.pop(ctx);
                  final provider = Provider.of<InspectionProvider>(
                    context,
                    listen: false,
                  );
                  provider.selectedTemplate = template;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ParameterListScreen(
                        template: template,
                        initialCategory: 'process',
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEF2FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFC7D2FE)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4F46E5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.settings_suggest_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Process Parameters',
                              style: TextStyle(
                                color: Color(0xFF0F172A),
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'First Piece Inspection — Process Setup Checks',
                              style: TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: Color(0xFF4F46E5),
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }
}
