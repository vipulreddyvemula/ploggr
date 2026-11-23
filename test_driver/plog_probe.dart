// Test-only entry point for the disposable Android Plog evidence validation stack.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/routes/app_router.dart';
import 'package:ploggr/features/plogging/data/photo_capture.dart';
import 'package:ploggr/features/spots/spot_api.dart';
import 'package:ploggr/features/spots/spot.dart';
import 'package:ploggr/core/config/app_config.dart';
import 'package:ploggr/core/config/app_config_provider.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/plogging/application/active_track.dart';
import 'package:ploggr/features/plogging/data/plog_api.dart';
import 'package:ploggr/features/plogging/data/plog_drafts.dart';

File marker(String name) =>
    File('${Directory.systemTemp.parent.path}/cache/plog-$name');

Future<void> waitFor(bool Function() ready, String description) async {
  final until = DateTime.now().add(const Duration(minutes: 6));
  while (!ready()) {
    if (DateTime.now().isAfter(until)) {
      throw StateError('Timed out during $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Expose the same accessibility tree used by screen readers to host UI automation.
  final semantics = WidgetsBinding.instance.ensureSemantics();
  final container = ProviderContainer(
    overrides: [
      appConfigProvider.overrideWithValue(AppConfig.fromEnvironment()),
    ],
  );
  runApp(
    UncontrolledProviderScope(container: container, child: const PloggrApp()),
  );
  TrackView view() => container.read(activeTrackProvider);
  try {
    final sessions = container.read(sessionControllerProvider.notifier);
    await sessions.accessToken();
    final restoring = await marker('checkpoint').exists();
    if (!restoring) {
      await sessions.signup(
        '${const Uuid().v4()}@example.test',
        const Uuid().v4(),
      );
    }
    if (!restoring) {
      await marker('ready').writeAsString('ok');
      await waitFor(() => marker('posted').existsSync(), 'first reporter');
      final spots = container.read(spotApiProvider);
      final post = (await spots.mine(null)).items.single;
      if (post.notes != 'Lakeside' ||
          post.point.latitude.abs() > 90 ||
          post.point.longitude.abs() > 180 ||
          post.photoCount != 1) {
        throw StateError('Report differs from confirmed photo, note or pin');
      }
      await marker('shared-id').writeAsString(post.id);
      await marker(
        'shared-point',
      ).writeAsString(jsonEncode([post.point.longitude, post.point.latitude]));
      await sessions.logout();
      await sessions.signup(
        '${const Uuid().v4()}@example.test',
        const Uuid().v4(),
      );
      final other = container.read(spotApiProvider);
      if ((await other.detail(post.id)).mine ||
          (await other.image(post.id, 0)).isEmpty) {
        throw StateError('Shared spot not available to second account');
      }
      await marker('walker').writeAsString('ok');
    }
    final owner = container.read(sessionControllerProvider).user!.id;
    if (!restoring) {
      await waitFor(
        () => view().phase == TrackPhase.gpsError,
        'permission denial',
      );
      if (view().track!.route.isNotEmpty) {
        throw StateError('Recorded GPS before permission');
      }
      await marker('denied').writeAsString('ok');
      await waitFor(
        () => view().phase == TrackPhase.tracking,
        'location access',
      );
      await marker('tracking').writeAsString('ok');
      final pin =
          (jsonDecode(await marker('shared-point').readAsString()) as List)
              .cast<num>();
      for (final (index, longitude) in [pin[0], pin[0] + .0004].indexed) {
        await waitFor(() {
          final state = view();
          if (state.phase == TrackPhase.gpsError) {
            throw StateError(
              'GPS stopped after permission was granted: ${state.error}',
            );
          }
          return state.track!.route.any(
            (p) =>
                (p.latitude - pin[1]).abs() < 0.00005 &&
                (p.longitude - longitude).abs() < 0.00005,
          );
        }, 'fix $index');
        await marker('fix-$index').writeAsString('ok');
      }
      await waitFor(
        () => view().phase == TrackPhase.saveError,
        'offline finish',
      );
      final track = (await container.read(plogDraftsProvider).load())!;
      if (track.endedAt == null ||
          track.distanceMeters < 10 ||
          track.route.length < 2) {
        throw StateError('Incomplete durable finish');
      }
      await marker('frozen').writeAsString('ok');
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!await marker('extra-fix').exists() &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!await marker('extra-fix').exists()) {
        throw StateError('Missing post-finish GPS check');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      if (view().track!.route.length != track.route.length ||
          view().track!.endedAt != track.endedAt) {
        throw StateError('Activity changed after finish');
      }
      final drafts = container.read(plogDraftsProvider);
      final ids = await drafts.photoIds(track.id);
      if (ids.length != 2 || !await drafts.photosLocked(track.id)) {
        throw StateError('Missing or unlocked evidence in offline draft');
      }
      for (final (index, id) in ids.indexed) {
        final photo = await drafts.readPhoto(track.id, id);
        final capture = photo.capture;
        if (index == 0 &&
                (capture?.source != PhotoSource.camera ||
                    capture?.gps == null) ||
            index == 1 && capture?.source != PhotoSource.gallery) {
          throw StateError(
            'Offline evidence lost its capture source or GPS metadata',
          );
        }
        await marker('expected-$id').writeAsBytes(photo.bytes, flush: true);
      }
      await marker('checkpoint').writeAsString(
        jsonEncode({
          'owner': owner,
          'photos': ids,
          'id': track.id,
          'start': track.startedAt.millisecondsSinceEpoch,
          'end': track.endedAt!.millisecondsSinceEpoch,
          'seconds': track.durationAt(track.endedAt!).inSeconds,
          'meters': track.distanceMeters,
          'route': [
            for (final p in track.route) [p.latitude, p.longitude],
          ],
        }),
        flush: true,
      );
    } else {
      final expected =
          jsonDecode(await marker('checkpoint').readAsString()) as Map;
      if (owner != expected['owner']) throw StateError('Account changed');
      await marker('reopened').writeAsString('ok');
      await waitFor(
        () => view().phase == TrackPhase.completed,
        'confirmed save',
      );
      container
          .read(appRouterProvider)
          .go('/profile/activity/${expected['id']}');
      await marker('completed').writeAsString('ok', flush: true);
      await waitFor(
        () => marker('storage-restarted').existsSync(),
        'private storage restart',
      );
      final api = container.read(plogApiProvider);
      final history = await api.completed(null);
      if (history.items.length != 1 ||
          history.items.single.id != expected['id'] ||
          await api.active() != null) {
        throw StateError('Unexpected completed activity list');
      }
      final record = await api.detail(history.items.single.id);
      final route = [
        for (final p in record.route!) [p.latitude, p.longitude],
      ];
      if (record.seconds < 1 ||
          record.seconds != expected['seconds'] ||
          (record.meters - (expected['meters'] as num)).abs() > 1 ||
          jsonEncode(route) != jsonEncode(expected['route']) ||
          record.startedAt.millisecondsSinceEpoch != expected['start'] ||
          record.endedAt.millisecondsSinceEpoch != expected['end'] ||
          await container.read(plogDraftsProvider).load() != null) {
        throw StateError(
          'Persisted activity differs from the frozen GPS track',
        );
      }
      final ids = await api.evidence(record.id);
      if (!listEquals(ids, List<String>.from(expected['photos'] as List))) {
        throw StateError('Saved evidence differs from the selected photos');
      }
      for (final id in ids) {
        final original = await marker('expected-$id').readAsBytes();
        if (!listEquals(original, await api.image(record.id, id))) {
          throw StateError('Retrieved image differs from the draft bytes');
        }
      }
      final shared = await marker('shared-id').readAsString();
      final spots = container.read(spotApiProvider);
      if (record.verifiedCleanups != 1 ||
          (await spots.detail(shared)).status != 'collected' ||
          (await spots.explore(world)).items.any((s) => s.id == shared)) {
        throw StateError('Linked pickup remained on the open map');
      }
      if ((await spots.mine(null)).items.isNotEmpty) {
        throw StateError('Adding a private pickup created a public sighting.');
      }
      await marker('verified').writeAsString('ok', flush: true);
    }
  } catch (error) {
    final reason = error is StateError
        ? error.message
        : error.runtimeType.toString();
    await marker('failure').writeAsString(reason, flush: true);
  } finally {
    // The app remains on screen for the final activity-detail UI check.
    semantics.dispose();
  }
}
