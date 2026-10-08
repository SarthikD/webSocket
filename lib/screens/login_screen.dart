import 'package:flutter/material.dart';

import '../config.dart';
import '../core/api_client.dart';
import '../core/session.dart';
import '../services/google_sign_in_service.dart';

/// Phone → OTP → tokens. `POST /auth/login` only sends the OTP; the access
/// token comes from `POST /auth/verify-otp`.
///
/// Or Google: ID token → `POST /auth/google` → tokens. Google accounts may
/// have no phone; HavenApp then routes to AddPhoneScreen.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _otp = TextEditingController();
  bool _otpSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _otp.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      setState(() => _error = e is ApiException ? e.message : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestOtp() => _run(() async {
        await ApiClient.instance.login(_phone.text.trim());
        setState(() => _otpSent = true);
      });

  // Session change triggers navigation + socket connect in HavenApp.
  Future<void> _verify() => _run(() async {
        final data = await ApiClient.instance.verifyOtp(_phone.text.trim(), _otp.text.trim());
        await Session.instance.signIn(data);
      });

  Future<void> _googleSignIn() => _run(() async {
        final google = GoogleSignInService.instance;
        final idToken = await google.getIdToken();
        if (idToken == null) return; // cancelled
        try {
          final data = await ApiClient.instance.googleLogin(idToken, deviceId: Session.instance.deviceId);
          await Session.instance.signIn(data);
        } catch (_) {
          await google.signOut(); // let the user pick another account next time
          rethrow;
        }
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Server: $kBaseUrl', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          TextField(
            controller: _phone,
            enabled: !_otpSent && !_busy,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '+1555...',
              border: OutlineInputBorder(),
            ),
          ),
          if (_otpSent) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _otp,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'OTP', border: OutlineInputBorder()),
              onSubmitted: (_) => _verify(),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : (_otpSent ? _verify : _requestOtp),
            child: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_otpSent ? 'Verify' : 'Send OTP'),
          ),
          if (_otpSent)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _otpSent = false),
              child: const Text('Change number'),
            ),
          if (!_otpSent && GoogleSignInService.instance.isSupported) ...[
            const SizedBox(height: 24),
            const Row(children: [
              Expanded(child: Divider()),
              Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('or')),
              Expanded(child: Divider()),
            ]),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : _googleSignIn,
              icon: const Icon(Icons.account_circle),
              label: const Text('Continue with Google'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
