/// A GPS fix, as broadcast on `location:updated` (share room) and
/// `location:update` (incident room), or returned as `lastKnown`.
class LocationPoint {
  LocationPoint({
    required this.latitude,
    required this.longitude,
    this.shareId,
    this.incidentId,
    this.userId,
    this.accuracy,
    this.altitude,
    this.capturedAt,
  });

  factory LocationPoint.fromJson(Map<String, dynamic> json) => LocationPoint(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        shareId: json['shareId']?.toString(),
        incidentId: json['incidentId']?.toString(),
        userId: (json['ownerId'] ?? json['userId'] ?? json['senderId'])?.toString(),
        accuracy: (json['accuracy'] as num?)?.toDouble(),
        altitude: (json['altitude'] as num?)?.toDouble(),
        capturedAt: DateTime.tryParse(json['capturedAt']?.toString() ?? '')?.toLocal(),
      );

  /// Returns null if [json] has no coordinates (e.g. `lastKnown: null`).
  static LocationPoint? tryParse(dynamic json) {
    if (json is! Map || json['latitude'] is! num || json['longitude'] is! num) return null;
    return LocationPoint.fromJson(Map<String, dynamic>.from(json));
  }

  final double latitude;
  final double longitude;
  final String? shareId;
  final String? incidentId;
  final String? userId;
  final double? accuracy;
  final double? altitude;
  final DateTime? capturedAt;

  String get coords => '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
}
