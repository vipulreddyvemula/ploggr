import 'dart:collection';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import 'location_source.dart';

typedef _RoutePoint = ({RouteFix point, GpsSample? sample});

/// Each snapshot sees a fixed prefix. Appending to the latest snapshot
/// extends the shared backing list without copying the previous fixes.
class _RouteView extends ListBase<RouteFix> {
  _RouteView(this.points, this.length);
  final List<_RoutePoint> points;
  @override
  final int length;
  @override
  set length(int value) => throw UnsupportedError('Read-only route');
  @override
  RouteFix operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return points[index].point;
  }

  @override
  void operator []=(int index, RouteFix value) =>
      throw UnsupportedError('Read-only route');
}

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

  static const maxPoints = 20000;
  bool get hasGpsMetadata =>
      pauses['timed'] == true ||
      route.isNotEmpty && sampleAt(route.length - 1) != null;

  static List<RouteFix> restoredRoute(
    Iterable<({RouteFix point, GpsSample? sample})> points,
  ) {
    final records = points.toList();
    return _RouteView(records, records.length);
  }

  GpsSample? sampleAt(int index) {
    final view = route;
    return view is _RouteView ? view.points[index].sample : null;
  }

  DateTime? get pausedAt => DateTime.tryParse(pauses['since'] as String? ?? '');
  bool get isOnAnotherDevice => pauses['otherDevice'] == true;
  PlogTrack deviceStatus(bool other) =>
      _withPauses({...pauses, 'otherDevice': other});
  bool get recoveringPhotos => pauses['recoveringPhotos'] == true;
  PlogTrack photoRecovery(bool pending) =>
      _withPauses({...pauses, 'recoveringPhotos': pending});
  bool get cancellationPending => pauses['cancel'] == true;
  PlogTrack requestCancellation() => _withPauses({...pauses, 'cancel': true});
  PlogTrack useTimedRoute() => _withPauses({...pauses, 'timed': true});
  bool get withoutGps => pauses['noGps'] == true;
  Duration get pausedTime => Duration(milliseconds: pauses['ms'] as int? ?? 0);
  List<int> get breaks => List<int>.from(pauses['breaks'] as List? ?? []);

  Duration durationAt(DateTime now) {
    final d = (pausedAt ?? endedAt ?? now).difference(startedAt) - pausedTime;
    return d.isNegative ? Duration.zero : d;
  }

  PlogTrack _withPauses(Map<String, dynamic> next) => PlogTrack(
    id,
    startedAt,
    endedAt: endedAt,
    route: route,
    distanceMeters: distanceMeters,
    pauses: next,
  );

  PlogTrack discontinuity() {
    final segments = breaks;
    if (route.isEmpty || segments.lastOrNull == route.length) return this;
    return _withPauses({
      ...pauses,
      'breaks': [...segments, route.length],
    });
  }

  PlogTrack routeChoice(bool off) =>
      _withPauses({...pauses, 'noGps': off}).discontinuity();

  PlogTrack pause(DateTime now) =>
      _withPauses({...pauses, 'since': now.toIso8601String()});

  PlogTrack resume(DateTime now) => _withPauses({
    ...pauses,
    'since': null,
    'ms':
        (pausedTime +
                (now.isBefore(pausedAt!)
                    ? Duration.zero
                    : now.difference(pausedAt!)))
            .inMilliseconds,
  }).discontinuity();

  PlogTrack append(RouteFix point, {GpsSample? sample}) {
    if (route.length >= maxPoints ||
        sample != null && (!sample.valid || sample.accuracyMeters > 50)) {
      return this;
    }
    final previous = route.lastOrNull;
    final prior = previous == null ? null : sampleAt(route.length - 1);
    var base = this;
    final gap = sample == null || prior == null
        ? null
        : sample.recordedAt.difference(prior.recordedAt);
    if (gap != null && gap <= Duration.zero) return this;
    if (gap != null && gap > const Duration(seconds: 30) ||
        prior == null && sample != null) {
      base = discontinuity();
    }
    var meters = 0.0;
    if (previous != null &&
        (base.pauses['breaks'] as List?)?.lastOrNull != route.length) {
      meters = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        point.latitude,
        point.longitude,
      );
      if (gap != null) {
        final uncertainty = math.max(
          5,
          math.min(20, (sample!.accuracyMeters + prior!.accuracyMeters) / 2),
        );
        if (meters < uncertainty ||
            meters > 7 * gap.inMilliseconds / 1000 + uncertainty) {
          return this;
        }
      } else if (previous == point) {
        return this;
      }
    }
    final old = route;
    final points = old is _RouteView
        ? (old.length == old.points.length
              ? old.points
              : old.points.sublist(0, old.length))
        : [for (final p in old) (point: p, sample: null as GpsSample?)];
    points.add((point: point, sample: sample));
    return PlogTrack(
      id,
      startedAt,
      pauses: base.pauses,
      route: _RouteView(points, points.length),
      distanceMeters: distanceMeters + meters,
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
