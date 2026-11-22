import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

typedef RouteFix = ({double latitude, double longitude});

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
  Position? _latest;
  RouteFix? get recentFix {
    final p = _latest;
    if (p == null ||
        p.accuracy > 50 ||
        p.accuracy <= 0 ||
        DateTime.now().difference(p.timestamp).inSeconds > 60) {
      return null;
    }
    return (latitude: p.latitude, longitude: p.longitude);
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
    return platform.getCurrentPosition(
      locationSettings: AndroidSettings(
        forceLocationManager: true,
        accuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      ),
    );
  }

  // Listening starts the native stream. Cancelling releases the subscription.
  Stream<RouteFix> fixes() {
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
        .where(
          (p) =>
              !p.timestamp.isBefore(since) &&
              p.latitude.abs() <= 90 &&
              p.longitude.abs() <= 180,
        )
        .map((p) {
          _latest = p;
          return (latitude: p.latitude, longitude: p.longitude);
        });
  }
}

final locationSourceProvider = Provider<LocationSource>(
  (ref) => LocationSource(GeolocatorPlatform.instance),
);
