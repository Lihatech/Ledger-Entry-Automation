import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/inspection_provider.dart';
import '../services/api_service.dart';
import 'app_home_screen.dart';
import 'operation_select_screen.dart';

class PartSelectScreen extends StatefulWidget {
  const PartSelectScreen({super.key});

  @override
  State<PartSelectScreen> createState() => _PartSelectScreenState();
}

class _PartSelectScreenState extends State<PartSelectScreen> {
  bool _isLoading = true;
  List<dynamic> _parts = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadParts();
  }

  Future<void> _loadParts() async {
    try {
      final provider = Provider.of<InspectionProvider>(context, listen: false);
      final machineId = provider.selectedMachine?['id'];

      if (machineId != null) {
        final loaded = await ApiService.getPartsByMachine(machineId);
        if (mounted) {
          setState(() {
            _parts = loaded;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _parts = [];
            _error = 'Select a machine before loading its master-data parts.';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load parts for selected machine.';
          _isLoading = false;
        });
      }
    }
  }

  void _selectPart(Map<String, dynamic> partObj) {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    provider.selectPart(partObj);

    // FLOW STEP 3 ➔ STEP 4: Navigate to OPERATION Screen
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OperationSelectScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final selectedMachine = provider.selectedMachine;
    final machineCode = selectedMachine?['machine_code']?.toString() ?? '—';
    final machineName =
        selectedMachine?['name']?.toString() ?? 'Selected machine';

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF0F172A)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Step 2 of 5: Select Part',
              style: TextStyle(
                color: Color(0xFF4F46E5),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Machine: $machineCode',
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 16,
                fontWeight: FontWeight.bold,
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
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Flow Breadcrumb Header
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFC7D2FE)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.account_tree_rounded,
                      color: Color(0xFF4F46E5),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'FLOW: Home ➔ $machineCode ➔ Part ➔ Operation ➔ Parameter ➔ Data Entry',
                        style: const TextStyle(
                          color: Color(0xFF3730A3),
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              Text(
                'Parts Manufactured on $machineName',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF64748B),
                ),
              ),

              const SizedBox(height: 14),

              if (_isLoading)
                const Expanded(
                  child: Center(
                    child: CircularProgressIndicator(color: Color(0xFF4F46E5)),
                  ),
                )
              else if (_error != null || _parts.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      _error ??
                          'No parts are configured for this machine in the master database.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: _parts.length,
                    itemBuilder: (context, index) {
                      final p = _parts[index];
                      final partNo = p['part_number']?.toString() ?? '—';
                      final partName =
                          p['part_name']?.toString() ?? 'Unnamed part';
                      final dwg = p['drawing_number']?.toString() ?? '—';

                      return Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => _selectPart(p),
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEEF2FF),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(
                                      Icons.inventory_2_rounded,
                                      color: Color(0xFF4F46E5),
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(
                                              0xFF4F46E5,
                                            ).withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Text(
                                            partNo,
                                            style: const TextStyle(
                                              color: Color(0xFF4F46E5),
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          partName,
                                          style: const TextStyle(
                                            color: Color(0xFF0F172A),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Drawing No: $dwg',
                                          style: const TextStyle(
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
                                    size: 18,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
