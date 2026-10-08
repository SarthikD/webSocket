import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config.dart';

/// Wraps google_sign_in 7.x. Only produces the Google ID token; the backend
/// exchanges it for our own tokens at `POST /auth/google`.
class GoogleSignInService {
  GoogleSignInService._();
  static final GoogleSignInService instance = GoogleSignInService._();

  final GoogleSignIn _signIn = GoogleSignIn.instance;
  Future<void>? _init;

  static bool get _isApple =>
      defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;

  Future<void> _ensureInitialized() {
    if (kGoogleWebClientId.isEmpty) {
      throw StateError(
        'GOOGLE_WEB_CLIENT_ID not set. Run with '
        '--dart-define=GOOGLE_WEB_CLIENT_ID=<web client id>.apps.googleusercontent.com',
      );
    }
    return _init ??= _initialize().catchError((Object e) {
      _init = null; // allow retry after a failed init
      throw e;
    });
  }

  Future<void> _initialize() => _signIn.initialize(
        clientId: _isApple && kGoogleIosClientId.isNotEmpty ? kGoogleIosClientId : null,
        serverClientId: kGoogleWebClientId,
      );

  /// False on web, where `authenticate()` is not supported.
  bool get isSupported => !kIsWeb && _signIn.supportsAuthenticate();

  /// Returns the Google ID token, or `null` when the user cancels.
  Future<String?> getIdToken() async {
    await _ensureInitialized();
    final GoogleSignInAccount account;
    try {
      account = await _signIn.authenticate(scopeHint: const ['email', 'profile']);
    } on GoogleSignInException catch (e) {
      debugPrint('google authenticate failed: ${e.code} ${e.description}');
      // Android Credential Manager reports a missing/mismatched Android OAuth
      // client (package name + SHA-1) as a cancellation: "[16] Account reauth
      // failed". Surface it instead of treating it as a user cancel.
      final description = e.description ?? '';
      final misconfigured = description.contains('[16]') || description.contains('reauth');
      if (e.code == GoogleSignInExceptionCode.canceled && !misconfigured) return null;
      throw StateError(
        misconfigured
            ? 'Google sign-in misconfigured: add an Android OAuth client for this '
                'package name + SHA-1 in the same Cloud project as the Web client ID. ($description)'
            : 'Google sign-in failed: ${e.code.name} $description',
      );
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) throw StateError('Google returned no ID token (check serverClientId)');
    return idToken;
  }

  /// Clears the cached Google account so the next login shows the picker.
  Future<void> signOut() async {
    if (kIsWeb) return;
    try {
      await _ensureInitialized();
      await _signIn.signOut();
    } catch (e) {
      debugPrint('google signOut failed: $e');
    }
  }
}
