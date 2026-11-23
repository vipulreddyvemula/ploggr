import 'location_source.dart';

enum PhotoSource { camera, gallery, unknown }

class PhotoCapture {
  const PhotoCapture(
    this.source,
    this.capturedAt, {
    this.gps,
    this.embeddedLocation,
    this.embeddedTime = false,
  });

  final PhotoSource source;
  final DateTime capturedAt;
  final GpsSample? gps;
  final RouteFix? embeddedLocation;
  final bool embeddedTime;

  factory PhotoCapture.fromJson(Map<String, dynamic> json) => PhotoCapture(
    PhotoSource.values.byName(json['source'] as String),
    DateTime.parse(json['capturedAt'] as String),
    gps: json['gps'] is Map<String, dynamic>
        ? GpsSample.fromJson(json['gps'] as Map<String, dynamic>)
        : null,
    embeddedLocation: switch (json['embeddedLocation']) {
      {'latitude': num lat, 'longitude': num lon} => (
        latitude: lat.toDouble(),
        longitude: lon.toDouble(),
      ),
      _ => null,
    },
    embeddedTime: json['embeddedTime'] == true,
  );

  Map<String, dynamic> toJson() => {
    'source': source.name,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'gps': ?gps?.toJson(),
    if (embeddedTime) 'embeddedTime': true,
    if (embeddedLocation case final RouteFix point)
      'embeddedLocation': {
        'latitude': point.latitude,
        'longitude': point.longitude,
      },
  };
}
