import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../models/location_point.dart';
import '../services/location_tracker.dart';
import '../socket/haven_socket.dart';
import '../socket/live_location_socket.dart';
import 'connection_badge.dart';
import 'format.dart';

/// Live-location share. The owner streams GPS; viewers render
/// `location:updated` until `share:stopped`.
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key, required this.shareId, required this.isOwner});

  final String shareId;
  final bool isOwner;

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  final _socket = HavenSocket.instance;
  final _subs = <StreamSubscription>[];
  late final LocationTracker _tracker = LocationTracker((p) {
    final sent = _socket.sendShareLocation(
      shareId: widget.shareId,
      latitude: p.latitude,
      longitude: p.longitude,
      accuracy: p.accuracy,
      altitude: p.altitude,
    );
    if (sent && mounted) setState(() => _sentCount++);
  });

  final List<LocationPoint> _trail = [];
  Map<String, dynamic>? _share;
  bool _stopped = false;
  bool _stopping = false;
  int _sentCount = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_socket.shareLocations(widget.shareId).listen(_addPoint))
      ..add(_socket.shareStopped(widget.shareId).listen((_) => _onStopped()))
      ..add(_socket.rejoined
          .where((r) => r.room == WsRoom.share(widget.shareId))
          .listen((r) => _applySnapshot(r.snapshot)));
    _join();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _tracker.stop();
    _socket.unsubscribeShare(widget.shareId);
    super.dispose();
  }

  Future<void> _join() async {
    try {
      _applySnapshot(await _socket.subscribeShare(widget.shareId));
      if (widget.isOwner && !_stopped) await _tracker.start();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _applySnapshot(Map<String, dynamic> ack) {
    if (!mounted) return;
    setState(() {
      if (ack['share'] is Map) _share = Map<String, dynamic>.from(ack['share']);
      final last = LocationPoint.tryParse(ack['lastKnown']);
      if (last != null) _addPointInternal(last);
      if (_share?['status'] == 'STOPPED' || _share?['stoppedAt'] != null) _stopped = true;
    });
  }

  void _addPoint(LocationPoint p) {
    if (mounted) setState(() => _addPointInternal(p));
  }

  void _addPointInternal(LocationPoint p) {
    if (_trail.isNotEmpty && _trail.first.capturedAt == p.capturedAt && p.capturedAt != null) return;
    _trail.insert(0, p);
    if (_trail.length > 50) _trail.removeLast();
  }

  void _onStopped() {
    _tracker.stop();
    if (mounted) setState(() => _stopped = true);
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    try {
      await ApiClient.instance.stopShare(widget.shareId); // server emits share:stopped
      _onStopped();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Stop failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = _trail.isEmpty ? null : _trail.first;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isOwner ? 'Sharing my location' : 'Live location'),
        actions: const [ConnectionBadge()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          if (_stopped)
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const ListTile(leading: Icon(Icons.location_off), title: Text('Sharing has ended')),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.my_location),
              title: Text(latest?.coords ?? 'Waiting for location…'),
              subtitle: latest == null
                  ? null
                  : Text([
                      if (latest.accuracy != null) '±${latest.accuracy!.toStringAsFixed(0)} m',
                      if (latest.capturedAt != null) hms(latest.capturedAt!),
                    ].join(' · ')),
            ),
          ),
          if (widget.isOwner && !_stopped) ...[
            Text('Fixes sent: $_sentCount', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
              onPressed: _stopping ? null : _stop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop sharing'),
            ),
          ],
          const SizedBox(height: 16),
          Text('Recent updates', style: theme.textTheme.titleSmall),
          for (final p in _trail.skip(1))
            ListTile(
              dense: true,
              title: Text(p.coords),
              trailing: p.capturedAt == null ? null : Text(hms(p.capturedAt!)),
            ),
        ],
      ),
    );
  }
}
