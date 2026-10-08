import '../models/chat_message.dart';
import '../models/location_point.dart';
import 'haven_socket.dart';

/// SOS incident room: chat, live location and status events.
///
/// `subscribe({ incidentId })` must be acked before `chat:send`,
/// `chat:typing` or `location:update`, otherwise the server emits
/// `exception { code: "NOT_SUBSCRIBED" }`.
extension LiveChatSocket on HavenSocket {
  /// Ack: `{ ok, incidentId, incident }`.
  Future<Map<String, dynamic>> subscribeIncident(String incidentId) =>
      subscribe(WsRoom.incident(incidentId));

  void unsubscribeIncident(String incidentId) => unsubscribe(WsRoom.incident(incidentId));

  /// SOS from a circle member; arrives in the user room before subscribe.
  /// Payload: `{ incidentId, ownerUserId }`.
  Stream<Map<String, dynamic>> get incidentTriggered => on('incident:triggered');

  // -------------------------------------------------------------- chat

  Stream<ChatMessage> chatMessages(String incidentId) =>
      _room('chat:message', incidentId).map(ChatMessage.fromJson);

  /// Payload: `{ incidentId, userId, isTyping }`.
  Stream<Map<String, dynamic>> typing(String incidentId) => _room('chat:typing', incidentId);

  /// Returns messages oldest-first (the server sends newest-first).
  Future<List<ChatMessage>> loadHistory(
    String incidentId, {
    String? before,
    int limit = 50,
  }) async {
    final ack = await request('chat:history', {
      'incidentId': incidentId,
      'before': ?before,
      'limit': limit,
    });
    final raw = ack['messages'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
        .toList()
        .reversed
        .toList();
  }

  /// Ack has the same shape as `chat:message`. Reuse [clientMessageId] when
  /// retrying so the server can de-duplicate.
  Future<ChatMessage> sendText(
    String incidentId,
    String body, {
    required String clientMessageId,
  }) async =>
      ChatMessage.fromJson(await request('chat:send', {
        'incidentId': incidentId,
        'body': body,
        'clientMessageId': clientMessageId,
      }));

  /// Returns false if offline (not sent).
  bool setTyping(String incidentId, bool isTyping) =>
      emit('chat:typing', {'incidentId': incidentId, 'isTyping': isTyping});

  // ---------------------------------------------------- live location

  /// Incident room broadcast (no "d", unlike the share room).
  Stream<LocationPoint> incidentLocations(String incidentId) => _room('location:update', incidentId)
      .map(LocationPoint.tryParse)
      .where((p) => p != null)
      .cast<LocationPoint>();

  bool sendIncidentLocation({
    required String incidentId,
    required double latitude,
    required double longitude,
    double? accuracy,
  }) =>
      emit('location:update', {
        'incidentId': incidentId,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': ?accuracy,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
      });

  // ----------------------------------------------------------- status

  /// Active SOS roster changes.
  Stream<Map<String, dynamic>> circleStatus(String incidentId) => _room('circle:status', incidentId);

  /// ESCALATED / DURESS / ENDED.
  Stream<Map<String, dynamic>> sosStatus(String incidentId) => _room('sos:status', incidentId);

  /// CANCELLED / RESOLVED.
  Stream<Map<String, dynamic>> incidentStatus(String incidentId) =>
      _room('incident:status', incidentId);

  /// Evidence upload progress.
  Stream<Map<String, dynamic>> documentStatus(String incidentId) =>
      _room('document:status', incidentId);

  /// Filters a room event to one incident. Payloads without an incidentId are
  /// let through, since the socket only receives events for joined rooms.
  Stream<Map<String, dynamic>> _room(String event, String incidentId) =>
      on(event).where((d) => d['incidentId'] == null || d['incidentId'] == incidentId);
}
