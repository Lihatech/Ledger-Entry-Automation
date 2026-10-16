import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
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
      final machines = await ApiService.getMachines();
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
      final report = await ApiService.openRunChart(
        machineId: _machine!['id'] as int,
        templateId: _operation!['id'] as int,
        parameterId: parameter['id'] as int,
        shift: auth.assignedShift == 'ALL' ? 'I' : auth.assignedShift,
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
        ? 'Choose a machine to record every job/piece against its critical parameters.'
        : operationStep
        ? 'Choose the operation and part currently running on this machine.'
        : 'Choose one parameter. Each parameter opens its own report and live graph.';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F172A), Color(0xFF1E3A8A)],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.show_chart_rounded,
            color: Color(0xFF93C5FD),
            size: 30,
          ),
          const SizedBox(height: 10),
          Text(
            heading,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            help,
            style: const TextStyle(
              color: Color(0xFFCBD5E1),
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
  bool _downloading = false;
  String? _error;

  List<Map<String, dynamic>> get _readings => List<Map<String, dynamic>>.from(
    (_report['readings'] as List? ?? const []).map(
      (e) => Map<String, dynamic>.from(e as Map),
    ),
  );

  @override
  void initState() {
    super.initState();
    _report = Map<String, dynamic>.from(widget.initialReport);
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
      );
      final readings = List<dynamic>.from(_report['readings'] ?? const []);
      readings.add(result['reading']);
      setState(() {
        _report['readings'] = readings;
        _report['next_piece_number'] = result['next_piece_number'];
        _valueController.clear();
      });
      final alert = result['alert']?.toString();
      if (alert != null && mounted) await _showAlert(alert, result['reading']);
      _focusNode.requestFocus();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

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
    final path = await ApiService.downloadRunChartPDF(
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
              ? 'Could not download the run chart.'
              : 'Run chart downloaded successfully.',
        ),
        backgroundColor: path == null
            ? const Color(0xFFDC2626)
            : const Color(0xFF059669),
      ),
    );
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
            tooltip: 'Maximize graph',
            onPressed: _openFullscreen,
            icon: const Icon(Icons.fullscreen_rounded),
          ),
          IconButton(
            tooltip: 'Download PDF',
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
            Container(
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
                'Live run chart',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
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
            // Keep the plot wide enough to match the production run-chart
            // format. On narrow phones the user can scroll horizontally;
            // the y-axis remains visible at the left edge of the chart.
            final width = math.max(
              math.max(constraints.maxWidth, 620.0),
              math.max(1, readings.length) * 52.0 + 100,
            );
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const AlwaysScrollableScrollPhysics(),
              child: SizedBox(
                width: width,
                height: 250,
                child: RunChartPlot(report: _report),
              ),
            );
          },
        ),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LegendDot(color: Color(0xFF16A34A), label: 'Green'),
            SizedBox(width: 12),
            _LegendDot(color: Color(0xFFD97706), label: 'Warning'),
            SizedBox(width: 12),
            _LegendDot(color: Color(0xFFDC2626), label: 'Out of spec'),
          ],
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
          final width = math.max(
            constraints.maxWidth,
            math.max(1, readings.length) * 52.0 + 100,
          );
          return InteractiveViewer(
            constrained: false,
            minScale: .7,
            maxScale: 4,
            boundaryMargin: const EdgeInsets.all(120),
            child: Container(
              width: width,
              height: constraints.maxHeight,
              padding: const EdgeInsets.all(12),
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

  @override
  void paint(Canvas canvas, Size size) {
    final readings = List<Map<String, dynamic>>.from(
      (report['readings'] as List? ?? const []).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    );
    final lower = (report['lower_limit'] as num).toDouble();
    final upper = (report['upper_limit'] as num).toDouble();
    final nominal = (report['nominal_value'] as num).toDouble();
    final values = readings
        .map((r) => (r['measured_value'] as num).toDouble())
        .toList();
    final all = <double>[lower, upper, nominal, ...values];
    var minY = all.reduce(math.min);
    var maxY = all.reduce(math.max);
    var span = maxY - minY;
    if (span == 0) span = math.max(nominal.abs() * .001, .001);
    minY -= span * .15;
    maxY += span * .15;

    const left = 58.0, right = 16.0, top = 14.0, bottom = 34.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    double y(double v) =>
        plot.bottom - ((v - minY) / (maxY - minY)) * plot.height;
    double x(int index) =>
        plot.left + (index / math.max(readings.length - 1, 1)) * plot.width;

    final band = (upper - lower) * .20;
    final greenLow = lower + band;
    final greenHigh = upper - band;
    final fill = Paint()..style = PaintingStyle.fill;
    fill.color = const Color(0xFFFEE2E2);
    canvas.drawRect(
      Rect.fromLTRB(plot.left, plot.top, plot.right, y(upper)),
      fill,
    );
    canvas.drawRect(
      Rect.fromLTRB(plot.left, y(lower), plot.right, plot.bottom),
      fill,
    );
    fill.color = const Color(0xFFFEF3C7);
    canvas.drawRect(
      Rect.fromLTRB(plot.left, y(upper), plot.right, y(greenHigh)),
      fill,
    );
    canvas.drawRect(
      Rect.fromLTRB(plot.left, y(greenLow), plot.right, y(lower)),
      fill,
    );
    fill.color = const Color(0xFFDCFCE7);
    canvas.drawRect(
      Rect.fromLTRB(plot.left, y(greenHigh), plot.right, y(greenLow)),
      fill,
    );

    final grid = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final gy = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, gy), Offset(plot.right, gy), grid);
      final value = maxY - (maxY - minY) * i / 4;
      _text(
        canvas,
        _shortNumber(value),
        Offset(2, gy - 6),
        const Color(0xFF64748B),
        9,
      );
    }
    canvas.drawLine(
      plot.bottomLeft,
      plot.bottomRight,
      Paint()..color = const Color(0xFF64748B),
    );
    canvas.drawLine(
      plot.topLeft,
      plot.bottomLeft,
      Paint()..color = const Color(0xFF64748B),
    );

    void limitLine(double value, Color color, String label) {
      final py = y(value);
      canvas.drawLine(
        Offset(plot.left, py),
        Offset(plot.right, py),
        Paint()
          ..color = color
          ..strokeWidth = 1.2,
      );
      _text(
        canvas,
        '$label ${_shortNumber(value)}',
        Offset(plot.left + 4, py - 14),
        color,
        9,
        bold: true,
      );
    }

    limitLine(lower, const Color(0xFFDC2626), 'LSL');
    limitLine(nominal, const Color(0xFF2563EB), 'NOM');
    limitLine(upper, const Color(0xFFDC2626), 'USL');

    if (readings.isEmpty) {
      _text(
        canvas,
        'No readings yet',
        Offset(plot.center.dx - 44, plot.center.dy - 8),
        const Color(0xFF64748B),
        13,
        bold: true,
      );
      return;
    }
    final path = Path();
    for (var i = 0; i < readings.length; i++) {
      final point = Offset(
        x(i),
        y((readings[i]['measured_value'] as num).toDouble()),
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF0F172A)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    final labelEvery = math.max(1, (readings.length / 8).ceil());
    for (var i = 0; i < readings.length; i++) {
      final reading = readings[i];
      final point = Offset(
        x(i),
        y((reading['measured_value'] as num).toDouble()),
      );
      canvas.drawCircle(
        point,
        5,
        Paint()..color = _zoneColor(reading['zone']?.toString()),
      );
      canvas.drawCircle(
        point,
        5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      if (i % labelEvery == 0 || i == readings.length - 1) {
        _text(
          canvas,
          '${reading['piece_number']}',
          Offset(point.dx - 7, plot.bottom + 7),
          const Color(0xFF475569),
          9,
        );
      }
    }
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

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 4),
      Text(
        label,
        style: const TextStyle(fontSize: 9.5, color: Color(0xFF64748B)),
      ),
    ],
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
