import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/protected_api.dart';
import '../data/plog_api.dart';
import '../data/completed_plog.dart';
import '../../spots/observation_sync.dart';
import '../data/plog_drafts.dart';
import '../data/plog_track.dart';
import '../data/location_source.dart';

enum TrackPhase {
  idle,
  starting,
  startError,
  locating,
  tracking,
  gpsError,
  noRoute,
  paused,
  stopped,
  saving,
  saveError,
  conflict,
  completed,
  cancelling,
  cancelPending,
  otherDevice,
}

class TrackView {
  const TrackView(
    this.phase, {
    this.track,
    this.elapsed = Duration.zero,
    this.error,
    this.uploads = const {},
    this.completion,
  });
  final TrackPhase phase;
  final PlogTrack? track;
  final Duration elapsed;
  final String? error;
  final Map<String, double> uploads;
  final CompletedPlog? completion;
}

final activeTrackProvider = NotifierProvider<ActiveTrackController, TrackView>(
  ActiveTrackController.new,
);

final plogOfflineProvider = NotifierProvider<PlogOffline, bool>(
  PlogOffline.new,
);

class PlogOffline extends Notifier<bool> {
  @override
  bool build() => false;

  void update(bool offline) => state = offline;
}

class ActiveTrackController extends Notifier<TrackView> {
  PlogDrafts? _drafts;
  Timer? _timer, _firstFixTimeout;
  StreamSubscription<GpsSample>? _positions;
  int _generation = 0;
  final _clock = Stopwatch();
  Duration _initial = Duration.zero;
  Duration get _elapsed => _initial + _clock.elapsed;

  @override
  TrackView build() {
    _drafts = null;
    _editingPhotos = false;
    ref.onDispose(_stop);
    return const TrackView(TrackPhase.idle);
  }

  void _stop() {
    _generation++;
    _timer?.cancel();
    _firstFixTimeout?.cancel();
    _clock.stop();
    unawaited(_positions?.cancel());
    _positions = null;
  }

  bool _syncing = false;
  bool _editingPhotos = false;

  Future<void> syncPending() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final drafts = ref.read(plogDraftsProvider);
      final current = state.track;
      if (current != null &&
          current.endedAt == null &&
          state.phase != TrackPhase.otherDevice &&
          state.phase != TrackPhase.conflict) {
        final generation = _generation;
        final remote = await ref.read(plogApiProvider).active();
        if (ref.mounted) ref.read(plogOfflineProvider.notifier).update(false);
        if (generation != _generation ||
            !ref.mounted ||
            state.track?.endedAt != null) {
          return;
        }
        if (remote?.id == current.id && remote!.isOnAnotherDevice) {
          _otherDevice(state.track!.discontinuity());
        } else if (remote?.id != current.id) {
          _stop();
          state = TrackView(
            TrackPhase.conflict,
            track: state.track,
            error:
                'This Plog is no longer active. Your draft is still on this phone.',
          );
        }
        return;
      }
      if (![
        TrackPhase.idle,
        TrackPhase.cancelPending,
        TrackPhase.saveError,
      ].contains(state.phase)) {
        return;
      }
      final pending = current ?? await drafts.load();
      if (!ref.mounted || pending == null) return;
      if (pending.cancellationPending ||
          pending.endedAt != null && await drafts.photosLocked(pending.id)) {
        if (!ref.mounted) return;
        if (state.phase == TrackPhase.idle) await startOrResume();
        if (!ref.mounted) return;
        if (state.phase == TrackPhase.cancelPending) {
          await cancel();
        } else if (state.phase == TrackPhase.saveError &&
            state.track?.id == pending.id) {
          await submit();
        }
      }
    } on ProtectedApiFailure catch (error) {
      if (ref.mounted) {
        ref.read(plogOfflineProvider.notifier).update(error.status == null);
      }
      rethrow;
    } finally {
      _syncing = false;
    }
  }

  Future<void> startOrResume() async {
    if (![
      TrackPhase.idle,
      TrackPhase.startError,
      TrackPhase.completed,
    ].contains(state.phase)) {
      return;
    }
    final generation = ++_generation;
    state = const TrackView(TrackPhase.starting);
    try {
      final api = ref.read(plogApiProvider);
      final drafts = ref.read(plogDraftsProvider);
      _drafts = drafts;
      final draft = await drafts.load();
      if (generation != _generation) return;
      if (draft?.cancellationPending == true) {
        state = TrackView(
          TrackPhase.cancelPending,
          track: draft,
          error: 'Discard pending. Reconnecting will retry.',
        );
        return;
      }
      if (draft != null && draft.endedAt != null) {
        final locked = await drafts.photosLocked(draft.id);
        if (generation != _generation) return;
        state = TrackView(
          locked ? TrackPhase.saveError : TrackPhase.stopped,
          track: draft,
          elapsed: draft.durationAt(draft.endedAt!),
          error: locked
              ? 'Recovered your Plog and photos. Retry to confirm the save.'
              : null,
        );
        return;
      }
      PlogTrack? track;
      try {
        track = await api.active();
        if (ref.mounted) ref.read(plogOfflineProvider.notifier).update(false);
      } on ProtectedApiFailure catch (e) {
        if (ref.mounted && generation == _generation) {
          ref.read(plogOfflineProvider.notifier).update(e.status == null);
        }
        if (draft == null ||
            draft.recoveringPhotos ||
            e.status != null && e.status! < 500) {
          rethrow;
        }
        if (generation == _generation) await begin(draft.discontinuity());
        return;
      }
      if (generation != _generation) return;
      if (draft != null && draft.id != track?.id) {
        state = TrackView(
          TrackPhase.conflict,
          track: draft,
          error:
              'This Plog is no longer active on the server. Its local route is still on this device.',
        );
        return;
      }
      var restoring = track != null;
      if (track == null) {
        try {
          track = await api.start();
        } on ProtectedApiFailure catch (error) {
          if (error.status != 409 || generation != _generation) rethrow;
          track = await api.active();
          if (track == null) rethrow;
          restoring = true;
        }
      }
      if (generation != _generation) return;
      if (track.isOnAnotherDevice) {
        _otherDevice(draft ?? track);
        return;
      }
      if (restoring && draft == null || draft?.recoveringPhotos == true) {
        track = await _recoverPhotos(api, drafts, draft ?? track, generation);
        if (generation != _generation) return;
      } else {
        track = draft ?? track;
      }
      await begin(track.discontinuity());
    } catch (_) {
      if (generation == _generation) {
        state = const TrackView(
          TrackPhase.startError,
          error:
              'Could not start or resume your Plog. Check your connection and retry.',
        );
      }
    }
  }

  void _otherDevice(PlogTrack track) {
    _stop();
    state = TrackView(
      TrackPhase.otherDevice,
      track: track.deviceStatus(true),
      error: 'This Plog is active on another device.',
    );
  }

  Future<void> takeOver() async {
    if (state.phase != TrackPhase.otherDevice) return;
    final previous = state.track!;
    final generation = ++_generation;
    state = const TrackView(TrackPhase.starting);
    try {
      final api = ref.read(plogApiProvider);
      final drafts = _drafts!;
      final track = await api.transfer(previous.id);
      final local = await drafts.load();
      if (generation != _generation) return;
      if (local == null || local.recoveringPhotos) {
        await _recoverPhotos(api, drafts, local ?? track, generation);
      }
      if (generation != _generation) return;
      state = const TrackView(TrackPhase.idle);
      await startOrResume();
    } catch (_) {
      if (generation == _generation) {
        state = TrackView(
          TrackPhase.otherDevice,
          track: previous,
          error:
              'Could not transfer this Plog. Check your connection and retry.',
        );
      }
    }
  }

  Future<PlogTrack> _recoverPhotos(
    PlogApi api,
    PlogDrafts drafts,
    PlogTrack track,
    int generation,
  ) async {
    final pending = track.photoRecovery(true);
    await drafts.save(pending);
    if (generation != _generation) return pending;
    final photos = await api.recoverEvidence(track.id);
    if (generation != _generation) return pending;
    await drafts.recoverPickupPhotos(track.id, photos);
    final recovered = pending.photoRecovery(false);
    await drafts.save(recovered);
    return recovered;
  }

  Future<void> selectEvidence() async {
    final track = freeze();
    if (track == null) return;
    final generation = _generation;
    try {
      await _drafts!.save(track);
    } catch (_) {
      if (generation == _generation) {
        state = TrackView(
          TrackPhase.stopped,
          track: track,
          elapsed: state.elapsed,
          error:
              'Could not checkpoint the finish time. Keep this screen open and retry saving.',
        );
      }
    }
  }

  Future<void> submit() async {
    if (_editingPhotos ||
        ![
          TrackPhase.locating,
          TrackPhase.tracking,
          TrackPhase.paused,
          TrackPhase.gpsError,
          TrackPhase.noRoute,
          TrackPhase.stopped,
          TrackPhase.saveError,
        ].contains(state.phase)) {
      return;
    }
    final track = freeze();
    if (track == null) return;
    final generation = _generation;
    final elapsed = track.durationAt(track.endedAt!);
    var selectionLocked = state.phase == TrackPhase.saveError;
    Map<String, double> uploads = {};
    void progress(String id, double value) {
      if (generation != _generation || state.phase != TrackPhase.saving) return;
      uploads = {...uploads, id: value};
      state = TrackView(
        TrackPhase.saving,
        track: track,
        elapsed: elapsed,
        uploads: uploads,
      );
    }

    state = TrackView(TrackPhase.saving, track: track, elapsed: elapsed);
    try {
      final drafts = _drafts!;
      await drafts.save(track);
      if (generation != _generation) return;
      final api = ref.read(plogApiProvider);
      final photos = await drafts.lockPhotos(track.id);
      selectionLocked = true;
      for (final removed in await drafts.photoRemovals(track.id)) {
        if (generation != _generation) return;
        await api.removePhoto(track.id, removed);
        await drafts.acknowledgePhotoRemoval(track.id, removed);
      }
      Object? uploadError;
      for (final id in photos) {
        if (generation != _generation) return;
        progress(id, 0);
        try {
          final photo = await drafts.readPhoto(track.id, id);
          if (generation != _generation) return;
          await api.upload(
            track.id,
            id,
            photo.type,
            photo.bytes,
            capture: photo.capture,
            onProgress: (sent, total) =>
                progress(id, total <= 0 ? 0 : (sent / total).clamp(0, .99)),
          );
          progress(id, 1);
        } catch (error) {
          progress(id, -1);
          uploadError ??= error;
        }
      }
      if (uploadError != null) throw uploadError;
      if (generation != _generation) return;
      final observations = await drafts.observations(
        plog: track.id,
        unsent: true,
      );
      if (generation != _generation) return;
      if (observations.isNotEmpty) {
        await ref.read(observationSyncProvider).flush(plog: track.id);
      }
      final groups = await drafts.collectionGroups(track.id);
      for (final group in groups.entries) {
        if (generation != _generation) return;
        await api.publishCollection(group.key, group.value);
      }
      final pickups = await drafts.pickups(track.id);
      if (generation != _generation) return;
      final saved = await api.finish(
        track,
        pickupIds: [
          for (final row in pickups)
            if (row['selected'] == 1) row['report_id'] as String,
        ],
      );
      await drafts.remove(track.id);
      if (generation == _generation) {
        ref.invalidate(resumablePlogProvider);
        ref.read(plogOfflineProvider.notifier).update(false);
        state = TrackView(
          TrackPhase.completed,
          track: track,
          elapsed: Duration(seconds: saved.seconds),
          completion: saved,
        );
      }
    } catch (error) {
      if (generation == _generation) {
        if (error is ProtectedApiFailure) {
          ref.read(plogOfflineProvider.notifier).update(error.status == null);
        }
        if (!selectionLocked) {
          state = TrackView(
            TrackPhase.stopped,
            track: track,
            elapsed: elapsed,
            error:
                'Could not save the selection on this device. Check your photos and retry.',
          );
          return;
        }
        if (error is ProtectedApiFailure && error.status == 409) {
          try {
            final remote = await ref.read(plogApiProvider).active();
            if (generation != _generation) return;
            if (remote?.id == track.id && remote!.isOnAnotherDevice) {
              _otherDevice(track);
              return;
            }
          } catch (_) {
            if (generation != _generation) return;
          }
        }
        final failedPhoto = uploads.values.contains(-1);
        final conflict =
            !failedPhoto &&
            error is ProtectedApiFailure &&
            (error.status == 404 || error.status == 409);
        state = TrackView(
          conflict ? TrackPhase.conflict : TrackPhase.saveError,
          track: track,
          elapsed: elapsed,
          uploads: uploads,
          error: conflict
              ? 'The server has a different result for this Plog. Your local route and photos are still on this device.'
              : _saveError(error, failedPhoto),
        );
      }
    }
  }

  String _saveError(Object error, bool failedPhoto) {
    if (error is ProtectedApiFailure) {
      if (error.status == null) {
        return 'Save pending. Restore your connection or retry.';
      }
      if (error.status == 401) {
        return 'Sign in to the same account to resume saving.';
      }
      if (error.status == 400 || error.status == 413 || error.status == 415) {
        return failedPhoto
            ? 'Replace the failed photo, then retry saving.'
            : 'The server could not validate this Plog.';
      }
      if (error.status == 503) {
        return 'Image storage is unavailable. Your photos are saved on this phone.';
      }
    }
    return 'Could not confirm the save. Retry to send the same activity.';
  }

  Future<void> editPhotos() async {
    if (_editingPhotos || state.phase != TrackPhase.saveError) return;
    _editingPhotos = true;
    final view = state;
    try {
      await _drafts!.unlockPhotos(view.track!.id);
      if (ref.mounted && identical(view, state)) {
        state = TrackView(
          TrackPhase.stopped,
          track: view.track,
          elapsed: view.elapsed,
          uploads: view.uploads,
        );
      }
    } catch (_) {
      if (ref.mounted && identical(view, state)) {
        state = TrackView(
          view.phase,
          track: view.track,
          elapsed: view.elapsed,
          error: 'Could not reopen photo selection.',
          uploads: view.uploads,
        );
      }
    } finally {
      _editingPhotos = false;
    }
  }

  Future<void> cancel() async {
    if ([
      TrackPhase.saving,
      TrackPhase.conflict,
      TrackPhase.completed,
      TrackPhase.cancelling,
      TrackPhase.otherDevice,
    ].contains(state.phase)) {
      return;
    }
    final drafts = _drafts;
    final track = freeze()?.requestCancellation();
    if (track == null || drafts == null) return;
    final generation = ++_generation;
    state = TrackView(
      TrackPhase.cancelling,
      track: track,
      error: 'Discarding Plog…',
    );
    try {
      await drafts.save(track);
      if (generation != _generation) return;
      final api = ref.read(plogApiProvider);
      try {
        await api.cancel(track.id);
      } on ProtectedApiFailure catch (error) {
        if (error.status != 404) rethrow;
      }
      await drafts.remove(track.id);
      if (generation == _generation) {
        ref.invalidate(resumablePlogProvider);
        clear();
      }
    } catch (error) {
      if (generation != _generation) return;
      final conflict = error is ProtectedApiFailure && error.status == 409;
      state = TrackView(
        conflict ? TrackPhase.conflict : TrackPhase.cancelPending,
        track: track,
        error: conflict
            ? 'This Plog changed on the server. You can discard its local copy.'
            : 'Discard pending. Your draft is still on this phone.',
      );
    }
  }

  Future<void> discardConflict() async {
    if (state.phase != TrackPhase.conflict) return;
    final generation = _generation;
    final track = state.track!;
    try {
      await ref.read(plogDraftsProvider).remove(track.id);
      if (generation == _generation) {
        ref.invalidate(resumablePlogProvider);
        clear();
      }
    } catch (_) {
      if (generation == _generation) {
        state = TrackView(
          TrackPhase.conflict,
          track: track,
          error: 'Could not remove the local draft.',
        );
      }
    }
  }

  Future<void> begin(PlogTrack track) async {
    if (state.phase != TrackPhase.idle && state.phase != TrackPhase.starting) {
      return;
    }
    final age = track.durationAt(DateTime.now().toUtc());
    _initial = age.isNegative ? Duration.zero : age;
    _clock
      ..reset()
      ..start();
    state = TrackView(TrackPhase.locating, track: track, elapsed: _elapsed);
    if (track.pausedAt != null) {
      _clock.stop();
      state = TrackView(TrackPhase.paused, track: track, elapsed: age);
      return;
    }
    _tick();
    if (track.withoutGps || track.route.length >= PlogTrack.maxPoints) {
      await _withoutRoute(track);
      return;
    }
    await _listen();
  }

  void _tick() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      state = TrackView(
        state.phase,
        track: state.track,
        elapsed: _elapsed,
        error: state.error,
      );
    });
  }

  Future<void> pause() async {
    final track = state.track;
    if (track == null ||
        ![
          TrackPhase.tracking,
          TrackPhase.locating,
          TrackPhase.noRoute,
          TrackPhase.gpsError,
        ].contains(state.phase)) {
      return;
    }
    final t = track.pause(DateTime.now().toUtc());
    _stop();
    state = TrackView(
      TrackPhase.paused,
      track: t,
      elapsed: t.durationAt(t.pausedAt!),
    );
    try {
      await _drafts!.save(t);
    } catch (_) {
      if (ref.mounted && state.track == t) {
        state = TrackView(
          TrackPhase.paused,
          track: t,
          elapsed: state.elapsed,
          error:
              'Could not save the pause on this phone. Keep the Plog open and retry.',
        );
      }
    }
  }

  Future<void> resume() async {
    if (state.phase != TrackPhase.paused) return;
    final t = state.track!.resume(DateTime.now().toUtc());
    state = const TrackView(TrackPhase.idle);
    await begin(t);
  }

  void withoutRoute() {
    if (![
      TrackPhase.tracking,
      TrackPhase.gpsError,
      TrackPhase.locating,
    ].contains(state.phase)) {
      return;
    }
    unawaited(_withoutRoute(state.track!));
  }

  Future<void> _withoutRoute(PlogTrack current) async {
    final generation = ++_generation;
    _firstFixTimeout?.cancel();
    unawaited(_positions?.cancel());
    _positions = null;
    final track = current.routeChoice(true);
    state = TrackView(
      TrackPhase.noRoute,
      track: track,
      elapsed: _elapsed,
      error: track.route.length >= PlogTrack.maxPoints
          ? 'Route limit reached. You can keep adding pickups or finish this Plog.'
          : null,
    );
    try {
      await _drafts!.save(track);
    } catch (_) {
      if (generation == _generation) {
        state = TrackView(
          TrackPhase.noRoute,
          track: track,
          elapsed: _elapsed,
          error: 'Could not save the route choice on this phone.',
        );
      }
    }
  }

  Future<void> retryGps() async {
    if (![TrackPhase.gpsError, TrackPhase.noRoute].contains(state.phase)) {
      return;
    }
    final track = state.track!;
    if (track.route.length >= PlogTrack.maxPoints) return;
    state = TrackView(
      state.phase,
      track: track.routeChoice(false),
      elapsed: _elapsed,
    );
    await _listen();
  }

  Future<void> _listen() async {
    final generation = ++_generation;
    final source = ref.read(locationSourceProvider);
    final drafts = _drafts ?? ref.read<PlogDrafts>(plogDraftsProvider);
    _drafts = drafts;
    state = TrackView(
      TrackPhase.locating,
      track: state.track,
      elapsed: _elapsed,
    );
    void failed(Object error) {
      if (generation != _generation) return;
      _generation++;
      _firstFixTimeout?.cancel();
      unawaited(_positions?.cancel());
      _positions = null;
      final message = error is LocationFailure
          ? error.message
          : error is String
          ? error
          : LocationFailure.unavailable.message;
      state = TrackView(
        TrackPhase.gpsError,
        track: state.track,
        elapsed: _elapsed,
        error: message,
      );
    }

    try {
      try {
        await drafts.save(state.track!);
      } catch (_) {
        failed(
          'Device storage could not save this Plog. Free space and retry.',
        );
        return;
      }
      if (generation != _generation) return;
      await source.requestAccess();
      if (generation != _generation) return;
      await requestTrackingNotification();
      if (generation != _generation) return;
      state = TrackView(
        TrackPhase.tracking,
        track: state.track,
        elapsed: _elapsed,
      );
      _firstFixTimeout = Timer(const Duration(seconds: 30), () {
        failed(
          'No accurate GPS fix yet. Move outdoors, then retry or continue without GPS.',
        );
      });
      _positions = source.fixes().listen(
        (point) {
          if (generation != _generation) return;
          _firstFixTimeout?.cancel();
          final track = state.track!;
          final updated = track.append(point.point, sample: point);
          if (identical(track, updated)) return;
          if (updated.route.length == PlogTrack.maxPoints) {
            unawaited(_withoutRoute(updated));
            return;
          }
          unawaited(
            drafts.save(updated).catchError((Object _) {
              failed(
                'Device storage could not save this fix. Free space and retry.',
              );
            }),
          );
          state = TrackView(
            TrackPhase.tracking,
            track: updated,
            elapsed: _elapsed,
          );
        },
        onError: failed,
        onDone: () => failed(LocationFailure.unavailable),
        cancelOnError: true,
      );
    } catch (error) {
      failed(error);
    }
  }

  PlogTrack? freeze() {
    final track = state.track;
    if (track == null || track.endedAt != null) return track;
    _stop();
    final now = DateTime.now().toUtc();
    final end = now.isBefore(track.startedAt) ? track.startedAt : now;
    final stopped = (track.pausedAt == null ? track : track.resume(end)).finish(
      end,
    );
    state = TrackView(
      TrackPhase.stopped,
      track: stopped,
      elapsed: stopped.durationAt(end),
    );
    return stopped;
  }

  void clear() {
    _stop();
    state = const TrackView(TrackPhase.idle);
  }
}
