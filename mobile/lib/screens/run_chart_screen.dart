import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/company_provider.dart';
import '../services/api_service.dart';

class RunChartScreen extends StatefulWidget {
  const RunChartScreen({super.key});

  @override
  State<RunChartScreen> createState() => _RunChartScreenState();
}

class _RunChartScreenState extends State<RunChartScreen> {
  bool _loading = true;
  String? _error;
  List<dynamic> _machines = [];
  List<dynamic> _operations = [];
  List<dynamic> _parameters = [];
  Map<String, dynamic>? _machine;
  Map<String, dynamic>? _operation;

  @override
  void initState() {
    super.initState();
    _loadMachines();
  }

  Future<void> _loadMachines() async {
    setState(() {
      _loading = true;
      _error = null;
      _machine = null;
      _operation = null;
    });
    try {
      final machines = await ApiService.getMachinesStrict();
      if (!mounted) return;
      setState(
        () => _machines = machines
            .where((m) => m['status'] != 'inactive')
            .toList(),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to load machines. Pull down to retry.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectMachine(Map<String, dynamic> machine) async {
    setState(() {
      _machine = machine;
      _operation = null;
      _operations = [];
      _loading = true;
      _error = null;
    });
    try {
      final operations = await ApiService.getRunChartOperations(
        machine['id'] as int,
      );
      if (mounted) setState(() => _operations = operations);
    } catch (e) {
      if (mounted) setState(() => _error = _cleanError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectOperation(Map<String, dynamic> operation) async {
    setState(() {
      _operation = operation;
      _parameters = [];
      _loading = true;
      _error = null;
    });
    try {
      final parameters = await ApiService.getRunChartParameters(
        operation['id'] as int,
      );
      if (mounted) setState(() => _parameters = parameters);
    } catch (e) {
      if (mounted) setState(() => _error = _cleanError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openParameter(Map<String, dynamic> parameter) async {
    if (_machine == null || _operation == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = context.read<AuthProvider>();
      final company = context.read<CompanyProvider>();

      // Use the same logic as homepage to get current shift
      String shift = company.availableShifts.contains(auth.assignedShift)
          ? auth.assignedShift
          : company.availableShifts.first;

      final report = await ApiService.openRunChart(
        machineId: _machine!['id'] as int,
        templateId: _operation!['id'] as int,
        parameterId: parameter['id'] as int,
        shift: shift,
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RunChartEntryScreen(initialReport: report),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = _cleanError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _cleanError(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  void _goBackOneLevel() {
    setState(() {
      _error = null;
      if (_operation != null) {
        _operation = null;
        _parameters = [];
      } else if (_machine != null) {
        _machine = null;
        _operations = [];
      } else {
        Navigator.pop(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMachineStep = _machine == null;
    final isOperationStep = _machine != null && _operation == null;
    final title = isMachineStep
        ? 'Run Chart'
        : isOperationStep
        ? 'Select Operation'
        : 'Critical Parameters';
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _goBackOneLevel,
        ),
      ),
      body: RefreshIndicator(
        onRefresh: isMachineStep
            ? _loadMachines
            : isOperationStep
            ? () => _selectMachine(_machine!)
            : () => _selectOperation(_operation!),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _buildHeader(isMachineStep, isOperationStep),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _MessageCard(message: _error!, isError: true),
            ],
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (isMachineStep)
              ..._machines.map(
                (m) => _machineCard(Map<String, dynamic>.from(m)),
              )
            else if (isOperationStep)
              ..._operations.map(
                (o) => _operationCard(Map<String, dynamic>.from(o)),
              )
            else
              ..._parameters.map(
                (p) => _parameterCard(Map<String, dynamic>.from(p)),
              ),
            if (!_loading && _currentListIsEmpty())
              const _MessageCard(
                message:
                    'No eligible Master Database records were found for this selection.',
              ),
          ],
        ),
      ),
    );
  }

  bool _currentListIsEmpty() {
    if (_machine == null) return _machines.isEmpty;
    if (_operation == null) return _operations.isEmpty;
    return _parameters.isEmpty;
  }

  Widget _buildHeader(bool machineStep, bool operationStep) {
    final heading = machineStep
        ? '100% critical inspection'
        : operationStep
        ? '${_machine!['machine_code']} · ${_machine!['name']}'
        : '${_operation!['name']} · ${_operation!['part_number']}';
    final help = machineStep
        ? 'Choose a Machine for recording a critical parameters'
        : operationStep
        ? 'Choose part and operation currently running on this machine'
        : 'Choose one parameter. Each parameter opens its own report and live graph.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: const TextStyle(
              color: Color(0xFF111827),
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            help,
            style: const TextStyle(
              color: Color(0xFF64748B),
              height: 1.35,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _machineCard(Map<String, dynamic> machine) => _SelectionCard(
    icon: Icons.precision_manufacturing_rounded,
    iconColor: const Color(0xFF2563EB),
    title: machine['machine_code']?.toString() ?? 'Machine',
    subtitle: machine['name']?.toString() ?? '',
    trailing: (machine['status'] ?? 'active').toString().toUpperCase(),
    onTap: () => _selectMachine(machine),
  );

  Widget _operationCard(Map<String, dynamic> operation) => _SelectionCard(
    icon: Icons.settings_suggest_rounded,
    iconColor: const Color(0xFF7C3AED),
    title: operation['name']?.toString() ?? 'Operation',
    subtitle: '${operation['part_number']} · ${operation['part_name']}',
    trailing: '${operation['critical_parameter_count']} critical',
    onTap: () => _selectOperation(operation),
  );

  Widget _parameterCard(Map<String, dynamic> parameter) {
    final unit = parameter['unit'] ?? '';
    return _SelectionCard(
      icon: Icons.track_changes_rounded,
      iconColor: const Color(0xFFDC2626),
      title:
          parameter['parameter_name']?.toString() ??
          parameter['parameter_code'].toString(),
      subtitle:
          'Nominal ${_number(parameter['nominal_value'])} $unit\nLimits ${_number(parameter['lower_limit'])} – ${_number(parameter['upper_limit'])} $unit',
      trailing: 'OPEN',
      onTap: () => _openParameter(parameter),
    );
  }
}

class RunChartEntryScreen extends StatefulWidget {
  final Map<String, dynamic> initialReport;

  const RunChartEntryScreen({super.key, required this.initialReport});

  @override
  State<RunChartEntryScreen> createState() => _RunChartEntryScreenState();
}

class _RunChartEntryScreenState extends State<RunChartEntryScreen> {
  late Map<String, dynamic> _report;
  final _valueController = TextEditingController();
  final _focusNode = FocusNode();
  bool _saving = false;
  bool _completing = false;
  bool _downloading = false;
  String? _error;
  late String _submissionKey;

  List<Map<String, dynamic>> get _readings => List<Map<String, dynamic>>.from(
    (_report['readings'] as List? ?? const []).map(
      (e) => Map<String, dynamic>.from(e as Map),
    ),
  );

  @override
  void initState() {
    super.initState();
    _report = Map<String, dynamic>.from(widget.initialReport);
    _submissionKey = _newSubmissionKey();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNode.requestFocus(),
    );
  }

  @override
  void dispose() {
    _valueController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final refreshed = await ApiService.getRunChart(
      _report['report_id'].toString(),
    );
    if (mounted) setState(() => _report = refreshed);
  }

  Future<void> _submit() async {
    if (_saving) return;
    final value = double.tryParse(_valueController.text.trim());
    if (value == null) {
      setState(() => _error = 'Enter a valid measured value.');
      _focusNode.requestFocus();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ApiService.addRunChartReading(
        reportId: _report['report_id'].toString(),
        measuredValue: value,
        pieceNumber: (_report['next_piece_number'] as num).toInt(),
        idempotencyKey: _submissionKey,
      );
      final readings = List<dynamic>.from(_report['readings'] ?? const []);
      readings.add(result['reading']);
      if (!mounted) return;
      setState(() {
        _report['readings'] = readings;
        _report['next_piece_number'] = result['next_piece_number'];
        _valueController.clear();
        _submissionKey = _newSubmissionKey();
      });
      final alert = result['alert']?.toString();
      if (alert != null && mounted) await _showAlert(alert, result['reading']);
      _focusNode.requestFocus();
    } catch (e) {
      if (mounted) {
        final message = e.toString().replaceFirst('Exception: ', '');
        setState(() => _error = message);
        if (message.contains('next required piece')) {
          try {
            await _refresh();
          } catch (_) {}
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _newSubmissionKey() =>
      '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1000000000)}';

  Future<void> _showAlert(String alert, dynamic reading) async {
    final stop = alert == 'stop_process';
    await showDialog<void>(
      context: context,
      barrierDismissible: !stop,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          stop ? Icons.report_rounded : Icons.warning_amber_rounded,
          color: stop ? const Color(0xFFDC2626) : const Color(0xFFD97706),
          size: 42,
        ),
        title: Text(
          stop ? 'STOP PROCESS' : 'PROCESS WARNING',
          textAlign: TextAlign.center,
        ),
        content: Text(
          stop
              ? 'Piece ${reading['piece_number']} is outside the Master Database limits. Inform the supervisor and correct the process before continuing.'
              : 'Three of the latest five readings are in a yellow zone. Check the process and tool condition.',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ACKNOWLEDGE'),
          ),
        ],
      ),
    );
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    final path = await ApiService.downloadRunChartExcel(
      _report['report_id'].toString(),
      machineCode: _report['machine_code'].toString(),
      parameterName: _report['parameter_name'].toString(),
    );
    if (!mounted) return;
    setState(() => _downloading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path == null
              ? 'Could not download the Excel report.'
              : 'Excel report downloaded successfully.',
        ),
        backgroundColor: path == null
            ? const Color(0xFFDC2626)
            : const Color(0xFF059669),
      ),
    );
    if (path != null && path != 'web_downloaded') {
      await OpenFilex.open(path);
    }
  }

  Future<void> _complete() async {
    if (_completing || _readings.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Complete run chart?'),
        content: const Text(
          'This closes the current shift report. Its readings and graph will be available in the web Reports archive.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('COMPLETE')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _completing = true);
    try {
      final completed = await ApiService.completeRunChart(_report['report_id'].toString());
      if (!mounted) return;
      setState(() => _report = completed);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run chart completed and saved.')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  void _openFullscreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RunChartFullscreenScreen(report: _report),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unit = _report['unit']?.toString() ?? '';
    final nextPiece = _report['next_piece_number'];
    final readings = _readings;
    final isClosed = _report['status']?.toString() == 'closed';
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _report['parameter_name'].toString(),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            Text(
              '${_report['machine_code']} · ${_report['operation_name']}',
              style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Maximize report',
            onPressed: _openFullscreen,
            icon: const Icon(Icons.fullscreen_rounded),
          ),
          IconButton(
            tooltip: 'Download Excel report',
            onPressed: _downloading ? null : _download,
            icon: _downloading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(14),
          children: [
            _specCard(),
            const SizedBox(height: 12),
            _chartCard(readings),
            const SizedBox(height: 12),
            if (!isClosed) Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PIECE ${nextPiece.toString().padLeft(4, '0')}',
                    style: const TextStyle(
                      color: Color(0xFF2563EB),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Enter ${_report['parameter_name']} value',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _valueController,
                    focusNode: _focusNode,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Measured value',
                      suffixText: unit,
                      errorText: _error,
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.arrow_forward_rounded),
                      label: Text(
                        _saving ? 'SAVING...' : 'SAVE & NEXT PIECE',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (isClosed) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF86EFAC)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Color(0xFF059669)),
                    SizedBox(width: 10),
                    Expanded(child: Text('Completed run chart. This report is now available in the web Reports archive.')),
                  ],
                ),
              ),
            ] else if (readings.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _completing ? null : _complete,
                  icon: _completing
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check_circle_outline_rounded),
                  label: Text(_completing ? 'COMPLETING...' : 'COMPLETE RUN CHART'),
                ),
              ),
            ],
            if (readings.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text(
                'Latest readings',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              ...readings.reversed.take(5).map(_readingTile),
            ],
          ],
        ),
      ),
    );
  }

  Widget _specCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF0F172A),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _spec('LOWER', _report['lower_limit']),
        _spec('NOMINAL', _report['nominal_value'], highlight: true),
        _spec('UPPER', _report['upper_limit']),
      ],
    ),
  );

  Widget _spec(String label, dynamic value, {bool highlight = false}) => Column(
    children: [
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF94A3B8),
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        '${_number(value)} ${_report['unit']}',
        style: TextStyle(
          color: highlight ? const Color(0xFF93C5FD) : Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );

  Widget _chartCard(List<Map<String, dynamic>> readings) => Container(
    padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Column(
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Run Chart (Stop Light Control Chart)',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: _openFullscreen,
              tooltip: 'Maximize',
              icon: const Icon(
                Icons.fullscreen_rounded,
                color: Color(0xFF2563EB),
              ),
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final columnCount = math.max(33, readings.length);
            final width = math.max(
              constraints.maxWidth,
              70.0 + columnCount * 36.0 + 92.0,
            );
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const AlwaysScrollableScrollPhysics(),
              child: SizedBox(
                width: width,
                height: 760,
                child: RunChartPlot(report: _report),
              ),
            );
          },
        ),
      ],
    ),
  );

  Widget _readingTile(Map<String, dynamic> reading) {
    final color = _zoneColor(reading['zone']?.toString());
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: color.withValues(alpha: .12),
            child: Text(
              '${reading['piece_number']}',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Piece ${reading['piece_number']}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '${_number(reading['measured_value'])} ${_report['unit']}',
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class RunChartFullscreenScreen extends StatefulWidget {
  final Map<String, dynamic> report;
  const RunChartFullscreenScreen({super.key, required this.report});

  @override
  State<RunChartFullscreenScreen> createState() =>
      _RunChartFullscreenScreenState();
}

class _RunChartFullscreenScreenState extends State<RunChartFullscreenScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final readings = widget.report['readings'] as List? ?? const [];
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
        title: Text(
          '${widget.report['parameter_name']} · ${widget.report['machine_code']}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final columnCount = math.max(33, readings.length);
          final width = math.max(
            constraints.maxWidth,
            70.0 + columnCount * 36.0 + 92.0,
          );
          return InteractiveViewer(
            constrained: false,
            minScale: .7,
            maxScale: 4,
            boundaryMargin: const EdgeInsets.all(120),
            child: Container(
              width: width,
              height: math.max(constraints.maxHeight, 760.0),
              color: Colors.white,
              child: RunChartPlot(report: widget.report),
            ),
          );
        },
      ),
    );
  }
}

class RunChartPlot extends StatelessWidget {
  final Map<String, dynamic> report;
  const RunChartPlot({super.key, required this.report});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _RunChartPainter(report));
}

class _RunChartPainter extends CustomPainter {
  final Map<String, dynamic> report;
  _RunChartPainter(this.report);

  static const _red = Color(0xFFFF0000);
  static const _yellow = Color(0xFFFFFF00);
  static const _green = Color(0xFFA8D348);
  static const _rules =
      'प्रोसेस कंट्रोल बाबतचे नियम (प्रोसेस कंट्रोल चार्ट रेग्युलेशन)\n'
      '1. First Piece ची साइज मिनिमम असावी. तसे नसल्यास साइज सेट करून प्रोसेस correct करून साइज मिन जॉब सेट करा.\n'
      '2. कोणत्याही एका जॉबच्या साइज लाल झोनमध्ये गेल्यास प्रोडक्शन थांबवा व सुपरवायझर कडून प्रोसेस correct करून घ्या.\n'
      '3. सलग पाच जॉब पैकी कोणतीही तीन जॉब पिवळ्या झोनमध्ये गेल्यास प्रोडक्शन थांबवा व सुपरवायझर कडून प्रोसेस correct करून घ्या.\n'
      '4. मशीन सेटिंग्स व टूल बदलानंतर साइज तीन जॉब तपासा. साइज कंट्रोल दिसेपर्यंत जॉब चालू ठेवू नका.\n'
      '5. एका प्लेटमध्ये एका पेक्षा अधिक जॉब असले तरी वरील नियम पाळणे.';

  @override
  void paint(Canvas canvas, Size size) {
    final readings = List<Map<String, dynamic>>.from(
      (report['readings'] as List? ?? const []).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    );
    final lower = (report['lower_limit'] as num).toDouble();
    final nominal = (report['nominal_value'] as num).toDouble();
    final upper = (report['upper_limit'] as num).toDouble();
    final span = math.max(upper - lower, .000001);
    final columnCount = math.max(33, readings.length);

    const left = 70.0, right = 92.0;
    const headerTop = 8.0, headerBottom = 128.0;
    const plotBottom = 568.0, jobBottom = 596.0;
    const notesBottom = 716.0, footerBottom = 754.0;
    final plot = Rect.fromLTRB(
      left,
      headerBottom,
      size.width - right,
      plotBottom,
    );
    final rowHeight = plot.height / 30;
    final columnWidth = plot.width / columnCount;
    double y(double value) =>
        plot.bottom - ((value - lower) / span) * plot.height;
    double x(int index) => plot.left + columnWidth * (index + .5);

    final fill = Paint()..style = PaintingStyle.fill;

    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final thin = Paint()
      ..color = Colors.black
      ..strokeWidth = .75
      ..style = PaintingStyle.stroke;
    final outline = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    final totalWidth = size.width;
    final third = totalWidth / 3;
    _cell(
      canvas,
      Rect.fromLTRB(0, headerTop, third, 42),
      (report['company_name'] ?? 'SAPOTECH COMPONENTS PVT. LTD.').toString(),
      13,
      bold: true,
      border: outline,
    );
    _cell(
      canvas,
      Rect.fromLTRB(third, headerTop, third * 2, 42),
      'Run Chart  (Stop Light Control Chart)',
      13,
      bold: true,
      align: TextAlign.center,
      border: outline,
    );
    _cell(
      canvas,
      Rect.fromLTRB(third * 2, headerTop, totalWidth, 42),
      'Page : 1',
      10,
      border: outline,
    );

    final half = totalWidth / 2;
    final quarter = totalWidth / 4;
    _cell(
      canvas,
      Rect.fromLTRB(0, 42, quarter, 70),
      'Part Name : ${report['part_number']} - ${report['part_name']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(quarter, 42, half, 70),
      'Characteristic : ${report['parameter_name']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(half, 42, quarter * 3, 70),
      'Machine : ${report['machine_code']} - ${report['machine_name']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(quarter * 3, 42, totalWidth, 70),
      'Sample Freq : 100%',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(0, 70, quarter, 98),
      'Operation : ${report['operation_name']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(quarter, 70, half, 98),
      'Specification : ${_number(report['lower_limit'])} to ${_number(report['upper_limit'])} ${report['unit']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(half, 70, quarter * 3, 98),
      'Date/Shift : ${report['report_date']} / ${report['shift']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(quarter * 3, 70, totalWidth, 98),
      'Operator Name : ${report['operator_name'] ?? ''}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(0, 98, quarter, headerBottom),
      'Lower Limit : ${_number(report['lower_limit'])} ${report['unit']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(quarter, 98, half, headerBottom),
      'Mean Size : ${_number(report['nominal_value'])} ${report['unit']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(half, 98, quarter * 3, headerBottom),
      'Upper Limit : ${_number(report['upper_limit'])} ${report['unit']}',
      9,
      border: thin,
    );
    _cell(
      canvas,
      Rect.fromLTRB(quarter * 3, 98, totalWidth, headerBottom),
      '1Div. = ${_number(report['division_value'] ?? span / 30)} ${report['unit']}',
      9,
      bold: true,
      border: thin,
    );

    // Use the boundaries calculated by the backend so every renderer follows
    // the same measurement-type rules (including min/max-limit parameters).
    final lowerWarningBoundary =
        (report['lower_warning_boundary'] as num?)?.toDouble() ??
        (lower + nominal) / 2;
    final upperWarningBoundary =
        (report['upper_warning_boundary'] as num?)?.toDouble() ??
        (nominal + upper) / 2;
    Color zoneForRow(int row) {
      if (row == 0 || row == 29) return _red;
      final value = upper - ((row + .5) / 30) * span;
      if (value <= lower || value >= upper) return _red;
      if (value <= lowerWarningBoundary || value >= upperWarningBoundary) {
        return _yellow;
      }
      return _green;
    }

    for (var row = 0; row < 30; row++) {
      fill.color = zoneForRow(row);
      canvas.drawRect(
        Rect.fromLTRB(
          plot.left,
          plot.top + row * rowHeight,
          plot.right,
          plot.top + (row + 1) * rowHeight,
        ),
        fill,
      );
    }

    final grid = Paint()
      ..color = const Color(0xFF1F2937)
      ..strokeWidth = .85
      ..style = PaintingStyle.stroke;

    for (var row = 0; row <= 30; row++) {
      final gy = plot.top + row * rowHeight;
      canvas.drawLine(Offset(plot.left, gy), Offset(plot.right, gy), grid);
    }
    for (var column = 0; column <= columnCount; column++) {
      final gx = plot.left + column * columnWidth;
      canvas.drawLine(Offset(gx, plot.top), Offset(gx, plot.bottom), grid);
    }

    // The Excel template also borders the division-number column. Keep that
    // frame and its row separators visible instead of leaving a white gap
    // between the labels and the plotted cells.
    final labelFrame = Rect.fromLTRB(24, plot.top, plot.left, plot.bottom);
    canvas.drawRect(labelFrame, outline);
    for (var row = 0; row <= 30; row++) {
      final gy = plot.top + row * rowHeight;
      canvas.drawLine(
        Offset(labelFrame.left, gy),
        Offset(labelFrame.right, gy),
        grid,
      );
    }
    // Join the upper and lower points into one continuous unit column.
    final unitFrame = Rect.fromLTRB(0, plot.top, 24, plot.bottom);
    canvas.drawRect(unitFrame, outline);

    // The centre/nominal reference from the Excel report is intentionally
    // heavier than the surrounding grid so operators can read it at a glance.
    final nominalLineY = y(nominal);
    canvas.drawLine(
      Offset(plot.left, nominalLineY),
      Offset(plot.right, nominalLineY),
      Paint()
        ..color = Colors.black
        ..strokeWidth = 2.8
        ..style = PaintingStyle.stroke,
    );

    canvas.drawRect(plot, outline);

    for (var row = 0; row < 30; row++) {
      final division = row < 15 ? 15 - row : row - 14;
      _centeredText(
        canvas,
        division.toString(),
        Rect.fromLTWH(32, plot.top + row * rowHeight, 34, rowHeight),
        Colors.black,
        9,
      );
    }

    _verticalText(canvas, 'IN MICRONS', unitFrame, Colors.black, 8.5);

    void zoneLabel(String text, int firstRow, int lastRow) {
      _centeredText(
        canvas,
        text,
        Rect.fromLTRB(
          plot.right,
          plot.top + firstRow * rowHeight,
          size.width,
          plot.top + lastRow * rowHeight,
        ),
        Colors.black,
        9,
        italic: true,
      );
    }

    for (var row = 0; row < 30; row++) {
      fill.color = zoneForRow(row);
      canvas.drawRect(
        Rect.fromLTRB(
          plot.right,
          plot.top + row * rowHeight,
          size.width,
          plot.top + (row + 1) * rowHeight,
        ),
        fill,
      );
    }
    canvas.drawRect(
      Rect.fromLTRB(plot.right, plot.top, size.width, plot.bottom),
      outline,
    );
    // Merged zone cells still need a visible boundary at each colour change.
    for (var boundary = 1; boundary < 30; boundary++) {
      if (zoneForRow(boundary) != zoneForRow(boundary - 1)) {
        final gy = plot.top + boundary * rowHeight;
        canvas.drawLine(
          Offset(plot.right, gy),
          Offset(size.width, gy),
          outline,
        );
      }
    }
    var runStart = 0;
    var runColor = zoneForRow(0);
    for (var row = 1; row <= 30; row++) {
      final nextColor = row < 30 ? zoneForRow(row) : null;
      if (nextColor != runColor) {
        zoneLabel(
          runColor == _red
              ? 'Red Zone'
              : runColor == _yellow
              ? 'Yellow Zone'
              : 'Green Zone',
          runStart,
          row,
        );
        if (row < 30) {
          runStart = row;
          runColor = nextColor!;
        }
      }
    }

    final jobRow = Rect.fromLTRB(0, plot.bottom, plot.right, jobBottom);
    canvas.drawRect(jobRow, Paint()..color = Colors.white);
    canvas.drawRect(jobRow, outline);
    canvas.drawRect(
      Rect.fromLTRB(plot.right, plot.bottom, size.width, jobBottom),
      outline,
    );
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.left, jobBottom),
      outline,
    );
    _centeredText(
      canvas,
      'Job No.',
      Rect.fromLTRB(0, plot.bottom, plot.left, jobBottom),
      Colors.black,
      10,
      bold: true,
    );
    for (var column = 0; column <= columnCount; column++) {
      final gx = plot.left + column * columnWidth;
      canvas.drawLine(Offset(gx, plot.bottom), Offset(gx, jobBottom), grid);
    }
    for (var index = 0; index < readings.length; index++) {
      _centeredText(
        canvas,
        '${readings[index]['piece_number']}',
        Rect.fromLTWH(
          plot.left + index * columnWidth,
          plot.bottom,
          columnWidth,
          jobBottom - plot.bottom,
        ),
        Colors.black,
        8,
      );
    }

    if (readings.isEmpty) {
      _text(
        canvas,
        'No readings yet',
        Offset(plot.left + 14, plot.center.dy - 8),
        Colors.black87,
        12,
        bold: true,
      );
    } else {
      final path = Path();
      for (var i = 0; i < readings.length; i++) {
        final point = Offset(
          x(i),
          y(
            ((readings[i]['measured_value'] as num).toDouble())
                .clamp(lower, upper)
                .toDouble(),
          ),
        );
        i == 0
            ? path.moveTo(point.dx, point.dy)
            : path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
      for (var i = 0; i < readings.length; i++) {
        final point = Offset(
          x(i),
          y(
            ((readings[i]['measured_value'] as num).toDouble())
                .clamp(lower, upper)
                .toDouble(),
          ),
        );
        canvas.drawCircle(point, 4.5, Paint()..color = Colors.black);
        canvas.drawCircle(
          point,
          4.5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }

    final rulesRect = Rect.fromLTRB(
      0,
      jobBottom,
      totalWidth * .62,
      notesBottom,
    );
    final remarksRect = Rect.fromLTRB(
      totalWidth * .62,
      jobBottom,
      totalWidth,
      notesBottom,
    );
    _cell(
      canvas,
      rulesRect,
      _rules,
      8.2,
      border: outline,
      verticalTop: true,
      maxLines: 7,
    );
    _cell(
      canvas,
      remarksRect,
      'Remarks :',
      10,
      border: outline,
      verticalTop: true,
      maxLines: 3,
    );
    _cell(
      canvas,
      Rect.fromLTRB(0, notesBottom, third, footerBottom),
      'Inspected By: ${report['operator_name'] ?? ''}',
      9,
      align: TextAlign.center,
      border: outline,
    );
    _cell(
      canvas,
      Rect.fromLTRB(third, notesBottom, third * 2, footerBottom),
      'SCPL/FT/PRD -',
      9,
      align: TextAlign.center,
      border: outline,
    );
    _cell(
      canvas,
      Rect.fromLTRB(third * 2, notesBottom, totalWidth, footerBottom),
      'Approved By: ____________________',
      9,
      align: TextAlign.center,
      border: outline,
    );
  }

  String _number(dynamic value) {
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    if (number == null) return '$value';
    return number
        .toStringAsFixed(6)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  void _cell(
    Canvas canvas,
    Rect rect,
    String text,
    double fontSize, {
    bool bold = false,
    TextAlign align = TextAlign.left,
    Paint? border,
    bool verticalTop = false,
    int maxLines = 2,
  }) {
    canvas.drawRect(rect, Paint()..color = Colors.white);
    if (border != null) canvas.drawRect(rect, border);
    final baseStyle = TextStyle(
      color: Colors.black,
      fontSize: fontSize,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      height: 1.18,
    );
    final textStyle = text == _rules
        ? GoogleFonts.notoSansDevanagari(textStyle: baseStyle)
        : baseStyle;
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textAlign: align,
      maxLines: maxLines,
      ellipsis: maxLines <= 2 ? '…' : null,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0, rect.width - 10));
    final yOffset = verticalTop ? 5.0 : (rect.height - painter.height) / 2;
    painter.paint(canvas, Offset(rect.left + 5, rect.top + yOffset));
  }

  void _centeredText(
    Canvas canvas,
    String text,
    Rect bounds,
    Color color,
    double size, {
    bool bold = false,
    bool italic = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: bounds.width);
    painter.paint(
      canvas,
      Offset(
        bounds.left + (bounds.width - painter.width) / 2,
        bounds.top + (bounds.height - painter.height) / 2,
      ),
    );
  }

  void _verticalText(
    Canvas canvas,
    String text,
    Rect bounds,
    Color color,
    double size,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(bounds.center.dx, bounds.center.dy);
    canvas.rotate(-math.pi / 2);
    painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
    canvas.restore();
  }

  void _text(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double size, {
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _RunChartPainter oldDelegate) => true;
}

class _SelectionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String trailing;
  final VoidCallback onTap;

  const _SelectionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: iconColor),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            subtitle,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: Color(0xFF64748B),
            ),
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              trailing,
              style: TextStyle(
                color: iconColor,
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            const Icon(Icons.chevron_right_rounded, size: 20),
          ],
        ),
      ),
    ),
  );
}

class _MessageCard extends StatelessWidget {
  final String message;
  final bool isError;
  const _MessageCard({required this.message, this.isError = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: isError ? const Color(0xFFFEF2F2) : Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: isError ? const Color(0xFFFCA5A5) : const Color(0xFFE2E8F0),
      ),
    ),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: isError ? const Color(0xFFB91C1C) : const Color(0xFF64748B),
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

Color _zoneColor(String? zone) {
  if (zone == 'red') return const Color(0xFFDC2626);
  if (zone == 'yellow') return const Color(0xFFD97706);
  return const Color(0xFF16A34A);
}

String _number(dynamic value) {
  if (value == null) return '—';
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse(value.toString());
  if (parsed == null) return value.toString();
  return _shortNumber(parsed);
}

String _shortNumber(double value) {
  final text = value.toStringAsFixed(6);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}
