import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

typedef RouteFix = ({double latitude, double longitude});

class GpsSample {
  const GpsSample(this.point, this.recordedAt, this.accuracyMeters);

  factory GpsSample.fromPosition(Position position) => GpsSample(
    (latitude: position.latitude, longitude: position.longitude),
    position.timestamp.toUtc(),
    position.accuracy,
  );

  factory GpsSample.fromJson(Map<String, dynamic> json) => GpsSample(
    (
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
    ),
    DateTime.parse(json['recordedAt'] as String),
    (json['accuracyMeters'] as num).toDouble(),
  );

  final RouteFix point;
  final DateTime recordedAt;
  final double accuracyMeters;

  bool get valid =>
      point.latitude.abs() <= 90 &&
      point.longitude.abs() <= 180 &&
      accuracyMeters.isFinite &&
      accuracyMeters >= 0.1 &&
      accuracyMeters <= 10000;

  bool freshAt(DateTime time, {Duration maxAge = const Duration(seconds: 30)}) {
    final age = time.difference(recordedAt);
    return age >= const Duration(seconds: -5) && age <= maxAge;
  }

  Map<String, dynamic> toJson() => {
    'latitude': point.latitude,
    'longitude': point.longitude,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'accuracyMeters': accuracyMeters,
  };
}

/// Android 13+ asks once before displaying the ongoing tracking notification.
Future<void> requestTrackingNotification() async {
  if (Platform.isAndroid) {
    await const MethodChannel(
      'ploggr/tracking',
    ).invokeMethod<void>('requestNotification');
  }
}

enum LocationFailure implements Exception {
  disabled('Turn on device location, then retry GPS.'),
  denied('Allow location while using Ploggr, then retry GPS.'),
  blocked('Allow location for Ploggr in Android settings, then retry GPS.'),
  unavailable('GPS updates stopped. Check device location and retry.');

  const LocationFailure(this.message);
  final String message;
}

class LocationSource {
  LocationSource(this.platform);
  final GeolocatorPlatform platform;
  GpsSample? _latest;
  GpsSample? get recentSample {
    final fix = _latest;
    return fix != null && fix.freshAt(DateTime.now()) ? fix : null;
  }

  RouteFix? get recentFix => recentSample?.point;

  Future<GpsSample> photographLocation() async {
    await requestAccess();
    final cached = recentSample;
    if (cached != null && cached.accuracyMeters <= 40) return cached;
    final p = await _currentPosition();
    final sample = GpsSample.fromPosition(p);
    if (p.isMocked || !sample.valid || !sample.freshAt(DateTime.now())) {
      throw LocationFailure.unavailable;
    }
    _latest = sample;
    return sample;
  }

  Future<void> requestAccess() async {
    if (!await platform.isLocationServiceEnabled()) {
      throw LocationFailure.disabled;
    }
    var permission = await platform.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await platform.requestPermission();
    }
    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return;
      case LocationPermission.deniedForever:
        throw LocationFailure.blocked;
      default:
        throw LocationFailure.denied;
    }
  }

  Future<Position?> lastKnown() async {
    try {
      final permission = await platform.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        return await platform.getLastKnownPosition();
      }
    } catch (_) {}
    return null;
  }

  /// Supplies a starting map area using permission already granted to the app.
  Future<RouteFix?> cachedPoint() async {
    final recent = recentFix;
    if (recent != null) return recent;
    final cached = await lastKnown();
    return cached == null
        ? null
        : (latitude: cached.latitude, longitude: cached.longitude);
  }

  Future<Position> current() async {
    await requestAccess();
    return _currentPosition();
  }

  Future<Position> _currentPosition() => platform.getCurrentPosition(
    locationSettings: AndroidSettings(
      forceLocationManager: true,
      accuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 10),
    ),
  );

  // Listening starts the native stream. Cancelling releases the subscription.
  Stream<GpsSample> fixes() {
    final since = DateTime.now();
    return platform
        .getPositionStream(
          locationSettings: AndroidSettings(
            // Use Android location services directly, including on devices without Play Services.
            forceLocationManager: true,
            accuracy: LocationAccuracy.high,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Plog in progress',
              notificationText:
                  'Recording your route until you finish this Plog.',
              notificationChannelName: 'Plog tracking',
              setOngoing: true,
              enableWakeLock: true,
            ),
            distanceFilter: 3,
            intervalDuration: const Duration(seconds: 2),
          ),
        )
        .where((p) => !p.isMocked && !p.timestamp.isBefore(since))
        .map(GpsSample.fromPosition)
        .where(
          (fix) =>
              fix.valid &&
              fix.accuracyMeters <= 50 &&
              fix.freshAt(DateTime.now()),
        )
        .map((fix) {
          _latest = fix;
          return fix;
        });
  }
}

final locationSourceProvider = Provider<LocationSource>(
  (ref) => LocationSource(GeolocatorPlatform.instance),
);
