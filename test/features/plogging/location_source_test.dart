import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ploggr/features/plogging/data/location_source.dart';

class _Device extends GeolocatorPlatform {
  bool enabled = true;
  LocationPermission permission = LocationPermission.denied;
  LocationPermission grant = LocationPermission.denied;
  int requests = 0;
  Position? position;
  final positions = StreamController<Position>();
  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => position;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async => position!;

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
  test('discovery uses a cached or current fix without prompting', () async {
    final device = _Device()
      ..position = Position(
        latitude: 17.5,
        longitude: 78.1,
        timestamp: DateTime.now(),
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
    final source = LocationSource(device);
    expect(await source.cachedPoint(), isNull);
    expect(await source.currentIfPermitted(), isNull);
    device.permission = LocationPermission.whileInUse;
    const point = (latitude: 17.5, longitude: 78.1);
    expect(await source.cachedPoint(), point);
    expect(await source.currentIfPermitted(), point);
    device.enabled = false;
    expect(await source.cachedPoint(), point);
    expect(await source.currentIfPermitted(), isNull);
    expect(device.requests, 0);
  });

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
    final sub = source.fixes().listen((fix) => route.add(fix.point));
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
