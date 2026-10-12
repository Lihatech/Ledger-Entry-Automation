import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_saver/file_saver.dart';

class ApiService {
  // Fix: Use 10.0.2.2 on Android debug builds (emulator/physical device loopback to host).
  // `localhost` only works inside the iOS simulator; Android needs the host alias.
  static String baseUrl = _resolveBaseUrl();

  static String _resolveBaseUrl() {
    const envUrl = String.fromEnvironment('API_BASE_URL');
    if (envUrl.isNotEmpty) return envUrl;
    if (kDebugMode) {
      // kIsWeb guards Platform.isAndroid — dart:io Platform is unsupported on web.
      if (kIsWeb) return 'http://localhost:8000/api';
      return Platform.isAndroid
          ? 'http://10.0.2.2:8000/api'
          : 'http://localhost:8000/api';
    }
    return 'https://backend-production-343b4.up.railway.app/api';
  }

  // Secure storage for JWT tokens — EncryptedSharedPreferences on Android / Keychain on iOS
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Global callback triggered when silent token refresh fails on a 401 response.
  /// AuthProvider hooks into this to clear auth state and navigate to LoginScreen.
  static VoidCallback? onUnauthenticated;

  // Single-flight mutex lock variables for thread-safe token refreshing.
  // Prevents multiple concurrent 401 API requests from racing each other
  // and triggering duplicate refresh calls (which would invalidate rotated tokens).
  static bool _isRefreshing = false;
  static Completer<bool?>? _refreshCompleter;

  // ── Token Storage ──────────────────────────────────────────────────────────

  /// Read access token securely. Checks secure storage first, falls back to SharedPreferences.
  static Future<String?> getToken() async {
    try {
      final secure = await _secure.read(key: 'access_token');
      if (secure != null && secure.isNotEmpty) return secure;
    } catch (_) {}
    // Fallback: SharedPreferences (for backwards compatibility)
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('access_token');
  }

  /// Read refresh token securely. Checks secure storage first, falls back to SharedPreferences.
  static Future<String?> getRefreshToken() async {
    try {
      final secure = await _secure.read(key: 'refresh_token');
      if (secure != null && secure.isNotEmpty) return secure;
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('refresh_token');
  }

  /// Write access and refresh tokens to secure storage (and SharedPreferences for compat).
  static Future<void> _writeTokens(String access, String? refresh) async {
    try {
      await _secure.write(key: 'access_token', value: access);
      if (refresh != null && refresh.isNotEmpty) {
        await _secure.write(key: 'refresh_token', value: refresh);
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('access_token', access);
    if (refresh != null && refresh.isNotEmpty) {
      await prefs.setString('refresh_token', refresh);
    }
  }

  /// Clear all stored tokens from secure storage and SharedPreferences.
  static Future<void> clearTokens() async {
    try {
      await _secure.delete(key: 'access_token');
      await _secure.delete(key: 'refresh_token');
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
  }

  /// Silently refresh the access token using the stored refresh token.
  /// Returns:
  ///   true  -> Refresh succeeded (new access token saved)
  ///   false -> Token explicitly rejected by backend (400/401 invalid/blacklisted)
  ///   null  -> Network error or server unreachable (do NOT log out!)
  static Future<bool?> refreshToken([bool Function()? isCurrent]) async {
    if (isCurrent != null && !isCurrent()) return null;
    if (_isRefreshing) {
      return await _refreshCompleter!.future;
    }

    _isRefreshing = true;
    _refreshCompleter = Completer<bool?>();

    try {
      final refresh = await getRefreshToken();
      if (isCurrent != null && !isCurrent()) {
        _refreshCompleter!.complete(null);
        _isRefreshing = false;
        return null;
      }
      if (refresh == null || refresh.isEmpty) {
        debugPrint('[ApiService] No refresh token found.');
        _refreshCompleter!.complete(false);
        _isRefreshing = false;
        return false;
      }

      // Try refresh endpoint (using users/token/refresh/ or auth/refresh/)
      final response = await http.post(
        Uri.parse('$baseUrl/users/token/refresh/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh': refresh}),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final newAccess = data['access'] as String?;
        final newRefresh = data['refresh'] as String?;

        if (newAccess != null && newAccess.isNotEmpty) {
          if (isCurrent != null && !isCurrent()) {
            _refreshCompleter!.complete(null);
            _isRefreshing = false;
            return null;
          }
          await _writeTokens(newAccess, newRefresh ?? refresh);
          if (isCurrent != null && !isCurrent()) {
            _refreshCompleter!.complete(null);
            _isRefreshing = false;
            return null;
          }
          debugPrint('[ApiService] Token rotated & refreshed successfully.');
          _refreshCompleter!.complete(true);
          _isRefreshing = false;
          return true;
        }
      } else if (response.statusCode == 400 || response.statusCode == 401) {
        debugPrint('[ApiService] Refresh token rejected by server (HTTP ${response.statusCode}).');
        _refreshCompleter!.complete(false);
        _isRefreshing = false;
        return false;
      }
    } catch (e) {
      debugPrint('[ApiService] Token refresh network/timeout exception: $e');
      _refreshCompleter!.complete(null);
      _isRefreshing = false;
      return null;
    }

    _refreshCompleter!.complete(null);
    _isRefreshing = false;
    return null;
  }

  /// Build standard headers with Authorization Bearer token.
  static Future<Map<String, String>> _headers() async {
    final token = await getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Interceptor wrapper for authenticated HTTP requests.
  /// Automatically attaches headers, catches 401 responses, performs thread-safe silent token refresh,
  /// retries the request once if successful, or triggers logout if token is explicitly blacklisted/invalid.
  static Future<http.Response> authenticatedRequest(
    Future<http.Response> Function(Map<String, String> headers) requestFn,
  ) async {
    var headers = await _headers();
    var response = await requestFn(headers);

    if (response.statusCode == 401) {
      debugPrint('[ApiService] Received HTTP 401. Attempting silent token refresh...');
      final refreshStatus = await refreshToken();
      if (refreshStatus == true) {
        debugPrint('[ApiService] Token refresh succeeded. Retrying original request.');
        headers = await _headers();
        response = await requestFn(headers);
      } else if (refreshStatus == false) {
        debugPrint('[ApiService] Token refresh explicitly rejected. Triggering unauthenticated logout callback.');
        await clearTokens();
        onUnauthenticated?.call();
      }
      // If refreshStatus == null (network error), do NOT log out — keep local session intact
    }
    return response;
  }

  // ── Auth Endpoints ─────────────────────────────────────────────────────────

  // 1. Auth: Login
  static Future<Map<String, dynamic>> login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/users/login/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 35));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {'success': true, 'data': data};
      } else {
        final body = jsonDecode(response.body);
        return {
          'success': false,
          'message': body['detail'] ?? 'Login failed (${response.statusCode})'
        };
      }
    } catch (e) {
      return {'success': false, 'message': 'Cannot connect to backend server ($baseUrl). Please check network connection.'};
    }
  }

  /// POST /api/users/password-reset/request/ — request a reset email.
  ///
  /// The backend deliberately returns the same success message whether or not
  /// the email belongs to an account, preventing user enumeration.
  static Future<Map<String, dynamic>> requestPasswordReset(String email) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/users/password-reset/request/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email.trim()}),
      ).timeout(const Duration(seconds: 30));

      final body = jsonDecode(response.body);
      if (response.statusCode == 200) {
        return {
          'success': true,
          'message': body['message'] ??
              'If an account with that email exists, a password reset link has been sent.',
        };
      }

      return {
        'success': false,
        'message': body['error'] ?? body['detail'] ?? 'Unable to send reset link.',
      };
    } catch (_) {
      return {
        'success': false,
        'message': 'Unable to connect to the server. Please try again.',
      };
    }
  }

  /// Persist a successful login only after the caller confirms the request
  /// still belongs to the active authentication session.
  static Future<bool> persistLoginSession(
    Map<String, dynamic> data,
    bool Function()? isCurrent,
  ) async {
    if (isCurrent != null && !isCurrent()) return false;
    await _writeTokens(data['access'], data['refresh']);
    if (isCurrent != null && !isCurrent()) return false;
    if (data['user'] != null) {
      final prefs = await SharedPreferences.getInstance();
      if (isCurrent != null && !isCurrent()) return false;
      await prefs.setString('user_info', jsonEncode(data['user']));
    }
    return isCurrent == null || isCurrent();
  }

  // 1b. Auth: Logout
  static Future<void> logout() async {
    try {
      final refresh = await getRefreshToken();
      if (refresh != null && refresh.isNotEmpty) {
        final token = await getToken();
        await http.post(
          Uri.parse('$baseUrl/users/logout/'),
          headers: {
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'refresh': refresh}),
        ).timeout(const Duration(seconds: 10));
      }
    } catch (e) {
      debugPrint('[ApiService] Server logout notice: $e');
    } finally {
      await clearTokens();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('user_info');
      await prefs.remove('username');
    }
  }

  // ── Profile Endpoints ───────────────────────────────────────────────────────

  /// GET /api/users/me/ — fetch logged-in user profile details
  static Future<Map<String, dynamic>?> getProfile() async {
    try {
      final response = await authenticatedRequest((headers) => http.get(
        Uri.parse('$baseUrl/users/me/'),
        headers: headers,
      ));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      debugPrint('[ApiService] getProfile error: $e');
    }
    return null;
  }

  /// PATCH /api/users/me/ — update personal information (first_name, last_name, email, phone)
  static Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> data) async {
    try {
      final response = await authenticatedRequest((headers) => http.patch(
        Uri.parse('$baseUrl/users/me/'),
        headers: headers,
        body: jsonEncode(data),
      ));
      if (response.statusCode == 200) {
        return {'success': true, 'data': jsonDecode(response.body)};
      } else {
        final body = jsonDecode(response.body);
        return {'success': false, 'message': body['detail'] ?? body['message'] ?? 'Failed to update profile'};
      }
    } catch (e) {
      return {'success': false, 'message': 'Network error while updating profile'};
    }
  }

  /// POST /api/users/change-password/ — change user password
  static Future<Map<String, dynamic>> changePassword(String oldPassword, String newPassword) async {
    try {
      final response = await authenticatedRequest((headers) => http.post(
        Uri.parse('$baseUrl/users/change-password/'),
        headers: headers,
        body: jsonEncode({'old_password': oldPassword, 'new_password': newPassword}),
      ));
      if (response.statusCode == 200) {
        return {'success': true, 'message': 'Password updated successfully'};
      } else {
        final body = jsonDecode(response.body);
        final msg = body['old_password']?[0] ?? body['new_password']?[0] ?? body['detail'] ?? body['message'] ?? 'Failed to change password';
        return {'success': false, 'message': msg};
      }
    } catch (e) {
      return {'success': false, 'message': 'Network error while changing password'};
    }
  }

  // ── Domain Endpoints (Protected by authenticatedRequest) ───────────────────

  // 2. Machine QR / Code Lookup
  static Future<Map<String, dynamic>?> getMachineByCode(String code) async {
    final response = await authenticatedRequest((headers) => http.get(
      Uri.parse('$baseUrl/machines/scan/$code/'),
      headers: headers,
    ));

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    return null;
  }

  // 2b. Get All Floor Machines
  static Future<List<dynamic>> getMachines() async {
    try {
      final response = await authenticatedRequest((headers) => http.get(
        Uri.parse('$baseUrl/machines/'),
        headers: headers,
      ));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        List<dynamic> result = [];
        if (decoded is List) result = decoded;
        if (decoded is Map && decoded['results'] != null) result = decoded['results'];
        
        if (result.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cached_machines', jsonEncode(result));
        }
        return result;
      }
    } catch (_) {}
    
    // Fallback to cache on network failure
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedStr = prefs.getString('cached_machines');
      if (cachedStr != null && cachedStr.isNotEmpty) {
        return jsonDecode(cachedStr) as List<dynamic>;
      }
    } catch (_) {}

    return [];
  }

  // 3. Get Parts by Machine
  static Future<List<dynamic>> getPartsByMachine(int machineId) async {
    final response = await authenticatedRequest((headers) => http.get(
      Uri.parse('$baseUrl/parts/?machine=$machineId'),
      headers: headers,
    ));

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is List) return decoded;
      if (decoded is Map && decoded['results'] != null) return decoded['results'];
    }
    return [];
  }

  // 4. Get Templates by Part
  static Future<List<dynamic>> getTemplatesByPart(String partNumber) async {
    final response = await authenticatedRequest((headers) => http.get(
      Uri.parse('$baseUrl/parts/$partNumber/templates/'),
      headers: headers,
    ));

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is List) return decoded;
      if (decoded is Map && decoded['results'] != null) return decoded['results'];
      if (decoded is Map) return [decoded];
    }
    return [];
  }

  // 5. Get Parameters for a Template
  static Future<List<dynamic>> getParameters(int templateId) async {
    final response = await authenticatedRequest((headers) => http.get(
      Uri.parse('$baseUrl/parts/templates/$templateId/parameters/'),
      headers: headers,
    ));

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is List) return decoded;
      if (decoded is Map && decoded['results'] != null) return decoded['results'];
    }
    return [];
  }

  // 5b. Get Process Parameters for a Template (Setup Approval Only)
  static Future<List<dynamic>> getProcessParameters(int templateId) async {
    final response = await authenticatedRequest((headers) => http.get(
      Uri.parse('$baseUrl/parts/templates/$templateId/process-parameters/'),
      headers: headers,
    ));

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is List) return decoded;
      if (decoded is Map && decoded['results'] != null) return decoded['results'];
    }
    return [];
  }

  // 6. Start Inspection Session
  static Future<Map<String, dynamic>?> startSession({
    required String partNumber,
    required int machineId,
    required int templateId,
    required String inspectionType,
    required String shift,
    int trialNumber = 1,
    int hourlySlot = 1,
    String? parentSessionId,
  }) async {
    final response = await authenticatedRequest((headers) => http.post(
      Uri.parse('$baseUrl/inspections/start/'),
      headers: headers,
      body: jsonEncode({
        'part_number': partNumber,
        'machine_id': machineId,
        'template_id': templateId,
        'inspection_type': inspectionType,
        'shift': shift,
        'trial_number': trialNumber,
        'hourly_slot': hourlySlot,
        'parent_session_id': parentSessionId,
      }),
    ));

    if (response.statusCode == 201 || response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    return null;
  }

  // Fetch session detail document
  static Future<Map<String, dynamic>?> getSessionDetail(String sessionId) async {
    try {
      final response = await authenticatedRequest((headers) => http.get(
        Uri.parse('$baseUrl/inspections/$sessionId/'),
        headers: headers,
      ));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (_) {}
    return null;
  }

  // Download PDF Report file for Session
  static Future<String?> downloadSessionPDF(
    String sessionId, {
    String? partNumber,
    String? machineCode,
    String? shift,
  }) async {
    try {
      final response = await authenticatedRequest((headers) => http.get(
        Uri.parse('$baseUrl/inspections/$sessionId/pdf/'),
        headers: headers,
      ));

      if (response.statusCode == 200) {
        // Check if server sent a filename in Content-Disposition
        String? filename;
        final disposition = response.headers['content-disposition'];
        if (disposition != null && disposition.contains('filename=')) {
          final match = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
          if (match != null && match.group(1) != null) {
            filename = match.group(1)!.trim();
          }
        }

        // Fallback to dynamic selection-aware name
        if (filename == null || filename.isEmpty) {
          final dateStr = DateTime.now().toIso8601String().substring(0, 10);
          final cleanMc = (machineCode ?? 'MCH').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          final cleanPart = (partNumber ?? 'PART').replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          final cleanShift = shift ?? 'A';
          filename = 'FirstPiece_Report_${dateStr}_Shift_${cleanShift}_${cleanMc}_${cleanPart}.pdf';
        }

        if (kIsWeb) {
          await FileSaver.instance.saveFile(
            name: filename.replaceAll('.pdf', ''),
            bytes: response.bodyBytes,
            ext: 'pdf',
            mimeType: MimeType.pdf,
          );
          return 'web_downloaded';
        } else {
          final dir = await getApplicationDocumentsDirectory();
          final file = File('${dir.path}/$filename');
          await file.writeAsBytes(response.bodyBytes);
          return file.path;
        }
      }
    } catch (e) {
      debugPrint('[API] PDF Download error: $e');
    }
    return null;
  }

  // Fetch list of inspection sessions
  static Future<List<dynamic>> getSessions({String? machineCode}) async {
    try {
      final query = machineCode != null ? '?machine=$machineCode' : '';
      final response = await authenticatedRequest((headers) => http.get(
        Uri.parse('$baseUrl/inspections/$query'),
        headers: headers,
      ));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['results'] != null) return decoded['results'];
      }
    } catch (_) {}
    return [];
  }

  // Fetch 1st Piece Setup Approval Status for Machine
  static Future<Map<String, dynamic>> checkSetupApproved(int machineId, {String? date}) async {
    try {
      final query = date != null ? '&date=$date' : '';
      final response = await authenticatedRequest((headers) => http.get(
        Uri.parse('$baseUrl/inspections/setup-status/?machine=$machineId$query'),
        headers: headers,
      ));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (_) {}
    return {'is_setup_approved': false};
  }

  // Fetch active supervisor rejections for operator
  static Future<List<dynamic>> getRejections() async {
    final response = await authenticatedRequest((headers) => http.get(
      Uri.parse('$baseUrl/inspections/rejections/'),
      headers: headers,
    ));

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is List) return decoded;
      if (decoded is Map && decoded['results'] != null) return decoded['results'];
    }
    return [];
  }

  // 7. Transcribe Voice Audio File
  static Future<Map<String, dynamic>> transcribeVoice(String filePath) async {
    final sw = Stopwatch()..start();
    final file = File(filePath);
    final fileSizeKb = file.existsSync() ? (file.lengthSync() / 1024).toStringAsFixed(2) : '0';

    final token = await getToken();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/voice/transcribe/'),
    );
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    request.files.add(await http.MultipartFile.fromPath('audio_file', filePath));
    final streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 401) {
      final refreshed = await refreshToken();
      if (refreshed == true) {
        final newToken = await getToken();
        final retryReq = http.MultipartRequest('POST', Uri.parse('$baseUrl/voice/transcribe/'));
        if (newToken != null) retryReq.headers['Authorization'] = 'Bearer $newToken';
        retryReq.files.add(await http.MultipartFile.fromPath('audio_file', filePath));
        final retryStream = await retryReq.send();
        response = await http.Response.fromStream(retryStream);
      } else {
        await clearTokens();
        onUnauthenticated?.call();
      }
    }

    sw.stop();
    print('[PERF CLIENT] HTTP POST /voice/transcribe/ took ${sw.elapsedMilliseconds} ms (File size: $fileSizeKb KB)');
    debugPrint('[PERF CLIENT] HTTP POST /voice/transcribe/ took ${sw.elapsedMilliseconds} ms (File size: $fileSizeKb KB)');

    if (response.statusCode == 202 || response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) {
        data['client_upload_ms'] = sw.elapsedMilliseconds;
      }
      return data;
    } else {
      return {'error': 'Failed to transcribe audio'};
    }
  }

  // 7b. Poll transcription job status
  static Future<Map<String, dynamic>> checkTranscriptionStatus(String jobId) async {
    final sw = Stopwatch()..start();
    final response = await authenticatedRequest((headers) => http.get(
      Uri.parse('$baseUrl/voice/status/$jobId/'),
      headers: headers,
    ));
    sw.stop();

    if (response.statusCode == 200 || response.statusCode == 500) {
      final data = jsonDecode(response.body);
      print('[PERF CLIENT] GET /voice/status/$jobId/ -> Status: ${data['status']} (${sw.elapsedMilliseconds} ms)');
      return data;
    }
    print('[PERF CLIENT] GET /voice/status/$jobId/ -> Status: processing (${sw.elapsedMilliseconds} ms)');
    return {'status': 'processing'};
  }

  // 8. Transcribe Text / Parse Measurement Directly
  static Future<Map<String, dynamic>> parseText(String text) async {
    final sw = Stopwatch()..start();
    final response = await authenticatedRequest((headers) => http.post(
      Uri.parse('$baseUrl/voice/parse/'),
      headers: headers,
      body: jsonEncode({'text': text}),
    ));
    sw.stop();

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      print('[PERF CLIENT] POST /voice/parse/ ("$text") -> ${data['parsed_value']} (${sw.elapsedMilliseconds} ms)');
      return data;
    }
    return {'is_parseable': false};
  }

  // 9. Record Measurement
  static Future<Map<String, dynamic>?> recordMeasurement({
    required String sessionId,
    required String parameterCode,
    required double value,
    String voiceRawText = '',
    String method = 'voice',
    int? hourlySlot,
    String? inspectionType,
  }) async {
    final sw = Stopwatch()..start();
    final response = await authenticatedRequest((headers) => http.post(
      Uri.parse('$baseUrl/inspections/$sessionId/measure/'),
      headers: headers,
      body: jsonEncode({
        'parameter_code': parameterCode,
        'measured_value': value,
        'voice_raw_text': voiceRawText,
        'method': method,
        'hourly_slot': hourlySlot,
        'inspection_type': inspectionType,
      }),
    ));
    sw.stop();
    print('[PERF CLIENT] POST /inspections/measure/ ($parameterCode = $value) took ${sw.elapsedMilliseconds} ms [HTTP ${response.statusCode}]');

    // Backend returns 202 Accepted for async queued measurements (fast path)
    // and 200 OK for idempotent cache hits. Both are success.
    if (response.statusCode == 200 || response.statusCode == 202) {
      return jsonDecode(response.body);
    }
    return null;
  }

  // 9b. Batch Measure (All parameters for a piece submitted together)
  static Future<Map<String, dynamic>?> batchMeasure({
    required String sessionId,
    required List<Map<String, dynamic>> measurements,
  }) async {
    final sw = Stopwatch()..start();
    final response = await authenticatedRequest((headers) => http.post(
      Uri.parse('$baseUrl/inspections/$sessionId/batch-measure/'),
      headers: headers,
      body: jsonEncode({
        'measurements': measurements,
      }),
    ));
    sw.stop();
    print('[PERF CLIENT] POST /inspections/batch-measure/ (${measurements.length} fields) took ${sw.elapsedMilliseconds} ms [HTTP ${response.statusCode}]');

    // Backend returns 202 Accepted for async queued measurements (fast path)
    // and 200 OK for idempotent cache hits. Both are success.
    if (response.statusCode == 200 || response.statusCode == 202) {
      return jsonDecode(response.body);
    }
    return null;
  }

  // 10. Complete Session
  static Future<bool> completeSession(String sessionId) async {
    final response = await authenticatedRequest((headers) => http.post(
      Uri.parse('$baseUrl/inspections/$sessionId/complete/'),
      headers: headers,
    ));

    return response.statusCode == 200;
  }

  // 11. Finalize First Piece Session (Inspector Workflow)
  static Future<Map<String, dynamic>?> finalizeFirstPiece(String sessionId) async {
    final response = await authenticatedRequest((headers) => http.post(
      Uri.parse('$baseUrl/inspections/$sessionId/finalize/'),
      headers: headers,
    ));

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    return null;
  }

  // 12. Get Users
  static Future<List<dynamic>> getUsers({String? role}) async {
    try {
      final url = (role != null && role.isNotEmpty)
          ? '$baseUrl/users/?role=$role'
          : '$baseUrl/users/';
      final response = await authenticatedRequest((headers) => http.get(
        Uri.parse(url),
        headers: headers,
      ));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['results'] != null) return decoded['results'];
      }
    } catch (_) {}
    return [];
  }

  // 13. Submit Setup Approval
  static Future<Map<String, dynamic>?> submitSetupApproval({
    required int templateId,
    required int machineId,
    required String partNumber,
    required List<Map<String, dynamic>> processParamEntries,
    required String inspectorName,
  }) async {
    try {
      final response = await authenticatedRequest((headers) => http.post(
        Uri.parse('$baseUrl/inspections/setup-approval/'),
        headers: headers,
        body: jsonEncode({
          'template_id': templateId,
          'machine_id': machineId,
          'part_number': partNumber,
          'process_param_entries': processParamEntries,
          'inspector_name': inspectorName,
        }),
      ));
      if (response.statusCode == 200 || response.statusCode == 201) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      debugPrint('[API] submitSetupApproval error: $e');
    }
    return null;
  }

  // 14. Get Setup Approval Data
  static Future<Map<String, dynamic>?> getSetupApprovalData(int templateId, int machineId, {String? date}) async {
    try {
      final query = date != null ? '&date=$date' : '';
      final response = await authenticatedRequest((headers) => http.get(
        Uri.parse('$baseUrl/inspections/setup-approval/?machine=$machineId$query'),
        headers: headers,
      ));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      debugPrint('[API] getSetupApprovalData error: $e');
    }
    return null;
  }

  // 15. Submit Daily Production Report
  static Future<Map<String, dynamic>> submitDailyProductionReport(Map<String, dynamic> reportData) async {
    try {
      final response = await authenticatedRequest((headers) => http.post(
        Uri.parse('$baseUrl/inspections/daily-production-reports/'),
        headers: headers,
        body: jsonEncode(reportData),
      ));
      if (response.statusCode == 200 || response.statusCode == 201) {
        return {'success': true, 'data': jsonDecode(response.body)};
      } else {
        final body = jsonDecode(response.body);
        String msg = 'Failed to submit report (${response.statusCode})';
        if (body is Map) {
          final errs = <String>[];
          body.forEach((key, val) {
            if (val is List) {
              errs.add(val.join(', '));
            } else {
              errs.add(val.toString());
            }
          });
          if (errs.isNotEmpty) msg = errs.join('\n');
        }
        return {'success': false, 'message': msg};
      }
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  // ── Tasks ────────────────────────────────────────────────────────────────────
  static Future<List<dynamic>> getTasks() async {
    final response = await authenticatedRequest(
      (headers) => http.get(Uri.parse('$baseUrl/tasks/'), headers: headers),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data is List ? data : (data['results'] ?? []);
    }
    throw Exception('Failed to load tasks (status ${response.statusCode})');
  }

  static Future<bool> acceptTask(int taskId) async {
    final response = await authenticatedRequest(
      (headers) => http.post(
        Uri.parse('$baseUrl/tasks/$taskId/accept/'),
        headers: headers,
        body: jsonEncode({}),
      ),
    );
    return response.statusCode == 200;
  }

  static Future<bool> completeTask(int taskId) async {
    final response = await authenticatedRequest(
      (headers) => http.post(
        Uri.parse('$baseUrl/tasks/$taskId/complete/'),
        headers: headers,
        body: jsonEncode({}),
      ),
    );
    return response.statusCode == 200;
  }

  static Future<bool> flagTaskIssue(int taskId, String issueDescription) async {
    final response = await authenticatedRequest(
      (headers) => http.post(
        Uri.parse('$baseUrl/tasks/$taskId/flag_issue/'),
        headers: headers,
        body: jsonEncode({'issue_description': issueDescription}),
      ),
    );
    return response.statusCode == 200;
  }

  // ── JH (Autonomous Maintenance) Inspections ─────────────────────────────────
  static Future<List<dynamic>> getJhChecklistItems({dynamic machineId}) async {
    try {
      final uri = (machineId != null && machineId.toString().isNotEmpty)
          ? Uri.parse('$baseUrl/inspections/jh/items/?machine=$machineId')
          : Uri.parse('$baseUrl/inspections/jh/items/');
      final response = await authenticatedRequest(
        (headers) => http.get(uri, headers: headers),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['results'] ?? [];
      }
    } catch (e) {
      debugPrint('[API] getJhChecklistItems error: $e');
    }
    return [];
  }

  static Future<Map<String, dynamic>> submitJhInspection(Map<String, dynamic> payload) async {
    try {
      final response = await authenticatedRequest(
        (headers) => http.post(
          Uri.parse('$baseUrl/inspections/jh/submit/'),
          headers: headers,
          body: jsonEncode(payload),
        ),
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        return {'success': true, 'data': jsonDecode(response.body)};
      } else {
        final body = jsonDecode(response.body);
        String msg = 'Failed to submit JH inspection (${response.statusCode})';
        if (body is Map && body.containsKey('error')) {
          msg = body['error'];
        }
        return {'success': false, 'message': msg};
      }
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  static Future<List<dynamic>> getJhInspectionHistory({int? machineId, String? date}) async {
    try {
      final queryParams = <String, String>{};
      if (machineId != null) queryParams['machine'] = machineId.toString();
      if (date != null) queryParams['date'] = date;

      final uri = Uri.parse('$baseUrl/inspections/jh/reports/').replace(queryParameters: queryParams);
      final response = await authenticatedRequest((headers) => http.get(uri, headers: headers));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['results'] ?? [];
      }
    } catch (e) {
      debugPrint('[API] getJhInspectionHistory error: $e');
    }
    return [];
  }
}

