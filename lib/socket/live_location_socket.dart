import '../models/location_point.dart';
import 'haven_socket.dart';

/// Live-location share events.
///
/// Name trap: the share room broadcasts `location:updated` (with a "d"),
/// the incident room broadcasts `location:update`.
extension LiveLocationSocket on HavenSocket {
  /// Ack: `{ ok, shareId, share, lastKnown }`.
  Future<Map<String, dynamic>> subscribeShare(String shareId) =>
      subscribe(WsRoom.share(shareId));

  void unsubscribeShare(String shareId) => unsubscribe(WsRoom.share(shareId));

  /// Invite from a circle member; arrives in the user room before subscribe.
  Stream<Map<String, dynamic>> get shareStarted => on('share:started');

  Stream<LocationPoint> shareLocations(String shareId) => on('location:updated')
      .where((d) => d['shareId'] == shareId)
      .map(LocationPoint.tryParse)
      .where((p) => p != null)
      .cast<LocationPoint>();

  Stream<Map<String, dynamic>> shareStopped(String shareId) =>
      on('share:stopped').where((d) => d['shareId'] == null || d['shareId'] == shareId);

  /// Owner streams GPS. Returns false if the socket is offline (fix dropped).
  bool sendShareLocation({
    required String shareId,
    required double latitude,
    required double longitude,
    double? accuracy,
    double? altitude,
  }) =>
      emit('location:update', {
        'shareId': shareId,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': ?accuracy,
        'altitude': ?altitude,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
      });
}
