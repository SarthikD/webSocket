import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../config.dart';

class LocationUnavailable implements Exception {
  LocationUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Listens to GPS and hands the latest fix to [onFix] at most once per
/// [interval], so the socket is not flooded by high-rate position streams.
class LocationTracker {
  LocationTracker(this.onFix, {this.interval = kLocationSendInterval});

  final void Function(Position position) onFix;
  final Duration interval;

  StreamSubscription<Position>? _positions;
  Timer? _timer;
  Position? _latest;
  Position? _lastSent;

  bool get isRunning => _positions != null;

  /// Throws [LocationUnavailable] if services are off or permission denied.
  Future<void> start() async {
    if (isRunning) return;
    await ensurePermission();
    _positions = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).listen((p) => _latest = p);
    _timer = Timer.periodic(interval, (_) => _flush());
    // Send something right away instead of waiting for the first tick.
    try {
      _latest = await Geolocator.getLastKnownPosition() ?? _latest;
    } catch (_) {
      // Not supported on web; the stream will deliver the first fix.
    }
    _flush();
  }

  void stop() {
    _positions?.cancel();
    _positions = null;
    _timer?.cancel();
    _timer = null;
    _latest = null;
    _lastSent = null;
  }

  void _flush() {
    final latest = _latest;
    if (latest == null || identical(latest, _lastSent)) return;
    _lastSent = latest;
    onFix(latest);
  }

  static Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationUnavailable('Location services are disabled');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw LocationUnavailable('Location permission denied');
    }
  }

  /// One-off fix for `POST /incident/sos`. Returns null instead of throwing,
  /// because SOS must never be blocked by missing GPS.
  static Future<Position?> tryCurrentPosition() async {
    try {
      await ensurePermission();
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 5),
        ),
      );
    } catch (_) {
      return Geolocator.getLastKnownPosition().catchError((_) => null);
    }
  }
}
