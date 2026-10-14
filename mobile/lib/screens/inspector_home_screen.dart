import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/inspection_provider.dart';
import '../services/api_service.dart';
import 'inspection_voice_screen.dart';
import 'parameter_list_screen.dart';
import 'machine_select_screen.dart';
import 'report_sheet_screen.dart';
import 'login_screen.dart';
import 'setup_approval_screen.dart';
import 'setup_approval_report_screen.dart';

class InspectorHomeScreen extends StatefulWidget {
  const InspectorHomeScreen({super.key});

  @override
  State<InspectorHomeScreen> createState() => _InspectorHomeScreenState();
}

class _InspectorHomeScreenState extends State<InspectorHomeScreen> {
  bool _isLoading = true;
  List<dynamic> _fpiTemplates = [];
  int _selectedOpIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadInspectorData();
  }

  Future<void> _loadInspectorData() async {
    try {
      final provider = Provider.of<InspectionProvider>(context, listen: false);
      final machineId = provider.selectedMachine?['id'] ?? 2;

      await provider.fetchPendingRejections();
      final parts = await ApiService.getPartsByMachine(machineId);

      List<dynamic> rawTemplates = [];
      if (provider.selectedPart != null && provider.selectedPart?['part_number'] != null) {
        rawTemplates = await ApiService.getTemplatesByPart(provider.selectedPart!['part_number']);
      } else if (parts.isNotEmpty) {
        provider.selectPart(parts.first);
        rawTemplates = await ApiService.getTemplatesByPart(parts.first['part_number']);
      } else {
        provider.selectPart({'part_number': 'FBT00222', 'part_name': 'POLY V PULLEY'});
        rawTemplates = await ApiService.getTemplatesByPart('FBT00222');
      }

      final fpiOnly = rawTemplates.where((t) {
        final type = (t['inspection_type'] ?? '').toString().toLowerCase();
        return type == 'first_piece' || type.contains('first') || type.contains('fpi');
      }).toList();

      final List<dynamic> sorted = List.from(fpiOnly.isNotEmpty ? fpiOnly : rawTemplates);
      sorted.sort((a, b) {
        final vA = int.tryParse(a['version']?.toString() ?? '0') ?? 0;
        final vB = int.tryParse(b['version']?.toString() ?? '0') ?? 0;
        return vA.compareTo(vB);
      });

      int opIdx = _selectedOpIndex;
      if (opIdx >= sorted.length) {
        opIdx = 0;
      }

      if (mounted) {
        setState(() {
          _fpiTemplates = sorted;
          _selectedOpIndex = opIdx;
          _isLoading = false;
        });
      }

      if (sorted.isNotEmpty) {
        final current = sorted[opIdx];
        provider.selectTemplate(current);
        await provider.loadParameters(current, isFirstPiece: true);
      }
    } catch (e) {
      debugPrint('Error loading inspector templates: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _selectOperation(int index) async {
    if (index < 0 || index >= _fpiTemplates.length) return;
    setState(() {
      _selectedOpIndex = index;
    });
    final target = _fpiTemplates[index];
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    provider.selectTemplate(target);
    await provider.loadParameters(target, isFirstPiece: true);
  }

  Future<void> _startFpiTrial(Map<String, dynamic> template, int trialNumber) async {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    provider.clearPendingValues();
    if (trialNumber == 1) {
      await provider.loadParameters(template, isFirstPiece: true);
    } else {
      await provider.loadParametersForRetrial(template, trial: trialNumber);
    }

    final started = await provider.startSession(trial: trialNumber, inspectionType: 'first_piece');
    if (started && mounted) {
      if (trialNumber > 1) {
        final count = provider.parameters.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🎯 Corrective Trial 1ST PC #$trialNumber: Re-measuring $count failed parameter(s).'),
            backgroundColor: const Color(0xFFF59E0B),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const InspectionVoiceScreen(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final provider = Provider.of<InspectionProvider>(context);

    final inspectorName = auth.fullName ?? auth.username ?? 'Samruddhi Bartakke';
    final initials = inspectorName.split(' ').map((e) => e.isNotEmpty ? e[0] : '').take(2).join('').toUpperCase();

    final machineCode = provider.selectedMachine?['machine_code'] ?? 'MCH-001';
    final machineName = provider.selectedMachine?['name'] ?? 'CNC Turning Center 1';
    final partNumber = provider.selectedPart?['part_number'] ?? 'FBT00222';
    final partName = provider.selectedPart?['part_name'] ?? 'POLY V PULLEY';
    final targetTemplate = _fpiTemplates.isNotEmpty
        ? _fpiTemplates[_selectedOpIndex.clamp(0, _fpiTemplates.length - 1)]
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_user_rounded, color: Color(0xFF38BDF8), size: 20),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                'Quality Inspector Terminal',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz_rounded, color: Color(0xFF38BDF8)),
            tooltip: 'Switch Machine',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MachineSelectScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Color(0xFFEF4444)),
            tooltip: 'Logout',
            onPressed: () async {
              await auth.logout();
              provider.logout();
              if (context.mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadInspectorData,
        color: const Color(0xFF38BDF8),
        backgroundColor: const Color(0xFF0F172A),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [

              // 1. INSPECTOR USER PROFILE BLOCK
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF0F172A),
                    const Color(0xFF1E293B).withValues(alpha: 0.7),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  )
                ],
              ),
              child: Row(
                children: [
                  // Profile Avatar
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.2),
                    child: Text(
                      initials.isNotEmpty ? initials : 'QI',
                      style: const TextStyle(
                        color: Color(0xFF38BDF8),
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              inspectorName,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                              ),
                              child: const Text('ACTIVE', style: TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('🛡️ QUALITY INSPECTOR', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 2. MACHINE & PART PROFILE BLOCK
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF1E293B)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  )
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
                        ),
                        child: const Icon(Icons.precision_manufacturing_rounded, color: Color(0xFF38BDF8), size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              machineName,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Station Code: $machineCode',
                              style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const MachineSelectScreen()),
                          );
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF38BDF8)),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          minimumSize: Size.zero,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('CHANGE', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Color(0xFF1E293B)),
                  const SizedBox(height: 8),

                  // Part Info Sub-block
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.inventory_2_rounded, color: Color(0xFF94A3B8), size: 16),
                          const SizedBox(width: 6),
                          Text('Part: $partName', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('PN: $partNumber', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Active Rejection Warning Block
            if (provider.activeRejections.isNotEmpty) ...[
              const SizedBox(height: 16),
              ...provider.activeRejections.map((rej) {
                final currentTrial = rej['trial_number'] ?? 1;
                final nextTrial = currentTrial + 1;
                final remark = rej['rejection_reason'] ?? rej['supervisor_remark'] ?? 'Targeted parameter correction requested.';
                final List<dynamic> rejectedParams = rej['rejected_parameters'] ?? [];

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFF59E0B), width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 24),
                          const SizedBox(width: 8),
                          Text(
                            'TARGETED RE-ENTRY REQUEST (1ST PC #$nextTrial)',
                            style: const TextStyle(color: Color(0xFFF59E0B), fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Supervisor Remark: "$remark"',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontStyle: FontStyle.italic),
                      ),
                      if (rejectedParams.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Targeted Parameters: ${rejectedParams.join(", ")}',
                          style: const TextStyle(color: Color(0xFFFDE68A), fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],

            const SizedBox(height: 22),

            if (_isLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(30.0),
                  child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
                ),
              )
            else ...[
              // 2. WORKSHOP OPERATION SELECTOR BAR
              if (_fpiTemplates.length > 1) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.tune_rounded, color: Color(0xFF38BDF8), size: 16),
                              SizedBox(width: 6),
                              Text(
                                'WORKSHOP OPERATION SELECTOR',
                                style: TextStyle(
                                  color: Color(0xFF38BDF8),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${_fpiTemplates.length} Operations',
                            style: const TextStyle(color: Color(0xFF64748B), fontSize: 10),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: List.generate(_fpiTemplates.length, (idx) {
                            final t = _fpiTemplates[idx];
                            final isSelected = idx == _selectedOpIndex;
                            final v = t['version']?.toString() ?? '${idx + 1}';
                            final name = t['name']?.toString() ?? 'Op $v';
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(
                                  'OP $v: $name',
                                  style: TextStyle(
                                    color: isSelected ? Colors.black : Colors.white70,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                                selected: isSelected,
                                selectedColor: const Color(0xFF38BDF8),
                                backgroundColor: const Color(0xFF1E293B),
                                side: BorderSide(
                                  color: isSelected ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                                ),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                onSelected: (_) => _selectOperation(idx),
                              ),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 3. DISPATCHED TEMPLATE BROADCAST CARD
              if (targetTemplate != null) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 20),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF10B981), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF10B981).withValues(alpha: 0.15),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.bolt_rounded, color: Color(0xFF10B981), size: 18),
                                ),
                                const SizedBox(width: 8),
                                const Flexible(
                                  child: Text(
                                    'ACTIVE DISPATCHED TEMPLATE',
                                    style: TextStyle(
                                      color: Color(0xFF10B981),
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12,
                                      letterSpacing: 0.5,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.5)),
                            ),
                            child: const Text('READY FOR FPI', style: TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        targetTemplate['name']?.toString().isNotEmpty == true
                            ? targetTemplate['name'].toString()
                            : '1st Side Finish Turning',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Part: $partNumber ($partName) · Target: ${targetTemplate['target_parameter_count'] ?? 18} Params',
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ParameterListScreen(template: targetTemplate),
                                  ),
                                );
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF38BDF8),
                                side: const BorderSide(color: Color(0xFF38BDF8)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.grid_view_rounded, size: 16),
                              label: const Text('3-COL GRID (P1-P18)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _startFpiTrial(targetTemplate, 1),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0284C7),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.mic_rounded, size: 16),
                              label: const Text('START FPI ENTRY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => ReportSheetScreen(template: targetTemplate)),
                                );
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF10B981),
                                side: const BorderSide(color: Color(0xFF10B981)),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.table_chart_rounded, size: 14),
                              label: const Text('F02 LIVE REPORT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const SetupApprovalReportScreen()),
                                );
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF818CF8),
                                side: const BorderSide(color: Color(0xFF818CF8)),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.assignment_turned_in_rounded, size: 14),
                              label: const Text('SET UP REPORT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],

              // 3. FIRST PIECE TRIALS LAUNCH PAD (1PC#1 · 1PC#2 · 1PC#3)
              _buildFpiTrialPad(targetTemplate),
              const SizedBox(height: 20),

              // 4. SETUP APPROVAL ENTRY CARD
              // Process Parameters are ONLY accessed here — not in the FPI flow.
              _buildSetupApprovalCard(targetTemplate),
              const SizedBox(height: 20),

              // 5. First Piece Inspection Matrix Table (real data)
              _buildFirstPieceTableMatrix(targetTemplate),
              const SizedBox(height: 24),

              // 6. REPORTS SECTION (PART 5 — TWO DISTINCT REPORT TYPES)
              _buildReportsSection(context, targetTemplate),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    ),
  );
}

  Widget _buildFpiTrialPad(Map<String, dynamic>? targetTemplate) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(
              child: Text(
                'FIRST PIECE INSPECTION TRIALS',
                style: TextStyle(
                  color: Color(0xFF38BDF8),
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.4)),
              ),
              child: const Text(
                'INSPECTOR EXCLUSIVE',
                style: TextStyle(color: Color(0xFF38BDF8), fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            // 1ST PC #1
            Expanded(
              child: _buildTrialActionCard(
                trialNumber: 1,
                title: '1ST PC #1',
                subtitle: 'Initial Setup',
                color: const Color(0xFF38BDF8),
                icon: Icons.play_circle_filled_rounded,
                targetTemplate: targetTemplate,
              ),
            ),
            const SizedBox(width: 8),
            // 1ST PC #2
            Expanded(
              child: _buildTrialActionCard(
                trialNumber: 2,
                title: '1ST PC #2',
                subtitle: 'Corrective',
                color: const Color(0xFFF59E0B),
                icon: Icons.build_circle_rounded,
                targetTemplate: targetTemplate,
              ),
            ),
            const SizedBox(width: 8),
            // 1ST PC #3
            Expanded(
              child: _buildTrialActionCard(
                trialNumber: 3,
                title: '1ST PC #3',
                subtitle: 'Final Check',
                color: const Color(0xFF10B981),
                icon: Icons.verified_rounded,
                targetTemplate: targetTemplate,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTrialActionCard({
    required int trialNumber,
    required String title,
    required String subtitle,
    required Color color,
    required IconData icon,
    required Map<String, dynamic>? targetTemplate,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 6),
          Text(
            title,
            style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 13),
          ),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => targetTemplate != null
                  ? _startFpiTrial(targetTemplate, trialNumber)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                foregroundColor: (color == const Color(0xFFF59E0B) || color == const Color(0xFF38BDF8))
                    ? Colors.black
                    : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 6),
                minimumSize: Size.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                'START #$trialNumber',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupApprovalCard(Map<String, dynamic>? targetTemplate) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF312E81).withValues(alpha: 0.6),
            const Color(0xFF1E1B4B).withValues(alpha: 0.8),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF818CF8), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF818CF8).withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF818CF8).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF818CF8).withValues(alpha: 0.5)),
            ),
            child: const Icon(Icons.settings_suggest_rounded, color: Color(0xFF818CF8), size: 28),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SET UP APPROVAL',
                  style: TextStyle(
                    color: Color(0xFF818CF8),
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    letterSpacing: 0.5,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Section 1: Product Params · Section 2: Process Params\n1PC#1 · 1PC#2 · 1PC#3 (NO hourly slots)',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SetupApprovalScreen(template: targetTemplate)),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF818CF8),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('OPEN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildFirstPieceTableMatrix(Map<String, dynamic>? targetTemplate) {
    final provider = Provider.of<InspectionProvider>(context);
    final results = provider.recordedResults;
    final parameters = provider.parameters;

    // Group measurements by trial number from provider
    // Each result key is parameter_code; val has trial_number, measured_value, status
    Map<String, Map<String, dynamic>> byCode = {};
    results.forEach((code, val) {
      byCode.putIfAbsent(code, () => {});
      final trial = (val['trial_number'] ?? 1).toString();
      byCode[code]![trial] = val;
    });

    // Build rows — use parameters if available, else fall back to byCode keys
    final paramList = parameters.isNotEmpty
        ? parameters
        : byCode.keys.map((code) => {'parameter_code': code, 'parameter_name': code}).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'FIRST PIECE INSPECTION MATRIX (F02)',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Comparative readings for 1ST PC #1, #2, #3 trials',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () => targetTemplate != null
                  ? Navigator.push(context, MaterialPageRoute(builder: (_) => ReportSheetScreen(template: targetTemplate)))
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF38BDF8),
                foregroundColor: const Color(0xFF0F172A),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.table_chart_rounded, size: 15),
              label: const Text('FULL REPORT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
            ),
          ],
        ),
        const SizedBox(height: 14),

        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1E293B)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 4))
            ],
          ),
          child: paramList.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.assignment_outlined, color: Color(0xFF475569), size: 36),
                        SizedBox(height: 8),
                        Text(
                          'No inspection data yet.\nComplete a First PC trial to see results here.',
                          style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowColor: WidgetStateProperty.all(const Color(0xFF1E293B)),
                      dataRowMinHeight: 48,
                      dataRowMaxHeight: 56,
                      horizontalMargin: 16,
                      columnSpacing: 18,
                      columns: const [
                        DataColumn(label: Text('PARAMETER', style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 11))),
                        DataColumn(label: Text('1ST PC #1', style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 11))),
                        DataColumn(label: Text('1ST PC #2', style: TextStyle(color: Color(0xFFF59E0B), fontWeight: FontWeight.bold, fontSize: 11))),
                        DataColumn(label: Text('1ST PC #3', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 11))),
                      ],
                      rows: paramList.map((param) {
                        final code = param['parameter_code']?.toString() ?? '';
                        final name = param['parameter_name']?.toString() ?? '';
                        final t1Data = byCode[code]?['1'];
                        final t2Data = byCode[code]?['2'];
                        final t3Data = byCode[code]?['3'];

                        return DataRow(
                          cells: [
                            DataCell(
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(code, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                                  Text(name, style: const TextStyle(color: Color(0xFF64748B), fontSize: 10)),
                                ],
                              ),
                            ),
                            DataCell(_matrixCell(t1Data)),
                            DataCell(_matrixCell(t2Data)),
                            DataCell(_matrixCell(t3Data)),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _matrixCell(Map<String, dynamic>? data) {
    if (data == null) return const Text('\u2014', style: TextStyle(color: Color(0xFF475569), fontSize: 12));
    final value = data['measured_value']?.toString() ?? '\u2014';
    final isOk = (data['status']?.toString() ?? 'ok') == 'ok';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: isOk ? Colors.white : const Color(0xFFEF4444),
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        const SizedBox(width: 4),
        Icon(
          isOk ? Icons.check_circle_rounded : Icons.cancel_rounded,
          color: isOk ? const Color(0xFF10B981) : const Color(0xFFEF4444),
          size: 14,
        ),
      ],
    );
  }

  /// PART 5 — INSPECTOR APP REPORTS SECTION
  /// Displays exactly TWO distinct report options:
  ///   1. First PC Inspection & In-process Reports
  ///   2. Set Up Approval Reports
  Widget _buildReportsSection(BuildContext context, Map<String, dynamic>? targetTemplate) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'REPORTS',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 14,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 12),

        // 1) First PC Inspection & In-process Reports
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ReportSheetScreen(template: targetTemplate)),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0284C7), Color(0xFF0369A1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                  blurRadius: 10,
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
                  child: const Icon(Icons.table_chart_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'First PC Inspection & In-process Reports',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'View Product + In-process inspection',
                        style: TextStyle(color: Color(0xFFBAE6FD), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white, size: 16),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // 2) Set Up Approval Reports
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SetupApprovalReportScreen()),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(16),
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
                  color: const Color(0xFF4338CA).withValues(alpha: 0.25),
                  blurRadius: 10,
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
                  child: const Icon(Icons.assignment_turned_in_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Set Up Approval Reports',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'View Setup Approval inspection',
                        style: TextStyle(color: Color(0xFFC7D2FE), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white, size: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

