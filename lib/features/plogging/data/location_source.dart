import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

typedef RouteFix = ({double latitude, double longitude});

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

  // Listening starts the native stream. Cancelling releases the subscription.
  Stream<RouteFix> fixes() {
    final since = DateTime.now();
    return platform
        .getPositionStream(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.high,
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
        .map((p) => (latitude: p.latitude, longitude: p.longitude));
  }
}

final locationSourceProvider = Provider<LocationSource>(
  (ref) => LocationSource(GeolocatorPlatform.instance),
);
