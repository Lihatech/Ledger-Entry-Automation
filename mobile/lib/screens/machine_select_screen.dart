import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/inspection_provider.dart';
import '../services/api_service.dart';
import 'app_home_screen.dart';
import 'part_select_screen.dart';

class MachineSelectScreen extends StatefulWidget {
  const MachineSelectScreen({super.key});

  @override
  State<MachineSelectScreen> createState() => _MachineSelectScreenState();
}

class _MachineSelectScreenState extends State<MachineSelectScreen> {
  bool _isSelecting = false;
  bool _isLoading = true;
  String? _selectError;
  String _searchQuery = '';

  List<dynamic> _machines = [];

  final List<Map<String, dynamic>> _fallbackMachines = [];

  @override
  void initState() {
    super.initState();
    _loadMachines();
  }

  Future<void> _loadMachines() async {
    try {
      // Selection must reflect the current master database, not a cached/demo list.
      final loaded = await ApiService.getMachinesStrict();
      if (mounted) {
        setState(() {
          _machines = loaded.isNotEmpty ? loaded : _fallbackMachines;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _machines = _fallbackMachines;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _selectMachine(Map<String, dynamic> machineObj) async {
    setState(() {
      _isSelecting = true;
      _selectError = null;
    });

    final code = machineObj['machine_code']?.toString() ?? '';
    final fetched = await ApiService.getMachineByCode(code.trim());
    final finalMachine = fetched ?? machineObj;

    setState(() {
      _isSelecting = false;
    });

    if (mounted) {
      final provider = Provider.of<InspectionProvider>(context, listen: false);
      provider.selectMachine(finalMachine);

      Widget nextScreen = const PartSelectScreen();

      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => nextScreen),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredMachines = _machines.where((m) {
      final code = (m['machine_code'] ?? '').toString().toLowerCase();
      final name = (m['name'] ?? '').toString().toLowerCase();
      final q = _searchQuery.toLowerCase();
      return code.contains(q) || name.contains(q);
    }).toList();

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
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFDBEAFE)),
              ),
              child: const Icon(Icons.precision_manufacturing_rounded, color: Color(0xFF2563EB), size: 20),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select Machine',
                  style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 17),
                ),
                Text(
                  'Shop Floor Stations',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: [
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
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF2563EB)),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadMachines();
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
              // Search Input Bar - Enterprise Clean Style
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFCBD5E1)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x060F172A),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    )
                  ],
                ),
                child: TextField(
                  style: const TextStyle(color: Color(0xFF0F172A), fontSize: 14, fontWeight: FontWeight.w500),
                  onChanged: (val) => setState(() => _searchQuery = val),
                  decoration: const InputDecoration(
                    hintText: 'Search machine by code or name...',
                    hintStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                    prefixIcon: Icon(Icons.search_rounded, color: Color(0xFF2563EB)),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Header Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.sensors_rounded, color: Color(0xFF059669), size: 16),
                      SizedBox(width: 6),
                      Text(
                        'ACTIVE MACHINES ON FLOOR',
                        style: TextStyle(color: Color(0xFF475569), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.0),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFA7F3D0)),
                    ),
                    child: Text(
                      '${filteredMachines.length} Ready',
                      style: const TextStyle(color: Color(0xFF059669), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              if (_selectError != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFCA5A5)),
                  ),
                  child: Text(_selectError!, style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
                ),
              ],

              if (_isLoading)
                const Expanded(
                  child: Center(
                    child: CircularProgressIndicator(color: Color(0xFF2563EB)),
                  ),
                )
              else if (filteredMachines.isEmpty)
                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off_rounded, color: Color(0xFF94A3B8), size: 48),
                        SizedBox(height: 12),
                        Text('No matching machines found', style: TextStyle(color: Color(0xFF64748B), fontSize: 15, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: filteredMachines.length,
                    itemBuilder: (context, index) {
                      final machine = filteredMachines[index];
                      final code = machine['machine_code'] ?? 'M-${machine['id']}';
                      final name = machine['name'] ?? 'Machine $code';
                      final mType = machine['machine_type'] ?? machine['type'] ?? 'CNC';

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x0A0F172A),
                              blurRadius: 10,
                              offset: Offset(0, 3),
                            )
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _selectMachine(machine),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  // Icon Badge - Clean Blue Tint
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEFF6FF),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: const Color(0xFFDBEAFE)),
                                    ),
                                    child: const Icon(Icons.build_circle_rounded, color: Color(0xFF2563EB), size: 26),
                                  ),
                                  const SizedBox(width: 14),

                                  // Details
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFF1F5F9),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: const Color(0xFFE2E8F0)),
                                              ),
                                              child: Text(
                                                code,
                                                style: const TextStyle(
                                                  color: Color(0xFF1E293B),
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            const Icon(Icons.fiber_manual_record, color: Color(0xFF059669), size: 8),
                                            const SizedBox(width: 4),
                                            const Text('ONLINE', style: TextStyle(color: Color(0xFF059669), fontSize: 10, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          name,
                                          style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 15),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Process: $mType',
                                          style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Action Arrow Button
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF8FAFC),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: const Color(0xFFE2E8F0)),
                                    ),
                                    child: _isSelecting
                                        ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(color: Color(0xFF2563EB), strokeWidth: 2))
                                        : const Icon(Icons.arrow_forward_rounded, color: Color(0xFF2563EB), size: 18),
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
