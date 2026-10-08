import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import '../services/location_tracker.dart';
import '../socket/haven_socket.dart';
import '../socket/live_chat_socket.dart';
import '../socket/live_location_socket.dart';
import 'connection_badge.dart';
import 'donate_screen.dart';
import 'incident_screen.dart';
import 'share_screen.dart';
import 'subscription_screen.dart';

/// Owner actions (SOS, live share) plus incoming incidents/shares from the
/// circle. The REST lists are the fallback for WS invites missed while the
/// app was closed.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiClient.instance;
  final _subs = <StreamSubscription>[];

  Map<String, dynamic>? _active;
  List<Map<String, dynamic>> _incomingIncidents = [];
  List<Map<String, dynamic>> _incomingShares = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final socket = HavenSocket.instance;
    _subs
      ..add(socket.incidentTriggered.listen((_) => _refresh()))
      ..add(socket.shareStarted.listen((_) => _refresh()))
      ..add(socket.on('share:stopped').listen((_) => _refresh()));
    _refresh();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final results = await Future.wait([
        _api.activeIncident(),
        _api.incomingIncidents(),
        _api.incomingShares(),
      ]);
      if (!mounted) return;
      setState(() {
        _active = results[0] as Map<String, dynamic>?;
        _incomingIncidents = results[1] as List<Map<String, dynamic>>;
        _incomingShares = results[2] as List<Map<String, dynamic>>;
      });
    } catch (e) {
      _toast('Refresh failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _triggerSos() async {
    setState(() => _busy = true);
    try {
      final position = await LocationTracker.tryCurrentPosition();
      final incident = await _api.triggerSos(
        deviceId: Session.instance.deviceId,
        latitude: position?.latitude,
        longitude: position?.longitude,
      );
      final incidentId = incident['id'] as String; // never generated locally
      if (!mounted) return;
      setState(() => _active = incident);
      _openIncident(incidentId, isOwner: true);
    } catch (e) {
      _toast('SOS failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startShare() async {
    setState(() => _busy = true);
    try {
      final share = await _api.startShare();
      if (!mounted) return;
      _openShare(share['id'] as String, isOwner: true);
    } catch (e) {
      _toast('Could not start share: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openIncident(String id, {required bool isOwner}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => IncidentScreen(incidentId: id, isOwner: isOwner),
    ));
    _refresh();
  }

  Future<void> _openShare(String id, {required bool isOwner}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ShareScreen(shareId: id, isOwner: isOwner),
    ));
    _refresh();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _active;
    final user = Session.instance.user;

    return Scaffold(
      appBar: AppBar(
        title: Text(user?['name']?.toString() ?? user?['phoneNumber']?.toString() ?? 'Haven'),
        actions: [
          const ConnectionBadge(),
          IconButton(
            tooltip: 'Subscription',
            icon: const Icon(Icons.workspace_premium),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const SubscriptionScreen(),
            )),
          ),
          IconButton(
            tooltip: 'Donate',
            icon: const Icon(Icons.volunteer_activism),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const DonateScreen(),
            )),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: Session.instance.signOut,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (active != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.warning_amber),
                  title: const Text('Your SOS is active'),
                  subtitle: Text('Status: ${active['status'] ?? '-'}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openIncident(active['id'] as String, isOwner: true),
                ),
              )
            else
              _SosButton(busy: _busy, onTriggered: _triggerSos),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _startShare,
              icon: const Icon(Icons.share_location),
              label: const Text('Share live location'),
            ),
            const SizedBox(height: 24),
            Text('Incoming SOS', style: theme.textTheme.titleMedium),
            if (_loading) const LinearProgressIndicator(),
            if (!_loading && _incomingIncidents.isEmpty) const _Empty('No active SOS in your circle'),
            for (final i in _incomingIncidents)
              ListTile(
                leading: const Icon(Icons.sos, color: Colors.red),
                title: Text(_ownerLabel(i)),
                subtitle: Text('Status: ${i['status'] ?? '-'}'),
                onTap: () => _openIncident(i['id'] as String, isOwner: false),
              ),
            const SizedBox(height: 16),
            Text('Live locations shared with you', style: theme.textTheme.titleMedium),
            if (!_loading && _incomingShares.isEmpty) const _Empty('Nobody is sharing right now'),
            for (final s in _incomingShares)
              ListTile(
                leading: const Icon(Icons.location_on),
                title: Text(_ownerLabel(s)),
                onTap: () => _openShare(s['id'] as String, isOwner: false),
              ),
          ],
        ),
      ),
    );
  }

  static String _ownerLabel(Map<String, dynamic> item) {
    final owner = item['owner'] ?? item['user'];
    if (owner is Map) {
      return (owner['name'] ?? owner['phoneNumber'] ?? owner['id']).toString();
    }
    return (item['ownerId'] ?? item['ownerUserId'] ?? item['id']).toString();
  }
}

/// Press-and-hold SOS so it is not triggered by an accidental tap.
class _SosButton extends StatelessWidget {
  const _SosButton({required this.busy, required this.onTriggered});

  final bool busy;
  final VoidCallback onTriggered;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onLongPress: busy ? null : onTriggered,
          child: Container(
            width: 160,
            height: 160,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: busy ? Colors.red.shade200 : Colors.red,
            ),
            child: busy
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text(
                    'SOS',
                    style: TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Press and hold to send SOS'),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );
}
