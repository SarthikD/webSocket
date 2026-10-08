import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/session.dart';

/// Attaches a phone to an account that has none (Google sign-in).
/// `POST /auth/me/phone` sends the OTP; `POST /auth/verify-otp` saves the
/// phone and returns fresh tokens. SOS is unavailable until this is done.
class AddPhoneScreen extends StatefulWidget {
  const AddPhoneScreen({super.key});

  @override
  State<AddPhoneScreen> createState() => _AddPhoneScreenState();
}

class _AddPhoneScreenState extends State<AddPhoneScreen> {
  static final _e164 = RegExp(r'^\+?[1-9]\d{6,14}$');

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
    } on ApiException catch (e) {
      setState(() => _error = e.statusCode == 409 ? 'This number is already used by another account' : e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _phoneNumber => _phone.text.trim().replaceAll(RegExp(r'[\s\-()]'), '');

  // Also used for "Resend"; backend enforces a 30 s cooldown (400 + message).
  Future<void> _requestOtp() => _run(() async {
        if (!_e164.hasMatch(_phoneNumber)) {
          throw 'Enter the number in international format, e.g. +15551234567';
        }
        await ApiClient.instance.requestPhoneOtp(_phoneNumber);
        setState(() => _otpSent = true);
      });

  // Session change (user now has a phone) triggers navigation in HavenApp.
  Future<void> _verify() => _run(() async {
        final data = await ApiClient.instance.verifyOtp(_phoneNumber, _otp.text.trim());
        await Session.instance.signIn(data);
      });

  @override
  Widget build(BuildContext context) {
    final email = Session.instance.user?['email']?.toString();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add phone number'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: Session.instance.signOut,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'A verified phone number is required for SOS alerts.'
            '${email == null ? '' : '\nSigned in as $email'}',
          ),
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
          if (_otpSent) ...[
            TextButton(
              onPressed: _busy ? null : _requestOtp,
              child: const Text('Resend code'),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _otpSent = false),
              child: const Text('Change number'),
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
