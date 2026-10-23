import 'package:flutter/material.dart';

import '../services/api_service.dart';

class PdiReportScreen extends StatefulWidget {
  const PdiReportScreen({super.key});

  @override
  State<PdiReportScreen> createState() => _PdiReportScreenState();
}

class _PdiReportScreenState extends State<PdiReportScreen> {
  List<dynamic> _machines = [];
  List<dynamic> _operations = [];
  List<dynamic> _parameters = [];
  int? _machineId;
  int? _templateId;
  String? _reportId;
  int _sample = 1;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _visualJudgements = {};
  final Map<String, Future<void>> _saveChains = {};
  int _selectionRequest = 0;

  @override
  void initState() {
    super.initState();
    _loadMachines();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) controller.dispose();
    super.dispose();
  }

  Future<void> _loadMachines() async {
    try {
      final machines = await ApiService.getMachinesStrict();
      if (!mounted) return;
      setState(() {
        _machines = machines;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _selectMachine(int? id) async {
    if (id == null) return;
    final request = ++_selectionRequest;
    setState(() {
      _machineId = id;
      _templateId = null;
      _parameters = [];
      _operations = [];
      _reportId = null;
      _loading = true;
      _error = null;
    });
    try {
      final operations = await ApiService.getPdiOperations(id);
      if (!mounted) return;
      if (request != _selectionRequest || _machineId != id) return;
      setState(() {
        _operations = operations;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (request != _selectionRequest || _machineId != id) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _selectOperation(int? id) async {
    if (id == null || _machineId == null) return;
    final machineId = _machineId!;
    final request = ++_selectionRequest;
    setState(() {
      _templateId = id;
      _parameters = [];
      _reportId = null;
      _loading = true;
      _error = null;
    });
    try {
      final result = await Future.wait([
        ApiService.getPdiParameters(id),
        ApiService.createPdiReport(machineId: machineId, templateId: id),
      ]);
      if (!mounted) return;
      if (request != _selectionRequest || _machineId != machineId || _templateId != id) return;
      final parameters = result[0] as List<dynamic>;
      final report = result[1] as Map<String, dynamic>;
      _restoreReadings(parameters, report['readings'] as List<dynamic>? ?? const []);
      setState(() {
        _parameters = parameters;
        _reportId = report['report_id']?.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (request != _selectionRequest || _machineId != machineId || _templateId != id) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _restoreReadings(List<dynamic> parameters, List<dynamic> readings) {
    final byId = {for (final raw in readings) '${raw['parameter_id']}_${raw['sample_number']}': raw};
    for (final raw in parameters) {
      final parameter = Map<String, dynamic>.from(raw as Map);
      final id = parameter['id'] as int;
      for (var sample = 1; sample <= 5; sample++) {
        final reading = byId['${id}_$sample'];
        if (reading == null) continue;
        final key = '${id}_$sample';
        if (parameter['measurement_type'] == 'visual') {
          _visualJudgements[key] = reading['judgement']?.toString() ?? 'pass';
        } else {
          final controller = _controllers.putIfAbsent(key, () => TextEditingController());
          controller.text = reading['value_text']?.toString() ?? reading['numeric_value']?.toString() ?? '';
        }
      }
    }
  }

  Future<void> _save(int parameterId, Map<String, dynamic> parameter) async {
    if (_reportId == null) return;
    final key = '${parameterId}_$_sample';
    final isVisual = parameter['measurement_type'] == 'visual';
    final value = isVisual ? null : _controllers[key]?.text.trim();
    if (!isVisual && (value == null || value.isEmpty)) return;
    final reportId = _reportId!;
    final sampleNumber = _sample;
    final judgement = isVisual ? _visualJudgements[key] : null;
    final previous = _saveChains[key] ?? Future<void>.value();
    final save = previous.then((_) async {
      await ApiService.savePdiReading(
          reportId: reportId, parameterId: parameterId, sampleNumber: sampleNumber,
          numericValue: value, judgement: judgement);
    });
    _saveChains[key] = save.catchError((_) {});
    try {
      await save;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDI reading saved')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _submit() async {
    if (_reportId == null) return;
    setState(() => _saving = true);
    try {
      await ApiService.submitPdiReport(_reportId!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDI report submitted for review')));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PDI Report')),
      body: _loading && _machines.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadMachines,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('Pre-Dispatch Inspection', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('Select the approved machine operation and record five jobs: X1 to X5.'),
                  const SizedBox(height: 16),
                  if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
                  DropdownButtonFormField<int>(
                    value: _machineId,
                    decoration: const InputDecoration(labelText: 'Machine', border: OutlineInputBorder()),
                    items: _machines.map((machine) => DropdownMenuItem<int>(
                      value: machine['id'] as int,
                      child: Text('${machine['machine_code'] ?? machine['code'] ?? ''} ${machine['name'] ?? ''}'),
                    )).toList(),
                    onChanged: _selectMachine,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    value: _templateId,
                    decoration: const InputDecoration(labelText: 'Part / Operation', border: OutlineInputBorder()),
                    items: _operations.map((operation) => DropdownMenuItem<int>(
                      value: operation['id'] as int,
                      child: Text('${operation['part_number']} — ${operation['name']}'),
                    )).toList(),
                    onChanged: _selectOperation,
                  ),
                  if (_parameters.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SegmentedButton<int>(
                      segments: List.generate(5, (index) => ButtonSegment(value: index + 1, label: Text('X${index + 1}'))),
                      selected: {_sample},
                      onSelectionChanged: (value) => setState(() => _sample = value.first),
                    ),
                    const SizedBox(height: 16),
                    ..._parameters.map((raw) {
                      final parameter = Map<String, dynamic>.from(raw as Map);
                      final id = parameter['id'] as int;
                      final key = '${id}_$_sample';
                      final visual = parameter['measurement_type'] == 'visual';
                      final controller = _controllers.putIfAbsent(key, () => TextEditingController());
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${parameter['parameter_code']} — ${parameter['parameter_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('${parameter['specification']} ${parameter['inspection_method'] ?? ''}', style: const TextStyle(color: Colors.grey)),
                            const SizedBox(height: 8),
                            visual
                                ? DropdownButtonFormField<String>(
                                    value: _visualJudgements[key],
                                    decoration: const InputDecoration(labelText: 'Judgement', border: OutlineInputBorder()),
                                    items: const [
                                      DropdownMenuItem(value: 'pass', child: Text('Pass')),
                                      DropdownMenuItem(value: 'fail', child: Text('Fail')),
                                      DropdownMenuItem(value: 'na', child: Text('Not applicable')),
                                    ],
                                    onChanged: (value) => setState(() => _visualJudgements[key] = value ?? 'pass'),
                                  )
                                : TextField(
                                    controller: controller,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: InputDecoration(labelText: 'X$_sample value (${parameter['unit'] ?? ''})', border: const OutlineInputBorder()),
                                  ),
                            Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _save(id, parameter), child: const Text('Save reading'))),
                          ]),
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    FilledButton.icon(onPressed: _saving ? null : _submit, icon: const Icon(Icons.send), label: const Text('Submit PDI Report')),
                  ],
                ],
              ),
            ),
    );
  }
}
