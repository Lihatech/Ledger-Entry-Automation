import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

/// AuthProvider — manages user authentication state, silent token refresh,
/// persistent login, and server-side token blacklisting on logout.
class AuthProvider with ChangeNotifier {
  bool _isAuthenticated = false;
  String? _username;
  String? _userRole;
  Set<String> _permissions = {};
  String? _assignedShift;
  String? _fullName;
  String? _firstName;
  String? _lastName;
  String? _email;
  String? _phone;
  String? _employeeId;
  String? _plantName;
  String? _profilePhotoUrl;
  bool _isLoading = true;
  bool _roleVerified = false;
  int _sessionGeneration = 0;

  bool get isAuthenticated => _isAuthenticated;
  int? _userId;
  String? get username => _username;
  String? get userId => _userId?.toString();
  String? get userRole => _userRole;
  String get assignedShift => _assignedShift ?? 'ALL';
  bool get isShiftLocked => _assignedShift != null && _assignedShift != 'ALL';
  bool canAccessShift(String shift) =>
      _assignedShift == null ||
      _assignedShift == 'ALL' ||
      _assignedShift == shift;
  String? get fullName => _fullName;
  String? get firstName => _firstName;
  String? get lastName => _lastName;
  String? get email => _email;
  String? get phone => _phone;
  String? get employeeId => _employeeId;
  String? get plantName => _plantName;
  String? get profilePhotoUrl => _profilePhotoUrl;
  bool get isLoading => _isLoading;

  bool hasAccess(String key) => _permissions.contains(key);
  bool _isApprovedMobileRole(String? role) =>
      role == 'operator' || role == 'inspector';
  // Mobile access is role-based. Dashboard permissions must not turn a
  // supervisor, quality engineer, or HR user into a mobile operator.
  bool get isOperator => _userRole == 'operator';
  // Role identity is intentional here: Quality Engineer and Inspector may
  // share quality permissions, but only Inspector gets the mobile workflow.
  bool get isInspector => _userRole == 'inspector';
  bool get isMobileRole => _roleVerified && _isApprovedMobileRole(_userRole);
  bool get isQualityEngineer => _userRole == 'quality_engineer';
  bool get isSupervisor => hasAccess('quality.inspections.review');

  String? _lastErrorMessage;
  String? get lastErrorMessage => _lastErrorMessage;

  AuthProvider() {
    // Hook up ApiService 401 failure callback to trigger automatic logout
    ApiService.onUnauthenticated = forceLogout;
    checkLoginStatus();
  }

  /// Bootstrap auth state on app start:
  /// Reads stored access/refresh tokens and restores local session immediately.
  /// Silently attempts a background token refresh to keep session warm.
  /// ONLY forces logout if the backend explicitly rejects the refresh token (HTTP 400/401).
  Future<void> checkLoginStatus() async {
    final bootstrapGeneration = _sessionGeneration;
    _isLoading = true;
    notifyListeners();

    try {
      final token = await ApiService.getToken();
      final refreshToken = await ApiService.getRefreshToken();
      final prefs = await SharedPreferences.getInstance();
      if (bootstrapGeneration != _sessionGeneration) return;

      if ((token != null && token.isNotEmpty) ||
          (refreshToken != null && refreshToken.isNotEmpty)) {
        // Restore local user session immediately so app opens home screen instantly
        _username = prefs.getString('username') ?? 'Operator';
        _roleVerified = false;
        final userInfoStr = prefs.getString('user_info');
        if (userInfoStr != null) {
          try {
            final info = jsonDecode(userInfoStr);
            _username =
                prefs.getString('username') ??
                info['username']?.toString() ??
                _username;
            _userRole = info['role']?.toString();
            _roleVerified = _isApprovedMobileRole(_userRole);
            _permissions = Set<String>.from(info['permissions'] ?? []);
            _assignedShift = info['assigned_shift'] ?? 'ALL';
            _userId = info['id'];
            _fullName =
                (info['full_name'] != null &&
                    info['full_name'].toString().isNotEmpty)
                ? info['full_name']
                : _username;
          } catch (_) {
            _userRole = null;
            _permissions = {};
            _assignedShift = 'ALL';
          }
        } else {
          _userRole = null;
          _permissions = {};
          _assignedShift = 'ALL';
        }
        _isAuthenticated = true;
        debugPrint(
          '[AuthProvider] Restored local session for $_username (role: $_userRole, shift: $_assignedShift)',
        );

        // Silently attempt background refresh to get fresh access token & rotate refresh token
        if (bootstrapGeneration != _sessionGeneration) return;
        final refreshStatus = await ApiService.refreshToken(
          () => bootstrapGeneration == _sessionGeneration,
        );
        if (bootstrapGeneration != _sessionGeneration) return;
        if (refreshStatus == false) {
          // Explicitly rejected by server (expired/blacklisted/revoked) -> force logout
          debugPrint(
            '[AuthProvider] Refresh token explicitly rejected by server. Requiring login.',
          );
          await ApiService.clearTokens();
          if (bootstrapGeneration != _sessionGeneration) return;
          _isAuthenticated = false;
          _username = null;
          _userId = null;
          _userRole = null;
          _permissions = {};
          _assignedShift = null;
          _fullName = null;
        } else if (refreshStatus == true) {
          // Refresh succeeded — re-decode the new JWT to re-persist user_info.
          // Protects against OS wiping SharedPreferences while SecureStorage survives.
          try {
            final newToken = await ApiService.getToken();
            if (newToken != null) {
              final parts = newToken.split('.');
              if (parts.length == 3) {
                final paddedPayload = base64Url.normalize(parts[1]);
                final payloadBytes = base64Url.decode(paddedPayload);
                final payload =
                    jsonDecode(utf8.decode(payloadBytes))
                        as Map<String, dynamic>;
                final roleFromJwt = payload['role']?.toString();
                final shiftFromJwt =
                    payload['assigned_shift']?.toString() ??
                    _assignedShift ??
                    'ALL';
                final idFromJwt = payload['user_id'] != null
                    ? int.tryParse(payload['user_id'].toString())
                    : _userId;
                _userRole = roleFromJwt;
                _roleVerified = _isApprovedMobileRole(roleFromJwt);
                _assignedShift = shiftFromJwt;
                _userId = idFromJwt;
                final prefs = await SharedPreferences.getInstance();
                if (bootstrapGeneration != _sessionGeneration) return;
                await prefs.setString(
                  'user_info',
                  jsonEncode({
                    'id': idFromJwt,
                    'role': roleFromJwt,
                    'permissions': _permissions.toList(),
                    'assigned_shift': shiftFromJwt,
                    'full_name': _fullName ?? _username,
                  }),
                );
                if (bootstrapGeneration != _sessionGeneration) return;
                debugPrint(
                  '[AuthProvider] Re-persisted user_info from JWT (role: $roleFromJwt, shift: $shiftFromJwt).',
                );
              }
            }
          } catch (e) {
            debugPrint('[AuthProvider] JWT payload decode warning: $e');
          }
        }
        // Fetch latest profile details from backend
        await refreshProfile();
        if (bootstrapGeneration != _sessionGeneration) return;
        // If refreshStatus == null -> network timeout/error, local session STAYS LOGGED IN!
      } else {
        _isAuthenticated = false;
        _username = null;
        _userId = null;
        _userRole = null;
        _roleVerified = false;
        _permissions = {};
        _assignedShift = null;
        _fullName = null;
      }
    } catch (e) {
      debugPrint('[AuthProvider] checkLoginStatus error: $e');
    } finally {
      if (bootstrapGeneration == _sessionGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Re-fetch current user profile details from backend and update local provider state
  Future<void> refreshProfile() async {
    final requestGeneration = _sessionGeneration;
    final requestUserId = _userId;
    try {
      final profile = await ApiService.getProfile();
      if (profile != null &&
          requestGeneration == _sessionGeneration &&
          _isAuthenticated &&
          (requestUserId == null || requestUserId == _userId)) {
        _username = profile['username'] ?? _username;
        _firstName = profile['first_name'] ?? '';
        _lastName = profile['last_name'] ?? '';
        _email = profile['email'] ?? '';
        _phone = profile['phone'] ?? '';
        _employeeId = profile['employee_id'] ?? '';
        _plantName = profile['plant_name'] ?? '';
        _profilePhotoUrl = profile['profile_photo_url'];
        _userRole = profile['role']?.toString();
        _roleVerified = _isApprovedMobileRole(_userRole);
        _permissions = Set<String>.from(profile['permissions'] ?? []);
        _assignedShift = profile['assigned_shift'] ?? _assignedShift ?? 'ALL';
        if (profile['id'] != null) {
          _userId = int.tryParse(profile['id'].toString());
        }

        final first = _firstName ?? '';
        final last = _lastName ?? '';
        final full = '$first $last'.trim();
        _fullName = full.isNotEmpty ? full : _username;

        final prefs = await SharedPreferences.getInstance();
        if (requestGeneration != _sessionGeneration ||
            !_isAuthenticated ||
            (requestUserId != null && requestUserId != _userId)) {
          return;
        }
        await prefs.setString(
          'user_info',
          jsonEncode({
            'id': _userId,
            'role': _userRole,
            'permissions': _permissions.toList(),
            'assigned_shift': _assignedShift,
            'full_name': _fullName,
          }),
        );

        notifyListeners();
      }
    } catch (e) {
      debugPrint('[AuthProvider] refreshProfile error: $e');
    }
  }

  /// Change the official current shift for an operator or inspector.
  Future<Map<String, dynamic>> changeAssignedShift(String shift) async {
    final result = await ApiService.changeMyShift(shift);
    if (result['success'] != true) return result;

    final data = Map<String, dynamic>.from(result['data'] ?? {});
    _assignedShift = data['assigned_shift']?.toString() ?? shift;
    final prefs = await SharedPreferences.getInstance();
    final stored = <String, dynamic>{
      'id': _userId,
      'role': _userRole,
      'permissions': _permissions.toList(),
      'assigned_shift': _assignedShift,
      'full_name': _fullName,
    };
    await prefs.setString('user_info', jsonEncode(stored));
    notifyListeners();
    return result;
  }

  /// User explicit login with username & password.
  Future<bool> login(String username, String password) async {
    final requestGeneration = ++_sessionGeneration;
    _isLoading = true;
    _lastErrorMessage = null;
    notifyListeners();

    try {
      final result = await ApiService.login(username, password);

      if (requestGeneration != _sessionGeneration) return false;

      if (result['success'] == true) {
        final data = Map<String, dynamic>.from(result['data'] ?? {});
        final persisted = await ApiService.persistLoginSession(
          data,
          () => requestGeneration == _sessionGeneration,
        );
        if (!persisted || requestGeneration != _sessionGeneration) return false;

        final prefs = await SharedPreferences.getInstance();
        if (requestGeneration != _sessionGeneration) return false;
        await prefs.setString('username', username);
        if (requestGeneration != _sessionGeneration) return false;

        _isLoading = false;
        _isAuthenticated = true;
        _username = username;

        final userData = result['data']?['user'];
        if (userData != null) {
          _userRole = userData['role']?.toString();
          _roleVerified = _isApprovedMobileRole(_userRole);
          _permissions = Set<String>.from(userData['permissions'] ?? []);
          _assignedShift = userData['assigned_shift'] ?? 'ALL';
          if (userData['id'] != null) {
            _userId = int.tryParse(userData['id'].toString());
          }
          _fullName =
              (userData['full_name'] != null &&
                  userData['full_name'].toString().isNotEmpty)
              ? userData['full_name']
              : username;
        } else {
          _userRole = null;
          _roleVerified = false;
          _permissions = {};
          _assignedShift = 'ALL';
        }
        notifyListeners();
        return true;
      } else {
        _isLoading = false;
        _lastErrorMessage = result['message'] ?? 'Invalid username or password';
        notifyListeners();
        return false;
      }
    } catch (e) {
      if (requestGeneration != _sessionGeneration) return false;
      _isLoading = false;
      _lastErrorMessage = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Explicit user logout: calls backend to blacklist refresh token,
  /// deletes secure storage keys, clears local auth state.
  Future<void> logout() async {
    _sessionGeneration++;
    _isLoading = true;
    notifyListeners();

    await ApiService.logout();

    _isAuthenticated = false;
    _username = null;
    _userId = null;
    _userRole = null;
    _roleVerified = false;
    _permissions = {};
    _fullName = null;
    _isLoading = false;
    notifyListeners();
  }

  /// Triggered automatically when an unauthenticated 401 cannot be refreshed.
  /// Updates UI state synchronously first so navigation happens immediately,
  /// then clears tokens in the background (fire-and-forget is safe here).
  void forceLogout() {
    // Update auth state and notify listeners immediately so the UI
    // (router/splash) can react without waiting for the async token clear.
    _sessionGeneration++;
    _isAuthenticated = false;
    _username = null;
    _userId = null;
    _userRole = null;
    _roleVerified = false;
    _permissions = {};
    _fullName = null;
    _isLoading = false;
    notifyListeners();
    // Clear tokens in background — non-critical if it's slightly delayed.
    ApiService.clearTokens();
  }
}
