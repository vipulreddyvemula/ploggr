import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ploggr/features/plogging/data/location_source.dart';

class _Device extends GeolocatorPlatform {
  bool enabled = true;
  LocationPermission grant = LocationPermission.denied;
  int requests = 0;
  final positions = StreamController<Position>();
  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.denied;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return grant;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      positions.stream;
}

void main() {
  test(
    'reports unavailable services and distinguishes a permanent denial',
    () async {
      final device = _Device()..enabled = false;
      final source = LocationSource(device);
      await expectLater(
        source.requestAccess(),
        throwsA(LocationFailure.disabled),
      );
      expect(device.requests, 0);
      device.enabled = true;
      await expectLater(
        source.requestAccess(),
        throwsA(LocationFailure.denied),
      );
      device.grant = LocationPermission.deniedForever;
      await expectLater(
        source.requestAccess(),
        throwsA(LocationFailure.blocked),
      );
      expect(device.positions.hasListener, isFalse);
    },
  );

  test('delivers fresh fixes only while subscribed', () async {
    final device = _Device()..grant = LocationPermission.whileInUse;
    final source = LocationSource(device);
    await source.requestAccess();
    final route = <RouteFix>[];
    final sub = source.fixes().listen(route.add);
    Position fix(DateTime time) => Position(
      latitude: 17.5,
      longitude: 78.1,
      timestamp: time,
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
    device.positions.add(fix(DateTime(2001)));
    device.positions.add(fix(DateTime.now()));
    await Future<void>.delayed(Duration.zero);
    expect(route, [(latitude: 17.5, longitude: 78.1)]);
    await sub.cancel();
    expect(device.positions.hasListener, isFalse);
    await device.positions.close();
  });
}
