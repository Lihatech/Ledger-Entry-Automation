import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/inspection_provider.dart';
import '../services/api_service.dart';
import 'inspection_voice_screen.dart';
import 'operation_select_screen.dart';

/// Per-operation hourly slot picker screen (Light Theme UI).
///
/// Features:
/// - Clean, single vertical cards view (redundant horizontal strip removed).
/// - Dynamic refresh of per-operation slot progress from backend.
/// - Immediate visual feedback for completed, active, and locked slots.
class OperationHourlySlotScreen extends StatefulWidget {
  final Map<String, dynamic> template;
  final int totalSlots;
  final List<int> completedSlots;
  final int activeSlot;

  const OperationHourlySlotScreen({
    super.key,
    required this.template,
    required this.totalSlots,
    this.completedSlots = const [],
    this.activeSlot = 1,
  });

  @override
  State<OperationHourlySlotScreen> createState() => _OperationHourlySlotScreenState();
}

class _OperationHourlySlotScreenState extends State<OperationHourlySlotScreen> {
  late List<int> _completedSlots;
  late int _activeSlot;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _completedSlots = List<int>.from(widget.completedSlots);
    _activeSlot = widget.activeSlot;
    _refreshSlots();
  }

  Future<void> _refreshSlots() async {
    if (!mounted) return;
    setState(() {
      _isRefreshing = true;
    });

    try {
      final provider = Provider.of<InspectionProvider>(context, listen: false);
      final machineId = provider.selectedMachine?['id'] ?? 1;
      final partId = int.tryParse('${provider.selectedPart?['id']}');
      final setupStatus = await ApiService.checkSetupApproved(machineId, partId: partId);
      final List<dynamic> opsFromApi = setupStatus['operations'] ?? [];
      final tid = widget.template['id'] as int?;

      for (final op in opsFromApi) {
        if (op['template_id'] == tid) {
          if (mounted) {
            final List<int> backendSlots = List<int>.from(op['completed_slots'] ?? []);
            int backendActive = (op['active_slot'] ?? 1) as int;
            final Set<int> merged = {..._completedSlots, ...backendSlots};
            final sortedMerged = merged.toList()..sort();
            if (sortedMerged.contains(backendActive) && backendActive < widget.totalSlots) {
              backendActive = sortedMerged.last + 1;
            }
            setState(() {
              _completedSlots = sortedMerged;
              _activeSlot = backendActive;
            });
          }
          break;
        }
      }
    } catch (e) {
      debugPrint('[SLOT_SCREEN] Error refreshing slots: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  String get _opName {
    final name = (widget.template['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final v = widget.template['version']?.toString() ?? '';
    return 'Op $v — Inspection';
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Color(0xFF0F172A)),
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const OperationSelectScreen()),
              );
            }
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _opName,
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Text(
              'SELECT HOURLY SLOT',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontSize: 10,
                letterSpacing: 1.1,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Operation summary banner (Light Theme Card)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFBFDBFE)),
                    ),
                    child: const Icon(
                      Icons.precision_manufacturing_rounded,
                      color: Color(0xFF2563EB),
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _opName,
                          style: const TextStyle(
                            color: Color(0xFF0F172A),
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Hourly In-Process Inspection  •  ${widget.template['target_parameter_count'] ?? widget.template['total_parameters'] ?? '?'} params',
                          style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFA7F3D0)),
                    ),
                    child: Text(
                      '${_completedSlots.length}/${widget.totalSlots} done',
                      style: const TextStyle(
                        color: Color(0xFF059669),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'HOURLY INSPECTION SLOTS (1/HR - ${widget.totalSlots}/HR)',
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                if (_isRefreshing)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB)),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Clean vertical slot detail cards (Single view, no double horizontal strip)
            ...List.generate(widget.totalSlots, (index) {
              final slotNum = index + 1;
              final isCompleted = _completedSlots.contains(slotNum);
              final isActive = slotNum == _activeSlot;
              final isUnlocked = isCompleted || isActive || slotNum <= _activeSlot;

              final Color cardBg;
              final Color borderColor;
              final Color statusColor;
              final Color iconBg;
              final IconData iconData;
              final String statusLabel;

              if (isCompleted) {
                cardBg = Colors.white;
                borderColor = const Color(0xFFA7F3D0);
                statusColor = const Color(0xFF059669);
                iconBg = const Color(0xFFECFDF5);
                iconData = Icons.check_circle_rounded;
                statusLabel = 'COMPLETED';
              } else if (isActive) {
                cardBg = Colors.white;
                borderColor = const Color(0xFF2563EB);
                statusColor = const Color(0xFF2563EB);
                iconBg = const Color(0xFFEFF6FF);
                iconData = Icons.play_circle_fill_rounded;
                statusLabel = 'ACTIVE — TAP TO RECORD';
              } else if (isUnlocked) {
                cardBg = Colors.white;
                borderColor = const Color(0xFFE2E8F0);
                statusColor = const Color(0xFF64748B);
                iconBg = const Color(0xFFF8FAFC);
                iconData = Icons.play_arrow_rounded;
                statusLabel = 'UNLOCKED';
              } else {
                cardBg = const Color(0xFFFAFAFA);
                borderColor = const Color(0xFFE2E8F0);
                statusColor = const Color(0xFF94A3B8);
                iconBg = const Color(0xFFF1F5F9);
                iconData = Icons.lock_outline_rounded;
                statusLabel = 'LOCKED';
              }

              return GestureDetector(
                onTap: () => _onSlotTapped(context, provider, slotNum, isCompleted, isUnlocked),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: borderColor, width: isActive ? 1.8 : 1),
                    boxShadow: [
                      BoxShadow(
                        color: isActive
                            ? const Color(0xFF2563EB).withValues(alpha: 0.12)
                            : Colors.black.withValues(alpha: 0.03),
                        blurRadius: isActive ? 8 : 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: iconBg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(iconData, color: statusColor, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Slot $slotNum/HR',
                              style: TextStyle(
                                color: isUnlocked || isCompleted
                                    ? const Color(0xFF0F172A)
                                    : const Color(0xFF94A3B8),
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              statusLabel,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2563EB),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'RECORD',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(width: 4),
                              Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 14),
                            ],
                          ),
                        )
                      else if (isCompleted)
                        const Icon(Icons.check_circle_rounded, color: Color(0xFF059669), size: 22)
                      else if (isUnlocked)
                        const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF64748B), size: 14)
                      else
                        const Icon(Icons.lock_rounded, color: Color(0xFFCBD5E1), size: 18),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _onSlotTapped(
    BuildContext context,
    InspectionProvider provider,
    int slotNum,
    bool isCompleted,
    bool isUnlocked,
  ) async {
    if (isCompleted) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Slot $slotNum/HR for $_opName is already completed. Rewriting is not allowed.'),
            backgroundColor: const Color(0xFFD97706),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!isUnlocked) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Complete Slot ${slotNum - 1}/HR for $_opName first.'),
            backgroundColor: const Color(0xFFD97706),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final key = InspectionProvider.operationKey(widget.template, 'hourly');
    provider.switchActiveOperation(key);
    
    if (provider.sessionId != null && provider.hourlySlot == slotNum) {
      if (context.mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const InspectionVoiceScreen()),
        );
        if (mounted) await _refreshSlots();
      }
      return;
    }

    await provider.loadParameters(widget.template);
    final started = await provider.startSession(
      trial: 1,
      inspectionType: 'hourly',
      hourlySlot: slotNum,
    );

    if (started && context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const InspectionVoiceScreen()),
      );
      if (mounted) {
        await _refreshSlots();
      }
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot start: ${provider.errorMessage ?? "Unknown error."}'),
          backgroundColor: const Color(0xFFEF4444),
        ),
      );
    }
  }
}
