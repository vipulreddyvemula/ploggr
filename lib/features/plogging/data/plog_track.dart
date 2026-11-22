import 'package:geolocator/geolocator.dart';
import 'location_source.dart';

class PlogTrack {
  const PlogTrack(
    this.id,
    this.startedAt, {
    this.route = const [],
    this.distanceMeters = 0,
    this.endedAt,
    this.pauses = const {},
  });
  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<RouteFix> route;
  final double distanceMeters;

  final Map<String, dynamic> pauses;
  DateTime? get pausedAt => DateTime.tryParse(pauses['since'] as String? ?? '');
  bool get withoutGps => pauses['noGps'] == true;
  PlogTrack routeChoice(bool off) => PlogTrack(
    id,
    startedAt,
    route: route,
    endedAt: endedAt,
    distanceMeters: distanceMeters,
    pauses: {...pauses, 'noGps': off},
  );
  Duration get pausedTime => Duration(milliseconds: pauses['ms'] as int? ?? 0);
  List<int> get breaks => List<int>.from(pauses['breaks'] as List? ?? []);
  Duration durationAt(DateTime now) {
    final d = (pausedAt ?? endedAt ?? now).difference(startedAt) - pausedTime;
    return d.isNegative ? Duration.zero : d;
  }

  PlogTrack pause(DateTime now) => PlogTrack(
    id,
    startedAt,
    route: route,
    distanceMeters: distanceMeters,
    pauses: {...pauses, 'since': now.toIso8601String()},
  );
  PlogTrack resume(DateTime now) => PlogTrack(
    id,
    startedAt,
    route: route,
    distanceMeters: distanceMeters,
    pauses: {
      ...pauses,
      'since': null,
      'ms': (pausedTime + now.difference(pausedAt!)).inMilliseconds,
      'breaks': {...breaks, if (route.isNotEmpty) route.length}.toList(),
    },
  );
  PlogTrack append(RouteFix point) {
    final previous = route.lastOrNull;
    if (previous == point) return this;
    final segment = previous == null || breaks.contains(route.length)
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
      pauses: pauses,
      route: List.unmodifiable([...route, point]),
      distanceMeters: distanceMeters + segment,
    );
  }

  PlogTrack finish(DateTime end) => PlogTrack(
    id,
    startedAt,
    endedAt: end,
    pauses: pauses,
    route: route,
    distanceMeters: distanceMeters,
  );
}
