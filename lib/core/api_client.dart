import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/subscription.dart';
import 'session.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// REST client. Every call unwraps the `{ data: ... }` envelope and returns
/// `data`. Authenticated calls send `Authorization: Bearer <accessToken>` and
/// retry once after a token refresh on 401.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  final http.Client _http = http.Client();

  // ---------------------------------------------------------------- auth

  /// Sends an OTP. No token is returned at this step.
  Future<void> login(String phoneNumber) =>
      _send('POST', '/auth/login', body: {'phoneNumber': phoneNumber}, auth: false);

  /// Returns `{ accessToken, refreshToken, user }`.
  Future<Map<String, dynamic>> verifyOtp(String phoneNumber, String otp) async =>
      _asMap(await _send(
        'POST',
        '/auth/verify-otp',
        body: {'phoneNumber': phoneNumber, 'otp': otp},
        auth: false,
      ));

  /// Exchanges a Google ID token. Returns
  /// `{ user, accessToken, refreshToken, isNewUser }`; `user.phoneNumber`
  /// may be null.
  Future<Map<String, dynamic>> googleLogin(String idToken, {String? deviceId}) async =>
      _asMap(await _send(
        'POST',
        '/auth/google',
        body: {'idToken': idToken, 'deviceId': ?deviceId},
        auth: false,
      ));

  /// Sends an OTP to attach [phoneNumber] to the logged-in account. Confirm
  /// with [verifyOtp], which saves the phone and returns fresh tokens.
  Future<void> requestPhoneOtp(String phoneNumber) =>
      _send('POST', '/auth/me/phone', body: {'phoneNumber': phoneNumber});

  /// Current user.
  Future<Map<String, dynamic>> me() async => _asMap(await _send('GET', '/auth/me'));

  /// Returns `{ accessToken, refreshToken? }`.
  Future<Map<String, dynamic>> refreshToken(String refreshToken) async =>
      _asMap(await _send(
        'POST',
        '/auth/refreshtoken',
        body: {'refreshToken': refreshToken},
        auth: false,
      ));

  // ------------------------------------------------------------ incident

  /// Owner presses SOS. `data.id` is the incidentId.
  Future<Map<String, dynamic>> triggerSos({
    required String deviceId,
    double? latitude,
    double? longitude,
  }) async =>
      _asMap(await _send('POST', '/incident/sos', body: {
        'deviceId': deviceId,
        'latitude': ?latitude,
        'longitude': ?longitude,
      }));

  /// Owner's active incident, or `null` if none.
  Future<Map<String, dynamic>?> activeIncident() async {
    final data = await _send('GET', '/incident/active');
    return data == null ? null : _asMap(data);
  }

  /// Incidents from circle members (fallback when `incident:triggered` was missed).
  Future<List<Map<String, dynamic>>> incomingIncidents() async =>
      _asList(await _send('GET', '/incident/incoming'));

  Future<Map<String, dynamic>> incident(String id) async =>
      _asMap(await _send('GET', '/incident/$id'));

  // ------------------------------------------------------- live location

  /// Owner starts a share. `data.id` is the shareId.
  Future<Map<String, dynamic>> startShare([Map<String, dynamic>? body]) async =>
      _asMap(await _send('POST', '/live-location/shares', body: body ?? {}));

  Future<void> stopShare(String shareId) =>
      _send('POST', '/live-location/shares/$shareId/stop');

  /// Shares from circle members (fallback when `share:started` was missed).
  Future<List<Map<String, dynamic>>> incomingShares() async =>
      _asList(await _send('GET', '/live-location/incoming'));

  // -------------------------------------------------------- subscription

  /// Plan cards. Public, no token needed.
  Future<List<Plan>> subscriptionPlans() async =>
      _asList(await _send('GET', '/subscription/plans', auth: false)).map(Plan.fromJson).toList();

  /// Current plan and subscription state.
  Future<SubscriptionState> subscription() async =>
      SubscriptionState.fromJson(_asMap(await _send('GET', '/subscription')));

  /// Asks the backend to pull the latest state from RevenueCat, and returns
  /// it. Call after a purchase, a restore, a return from the store page, and
  /// on app resume.
  ///
  /// After a purchase, [plan] carries what the user bought:
  /// `{ planId, planName, price, currency, productId }`. The backend must
  /// still trust RevenueCat, not this body, for the entitlement.
  Future<SubscriptionState> syncSubscription([Map<String, dynamic>? plan]) async =>
      SubscriptionState.fromJson(
        _asMap(await _send('POST', '/subscription/sync', body: plan ?? {})),
      );

  // ------------------------------------------------------------ donation

  /// Donation buttons: `[{ productId, amount }]`.
  Future<List<Map<String, dynamic>>> donationOptions() async =>
      _asList(await _send('GET', '/donations/options', auth: false));

  /// Asks the backend to record the donation from RevenueCat. Returns
  /// `{ id, productId, amount, purchasedAt }`, or `null` when RevenueCat does
  /// not show the purchase yet. Without [transactionId] the backend returns
  /// the latest donation.
  Future<Map<String, dynamic>?> syncDonation([String? transactionId]) async {
    final data = _asMap(await _send(
      'POST',
      '/donations/sync',
      body: {'transactionId': ?transactionId},
    ));
    final donation = data['donation'];
    return donation is Map ? Map<String, dynamic>.from(donation) : null;
  }

  // ------------------------------------------------------------ internal

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    bool retryOn401 = true,
  }) async {
    final request = http.Request(method, Uri.parse('$kBaseUrl$path'))
      ..headers['Content-Type'] = 'application/json';
    if (auth) {
      final token = Session.instance.accessToken;
      if (token == null) throw ApiException(401, 'Not logged in');
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) request.body = jsonEncode(body);

    final response = await http.Response.fromStream(await _http.send(request));

    if (response.statusCode == 401 && auth && retryOn401) {
      if (await Session.instance.refresh()) {
        return _send(method, path, body: body, auth: auth, retryOn401: false);
      }
    }

    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, _errorMessage(decoded, response));
    }
    return decoded is Map ? decoded['data'] : decoded;
  }

  static String _errorMessage(dynamic decoded, http.Response response) {
    if (decoded is Map) {
      final message = decoded['message'];
      if (message is List) return message.join(', ');
      if (message != null) return message.toString();
    }
    return response.reasonPhrase ?? 'Request failed';
  }

  static Map<String, dynamic> _asMap(dynamic data) =>
      data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};

  static List<Map<String, dynamic>> _asList(dynamic data) {
    // Accept both a bare list and a paginated `{ items: [...] }` shape.
    final list = data is List ? data : (data is Map ? data['items'] : null);
    if (list is! List) return const [];
    return list.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }
}
