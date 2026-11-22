import 'location_source.dart';

class CompletedPlog {
  const CompletedPlog(
    this.id,
    this.startedAt,
    this.endedAt,
    this.seconds,
    this.meters,
    this.route, [
    this.breaks = const [],
  ]);
  final String id;
  final DateTime startedAt, endedAt;
  final int seconds;
  final double meters;
  final List<RouteFix>? route;
  final List<int> breaks;

  factory CompletedPlog.parse(
    Object? value,
    String owner, {
    bool detail = false,
  }) {
    if (value case {
      'id': String id,
      'userId': String userId,
      'status': 'completed',
      'startedAt': String start,
      'endedAt': String end,
      'durationSeconds': int seconds,
      'distanceMeters': num meters,
    } when userId == owner) {
      List<RouteFix>? route;
      if (detail) {
        if (value['route'] case final List points) {
          route = [
            for (final point in points)
              switch (point) {
                {'latitude': num lat, 'longitude': num lon} => (
                  latitude: lat.toDouble(),
                  longitude: lon.toDouble(),
                ),
                _ => throw const FormatException('Invalid GPS fix'),
              },
          ];
        } else {
          throw const FormatException('Missing completed route');
        }
      }
      return CompletedPlog(
        id,
        DateTime.parse(start),
        DateTime.parse(end),
        seconds,
        meters.toDouble(),
        route,
        List<int>.from(value['segmentStarts'] as List? ?? []),
      );
    }
    throw const FormatException('Invalid completed activity');
  }
}

typedef ActivityPageData = ({List<CompletedPlog> items, String? nextCursor});
