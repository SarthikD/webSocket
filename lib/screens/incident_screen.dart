import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/session.dart';
import '../models/chat_message.dart';
import '../models/location_point.dart';
import '../services/location_tracker.dart';
import '../socket/haven_socket.dart';
import '../socket/live_chat_socket.dart';
import 'connection_badge.dart';
import 'format.dart';

/// Active SOS: incident room chat, live locations and status events.
///
/// Order matters: `subscribe { incidentId }` is acked before history is
/// loaded or anything is sent, otherwise the server replies NOT_SUBSCRIBED.
class IncidentScreen extends StatefulWidget {
  const IncidentScreen({super.key, required this.incidentId, required this.isOwner});

  /// Always from `POST /incident/sos`, `GET /incident/active|incoming` or
  /// `incident:triggered` — never generated on the client.
  final String incidentId;
  final bool isOwner;

  @override
  State<IncidentScreen> createState() => _IncidentScreenState();
}

class _IncidentScreenState extends State<IncidentScreen> {
  static const _historyPage = 50;
  static const _closedStatuses = {'CANCELLED', 'RESOLVED', 'ENDED'};

  final _socket = HavenSocket.instance;
  final _subs = <StreamSubscription>[];
  final _input = TextEditingController();
  final _uuid = const Uuid();
  late final String _me = Session.instance.userId ?? '';

  late final LocationTracker _tracker = LocationTracker((p) {
    _socket.sendIncidentLocation(
      incidentId: widget.incidentId,
      latitude: p.latitude,
      longitude: p.longitude,
      accuracy: p.accuracy,
    );
  });

  /// Oldest first.
  final List<ChatMessage> _messages = [];
  final Map<String, Timer> _typingUsers = {};
  final Map<String, LocationPoint> _locations = {};
  final Map<String, String> _roster = {};
  final Map<String, Map<String, dynamic>> _documents = {};

  Map<String, dynamic>? _incident;
  String? _sosStatus;
  String? _incidentStatus;
  bool _joined = false;
  bool _loadingOlder = false;
  bool _hasMore = true;
  bool _sharingLocation = false;
  String? _error;

  Timer? _typingIdle;
  bool _typingSent = false;

  bool get _closed =>
      _closedStatuses.contains(_incidentStatus) || _closedStatuses.contains(_sosStatus);

  @override
  void initState() {
    super.initState();
    final id = widget.incidentId;
    _subs
      ..add(_socket.chatMessages(id).listen(_merge))
      ..add(_socket.typing(id).listen(_onTyping))
      ..add(_socket.incidentLocations(id).listen((p) {
        if (mounted) setState(() => _locations[p.userId ?? '?'] = p);
      }))
      ..add(_socket.circleStatus(id).listen(_onCircleStatus))
      ..add(_socket.sosStatus(id).listen((d) => _onStatus(sos: d['status']?.toString())))
      ..add(_socket.incidentStatus(id).listen((d) => _onStatus(incident: d['status']?.toString())))
      ..add(_socket.documentStatus(id).listen(_onDocumentStatus))
      ..add(_socket.rejoined.where((r) => r.room == WsRoom.incident(id)).listen((r) {
        // Back-fill anything missed while the socket was down.
        _applySnapshot(r.snapshot);
        _loadLatest();
      }));
    _join();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final t in _typingUsers.values) {
      t.cancel();
    }
    _typingIdle?.cancel();
    if (_typingSent) _socket.setTyping(widget.incidentId, false);
    _tracker.stop();
    _socket.unsubscribeIncident(widget.incidentId);
    _input.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ join

  Future<void> _join() async {
    try {
      _applySnapshot(await _socket.subscribeIncident(widget.incidentId));
      if (!mounted) return;
      setState(() => _joined = true);
      await _loadLatest();
      if (widget.isOwner && !_closed) await _setSharing(true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not join incident: $e');
    }
  }

  void _applySnapshot(Map<String, dynamic> ack) {
    final incident = ack['incident'];
    if (incident is! Map || !mounted) return;
    setState(() {
      _incident = Map<String, dynamic>.from(incident);
      _incidentStatus = _incident!['status']?.toString() ?? _incidentStatus;
    });
  }

  // ------------------------------------------------------------ chat

  Future<void> _loadLatest() async {
    try {
      final page = await _socket.loadHistory(widget.incidentId, limit: _historyPage);
      if (!mounted) return;
      setState(() {
        if (_messages.isEmpty) _hasMore = page.length >= _historyPage;
        page.forEach(_mergeInternal);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'History failed: $e');
    }
  }

  Future<void> _loadOlder() async {
    final oldest = _messages.where((m) => m.id != null).firstOrNull;
    if (_loadingOlder || !_hasMore || oldest == null) return;
    setState(() => _loadingOlder = true);
    try {
      final page = await _socket.loadHistory(
        widget.incidentId,
        before: oldest.createdAt.toUtc().toIso8601String(),
        limit: _historyPage,
      );
      if (!mounted) return;
      setState(() {
        _hasMore = page.length >= _historyPage;
        page.forEach(_mergeInternal);
      });
    } catch (e) {
      _toast('Could not load older messages: $e');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _merge(ChatMessage m) {
    if (mounted) setState(() => _mergeInternal(m));
  }

  /// Insert or replace (matching by id or clientMessageId), keeping
  /// chronological order. Replaces optimistic copies with the server echo.
  void _mergeInternal(ChatMessage m) {
    final i = _messages.indexWhere((x) => x.sameAs(m));
    if (i >= 0) {
      _messages[i] = m;
      return;
    }
    var at = _messages.length;
    while (at > 0 && _messages[at - 1].createdAt.isAfter(m.createdAt)) {
      at--;
    }
    _messages.insert(at, m);
  }

  void _send() {
    final body = _input.text.trim();
    if (body.isEmpty) return;
    _input.clear();
    _stopTyping();
    final pending = ChatMessage.pending(
      incidentId: widget.incidentId,
      senderId: _me,
      body: body,
      clientMessageId: _uuid.v4(),
    );
    setState(() => _messages.add(pending));
    _deliver(pending);
  }

  /// Sends (or re-sends) with the same clientMessageId so the server can
  /// de-duplicate if the first attempt actually got through.
  Future<void> _deliver(ChatMessage m) async {
    setState(() => m.delivery = DeliveryState.sending);
    try {
      final saved = await _socket.sendText(
        widget.incidentId,
        m.body ?? '',
        clientMessageId: m.clientMessageId!,
      );
      _merge(saved);
    } catch (_) {
      if (mounted) setState(() => m.delivery = DeliveryState.failed);
    }
  }

  void _onInputChanged(String text) {
    if (text.isEmpty) return _stopTyping();
    if (!_typingSent) {
      _typingSent = _socket.setTyping(widget.incidentId, true);
    }
    _typingIdle?.cancel();
    _typingIdle = Timer(const Duration(seconds: 3), _stopTyping);
  }

  void _stopTyping() {
    _typingIdle?.cancel();
    if (!_typingSent) return;
    _typingSent = false;
    _socket.setTyping(widget.incidentId, false);
  }

  void _onTyping(Map<String, dynamic> d) {
    final userId = d['userId']?.toString() ?? d['senderId']?.toString();
    if (userId == null || userId == _me || !mounted) return;
    setState(() {
      _typingUsers.remove(userId)?.cancel();
      if (d['isTyping'] == true) {
        // Expire in case the "stopped typing" event is lost.
        _typingUsers[userId] = Timer(const Duration(seconds: 6), () {
          if (mounted) setState(() => _typingUsers.remove(userId));
        });
      }
    });
  }

  // ---------------------------------------------------------- status

  void _onStatus({String? sos, String? incident}) {
    if (!mounted) return;
    setState(() {
      _sosStatus = sos ?? _sosStatus;
      _incidentStatus = incident ?? _incidentStatus;
    });
    if (_closed) _setSharing(false);
  }

  void _onCircleStatus(Map<String, dynamic> d) {
    if (!mounted) return;
    setState(() {
      final members = d['members'] ?? d['circle'];
      if (members is List) {
        _roster.clear();
        for (final m in members.whereType<Map>()) {
          _roster[_name(m)] = m['status']?.toString() ?? '-';
        }
      } else if (d['userId'] != null) {
        _roster[_name(d)] = d['status']?.toString() ?? '-';
      }
    });
  }

  void _onDocumentStatus(Map<String, dynamic> d) {
    final id = (d['documentId'] ?? d['id'])?.toString();
    if (id == null || !mounted) return;
    setState(() => _documents[id] = d);
  }

  Future<void> _setSharing(bool on) async {
    if (on == _sharingLocation) return;
    if (on) {
      try {
        await _tracker.start();
      } on LocationUnavailable catch (e) {
        _toast(e.message);
        return;
      }
    } else {
      _tracker.stop();
    }
    if (mounted) setState(() => _sharingLocation = on);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  static String _name(Map m) {
    final user = m['user'];
    if (user is Map) return (user['senderName'] ?? user['phoneNumber'] ?? user['id']).toString();
    return (m['senderName'] ?? m['userId'] ?? m['id']).toString();
  }

  // --------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _sosStatus ?? _incidentStatus ?? _incident?['status']?.toString();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isOwner ? 'My SOS' : 'SOS'),
        actions: [
          if (status != null) Chip(label: Text(status), visualDensity: VisualDensity.compact),
          const ConnectionBadge(),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [TextButton(onPressed: () => setState(() => _error = null), child: const Text('OK'))],
            ),
          if (_closed)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(12),
              child: Text('This incident is $status.'),
            ),
          _LivePanel(
            locations: _locations,
            roster: _roster,
            documents: _documents,
            me: _me,
            sharing: _sharingLocation,
            onSharingChanged: _closed ? null : _setSharing,
          ),
          const Divider(height: 1),
          Expanded(child: _buildMessages(theme)),
          if (_typingUsers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _typingUsers.length == 1 ? 'Someone is typing…' : '${_typingUsers.length} people are typing…',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildMessages(ThemeData theme) {
    if (!_joined) return const Center(child: CircularProgressIndicator());
    final items = _messages.reversed.toList(); // newest at the bottom with reverse: true
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 200) _loadOlder();
        return false;
      },
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.all(12),
        itemCount: items.length + (_loadingOlder ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == items.length) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final m = items[i];
          return _Bubble(
            message: m,
            mine: m.senderId == _me,
            onRetry: m.delivery == DeliveryState.failed ? () => _deliver(m) : null,
          );
        },
      ),
    );
  }

  Widget _buildComposer() {
    final enabled = _joined && !_closed;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                enabled: enabled,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: _onInputChanged,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder()),
              ),
            ),
            IconButton(onPressed: enabled ? _send : null, icon: const Icon(Icons.send)),
          ],
        ),
      ),
    );
  }
}

class _LivePanel extends StatelessWidget {
  const _LivePanel({
    required this.locations,
    required this.roster,
    required this.documents,
    required this.me,
    required this.sharing,
    required this.onSharingChanged,
  });

  final Map<String, LocationPoint> locations;
  final Map<String, String> roster;
  final Map<String, Map<String, dynamic>> documents;
  final String me;
  final bool sharing;
  final ValueChanged<bool>? onSharingChanged;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text('Live · ${locations.length} location(s) · ${roster.length} in circle'),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Share my location'),
          value: sharing,
          onChanged: onSharingChanged,
        ),
        for (final e in locations.entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place),
            title: Text(e.key == me ? 'Me' : e.key),
            subtitle: Text(e.value.coords),
            trailing: e.value.capturedAt == null ? null : Text(hms(e.value.capturedAt!)),
          ),
        for (final e in roster.entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person),
            title: Text(e.key),
            trailing: Text(e.value),
          ),
        for (final d in documents.values)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.attach_file),
            title: Text((d['name'] ?? d['documentId'] ?? d['id']).toString()),
            trailing: Text([d['status'], if (d['progress'] != null) '${d['progress']}%'].join(' ')),
          ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, this.onRetry});

  final ChatMessage message;
  final bool mine;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = message.isDocument
        ? '📎 ${message.document?['name'] ?? 'Evidence uploaded'}'
        : message.body ?? '';
    final meta = switch (message.delivery) {
      DeliveryState.sending => 'sending…',
      DeliveryState.failed => 'failed · tap to retry',
      DeliveryState.sent => hm(message.createdAt),
    };

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: onRetry,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
          decoration: BoxDecoration(
            color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: message.delivery == DeliveryState.failed ? Border.all(color: scheme.error) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!mine)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(message.senderId, style: Theme.of(context).textTheme.labelSmall),
                ),
              Text(text),
              Text(meta, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}
