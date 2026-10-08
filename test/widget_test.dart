import 'package:flutter_test/flutter_test.dart';

import 'package:web_socket_app/models/chat_message.dart';
import 'package:web_socket_app/models/location_point.dart';

void main() {
  test('ChatMessage parses server payload', () {
    final m = ChatMessage.fromJson({
      'id': 'm1',
      'incidentId': 'i1',
      'senderId': 'u1',
      'type': 'TEXT',
      'body': 'hello',
      'document': null,
      'clientMessageId': 'c1',
      'createdAt': '2026-09-24T10:00:00.000Z',
    });
    expect(m.id, 'm1');
    expect(m.body, 'hello');
    expect(m.isDocument, isFalse);
    expect(m.delivery, DeliveryState.sent);
  });

  test('server echo matches optimistic message by clientMessageId', () {
    final pending = ChatMessage.pending(
      incidentId: 'i1',
      senderId: 'u1',
      body: 'hi',
      clientMessageId: 'c1',
    );
    final echo = ChatMessage.fromJson({
      'id': 'm1',
      'incidentId': 'i1',
      'senderId': 'u1',
      'body': 'hi',
      'clientMessageId': 'c1',
      'createdAt': '2026-09-24T10:00:00.000Z',
    });
    expect(pending.sameAs(echo), isTrue);
  });

  test('LocationPoint.tryParse handles share payload and null lastKnown', () {
    final p = LocationPoint.tryParse({
      'shareId': 's1',
      'ownerId': 'u1',
      'latitude': 12.34,
      'longitude': 56.78,
      'accuracy': 10,
      'altitude': null,
      'capturedAt': '2026-09-24T10:00:00.000Z',
    });
    expect(p, isNotNull);
    expect(p!.shareId, 's1');
    expect(p.userId, 'u1');
    expect(p.accuracy, 10.0);
    expect(LocationPoint.tryParse(null), isNull);
  });
}
