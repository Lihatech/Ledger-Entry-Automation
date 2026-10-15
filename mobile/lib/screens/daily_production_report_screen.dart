import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/inspection_provider.dart';
import '../services/api_service.dart';

class DailyProductionReportScreen extends StatefulWidget {
  const DailyProductionReportScreen({super.key});

  @override
  State<DailyProductionReportScreen> createState() => _DailyProductionReportScreenState();
}

class _DailyProductionReportScreenState extends State<DailyProductionReportScreen> {
  final _formKey = GlobalKey<FormState>();

  final _targetController = TextEditingController(text: '42');
  final _completedController = TextEditingController(text: '0');
  final _correctController = TextEditingController(text: '0');
  final _incorrectController = TextEditingController(text: '0');
  final _crController = TextEditingController(text: '0');
  final _mrController = TextEditingController(text: '0');
  final _rwController = TextEditingController(text: '0');
  final _remarksController = TextEditingController();
  // Persisted until the submission succeeds so an app restart still retries
  // the same report instead of creating a duplicate.
  String? _submissionKey;

  bool _isSubmitting = false;
  bool _isLoadingContext = true;
  String? _validationError;

  // Station Context (Machine, Part, Operation)
  Map<String, dynamic>? _selectedMachine;
  Map<String, dynamic>? _selectedPart;
  Map<String, dynamic>? _selectedTemplate;
  String? _selectedCompany;
  List<dynamic> _allMachines = [];

  double _currentCycleTime = 10.0;
  int _currentAvailableTime = 420;

  @override
  void initState() {
    super.initState();
    _loadSubmissionKey();
    _initializeStationContext();
    _targetController.addListener(_validateInputs);
    _completedController.addListener(_validateInputs);
    _correctController.addListener(_validateInputs);
    _incorrectController.addListener(_validateInputs);
    _crController.addListener(_validateInputs);
    _mrController.addListener(_validateInputs);
    _rwController.addListener(_validateInputs);
  }

  Future<void> _loadSubmissionKey() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _submissionKey = prefs.getString('pending_daily_report_key') ??
          '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';
    });
    await prefs.setString('pending_daily_report_key', _submissionKey!);
  }

  @override
  void dispose() {
    _targetController.dispose();
    _completedController.dispose();
    _correctController.dispose();
    _incorrectController.dispose();
    _crController.dispose();
    _mrController.dispose();
    _rwController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  /// 1. Initialize and auto-detect current workstation context from active session or defaults
  Future<void> _initializeStationContext() async {
    setState(() => _isLoadingContext = true);
    final provider = Provider.of<InspectionProvider>(context, listen: false);

    try {
      final machines = await ApiService.getMachines();
      _allMachines = machines;

      // 1. Resolve Active Machine
      Map<String, dynamic>? activeMachine = provider.selectedMachine;
      if (activeMachine == null && machines.isNotEmpty) {
        activeMachine = machines.firstWhere(
          (m) => m['machine_code']?.toString().toUpperCase() == 'CNC-01',
          orElse: () => machines.first,
        );
      }
      _selectedMachine = activeMachine;

      // 2. Resolve Active Part for this machine
      if (_selectedMachine != null && _selectedMachine!['id'] != null) {
        final mId = _selectedMachine!['id'] as int;
        final parts = await ApiService.getPartsByMachine(mId);

        Map<String, dynamic>? activePart = provider.selectedPart;
        if (activePart == null || !parts.any((p) => p['id'] == activePart!['id'])) {
          if (parts.isNotEmpty) {
            activePart = parts.firstWhere(
              (p) => p['part_name']?.toString().toLowerCase().contains('brake drum') ?? false,
              orElse: () => parts.first,
            );
          }
        }
        _selectedPart = activePart;

        // 3. Resolve Active Template (Operation) for this part
        if (_selectedPart != null && _selectedPart!['part_number'] != null) {
          final pNum = _selectedPart!['part_number'].toString();
          final templates = await ApiService.getTemplatesByPart(pNum);

          Map<String, dynamic>? activeTemplate = provider.selectedTemplate;
          if (activeTemplate == null || !templates.any((t) => t['id'] == activeTemplate!['id'])) {
            if (templates.isNotEmpty) {
              activeTemplate = templates.first;
            }
          }
          _selectedTemplate = activeTemplate;
        }
      }

      // Sync back to Provider so rest of the app is consistent
      if (_selectedMachine != null) provider.selectedMachine = _selectedMachine;
      if (_selectedPart != null) provider.selectedPart = _selectedPart;
      if (_selectedTemplate != null) provider.selectedTemplate = _selectedTemplate;
    } catch (e) {
      debugPrint('[DailyProduction] Error initializing station: $e');
    } finally {
      _calculateTarget();
      if (mounted) {
        setState(() => _isLoadingContext = false);
      }
    }
  }

  /// 2. Auto-calculate target = (Available Time / Cycle Time)
  void _calculateTarget() {
    final shiftHours = (_selectedMachine?['shift_duration_hours'] as num?)?.toInt() ?? 8;
    final breakMins = (_selectedMachine?['total_break_mins'] as num?)?.toInt() ?? 60;
    _currentAvailableTime = (shiftHours * 60) - breakMins;

    double cycleTime = (_selectedTemplate?['cycle_time_mins'] as num?)?.toDouble() ?? 0.0;
    if (cycleTime <= 0) {
      cycleTime = 10.0; // standard fallback
    }
    _currentCycleTime = cycleTime;

    final target = (_currentAvailableTime / cycleTime).toInt();
    _targetController.text = target.toString();
    if (mounted) {
      setState(() {});
    }
  }

  /// 3. Change Station Modal with Cascading Dropdowns
  Future<void> _showChangeStationModal() async {
    Map<String, dynamic>? tempMachine = _selectedMachine;
    Map<String, dynamic>? tempPart = _selectedPart;
    Map<String, dynamic>? tempTemplate = _selectedTemplate;
    String? tempCompany = _selectedCompany;

    List<dynamic> modalParts = [];
    List<dynamic> modalTemplates = [];
    List<dynamic> modalReceipts;
    try {
      modalReceipts = await ApiService.getInventoryReceipts();
    } on InventoryReceiptFetchException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
      return;
    }
    bool isFetchingParts = false;
    bool isFetchingTemplates = false;

    // Pre-load parts for current machine
    if (tempMachine != null && tempMachine['id'] != null) {
      isFetchingParts = true;
      modalParts = await ApiService.getPartsByMachine(tempMachine['id'] as int);
      isFetchingParts = false;
    }

    // Pre-load templates for current part
    if (tempPart != null && tempPart['part_number'] != null) {
      isFetchingTemplates = true;
      modalTemplates = await ApiService.getTemplatesByPart(tempPart['part_number'].toString());
      isFetchingTemplates = false;
    }

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final eligibleReceipts = tempMachine == null
              ? <dynamic>[]
              : modalReceipts.where((receipt) {
                  final remaining = ((receipt['received_quantity'] as num?)?.toInt() ?? 0) -
                      ((receipt['dispatched_quantity'] as num?)?.toInt() ?? 0);
                  if (remaining <= 0) return false;
                  final steps = receipt['machine_sequence_steps'];
                  if (steps is! List || steps.isEmpty) return true;
                  return steps.any((step) => step is Map && '${step['machine_id']}' == '${tempMachine!['id']}');
                }).toList();
          final companies = eligibleReceipts
              .map((receipt) => (receipt['company_name'] ?? '').toString().trim())
              .where((company) => company.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
          final activeCompany = companies.contains(tempCompany) ? tempCompany : null;
          final companyParts = activeCompany == null
              ? <dynamic>[]
              : modalParts.where((part) {
                  final partName = (part['part_name'] ?? '').toString().trim().toLowerCase();
                  return eligibleReceipts.any((receipt) =>
                      (receipt['company_name'] ?? '').toString().trim() == activeCompany &&
                      (receipt['part_name'] ?? '').toString().trim().toLowerCase() == partName);
                }).toList();
          double modalCycleTime = (tempTemplate?['cycle_time_mins'] as num?)?.toDouble() ?? 10.0;
          if (modalCycleTime <= 0) modalCycleTime = 10.0;
          final modalTarget = (_currentAvailableTime / modalCycleTime).toInt();

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            padding: EdgeInsets.only(
              top: 20,
              left: 20,
              right: 20,
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Change Station & Operation',
                        style: TextStyle(color: Color(0xFF0F172A), fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Color(0xFF64748B)),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Text(
                    'Select machine, part, and operation for this shift.',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                  ),
                  const SizedBox(height: 18),

                  // 1. Machine Dropdown
                  const Text('Machine', style: TextStyle(color: Color(0xFF334155), fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<int>(
                    key: ValueKey('machine_${tempMachine?['id']}'),
                    initialValue: tempMachine?['id'] as int?,
                    dropdownColor: Colors.white,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF2563EB)),
                    isExpanded: true,
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2)),
                    ),
                    items: _allMachines.map<DropdownMenuItem<int>>((m) {
                      final code = m['machine_code'] ?? 'Machine';
                      final name = m['name'] ?? '';
                      return DropdownMenuItem<int>(
                        value: m['id'] as int,
                        child: Text('$code — $name', style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A), fontWeight: FontWeight.w500)),
                      );
                    }).toList(),
                    onChanged: (newMachineId) async {
                      if (newMachineId == null) return;
                      final selected = _allMachines.firstWhere((m) => m['id'] == newMachineId);
                      setModalState(() {
                        tempMachine = selected;
                        tempCompany = null;
                        tempPart = null;
                        tempTemplate = null;
                        isFetchingParts = true;
                        modalParts = [];
                        modalTemplates = [];
                      });

                      final fetchedParts = await ApiService.getPartsByMachine(newMachineId);
                      setModalState(() {
                        modalParts = fetchedParts;
                        isFetchingParts = false;
                        if (fetchedParts.isNotEmpty) {
                          tempPart = fetchedParts.first;
                        }
                      });

                      if (tempPart != null && tempPart!['part_number'] != null) {
                        setModalState(() => isFetchingTemplates = true);
                        final fetchedTemplates = await ApiService.getTemplatesByPart(tempPart!['part_number'].toString());
                        setModalState(() {
                          modalTemplates = fetchedTemplates;
                          isFetchingTemplates = false;
                          if (fetchedTemplates.isNotEmpty) {
                            tempTemplate = fetchedTemplates.first;
                          }
                        });
                      }
                    },
                  ),

                  const SizedBox(height: 14),

                  // 2. Company Dropdown — sourced only from active inventory.
                  const Text('Company', style: TextStyle(color: Color(0xFF334155), fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    key: ValueKey('company_$tempCompany'),
                    initialValue: activeCompany,
                    dropdownColor: Colors.white,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF2563EB)),
                    isExpanded: true,
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      filled: true, fillColor: Colors.white,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                    ),
                    hint: Text(tempMachine == null ? 'Select machine first' : companies.isEmpty ? 'No inventory available for this machine' : 'Select company', style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),),
                    items: companies.map<DropdownMenuItem<String>>((company) {
                      return DropdownMenuItem<String>(value: company, child: Text(company, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A), fontWeight: FontWeight.w500)));
                    }).toList(),
                    onChanged: (company) {
                      if (company == null) return;
                      setModalState(() {
                        tempCompany = company;
                        tempPart = null;
                        tempTemplate = null;
                        modalTemplates = [];
                      });
                    },
                  ),

                  const SizedBox(height: 14),

                  // 3. Part Dropdown (Filtered by Company and Machine)
                  const Text('Part (Filtered to Company & Machine)', style: TextStyle(color: Color(0xFF334155), fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  if (isFetchingParts)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                    )
                  else
                    DropdownButtonFormField<int>(
                      key: ValueKey('part_${tempPart?['id']}'),
                      initialValue: tempPart?['id'] as int?,
                      dropdownColor: Colors.white,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF2563EB)),
                      isExpanded: true,
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2)),
                      ),
                      hint: Text(tempCompany == null ? 'Select company first' : companyParts.isEmpty ? 'No inventory part available' : 'Select part', style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
                      items: companyParts.map<DropdownMenuItem<int>>((p) {
                        final pName = p['part_name'] ?? 'Part';
                        final pNum = p['part_number'] ?? '';
                        return DropdownMenuItem<int>(
                          value: p['id'] as int,
                          child: Text('$pName ($pNum)', style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A), fontWeight: FontWeight.w500)),
                        );
                      }).toList(),
                      onChanged: (newPartId) async {
                        if (newPartId == null) return;
                        final selected = companyParts.firstWhere((p) => p['id'] == newPartId);
                        setModalState(() {
                          tempPart = selected;
                          tempTemplate = null;
                          isFetchingTemplates = true;
                          modalTemplates = [];
                        });

                        final fetchedTemplates = await ApiService.getTemplatesByPart(selected['part_number'].toString());
                        setModalState(() {
                          modalTemplates = fetchedTemplates;
                          isFetchingTemplates = false;
                          if (fetchedTemplates.isNotEmpty) {
                            tempTemplate = fetchedTemplates.first;
                          }
                        });
                      },
                    ),

                  const SizedBox(height: 14),

                  // 4. Operation Dropdown (Filtered by Part)
                  const Text('Operation / Template', style: TextStyle(color: Color(0xFF334155), fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  if (isFetchingTemplates)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                    )
                  else
                    DropdownButtonFormField<int>(
                      key: ValueKey('template_${tempTemplate?['id']}'),
                      initialValue: tempTemplate?['id'] as int?,
                      dropdownColor: Colors.white,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A)),
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF2563EB)),
                      isExpanded: true,
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2)),
                      ),
                      hint: Text(modalTemplates.isEmpty ? 'No operations configured' : 'Select Operation', style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
                      items: modalTemplates.map<DropdownMenuItem<int>>((t) {
                        final opName = (t['name'] != null && t['name'].toString().trim().isNotEmpty)
                            ? t['name'].toString()
                            : (t['part_operation_name'] ?? 'Operation ${t['version'] ?? ''}');
                        final ct = (t['cycle_time_mins'] as num?)?.toDouble() ?? 10.0;
                        final ctDisplay = ct % 1 == 0 ? '${ct.toInt()} min' : '${ct.toStringAsFixed(1)} min';
                        return DropdownMenuItem<int>(
                          value: t['id'] as int,
                          child: Text('$opName ($ctDisplay)', style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A), fontWeight: FontWeight.w500)),
                        );
                      }).toList(),
                      onChanged: (newTemplateId) {
                        if (newTemplateId == null) return;
                        final selected = modalTemplates.firstWhere((t) => t['id'] == newTemplateId);
                        setModalState(() {
                          tempTemplate = selected;
                        });
                      },
                    ),

                  const SizedBox(height: 16),

                  // Dynamic Target Preview Box
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Shift Production Target', style: TextStyle(fontSize: 11, color: Color(0xFF475569), fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text('420 min shift / ${modalCycleTime % 1 == 0 ? modalCycleTime.toInt() : modalCycleTime.toStringAsFixed(1)} min cycle', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                          ],
                        ),
                        Text(
                          '$modalTarget pcs',
                          style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Apply Button
                  ElevatedButton(
                    onPressed: (tempMachine != null && activeCompany != null && tempPart != null && tempTemplate != null)
                        ? () {
                            setState(() {
                              _selectedMachine = tempMachine;
                              _selectedPart = tempPart;
                              _selectedTemplate = tempTemplate;
                              _selectedCompany = activeCompany;

                              final provider = Provider.of<InspectionProvider>(context, listen: false);
                              provider.selectedMachine = tempMachine;
                              provider.selectedPart = tempPart;
                              provider.selectedTemplate = tempTemplate;
                            });
                            _calculateTarget();
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Station updated: ${_selectedMachine?['machine_code']} | ${_selectedPart?['part_name']}'),
                                backgroundColor: const Color(0xFF059669),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Apply Station & Update Target', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _validateInputs() {
    final completedStr = _completedController.text.trim();
    final correctStr = _correctController.text.trim();
    final incorrectStr = _incorrectController.text.trim();

    final completed = int.tryParse(completedStr) ?? 0;
    final correct = int.tryParse(correctStr) ?? 0;
    final incorrect = int.tryParse(incorrectStr) ?? 0;
    final cr = int.tryParse(_crController.text.trim()) ?? 0;
    final mr = int.tryParse(_mrController.text.trim()) ?? 0;
    final rw = int.tryParse(_rwController.text.trim()) ?? 0;

    String? err;
    if (completed != (correct + incorrect)) {
      err = 'Validation Error: Jobs Completed ($completed) must equal Correct Jobs ($correct) + Incorrect Jobs ($incorrect).';
    } else if (incorrect != (cr + mr + rw)) {
      err = 'Validation Error: Incorrect Jobs ($incorrect) must equal CR ($cr) + MR ($mr) + RW ($rw).';
    }

    setState(() {
      _validationError = err;
    });
  }

  double get _achievementPercentage {
    final target = double.tryParse(_targetController.text.trim()) ?? 0;
    final completed = double.tryParse(_completedController.text.trim()) ?? 0;
    if (target > 0) {
      return (completed / target) * 100;
    }
    return 0.0;
  }

  Future<void> _submitReport() async {
    if (_submissionKey == null) await _loadSubmissionKey();
    _validateInputs();
    if (_validationError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_validationError!),
          backgroundColor: const Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final machineId = _selectedMachine?['id'];
    final partId = _selectedPart?['id'];

    if (machineId == null || partId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a valid Machine and Part before submitting.'),
          backgroundColor: Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);

    final now = DateTime.now();
    final dateStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

    final operation = (_selectedTemplate?['name'] != null && _selectedTemplate!['name'].toString().trim().isNotEmpty)
        ? _selectedTemplate!['name'].toString().trim()
        : (_selectedTemplate?['part_operation_name'] ?? 'Facing, Bore, I.D., O.D.');
    final shift = auth.isShiftLocked ? auth.assignedShift : provider.shift;

    final payload = {
      'idempotency_key': _submissionKey,
      'date': dateStr,
      'machine': machineId,
      'part': partId,
      'operation': operation,
      if (_selectedCompany != null) 'inventory_company_name': _selectedCompany,
      'shift': shift,
      'production_target': int.tryParse(_targetController.text.trim()) ?? 0,
      'jobs_completed': int.tryParse(_completedController.text.trim()) ?? 0,
      'correct_jobs': int.tryParse(_correctController.text.trim()) ?? 0,
      'incorrect_jobs': int.tryParse(_incorrectController.text.trim()) ?? 0,
      'cr_count': int.tryParse(_crController.text.trim()) ?? 0,
      'mr_count': int.tryParse(_mrController.text.trim()) ?? 0,
      'rw_count': int.tryParse(_rwController.text.trim()) ?? 0,
      'remarks': _remarksController.text.trim(),
    };

    final res = await ApiService.submitDailyProductionReport(payload);

    setState(() => _isSubmitting = false);

    if (mounted) {
      if (res['success'] == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pending_daily_report_key');
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Color(0xFF059669), size: 28),
                SizedBox(width: 10),
                Text('Report Submitted', style: TextStyle(color: Color(0xFF0F172A), fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(
              'Daily Production Report saved successfully!\nAchievement Rating: ${_achievementPercentage.toStringAsFixed(1)}%',
              style: const TextStyle(color: Color(0xFF334155), fontSize: 13),
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF059669),
                  foregroundColor: Colors.white,
                ),
                child: const Text('OK'),
              )
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit: ${res['message']}'),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context);
    final auth = Provider.of<AuthProvider>(context);

    final now = DateTime.now();
    final dateDisplay = "${now.day.toString().padLeft(2, '0')}-${_monthAbbr(now.month)}-${now.year}";
    final machineCode = _selectedMachine?['machine_code'] ?? provider.selectedMachine?['machine_code'] ?? 'CNC-01';
    final partName = _selectedPart?['part_name'] ?? provider.selectedPart?['part_name'] ?? 'Brake Drum Rear';
    final operation = (_selectedTemplate?['name'] != null && _selectedTemplate!['name'].toString().trim().isNotEmpty)
        ? _selectedTemplate!['name'].toString().trim()
        : (_selectedTemplate?['part_operation_name'] ?? 'Facing, Bore, I.D., O.D.');
    final shift = auth.isShiftLocked ? auth.assignedShift : provider.shift;
    final operatorName = auth.fullName ?? auth.username ?? 'Operator User';

    final isTargetMet = _achievementPercentage >= 100;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        shadowColor: const Color(0x1A000000),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Color(0xFF2563EB)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DAILY PRODUCTION REPORT',
              style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 0.5),
            ),
            Text(
              'End of Day Output & Rejection Log',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: _isLoadingContext
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF2563EB)))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. STATION DETAILS SPECIFICATION CARD
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: const [
                            BoxShadow(color: Color(0x06000000), blurRadius: 4, offset: Offset(0, 1)),
                          ],
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'STATION DETAILS',
                                  style: TextStyle(
                                    color: Color(0xFF64748B),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                InkWell(
                                  onTap: _showChangeStationModal,
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF1F5F9),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFFCBD5E1)),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.tune_rounded, size: 13, color: Color(0xFF2563EB)),
                                        SizedBox(width: 5),
                                        Text(
                                          'Change Station',
                                          style: TextStyle(color: Color(0xFF2563EB), fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 20, color: Color(0xFFF1F5F9)),
                            _metaRow('Date:', dateDisplay, 'Shift:', 'Shift $shift'),
                            const SizedBox(height: 8),
                            _metaRow('Machine:', machineCode, 'Operator:', operatorName),
                            const SizedBox(height: 8),
                            _metaRow('Part:', partName, 'Operation:', operation),
                            const SizedBox(height: 8),
                            _metaRow(
                              'Cycle Time:',
                              '${_currentCycleTime % 1 == 0 ? _currentCycleTime.toInt() : _currentCycleTime.toStringAsFixed(1)} min',
                              'Available Time:',
                              '$_currentAvailableTime min',
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      // 2. PRODUCTION ACHIEVEMENT CARD
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: const [
                            BoxShadow(color: Color(0x06000000), blurRadius: 4, offset: Offset(0, 1)),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Production Achievement',
                                  style: TextStyle(color: Color(0xFF64748B), fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${_achievementPercentage.toStringAsFixed(1)}%',
                                  style: TextStyle(
                                    color: isTargetMet ? const Color(0xFF16A34A) : const Color(0xFF2563EB),
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: isTargetMet ? const Color(0xFFDCFCE7) : const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isTargetMet ? const Color(0xFF86EFAC) : const Color(0xFFBFDBFE),
                                ),
                              ),
                              child: Text(
                                isTargetMet ? 'TARGET MET' : 'IN PROGRESS',
                                style: TextStyle(
                                  color: isTargetMet ? const Color(0xFF15803D) : const Color(0xFF1D4ED8),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            )
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      // 3. LIGHT VALIDATION WARNING BANNER
                      if (_validationError != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 20),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFFCA5A5)),
                          ),
                          child: Text(
                            _validationError!,
                            style: const TextStyle(color: Color(0xFF991B1B), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),

                      // 4. FORM INPUT FIELDS
                      _buildNumberInput(
                        'Production Target',
                        _targetController,
                        readOnly: true,
                        helperText: 'Standard: $_currentAvailableTime min available / ${_currentCycleTime % 1 == 0 ? _currentCycleTime.toInt() : _currentCycleTime.toStringAsFixed(1)} min cycle',
                        suffixBadge: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: const Text(
                            'Auto-calculated',
                            style: TextStyle(color: Color(0xFF64748B), fontSize: 10, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildNumberInput('Jobs Completed', _completedController),
                      const SizedBox(height: 14),

                      Row(
                        children: [
                          Expanded(child: _buildNumberInput('Correct Jobs', _correctController, color: const Color(0xFF059669))),
                          const SizedBox(width: 12),
                          Expanded(child: _buildNumberInput('Incorrect Jobs', _incorrectController, color: const Color(0xFFDC2626))),
                        ],
                      ),

                      const SizedBox(height: 18),
                      const Row(
                        children: [
                          Text(
                            'Rejection Breakdown',
                            style: TextStyle(color: Color(0xFF334155), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(width: 6),
                          Text(
                            '(Must equal Incorrect Jobs)',
                            style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      Row(
                        children: [
                          Expanded(child: _buildNumberInput('CR (Customer)', _crController, isCompact: true)),
                          const SizedBox(width: 8),
                          Expanded(child: _buildNumberInput('MR (Machine)', _mrController, isCompact: true)),
                          const SizedBox(width: 8),
                          Expanded(child: _buildNumberInput('RW (Rework)', _rwController, isCompact: true)),
                        ],
                      ),

                      const SizedBox(height: 18),

                      // Remarks Input
                      const Text(
                        'Remarks (Optional)',
                        style: TextStyle(color: Color(0xFF334155), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _remarksController,
                        maxLines: 3,
                        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'e.g. Tool change or downtime notes.',
                          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2)),
                        ),
                      ),

                      const SizedBox(height: 28),

                      // SUBMIT BUTTON
                      ElevatedButton(
                        onPressed: _isSubmitting ? null : _submitReport,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          elevation: 1,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: _isSubmitting
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : const Text(
                                'Submit Daily Production Report',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _metaRow(String label1, String val1, String label2, String val2) {
    return Row(
      children: [
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 12),
              children: [
                TextSpan(text: '$label1 ', style: const TextStyle(color: Color(0xFF64748B))),
                TextSpan(text: val1, style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 12),
              children: [
                TextSpan(text: '$label2 ', style: const TextStyle(color: Color(0xFF64748B))),
                TextSpan(text: val2, style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNumberInput(
    String label,
    TextEditingController controller, {
    IconData? icon,
    Color color = const Color(0xFF2563EB),
    bool isCompact = false,
    bool readOnly = false,
    String? helperText,
    Widget? suffixBadge,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isCompact) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Color(0xFF334155), fontSize: 12, fontWeight: FontWeight.bold)),
              if (suffixBadge != null) suffixBadge,
            ],
          ),
          const SizedBox(height: 6),
        ],
        TextField(
          controller: controller,
          readOnly: readOnly,
          keyboardType: TextInputType.number,
          onTap: () {
            if (!readOnly && controller.text == '0') {
              controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
            }
          },
          style: TextStyle(
            color: readOnly ? const Color(0xFF1E293B) : const Color(0xFF0F172A),
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
          decoration: InputDecoration(
            hintText: '0',
            hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
            labelText: isCompact ? label : null,
            labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
            prefixIcon: icon != null ? Icon(icon, color: color, size: 20) : null,
            filled: true,
            fillColor: readOnly ? const Color(0xFFF8FAFC) : Colors.white,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: isCompact ? 10 : 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: readOnly ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: readOnly ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: color, width: 2)),
          ),
        ),
        if (helperText != null) ...[
          const SizedBox(height: 4),
          Text(helperText, style: const TextStyle(color: Color(0xFF64748B), fontSize: 11, fontStyle: FontStyle.italic)),
        ],
      ],
    );
  }

  String _monthAbbr(int month) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[month - 1];
  }
}
