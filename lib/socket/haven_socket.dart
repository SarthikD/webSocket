import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

enum WsStatus { disconnected, connecting, connected }

/// Error pushed by the server on the `exception` event, e.g.
/// `{ code: "NOT_SUBSCRIBED", message: "..." }`.
class WsException implements Exception {
  WsException(this.code, this.message, [this.raw = const {}]);

  factory WsException.fromPayload(Map<String, dynamic> data) => WsException(
        data['code']?.toString() ?? 'UNKNOWN',
        data['message']?.toString() ?? 'Socket error',
        data,
      );

  final String code;
  final String message;
  final Map<String, dynamic> raw;

  @override
  String toString() => 'WsException($code): $message';
}

/// A room the client is subscribed to: `{ shareId }` or `{ incidentId }`.
class WsRoom {
  const WsRoom.share(this.id) : key = 'shareId';
  const WsRoom.incident(this.id) : key = 'incidentId';

  final String key;
  final String id;

  Map<String, dynamic> get payload => {key: id};

  @override
  bool operator ==(Object other) => other is WsRoom && other.key == key && other.id == id;

  @override
  int get hashCode => Object.hash(key, id);

  @override
  String toString() => '$key=$id';
}

/// App-wide Socket.IO connection to the `/ws` namespace.
///
/// * Transport is websocket only (the server rejects polling).
/// * The JWT goes in `auth.token`; it is read fresh on every (re)connect.
/// * Server events are exposed as broadcast streams via [on]. Screens listen
///   and cancel their subscriptions on dispose; the underlying `socket.on`
///   handlers survive reconnects and socket re-creation.
/// * Rooms joined with [subscribe] are re-joined automatically after a
///   reconnect, because server-side rooms do not survive a disconnect.
class HavenSocket {
  HavenSocket._();
  static final HavenSocket instance = HavenSocket._();

  static const Duration defaultAckTimeout = Duration(seconds: 10);

  io.Socket? _socket;
  final ValueNotifier<WsStatus> status = ValueNotifier(WsStatus.disconnected);

  final Map<String, StreamController<Map<String, dynamic>>> _events = {};
  final Set<WsRoom> _rooms = {};
  final Map<WsRoom, Completer<Map<String, dynamic>>> _pendingJoins = {};
  final StreamController<({WsRoom room, Map<String, dynamic> snapshot})> _rejoined =
      StreamController.broadcast();

  /// Called when the server rejects the handshake or kicks the socket.
  /// Should refresh the access token and return whether that succeeded.
  Future<bool> Function()? onAuthRejected;
  bool _recovering = false;
  int _authRetries = 0;

  bool get isConnected => _socket?.connected ?? false;

  /// Fires after a room is re-joined on reconnect, with the fresh snapshot.
  /// Use it to back-fill anything missed while offline (e.g. chat history).
  Stream<({WsRoom room, Map<String, dynamic> snapshot})> get rejoined => _rejoined.stream;

  /// Server `exception` events.
  Stream<WsException> get exceptions => on('exception').map(WsException.fromPayload);

  void connect(String baseUrl, String namespace, String Function() tokenProvider) {
    _disposeSocket();
    _authRetries = 0;
    status.value = WsStatus.connecting;

    final socket = io.io(
      '$baseUrl$namespace',
      io.OptionBuilder()
          .setTransports(['websocket']) // required: server rejects polling
          .setAuthFn((cb) => cb({'token': tokenProvider()}))
          .enableForceNew() // don't reuse a cached manager from a previous login
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(10000)
          .disableAutoConnect()
          .build(),
    );
    _socket = socket;

    socket
      ..onConnect((_) {
        debugPrint('ws connected ${socket.id}');
        status.value = WsStatus.connected;
        _authRetries = 0;
        _rejoinRooms();
      })
      ..onDisconnect((reason) {
        debugPrint('ws disconnected: $reason');
        status.value = WsStatus.disconnected;
        // Server-initiated disconnects (e.g. token expired) are not retried
        // by the client library.
        if (reason == 'io server disconnect') _recoverAuth(socket);
      })
      ..onConnectError((e) {
        debugPrint('ws connect_error: $e');
        // A middleware rejection (bad/expired JWT) destroys the socket and
        // stops auto-reconnect. Transport errors keep retrying on their own.
        if (!socket.active) {
          status.value = WsStatus.disconnected;
          _recoverAuth(socket);
        } else {
          status.value = WsStatus.connecting;
        }
      })
      ..onReconnectAttempt((_) => status.value = WsStatus.connecting);

    for (final event in _events.keys) {
      _bind(socket, event);
    }
    socket.connect();
  }

  /// Push a renewed access token to the live connection.
  void refreshAuth(String accessToken) {
    if (isConnected) _socket!.emit('auth:refresh', {'token': accessToken});
  }

  void dispose() {
    _disposeSocket();
    _rooms.clear();
    for (final c in _pendingJoins.values) {
      c.completeError(StateError('Socket disposed'));
    }
    _pendingJoins.clear();
    status.value = WsStatus.disconnected;
  }

  /// Broadcast stream of a server event's payload.
  Stream<Map<String, dynamic>> on(String event) {
    final existing = _events[event];
    if (existing != null) return existing.stream;
    final controller = StreamController<Map<String, dynamic>>.broadcast();
    _events[event] = controller;
    if (_socket != null) _bind(_socket!, event);
    return controller.stream;
  }

  /// Fire-and-forget emit. Dropped while offline (e.g. stale GPS fixes).
  bool emit(String event, Map<String, dynamic> payload) {
    if (!isConnected) return false;
    _socket!.emit(event, payload);
    return true;
  }

  /// Emit and wait for the server ack. Fails fast while offline so callers
  /// can surface "not sent" and retry.
  Future<Map<String, dynamic>> request(
    String event,
    Map<String, dynamic> payload, {
    Duration timeout = defaultAckTimeout,
  }) {
    final socket = _socket;
    if (socket == null || !socket.connected) {
      return Future.error(StateError('Socket offline'));
    }
    final completer = Completer<Map<String, dynamic>>();
    socket.emitWithAck(event, payload, ack: ([dynamic data]) {
      if (!completer.isCompleted) completer.complete(_asMap(data));
    });
    return completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('No ack for "$event"', timeout),
    );
  }

  /// Join a room. Required before `chat:send`, `chat:typing` or
  /// `location:update`, otherwise the server replies `NOT_SUBSCRIBED`.
  /// If offline, completes once the socket connects and the join is acked.
  Future<Map<String, dynamic>> subscribe(WsRoom room) {
    _rooms.add(room);
    if (isConnected) return request('subscribe', room.payload);
    return (_pendingJoins[room] ??= Completer()).future;
  }

  void unsubscribe(WsRoom room) {
    _rooms.remove(room);
    _pendingJoins.remove(room)?.completeError(StateError('Unsubscribed'));
    emit('unsubscribe', room.payload);
  }

  void _rejoinRooms() {
    for (final room in _rooms.toList()) {
      request('subscribe', room.payload).then((snapshot) {
        final pending = _pendingJoins.remove(room);
        if (pending != null) {
          pending.complete(snapshot);
        } else {
          _rejoined.add((room: room, snapshot: snapshot));
        }
      }, onError: (Object e) {
        debugPrint('ws rejoin $room failed: $e');
        _pendingJoins.remove(room)?.completeError(e);
      });
    }
  }

  Future<void> _recoverAuth(io.Socket socket) async {
    final refresh = onAuthRejected;
    // Give up after a couple of attempts so a persistent server-side
    // rejection doesn't turn into a refresh loop.
    if (refresh == null || _recovering || _authRetries >= 2) return;
    _recovering = true;
    _authRetries++;
    try {
      final ok = await refresh();
      // Only reconnect if this socket is still the current one.
      if (ok && identical(socket, _socket)) {
        status.value = WsStatus.connecting;
        socket.connect(); // authFn reads the refreshed token
      }
    } finally {
      _recovering = false;
    }
  }

  void _bind(io.Socket socket, String event) {
    socket.on(event, (data) => _events[event]?.add(_asMap(data)));
  }

  void _disposeSocket() {
    _socket
      ?..clearListeners()
      ..dispose();
    _socket = null;
  }

  static Map<String, dynamic> _asMap(dynamic data) {
    // Multiple emit args arrive as a List; the server sends one object.
    if (data is List) data = data.isEmpty ? null : data.first;
    if (data is Map) return Map<String, dynamic>.from(data);
    return data == null ? <String, dynamic>{} : {'value': data};
  }
}
