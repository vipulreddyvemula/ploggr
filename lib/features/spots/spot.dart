import 'dart:typed_data';
import '../plogging/data/location_source.dart';

import '../plogging/data/photo_capture.dart';

typedef SpotPhoto = ({
  String id,
  String type,
  Uint8List bytes,
  PhotoCapture? capture,
});
typedef MapViewport = ({double south, double west, double north, double east});
const world = (south: -90.0, west: -180.0, north: 90.0, east: 180.0);

class Spot {
  Spot.fromJson(Map data)
    : id = data['id'] as String,
      category = data['category'] as String,
      place = data['place'] as String? ?? '',
      needsChecking = data['needsChecking'] == true,
      stale = data['stale'] == true,
      locationSource = data['locationSource'] as String? ?? 'manual',
      previousReportId = data['previousReportId'] as String?,
      createdAt = DateTime.tryParse(data['createdAt']?.toString() ?? ''),
      lastSeenAt = DateTime.tryParse(data['lastSeenAt']?.toString() ?? ''),
      notes = data['notes'] as String,
      status = data['status'] as String,
      mine = data['mine'] as bool,
      photoCount = data['photoCount'] as int,
      point = (
        latitude: (data['latitude'] as num).toDouble(),
        longitude: (data['longitude'] as num).toDouble(),
      );
  final String id, category, notes, status, place;
  final DateTime? createdAt, lastSeenAt;
  final bool needsChecking, stale;
  final String locationSource;
  final String? previousReportId;
  String get statusLabel => status == 'collected'
      ? 'Collected'
      : needsChecking
      ? 'Needs checking'
      : stale
      ? 'Needs reconfirmation'
      : 'Needs cleanup';
  final bool mine;
  final int photoCount;
  final RouteFix point;
}

class SpotDetails {
  const SpotDetails(
    this.point,
    this.category,
    this.notes, [
    this.place = '',
    this.locationSource,
    this.previousReportId,
  ]);
  final RouteFix point;
  final String category, notes, place;
  final String? locationSource, previousReportId;
  Map<String, String> toJson() => {
    'latitude': point.latitude.toString(),
    'longitude': point.longitude.toString(),
    'category': category,
    'notes': notes,
    if (place.isNotEmpty) 'place': place,
    'locationSource': ?locationSource,
    'previousReportId': ?previousReportId,
  };
}
