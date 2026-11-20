import 'package:geolocator/geolocator.dart';
import 'location_source.dart';

class PlogTrack {
  const PlogTrack(
    this.id,
    this.startedAt, {
    this.route = const [],
    this.distanceMeters = 0,
    this.endedAt,
  });
  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<RouteFix> route;
  final double distanceMeters;

  PlogTrack append(RouteFix point) {
    final previous = route.lastOrNull;
    if (previous == point) return this;
    final segment = previous == null
        ? 0.0
        : Geolocator.distanceBetween(
            previous.latitude,
            previous.longitude,
            point.latitude,
            point.longitude,
          );
    return PlogTrack(
      id,
      startedAt,
      route: List.unmodifiable([...route, point]),
      distanceMeters: distanceMeters + segment,
    );
  }

  PlogTrack finish(DateTime end) => PlogTrack(
    id,
    startedAt,
    endedAt: end,
    route: route,
    distanceMeters: distanceMeters,
  );
}
