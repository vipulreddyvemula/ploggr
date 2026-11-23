import 'location_source.dart';

typedef CleanupLocation = ({
  String id,
  String category,
  String place,
  RouteFix point,
});

class CompletedPlog {
  const CompletedPlog(
    this.id,
    this.startedAt,
    this.endedAt,
    this.seconds,
    this.meters,
    this.route, [
    this.breaks = const [],
    this.verifiedCleanups = 0,
    this.unverifiedCleanups = 0,
    this.alreadyCollected = 0,
    this.hasRoute,
    this.pickupCount,
    this.photoCount,
    this.analysisState,
    this.cleanupLocations = const [],
  ]);
  final String id;
  final DateTime startedAt, endedAt;
  final int seconds;
  final double meters;
  final List<RouteFix>? route;
  final List<int> breaks;
  final int verifiedCleanups, unverifiedCleanups, alreadyCollected;
  final bool? hasRoute;
  final int? pickupCount, photoCount;
  final String? analysisState;
  final List<CleanupLocation> cleanupLocations;

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
        (value['cleanupClaims'] as Map?)?['verified'] as int? ?? 0,
        (value['cleanupClaims'] as Map?)?['unverified'] as int? ?? 0,
        (value['cleanupClaims'] as Map?)?['alreadyCollected'] as int? ?? 0,
        route == null ? value['hasRoute'] as bool? : route.isNotEmpty,
        value['pickupCount'] as int?,
        value['photoCount'] as int?,
        value['analysisState'] as String?,
        [
          for (final cleanup in (value['cleanupLocations'] as List? ?? []))
            if (cleanup case {
              'id': String id,
              'category': String category,
              'place': String place,
              'latitude': num lat,
              'longitude': num lon,
            })
              (
                id: id,
                category: category,
                place: place,
                point: (latitude: lat.toDouble(), longitude: lon.toDouble()),
              ),
        ],
      );
    }
    throw const FormatException('Invalid completed activity');
  }
}

typedef ActivityPageData = ({List<CompletedPlog> items, String? nextCursor});
