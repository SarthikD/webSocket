enum DeliveryState { sending, sent, failed }

/// Payload of `chat:message` and of the `chat:send` ack.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.incidentId,
    required this.senderId,
    required this.type,
    required this.body,
    required this.createdAt,
    this.document,
    this.clientMessageId,
    this.delivery = DeliveryState.sent,
    this.senderName
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id']?.toString(),
        incidentId: json['incidentId']?.toString() ?? '',
        senderId: json['senderId']?.toString() ?? '',
        senderName: json['senderName']?.toString(),
        type: json['type']?.toString() ?? 'TEXT',
        body: json['body']?.toString(),
        document: json['document'] is Map ? Map<String, dynamic>.from(json['document']) : null,
        clientMessageId: json['clientMessageId']?.toString(),
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
      );

  /// Optimistic local copy shown until the server ack arrives.
  factory ChatMessage.pending({
    required String incidentId,
    required String senderId,
    required String body,
    required String clientMessageId,
  }) =>
      ChatMessage(
        id: null,
        incidentId: incidentId,
        senderId: senderId,
        type: 'TEXT',
        body: body,
        clientMessageId: clientMessageId,
        createdAt: DateTime.now(),
        delivery: DeliveryState.sending,
      );

  /// Null until the server has stored the message.
  final String? id;
  final String incidentId;
  final String senderId;

  /// `TEXT`, or `DOCUMENT` when an evidence upload finishes.
  final String type;
  final String? body;
  final Map<String, dynamic>? document;

  /// Client-generated idempotency key. Reuse it when resending.
  final String? clientMessageId;
  final DateTime createdAt;
  DeliveryState delivery;

  var senderName;

  bool get isDocument => type == 'DOCUMENT';

  /// True if [other] is the same logical message (server echo of an
  /// optimistic send, or a duplicate delivery).
  bool sameAs(ChatMessage other) =>
      (id != null && id == other.id) ||
      (clientMessageId != null && clientMessageId == other.clientMessageId);
}
