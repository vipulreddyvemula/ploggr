import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:ploggr/core/network/protected_api.dart';
import 'package:ploggr/features/plogging/data/completed_plog.dart';
import 'package:ploggr/features/spots/spot.dart';
import 'package:ploggr/features/plogging/data/photo_capture.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ploggr/features/plogging/application/active_track.dart';
import 'package:ploggr/features/plogging/data/location_source.dart';
import 'package:ploggr/features/plogging/data/plog_track.dart';
import 'package:ploggr/features/plogging/data/plog_api.dart';
import 'package:ploggr/features/plogging/data/plog_drafts.dart';

class FakeGps extends Fake implements LocationSource {
  final stream = StreamController<GpsSample>.broadcast(sync: true);
  Future<void> Function() permission = () async {};
  @override
  Future<void> requestAccess() => permission();
  @override
  Stream<GpsSample> fixes() => stream.stream;
}

class FakePlogApi extends Fake implements PlogApi {
  final created = Completer<PlogTrack>();
  bool offline = false;
  bool recoveryOffline = false;
  int cancellations = 0, recoveries = 0;
  PlogTrack? remote;
  Completer<void>? cancelling;
  String? failedPhoto;
  final uploads = <String>[];
  int starts = 0;
  int finishes = 0;
  PlogTrack? submitted;
  @override
  Future<PlogTrack?> active() async => remote;

  @override
  Future<PlogTrack> transfer(String id) async =>
      remote = remote!.deviceStatus(false);

  @override
  Future<List<SpotPhoto>> recoverEvidence(String plogId) async {
    recoveries++;
    if (recoveryOffline) throw const ProtectedApiFailure(null);
    return [];
  }

  @override
  Future<void> cancel(String id) async {
    cancellations++;
    await cancelling?.future;
    if (offline) throw const ProtectedApiFailure(null);
  }

  @override
  Future<PlogTrack> start() {
    starts++;
    return created.future;
  }

  @override
  Future<void> upload(
    String plogId,
    String photoId,
    String type,
    Uint8List bytes, {
    PhotoCapture? capture,
    ProgressCallback? onProgress,
  }) async {
    uploads.add(photoId);
    if (photoId == failedPhoto) throw StateError('storage unavailable');
  }

  @override
  Future<CompletedPlog> finish(
    PlogTrack track, {
    List<String> pickupIds = const [],
  }) async {
    finishes++;
    submitted = track;
    if (offline) throw StateError('offline');
    return CompletedPlog(
      track.id,
      track.startedAt,
      track.endedAt!,
      10,
      25.0,
      null,
    );
  }
}

class MemoryDrafts extends Fake implements PlogDrafts {
  @override
  Future<List<Map<String, Object?>>> observations({
    String? plog,
    bool unsent = false,
  }) async => [];
  PlogTrack? record;
  @override
  Future<Map<String, Map<String, dynamic>>> collectionGroups(
    String plog,
  ) async => {};
  @override
  Future<List<Map<String, Object?>>> pickups(String plog) async => [];
  bool locked = false;
  final photos = ['photo'];
  @override
  Future<bool> photosLocked(String id) async => locked;
  @override
  Future<List<String>> lockPhotos(String id) async {
    if (photos.isEmpty) throw StateError('no photos');
    locked = true;
    return photos;
  }

  @override
  Future<List<String>> photoRemovals(String id) async => [];
  @override
  Future<({String type, Uint8List bytes, PhotoCapture? capture})> readPhoto(
    String plog,
    String id,
  ) async => (type: 'image/png', bytes: Uint8List(0), capture: null);
  @override
  Future<PlogTrack?> load() async => record;
  @override
  Future<bool> exists() async => record != null;
  @override
  Future<void> recoverPickupPhotos(String plog, List<SpotPhoto> photos) async {}
  @override
  Future<void> save(PlogTrack track) async {
    record = track;
  }

  @override
  Future<void> remove(String id) async {
    if (record?.id == id) record = null;
  }
}

void main() {
  GpsSample fix(double lat, double lon, {int age = 0, double accuracy = 5}) =>
      GpsSample(
        (latitude: lat, longitude: lon),
        DateTime.now().toUtc().subtract(Duration(seconds: age)),
        accuracy,
      );
  late MemoryDrafts drafts;
  late FakeGps gps;
  late FakePlogApi api;
  late ProviderContainer container;
  late ActiveTrackController controller;
  TrackView current() => container.read(activeTrackProvider);
  setUp(() {
    drafts = MemoryDrafts();
    gps = FakeGps();
    api = FakePlogApi();
    container = ProviderContainer(
      overrides: [
        locationSourceProvider.overrideWithValue(gps),
        plogApiProvider.overrideWithValue(api),
        plogDraftsProvider.overrideWithValue(drafts),
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
      final start = DateTime.now().toUtc().subtract(
        const Duration(seconds: 21),
      );
      await controller.begin(PlogTrack('one', start));
      gps.stream.add(fix(0, 0, age: 18));
      gps.stream.add(fix(0, 0.001));
      final result = controller.freeze()!;
      expect(result.route, [
        (latitude: 0.0, longitude: 0.0),
        (latitude: 0.0, longitude: 0.001),
      ]);
      expect(result.distanceMeters, closeTo(111, 1));
      expect(current().elapsed.inSeconds, greaterThanOrEqualTo(21));
      expect(current().phase, TrackPhase.stopped);
      expect(gps.stream.hasListener, isFalse);
      expect(controller.freeze(), same(result));
    },
  );
  test(
    'pausing excludes stopped time and movement, including after restoring a route-free walk',
    () async {
      final start = DateTime.utc(2026, 1, 1);
      final t = PlogTrack('p', start)
          .append((latitude: 1.0, longitude: 2.0))
          .pause(start.add(const Duration(minutes: 2)))
          .resume(start.add(const Duration(minutes: 12)))
          .append((latitude: 12.0, longitude: 30.0));
      expect(t.breaks, [1]);
      expect(t.distanceMeters, 0);
      expect(
        t.durationAt(start.add(const Duration(minutes: 15))),
        const Duration(minutes: 5),
      );
      final now = DateTime.now().toUtc();
      await controller.begin(PlogTrack('p', now));
      gps.permission = () async {
        throw LocationFailure.denied;
      };
      await controller.pause();
      await controller.resume();
      controller.withoutRoute();
      await controller.pause();
      await controller.resume();
      expect(current().phase, TrackPhase.noRoute);
      expect(gps.stream.hasListener, isFalse);
      expect(drafts.record!.withoutGps, isTrue);
    },
  );
  test('keeps route snapshots stable and enforces the long-session limit', () {
    final start = DateTime.utc(2026, 11, 22);
    var track = PlogTrack('long', start);
    PlogTrack? first;
    for (var n = 0; n <= PlogTrack.maxPoints; n++) {
      final point = (latitude: n * .00008, longitude: 0.0);
      track = track.append(
        point,
        sample: GpsSample(point, start.add(Duration(seconds: 2 * n)), 4),
      );
      first ??= track;
    }
    expect(track.route, hasLength(PlogTrack.maxPoints));
    expect(first!.route, [(latitude: 0.0, longitude: 0.0)]);
    expect(
      track
          .sampleAt(track.route.length - 1)!
          .recordedAt
          .difference(start)
          .inHours,
      11,
    );
    expect(track.route.last.latitude, closeTo(1.59992, 0.00001));
  });

  test('late permission result cannot start tracking after stop', () async {
    final pending = Completer<void>();
    gps.permission = () => pending.future;
    final starting = controller.begin(PlogTrack('one', DateTime.now()));
    await Future<void>.delayed(Duration.zero);
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
      gps.stream.add(fix(20, 30));
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
      gps.stream.add(fix(1, 2));
      await Future.wait([controller.submit(), controller.submit()]);
      expect(api.finishes, 1);
      expect(api.submitted!.id, 'created');
      expect(api.submitted!.route.length, 1);
      expect(gps.stream.hasListener, isFalse);
      expect(current().phase, TrackPhase.completed);
      expect(current().elapsed, const Duration(seconds: 10));
      expect(current().completion!.meters, 25.0);
    },
  );
  test(
    'can edit an incomplete selection and retry a partial upload with the same IDs',
    () async {
      await controller.begin(PlogTrack('existing', DateTime.now().toUtc()));
      await controller.selectEvidence();
      drafts.photos.clear();
      await controller.submit();
      expect(current().phase, TrackPhase.stopped);
      expect(api.uploads, isEmpty);
      final frozen = current().track;
      drafts.photos.addAll(['first', 'second']);
      api.failedPhoto = 'second';
      await controller.submit();
      expect(current().phase, TrackPhase.saveError);
      expect(api.finishes, 0);
      expect(drafts.locked, isTrue);
      api.failedPhoto = null;
      await controller.submit();
      expect(api.uploads, ['first', 'second', 'first', 'second']);
      expect(api.finishes, 1);
      expect(api.submitted, same(frozen));
      expect(current().phase, TrackPhase.completed);
    },
  );

  test(
    'recovers an offline completion after controller disposal with identical values',
    () async {
      api.offline = true;
      await controller.begin(PlogTrack('existing', DateTime.now().toUtc()));
      gps.stream.add(fix(10, 20));
      await controller.submit();
      expect(current().phase, TrackPhase.saveError);
      final frozen = drafts.record!;
      expect(frozen.endedAt, isNotNull);
      container.invalidate(activeTrackProvider);
      controller = container.read(activeTrackProvider.notifier);
      await controller.startOrResume();
      expect(current().phase, TrackPhase.saveError);
      expect(gps.stream.hasListener, isFalse);
      api.offline = false;
      await controller.submit();
      expect(api.submitted, same(frozen));
      expect(drafts.record, isNull);
      expect(api.starts, 0);
    },
  );
  test('recovers photos after an interrupted transfer', () async {
    api.remote = PlogTrack('remote', DateTime.now().toUtc()).deviceStatus(true);
    api.recoveryOffline = true;
    await controller.startOrResume();
    expect(current().phase, TrackPhase.otherDevice);
    expect(gps.stream.hasListener, isFalse);
    await controller.takeOver();
    expect(drafts.record!.recoveringPhotos, isTrue);
    expect(current().phase, TrackPhase.otherDevice);
    api.recoveryOffline = false;
    await controller.takeOver();
    expect(api.recoveries, 2);
    expect(drafts.record!.recoveringPhotos, isFalse);
    expect(current().phase, TrackPhase.tracking);
  });

  test(
    'keeps a pending cancellation across restart and retries it once',
    () async {
      await controller.begin(PlogTrack('existing', DateTime.now().toUtc()));
      gps.stream.add(fix(10, 20));
      api.offline = true;
      api.cancelling = Completer<void>();
      final pending = controller.cancel();
      await Future<void>.delayed(Duration.zero);
      await controller.cancel();
      api.cancelling!.complete();
      await pending;
      expect(api.cancellations, 1);
      expect(current().phase, TrackPhase.cancelPending);
      expect(drafts.record!.cancellationPending, isTrue);
      expect(gps.stream.hasListener, isFalse);

      container.invalidate(activeTrackProvider);
      controller = container.read(activeTrackProvider.notifier);
      api.offline = false;
      await controller.syncPending();
      expect(drafts.record, isNull);
      expect(api.cancellations, 2);
      expect(current().phase, TrackPhase.idle);
    },
  );

  test('turning off GPS keeps prior fixes and starts a new segment', () async {
    await controller.begin(PlogTrack('existing', DateTime.now().toUtc()));
    gps.stream.add(fix(10, 20, age: 1));
    controller.withoutRoute();
    expect(current().phase, TrackPhase.noRoute);
    expect(gps.stream.hasListener, isFalse);
    await controller.retryGps();
    gps.stream.add(fix(10, 20.0002));
    final updated = current().track!;
    expect(updated.route, hasLength(2));
    expect(updated.breaks, [1]);
    expect(updated.distanceMeters, 0);
  });
}
