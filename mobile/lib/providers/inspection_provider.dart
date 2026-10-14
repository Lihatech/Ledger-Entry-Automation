import 'package:flutter/material.dart';
import '../models/operation_session.dart';
import '../services/api_service.dart';
import '../services/persistence_service.dart';

class InspectionProvider with ChangeNotifier {
  // ── Machine / Part context (shared across all operations) ─────────────────
  Map<String, dynamic>? selectedMachine;
  Map<String, dynamic>? selectedPart;

  // ── Per-operation filing cabinet ──────────────────────────────────────────
  // Key: "${templateId}_${inspectionType}"  e.g. "12_hourly", "7_first_piece"
  final Map<String, OperationSession> _sessions = {};
  String? _activeOperationKey;

  // ── Shared / global state ─────────────────────────────────────────────────
  List<dynamic> activeRejections = [];
  Map<String, dynamic>? activeRejectionNotice;
  bool isLoading = false;
  String? errorMessage;
  int shiftHours = 8;
  int get totalHourlySlots => shiftHours;
  String shift = 'I';

  // First-piece trial tracking (shared, not per-operation)
  Map<int, String> trialStatuses = {1: 'pending', 2: 'locked', 3: 'locked'};
  Map<int, List<String>> trialFailedCodes = {};
  Map<int, String> trialSessionIds = {};

  String? currentUserId;

  // ── Backward-compatible getters → always point to the active operation ────
  OperationSession? get _active =>
      _activeOperationKey != null ? _sessions[_activeOperationKey] : null;

  String? get sessionId => _active?.sessionId;
  Map<String, dynamic>? get selectedTemplate => _active?.template;
  List<dynamic> get parameters => _active?.parameters ?? [];
  Map<String, Map<String, dynamic>> get recordedResults =>
      _active?.recordedResults ?? {};
  Map<String, Map<String, dynamic>> get pendingBatchValues =>
      _active?.pendingBatchValues ?? {};
  int get currentParamIndex => _active?.currentParamIndex ?? 0;
  String get inspectionType => _active?.inspectionType ?? '';
  int get hourlySlot => _active?.hourlySlot ?? 1;
  Set<int> get completedHourlySlots => _active?.completedHourlySlots ?? {};
  int get trialNumber => _active?.trialNumber ?? 1;
  String? get parentSessionId => _active?.parentSessionId;

  // ── Setters for backward-compat (older callers may assign directly) ────────
  set sessionId(String? v) { _active?.sessionId = v; }
  set selectedTemplate(Map<String, dynamic>? v) { _active?.template = v; }
  set parameters(List<dynamic> v) { if (_active != null) _active!.parameters = v; }
  set recordedResults(Map<String, Map<String, dynamic>> v) {
    if (_active != null) _active!.recordedResults = v;
  }
  set pendingBatchValues(Map<String, Map<String, dynamic>> v) {
    if (_active != null) _active!.pendingBatchValues = v;
  }
  set currentParamIndex(int v) { if (_active != null) _active!.currentParamIndex = v; }
  set inspectionType(String v) { if (_active != null) _active!.inspectionType = v; }
  set hourlySlot(int v) { if (_active != null) _active!.hourlySlot = v; }
  set completedHourlySlots(Set<int> v) {
    if (_active != null) _active!.completedHourlySlots = v;
  }
  set trialNumber(int v) { if (_active != null) _active!.trialNumber = v; }
  set parentSessionId(String? v) { if (_active != null) _active!.parentSessionId = v; }

  // ── Active operation key helper ───────────────────────────────────────────
  /// Call this before loadParameters() when the user taps an operation card.
  /// Creates the drawer if it doesn't exist yet; switches pointer if it does.
  void switchActiveOperation(String operationKey) {
    if (!_sessions.containsKey(operationKey)) {
      _sessions[operationKey] = OperationSession(operationKey: operationKey);
    }
    _activeOperationKey = operationKey;
    notifyListeners();
  }

  /// Convenience: build the key from template map + inspectionType string.
    bool isSessionActiveFor(Map<String, dynamic> template, String inspType) {
    final key = operationKey(template, inspType);
    return _sessions[key]?.sessionId != null;
  }
  
  bool isSessionActiveForOperationKey(String key) {
    return _sessions[key]?.sessionId != null;
  }

static String operationKey(Map<String, dynamic> template, String inspType) {
    final tid = template['id'] ?? template['version'] ?? '0';
    return '${tid}_$inspType';
  }

  // ── Machine selection (clears ALL session data) ───────────────────────────
  void selectMachine(Map<String, dynamic> machine) {
    selectedMachine = machine;
    selectedPart = null;
    _sessions.clear();
    _activeOperationKey = null;
    saveCurrentState();
    notifyListeners();
  }

  // ── Part selection ────────────────────────────────────────────────────────
  void selectPart(Map<String, dynamic> part) {
    selectedPart = part;
    saveCurrentState();
    notifyListeners();
  }

  // ── Template selection ────────────────────────────────────────────────────
  void selectTemplate(Map<String, dynamic> template) {
    selectedTemplate = template;
    saveCurrentState();
    notifyListeners();
  }

  // ── Reset helpers ─────────────────────────────────────────────────────────
  /// Called when operator goes back to machine-select or a new shift starts.
  void resetForNextOperation() {
    _sessions.clear();
    _activeOperationKey = null;
    activeRejectionNotice = null;
    isLoading = false;
    errorMessage = null;
    notifyListeners();
  }

  Future<void> resetSessionState() async {
    _sessions.clear();
    _activeOperationKey = null;
    activeRejectionNotice = null;
    shiftHours = 8;
    await PersistenceService.clearState();
    notifyListeners();
  }

  // ── Trial tracking ────────────────────────────────────────────────────────
  void recordTrialResult(int trial, bool isPassed, List<String> failedCodes) {
    if (isPassed) {
      trialStatuses[trial] = 'passed';
      trialFailedCodes.remove(trial);
      if (trial == 1) {
        trialStatuses[2] = 'not_needed';
        trialStatuses[3] = 'not_needed';
      } else if (trial == 2) {
        trialStatuses[3] = 'not_needed';
      }
    } else {
      trialStatuses[trial] = 'failed';
      trialFailedCodes[trial] = List<String>.from(failedCodes);
      if (trial < 3) {
        trialStatuses[trial + 1] = 'pending';
      }
    }
    notifyListeners();
  }

  void logout() {
    selectedMachine = null;
    currentUserId = null;
    resetForNextOperation();
    trialStatuses = {1: 'pending', 2: 'locked', 3: 'locked'};
    trialFailedCodes.clear();
    trialSessionIds.clear();
    PersistenceService.clearState();
  }

  // ── Persistence ───────────────────────────────────────────────────────────
  Future<void> saveCurrentState() async {
    if (currentUserId == null) {
      debugPrint('[InspectionProvider] WARNING: saveCurrentState() called but currentUserId is null — state NOT saved!');
      return;
    }
    await PersistenceService.saveState(
      userId: currentUserId!,
      machine: selectedMachine,
      part: selectedPart,
      sessions: _sessions,
      activeOperationKey: _activeOperationKey,
      shiftHours: shiftHours,
    );
  }

  /// Restore from a locally-persisted state (called at app start / splash).
  void restoreFromLocalState(Map<String, dynamic> state, String userId) {
    currentUserId = userId;
    selectedMachine = state['machine'];
    selectedPart = state['part'];
    shiftHours = (state['shift_hours'] as int?) ?? 8;
    _activeOperationKey = state['active_operation_key'] as String?;

    _sessions.clear();
    final rawSessions = state['sessions'] as Map<String, dynamic>?;
    if (rawSessions != null) {
      for (final entry in rawSessions.entries) {
        _sessions[entry.key] =
            OperationSession.fromJson(Map<String, dynamic>.from(entry.value as Map));
      }
    }

    // Auto-advance currentParamIndex within active session.
    final active = _active;
    if (active != null && active.parameters.isNotEmpty) {
      active.currentParamIndex = 0;
      for (int i = 0; i < active.parameters.length; i++) {
        final code = active.parameters[i]['parameter_code']?.toString();
        if (code != null && !active.recordedResults.containsKey(code)) {
          active.currentParamIndex = i;
          break;
        }
      }
    }

    notifyListeners();
  }

  // ── Rejections ────────────────────────────────────────────────────────────
  Future<void> fetchPendingRejections() async {
    try {
      final list = await ApiService.getRejections();
      activeRejections = list;
      notifyListeners();
    } catch (e) {
      debugPrint('Error fetching rejections: $e');
    }
  }

  // ── Load Parameters ───────────────────────────────────────────────────────
  /// Loads parameters for the CURRENTLY ACTIVE operation session.
  /// Call switchActiveOperation() first to ensure the right drawer is open.
  Future<void> loadParameters(
    Map<String, dynamic> template, {
    List<dynamic>? targetRejectedCodes,
    bool isFirstPiece = false,
    String? categoryFilter,
  }) async {
    // Ensure we have an active operation slot for this template.
    final inspType = isFirstPiece ? 'first_piece' : 'hourly';
    final key = operationKey(template, inspType);
    if (_activeOperationKey != key) {
      switchActiveOperation(key);
    }
    final op = _sessions[key]!;
    op.template = template;
    op.inspectionType = inspType;

    isLoading = true;
    notifyListeners();

    List<dynamic> allCombined = [];

    if (categoryFilter == 'process') {
      final procParams = await ApiService.getProcessParameters(template['id']);
      for (var pp in procParams) {
        pp['is_process_parameter'] = true;
      }
      allCombined = procParams;
    } else if (categoryFilter == 'product') {
      final prodParams = await ApiService.getParameters(template['id']);
      allCombined = List.from(prodParams);
    } else {
      final prodParams = await ApiService.getParameters(template['id']);
      final procParams = await ApiService.getProcessParameters(template['id']);
      for (var pp in procParams) {
        pp['is_process_parameter'] = true;
      }
      allCombined = [...procParams, ...prodParams];
    }

    if (targetRejectedCodes != null && targetRejectedCodes.isNotEmpty) {
      final filtered = allCombined
          .where((p) => targetRejectedCodes.contains(p['parameter_code']))
          .toList();
      op.parameters = filtered.isNotEmpty ? filtered : allCombined;
    } else {
      op.parameters = allCombined;
    }

        // Only reset state if we aren't resuming an active session for this operation
    if (op.sessionId == null) {
      op.currentParamIndex = 0;
      op.recordedResults.clear();
      op.pendingBatchValues.clear();
    }

    isLoading = false;
    notifyListeners();
  }

  Future<void> loadParametersForRetrial(
    Map<String, dynamic> template, {
    required int trial,
    List<String>? targetFailedCodes,
  }) async {
    final key = operationKey(template, 'first_piece');
    if (_activeOperationKey != key) switchActiveOperation(key);
    final op = _sessions[key]!;
    op.template = template;
    op.inspectionType = 'first_piece';

    isLoading = true;
    notifyListeners();

    final prodParams = await ApiService.getParameters(template['id']);
    final procParams = await ApiService.getProcessParameters(template['id']);
    for (var pp in procParams) {
      pp['is_process_parameter'] = true;
    }
    final allParams = [...procParams, ...prodParams];
    List<dynamic> targetCodes = [];

    if (targetFailedCodes != null && targetFailedCodes.isNotEmpty) {
      targetCodes = List.from(targetFailedCodes);
    }

    if (targetCodes.isEmpty && op.recordedResults.isNotEmpty) {
      for (var entry in op.recordedResults.entries) {
        final res = entry.value;
        if (res['status'] == 'out_of_spec' || res['status'] == 'error') {
          targetCodes.add(entry.key);
        }
      }
    }

    if (targetCodes.isEmpty && trialFailedCodes.containsKey(trial - 1)) {
      targetCodes = List.from(trialFailedCodes[trial - 1]!);
    }

    if (targetCodes.isEmpty) {
      await fetchPendingRejections();
      if (activeRejections.isNotEmpty) {
        targetCodes = activeRejections.first['rejected_parameters'] ?? [];
      }
    }

    if (targetCodes.isEmpty && selectedMachine != null) {
      final setupInfo = await ApiService.checkSetupApproved(selectedMachine!['id']);
      if (setupInfo['session_id'] != null) {
        final sessionDoc =
            await ApiService.getSessionDetail(setupInfo['session_id']);
        if (sessionDoc != null) {
          final rejList = sessionDoc['rejected_parameters'] as List?;
          if (rejList != null && rejList.isNotEmpty) {
            targetCodes = rejList;
          } else if (sessionDoc['measurements'] != null) {
            final measurements = sessionDoc['measurements'] as List;
            final prevTrial = trial - 1;
            final prevTrialMeasurements = measurements
                .where((m) => (m['trial_number'] ?? 1) == prevTrial)
                .toList();
            final oocCodes = prevTrialMeasurements
                .where((m) => m['status'] == 'out_of_spec')
                .map((m) => m['parameter_code'])
                .toSet()
                .toList();
            if (oocCodes.isNotEmpty) {
              targetCodes = oocCodes;
            }
          }
        }
      }
    }

    if (targetCodes.isNotEmpty) {
      final filtered = allParams
          .where((p) => targetCodes.contains(p['parameter_code']))
          .toList();
      op.parameters = filtered.isNotEmpty ? filtered : allParams;
    } else {
      op.parameters = allParams;
    }

        if (op.sessionId == null) {
      op.currentParamIndex = 0;
      op.recordedResults.clear();
      op.pendingBatchValues.clear();
    }
    isLoading = false;

    notifyListeners();
  }

  // ── Hourly slot helpers ───────────────────────────────────────────────────
  void setHourlySlot(int slot) {
    if (_active != null) {
      _active!.hourlySlot = slot;
      _active!.inspectionType = 'hourly';
    }
    notifyListeners();
  }

  void markHourlySlotCompleted(int slot) {
    _active?.completedHourlySlots.add(slot);
    if ((_active?.hourlySlot ?? 0) < 8) {
      _active?.hourlySlot = slot + 1;
    }
    notifyListeners();
  }

  void syncCompletedSlots(List<int> slots) {
    if (_active == null) return;
    _active!.completedHourlySlots = Set<int>.from(slots);
    if (_active!.completedHourlySlots.isNotEmpty) {
      final maxDone =
          _active!.completedHourlySlots.reduce((a, b) => a > b ? a : b);
      if (maxDone >= _active!.hourlySlot && maxDone < 8) {
        _active!.hourlySlot = maxDone + 1;
      }
    }
    notifyListeners();
  }

  bool isHourlySlotUnlocked(int slot) {
    if (slot <= 1) return true;
    return completedHourlySlots.contains(slot - 1);
  }

  // ── Restore active report state from server ───────────────────────────────
  Future<void> restoreActiveReportState(
      Map<String, dynamic> setupStatus) async {
    if (setupStatus['shift_hours'] is int) {
      shiftHours = setupStatus['shift_hours'];
    } else if (setupStatus['total_hourly_slots'] is int) {
      shiftHours = setupStatus['total_hourly_slots'];
    }

    if (selectedPart == null && setupStatus['part_number'] != null) {
      selectedPart = {
        'id': setupStatus['part_id'],
        'part_number': setupStatus['part_number'],
        'part_name': setupStatus['part_name'] ?? setupStatus['part_number'],
      };
    }
    if (selectedMachine == null && setupStatus['machine_id'] != null) {
      selectedMachine = {'id': setupStatus['machine_id']};
    }

    // Restore per-operation slot data from operations[] array.
    final List<dynamic> ops = setupStatus['operations'] ?? [];
    for (final op in ops) {
      final tid = op['template_id'];
      if (tid == null) continue;

      // 1. Hourly drawer for this operation
      final hourlyKey = '${tid}_hourly';
      if (!_sessions.containsKey(hourlyKey)) {
        _sessions[hourlyKey] = OperationSession(operationKey: hourlyKey, inspectionType: 'hourly');
      }
      final opSess = _sessions[hourlyKey]!;
      final completedList = List<int>.from(op['completed_slots'] ?? []);
      opSess.completedHourlySlots = Set<int>.from(completedList);
      final nextSlot = (op['next_unlocked_slot'] as int?) ?? 1;
      opSess.hourlySlot = nextSlot;

      // Restore active session id for this op if available.
      if (op['active_session_id'] != null) {
        opSess.sessionId = op['active_session_id'].toString();
      }

      // 2. First piece drawer for this operation
      final fpKey = '${tid}_first_piece';
      if (op['first_piece_session_id'] != null) {
        if (!_sessions.containsKey(fpKey)) {
          _sessions[fpKey] = OperationSession(operationKey: fpKey, inspectionType: 'first_piece');
        }
        _sessions[fpKey]!.sessionId = op['first_piece_session_id'].toString();
      }
    }

    // If there is only one active operation, make it the active key.
    if (_activeOperationKey == null && _sessions.length == 1) {
      _activeOperationKey = _sessions.keys.first;
    }

    // Restore recorded measurements for the globally reported session.
    final String? globalSessionId = setupStatus['session_id']?.toString();
    if (globalSessionId != null && _active != null) {
      try {
        final doc = await ApiService.getSessionDetail(globalSessionId);
        if (doc != null) {
          if (doc['measurements'] is List) {
            _active!.recordedResults.clear();
            for (var m in doc['measurements'] as List) {
              final code = m['parameter_code'];
              if (code != null) {
                _active!.recordedResults[code.toString()] = m;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error restoring recorded measurements: $e');
      }
    }

    notifyListeners();
  }

  // ── Start Session ─────────────────────────────────────────────────────────
  Future<bool> startSession({
    String shift = 'I',
    String inspectionType = 'first_piece',
    int trial = 1,
    int hourlySlot = 1,
    String? parentId,
  }) async {
    selectedPart ??= {'part_number': 'FBT00222', 'part_name': 'POLY V PULLEY'};
    selectedMachine ??= {'id': 1, 'machine_code': 'CNC-01', 'name': 'CNC Turning Center'};

    // Ensure there's an active operation slot.
    if (_activeOperationKey == null) {
      final fallbackKey = '1_$inspectionType';
      switchActiveOperation(fallbackKey);
    }
    final op = _active!;

    isLoading = true;
    op.trialNumber = inspectionType == 'hourly' ? 0 : trial;
    op.hourlySlot = inspectionType == 'first_piece' ? 0 : hourlySlot;
    op.inspectionType = inspectionType;
    op.parentSessionId = parentId;
    this.shift = shift;
    notifyListeners();

    final mId = int.tryParse('${selectedMachine!['id']}') ?? 1;
    final tId = int.tryParse('${op.template?['id'] ?? 1}') ?? 1;
    final partNo = (selectedPart!['part_number'] ?? 'FBT00222').toString();

    final result = await ApiService.startSession(
      partNumber: partNo,
      machineId: mId,
      templateId: tId,
      inspectionType: inspectionType,
      shift: shift,
      trialNumber: trial,
      hourlySlot: inspectionType == 'first_piece' ? 0 : hourlySlot,
      parentSessionId: parentId,
    );

    isLoading = false;
    if (result != null &&
        (result.containsKey('session_id') || result.containsKey('id'))) {
      final newSessionId = result['session_id'] ?? result['id'];
      
      // If the session ID is different, we are starting a completely new session.
      // Clear out any old measurements that were stored locally.
      if (op.sessionId != newSessionId) {
        op.recordedResults.clear();
        op.pendingBatchValues.clear();
        op.currentParamIndex = 0;
      }
      
      op.sessionId = newSessionId;
      if (inspectionType == 'first_piece' && trial >= 1) {
        trialSessionIds[trial] = op.sessionId!;
      }
      saveCurrentState();
      notifyListeners();
      return true;
    } else {
      errorMessage = 'Failed to start inspection session';
      notifyListeners();
      return false;
    }
  }

  // ── Parameter navigation ──────────────────────────────────────────────────
  Map<String, dynamic>? get currentParameter {
    final op = _active;
    if (op == null || op.parameters.isEmpty ||
        op.currentParamIndex >= op.parameters.length) {
      return null;
    }
    return op.parameters[op.currentParamIndex];
  }

  void nextParameter() {
    if (_active != null &&
        _active!.currentParamIndex < _active!.parameters.length - 1) {
      _active!.currentParamIndex++;
      notifyListeners();
    }
  }

  void previousParameter() {
    if (_active != null && _active!.currentParamIndex > 0) {
      _active!.currentParamIndex--;
      notifyListeners();
    }
  }

  void advanceToNext() => nextParameter();
  void goToPrev() => previousParameter();
  void jumpToParam(int index) => goToParameter(index);

  void goToParameter(int index) {
    if (_active != null &&
        index >= 0 && index < _active!.parameters.length) {
      _active!.currentParamIndex = index;
      notifyListeners();
    }
  }

  // ── Measurement helpers ───────────────────────────────────────────────────
  bool isParamFilled(String code) => recordedResults.containsKey(code);
  String? getParamStatus(String code) => recordedResults[code]?['status'];
  dynamic getParamReading(String code) => recordedResults[code]?['value'];
  int get filledCount => recordedResults.length;
  int get remainingCount => parameters.length - recordedResults.length;

  // ── Submit single measurement ─────────────────────────────────────────────
  Future<Map<String, dynamic>?> submitMeasurement({
    required double value,
    required String voiceRawText,
    String method = 'voice',
  }) async {
    final param = currentParameter;
    final op = _active;
    if (param == null || op == null || op.sessionId == null) return null;

    isLoading = true;
    notifyListeners();

    final result = await ApiService.recordMeasurement(
      sessionId: op.sessionId!,
      parameterCode: param['parameter_code'],
      value: value,
      voiceRawText: voiceRawText,
      method: method,
      hourlySlot: op.inspectionType == 'first_piece' ? 0 : op.hourlySlot,
      inspectionType: op.inspectionType,
    );

    isLoading = false;
    if (result != null) {
      final resultMap = Map<String, dynamic>.from(result);
      if (!resultMap.containsKey('trial_number')) {
        resultMap['trial_number'] = op.trialNumber;
      }
      op.recordedResults[param['parameter_code']] = resultMap;
      setPendingValue(param['parameter_code'], value, voiceRawText,
          method: method);
      saveCurrentState();
      notifyListeners();
    }
    return result;
  }

  void setPendingValue(String code, double value, String voiceRawText,
      {String method = 'voice'}) {
    final op = _active;
    if (op == null) return;
    op.pendingBatchValues[code] = {
      'parameter_code': code,
      'measured_value': value,
      'voice_raw_text': voiceRawText,
      'method': method,
      'inspection_type': op.inspectionType,
      'hourly_slot': op.hourlySlot,
      'trial_number': op.trialNumber,
    };
    notifyListeners();
  }

  void clearPendingValues() {
    _active?.pendingBatchValues.clear();
    notifyListeners();
  }

  // ── Batch submit ──────────────────────────────────────────────────────────
  Future<Map<String, dynamic>?> submitBatchMeasurements() async {
    final op = _active;
    debugPrint('[PROVIDER] submitBatchMeasurements() called. sessionId=${op?.sessionId}');

    if (op == null || op.sessionId == null) {
      debugPrint('[PROVIDER] ERROR: sessionId is null — aborting batch submit.');
      return null;
    }

    isLoading = true;
    notifyListeners();

    var measurementsList = op.pendingBatchValues.values.map((item) => {
          ...item,
          'inspection_type': item['inspection_type'] ?? op.inspectionType,
          'hourly_slot': item['hourly_slot'] ?? op.hourlySlot,
          'trial_number': item['trial_number'] ?? op.trialNumber,
        }).toList();

    if (measurementsList.isEmpty && op.recordedResults.isNotEmpty) {
      debugPrint('[PROVIDER] pendingBatchValues empty, constructing from recordedResults...');
      for (var entry in op.recordedResults.entries) {
        final code = entry.key;
        final data = entry.value;
        final rawVal = data['measured_value'] ?? data['value'];
        if (rawVal != null) {
          final doubleVal = (rawVal is num)
              ? rawVal.toDouble()
              : (double.tryParse(rawVal.toString()) ?? 0.0);
          measurementsList.add({
            'parameter_code': code,
            'measured_value': doubleVal,
            'voice_raw_text': data['voice_raw_text'] ?? '',
            'method': data['method'] ?? 'voice',
            'inspection_type': op.inspectionType,
            'hourly_slot': op.hourlySlot,
            'trial_number': op.trialNumber,
          });
        }
      }
    }

    debugPrint('[PROVIDER] Submitting ${measurementsList.length} measurement(s): '
        '${measurementsList.map((m) => "${m['parameter_code']}=${m['measured_value']}").join(", ")}');

    try {
      final result = await ApiService.batchMeasure(
        sessionId: op.sessionId!,
        measurements: measurementsList,
      );
      debugPrint('[PROVIDER] batchMeasure API response: $result');

      if (result != null && result['results'] is List) {
        for (var r in (result['results'] as List)) {
          final code = r['parameter_code'];
          if (code != null) {
            op.recordedResults[code.toString()] = r;
            debugPrint('[PROVIDER] recordedResult saved: $code → status=${r['status']}');
          }
        }
        saveCurrentState();
      }
      return result;
    } catch (e, stack) {
      debugPrint('[PROVIDER] EXCEPTION in batchMeasure API call: $e');
      debugPrint('[PROVIDER] Stack trace: $stack');
      return null;
    } finally {
      isLoading = false;
      notifyListeners();
      debugPrint('[PROVIDER] isLoading reset to false.');
    }
  }

  // ── Complete session ──────────────────────────────────────────────────────
  Future<bool> completeSession() async {
    final op = _active;
    if (op == null || op.sessionId == null) return false;

    isLoading = true;
    notifyListeners();

    final currentSlot = op.hourlySlot;
    final success = await ApiService.completeSession(op.sessionId!);
    if (success) {
      // Clear only this operation's session ID — other ops remain intact.
      op.sessionId = null;
      op.parentSessionId = null;
      op.recordedResults.clear();
      op.pendingBatchValues.clear();
      if (op.inspectionType == 'hourly') {
        op.completedHourlySlots.add(currentSlot);
        if (op.hourlySlot < 8) {
          op.hourlySlot = op.hourlySlot + 1;
        }
      }
      await saveCurrentState();
    }
    isLoading = false;
    notifyListeners();
    return success;
  }

  // ── Finalize first piece ──────────────────────────────────────────────────
  Future<Map<String, dynamic>?> finalizeFirstPieceSession() async {
    final op = _active;
    if (op == null || op.sessionId == null) return null;

    isLoading = true;
    notifyListeners();

    final result = await ApiService.finalizeFirstPiece(op.sessionId!);
    if (result != null) {
      op.sessionId = null;
      op.parentSessionId = null;
      op.recordedResults.clear();
      op.pendingBatchValues.clear();
      await saveCurrentState();
    }
    isLoading = false;
    notifyListeners();
    return result;
  }
}
