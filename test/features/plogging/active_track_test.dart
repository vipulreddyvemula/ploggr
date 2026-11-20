import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ploggr/features/plogging/application/active_track.dart';
import 'package:ploggr/features/plogging/data/location_source.dart';
import 'package:ploggr/features/plogging/data/plog_track.dart';
import 'package:ploggr/features/plogging/data/plog_api.dart';

class FakeGps extends Fake implements LocationSource {
  final stream = StreamController<RouteFix>.broadcast(sync: true);
  Future<void> Function() permission = () async {};
  @override
  Future<void> requestAccess() => permission();
  @override
  Stream<RouteFix> fixes() => stream.stream;
}

class FakePlogApi extends Fake implements PlogApi {
  final created = Completer<PlogTrack>();
  int starts = 0;
  int finishes = 0;
  PlogTrack? submitted;
  @override
  Future<PlogTrack?> active() async => null;
  @override
  Future<PlogTrack> start() {
    starts++;
    return created.future;
  }

  @override
  Future<void> finish(PlogTrack track) async {
    finishes++;
    submitted = track;
  }
}

void main() {
  late FakeGps gps;
  late FakePlogApi api;
  late ProviderContainer container;
  late ActiveTrackController controller;
  TrackView current() => container.read(activeTrackProvider);
  setUp(() {
    gps = FakeGps();
    api = FakePlogApi();
    container = ProviderContainer(
      overrides: [
        locationSourceProvider.overrideWithValue(gps),
        plogApiProvider.overrideWithValue(api),
      ],
    );
    controller = container.read(activeTrackProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await gps.stream.close();
  });
  test(
    'accumulates ordered fixes and meters, then freezes GPS and time',
    () async {
      final start = DateTime.now().toUtc().subtract(const Duration(seconds: 7));
      await controller.begin(PlogTrack('one', start));
      gps.stream.add((latitude: 0, longitude: 0));
      gps.stream.add((latitude: 0, longitude: 0.001));
      final result = controller.freeze()!;
      expect(result.route, [
        (latitude: 0.0, longitude: 0.0),
        (latitude: 0.0, longitude: 0.001),
      ]);
      expect(result.distanceMeters, closeTo(111, 1));
      expect(current().elapsed.inSeconds, greaterThanOrEqualTo(7));
      expect(current().phase, TrackPhase.stopped);
      expect(gps.stream.hasListener, isFalse);
      expect(controller.freeze(), same(result));
    },
  );
  test('late permission result cannot start tracking after stop', () async {
    final pending = Completer<void>();
    gps.permission = () => pending.future;
    final starting = controller.begin(PlogTrack('one', DateTime.now()));
    controller.freeze();
    pending.complete();
    await starting;
    expect(gps.stream.hasListener, isFalse);
  });
  test(
    'denial is recoverable and stream failure keeps existing fixes',
    () async {
      gps.permission = () async => throw LocationFailure.denied;
      await controller.begin(PlogTrack('one', DateTime.now()));
      expect(current().error, LocationFailure.denied.message);
      gps.permission = () async {};
      await controller.retryGps();
      gps.stream.add((latitude: 20, longitude: 30));
      gps.stream.addError(LocationFailure.disabled);
      expect(current().phase, TrackPhase.gpsError);
      expect(current().track!.route, hasLength(1));
      controller.clear();
      expect(current().phase, TrackPhase.idle);
    },
  );
  test(
    'waits for an owned active Plog before GPS and submits a single frozen track',
    () async {
      final starting = controller.startOrResume();
      await Future<void>.delayed(Duration.zero);
      await controller.startOrResume();
      expect(api.starts, 1);
      expect(gps.stream.hasListener, isFalse);
      api.created.complete(PlogTrack('created', DateTime.now().toUtc()));
      await starting;
      gps.stream.add((latitude: 1, longitude: 2));
      await Future.wait([controller.submit(), controller.submit()]);
      expect(api.finishes, 1);
      expect(api.submitted!.id, 'created');
      expect(api.submitted!.route.length, 1);
      expect(gps.stream.hasListener, isFalse);
      expect(current().phase, TrackPhase.completed);
    },
  );
}
