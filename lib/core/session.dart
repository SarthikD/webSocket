import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../services/google_sign_in_service.dart';
import '../services/subscription_controller.dart';
import '../socket/haven_socket.dart';
import 'api_client.dart';

/// Holds tokens and the current user, persisted in secure storage.
///
/// The access token is refreshed shortly before it expires; the new token is
/// pushed to the live socket with `auth:refresh` and used for reconnects.
class Session extends ChangeNotifier {
  Session._();
  static final Session instance = Session._();

  static const _kAccess = 'accessToken';
  static const _kRefresh = 'refreshToken';
  static const _kUser = 'user';
  static const _kDeviceId = 'deviceId';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String? _accessToken;
  String? _refreshToken;
  Map<String, dynamic>? _user;
  late String _deviceId;
  Timer? _refreshTimer;
  Future<bool>? _refreshing;

  String? get accessToken => _accessToken;
  Map<String, dynamic>? get user => _user;
  String? get userId => _user?['id']?.toString() ?? _jwtClaims(_accessToken)?['sub']?.toString();
  String get deviceId => _deviceId;
  bool get isLoggedIn => _accessToken != null;

  /// Google accounts start without a phone; SOS needs one.
  bool get needsPhone => isLoggedIn && _user != null && _user!['phoneNumber'] == null;

  Future<void> load() async {
    _accessToken = await _storage.read(key: _kAccess);
    _refreshToken = await _storage.read(key: _kRefresh);
    final rawUser = await _storage.read(key: _kUser);
    _user = rawUser == null ? null : Map<String, dynamic>.from(jsonDecode(rawUser));

    final storedDeviceId = await _storage.read(key: _kDeviceId);
    _deviceId = storedDeviceId ?? const Uuid().v4();
    if (storedDeviceId == null) await _storage.write(key: _kDeviceId, value: _deviceId);

    if (_accessToken != null) {
      if (_isExpired(_accessToken!) && !await refresh()) return;
      _scheduleRefresh();
    }
  }

  /// Re-reads the user from `GET /auth/me` so a stale stored user (e.g.
  /// phone attached on another device) does not misroute. Best effort.
  Future<void> syncUser() async {
    if (!isLoggedIn) return;
    try {
      final data = await ApiClient.instance.me();
      final user = data['user'] is Map ? Map<String, dynamic>.from(data['user']) : data;
      if (user.isEmpty) return;
      _user = user;
      await _storage.write(key: _kUser, value: jsonEncode(_user));
      notifyListeners();
    } catch (e) {
      debugPrint('syncUser failed: $e');
    }
  }

  /// Stores the result of `POST /auth/verify-otp` or `POST /auth/google`.
  Future<void> signIn(Map<String, dynamic> verifyData) async {
    await _setTokens(
      verifyData['accessToken'] as String,
      verifyData['refreshToken'] as String?,
    );
    final user = verifyData['user'];
    _user = user is Map ? Map<String, dynamic>.from(user) : null;
    await _storage.write(key: _kUser, value: _user == null ? null : jsonEncode(_user));
    notifyListeners();
  }

  Future<void> signOut() async {
    // RevenueCat logOut before the tokens are cleared.
    await SubscriptionController.instance.onLogout();
    _refreshTimer?.cancel();
    _accessToken = null;
    _refreshToken = null;
    _user = null;
    HavenSocket.instance.dispose();
    await Future.wait([
      GoogleSignInService.instance.signOut(),
      _storage.delete(key: _kAccess),
      _storage.delete(key: _kRefresh),
      _storage.delete(key: _kUser),
    ]);
    notifyListeners();
  }

  /// Exchanges the refresh token for a new access token. Concurrent callers
  /// share one request. Signs out if the refresh token is rejected.
  Future<bool> refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _doRefresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) return false;
    try {
      final data = await ApiClient.instance.refreshToken(refreshToken);
      await _setTokens(data['accessToken'] as String, data['refreshToken'] as String?);
      HavenSocket.instance.refreshAuth(_accessToken!);
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      debugPrint('token refresh rejected: $e');
      await signOut();
      return false;
    } catch (e) {
      // Network error: keep the session, try again later.
      debugPrint('token refresh failed: $e');
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(seconds: 15), refresh);
      return false;
    }
  }

  Future<void> _setTokens(String access, String? refresh) async {
    _accessToken = access;
    await _storage.write(key: _kAccess, value: access);
    if (refresh != null) {
      _refreshToken = refresh;
      await _storage.write(key: _kRefresh, value: refresh);
    }
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final exp = _expiry(_accessToken);
    if (exp == null) return;
    var wait = exp.difference(DateTime.now()) - kTokenRefreshLeeway;
    if (wait.isNegative) wait = Duration.zero;
    _refreshTimer = Timer(wait, refresh);
  }

  static bool _isExpired(String token) {
    final exp = _expiry(token);
    return exp != null && exp.isBefore(DateTime.now().add(kTokenRefreshLeeway));
  }

  static DateTime? _expiry(String? token) {
    final exp = _jwtClaims(token)?['exp'];
    return exp is num ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000) : null;
  }

  static Map<String, dynamic>? _jwtClaims(String? token) {
    final parts = token?.split('.');
    if (parts == null || parts.length != 3) return null;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      return Map<String, dynamic>.from(jsonDecode(payload));
    } catch (_) {
      return null;
    }
  }
}
