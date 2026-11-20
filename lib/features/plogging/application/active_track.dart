import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/protected_api.dart';
import '../data/plog_api.dart';
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
  stopped,
  saving,
  saveError,
  conflict,
  completed,
}

class TrackView {
  const TrackView(
    this.phase, {
    this.track,
    this.elapsed = Duration.zero,
    this.error,
  });
  final TrackPhase phase;
  final PlogTrack? track;
  final Duration elapsed;
  final String? error;
}

final activeTrackProvider = NotifierProvider<ActiveTrackController, TrackView>(
  ActiveTrackController.new,
);

class ActiveTrackController extends Notifier<TrackView> {
  PlogDrafts? _drafts;
  Timer? _timer;
  StreamSubscription<RouteFix>? _positions;
  int _generation = 0;
  final _clock = Stopwatch();
  Duration _initial = Duration.zero;
  Duration get _elapsed => _initial + _clock.elapsed;

  @override
  TrackView build() {
    _drafts = null;
    ref.onDispose(_stop);
    return const TrackView(TrackPhase.idle);
  }

  void _stop() {
    _generation++;
    _timer?.cancel();
    _clock.stop();
    unawaited(_positions?.cancel());
    _positions = null;
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
      if (draft != null && draft.endedAt != null) {
        final locked = await drafts.photosLocked(draft.id);
        if (generation != _generation) return;
        state = TrackView(
          locked ? TrackPhase.saveError : TrackPhase.stopped,
          track: draft,
          elapsed: draft.endedAt!.difference(draft.startedAt),
          error: locked
              ? 'Recovered your Plog and photos. Retry to confirm the save.'
              : null,
        );
        return;
      }
      var track = await api.active();
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
      if (generation != _generation) return;
      if (track == null) {
        try {
          track = await api.start();
        } on ProtectedApiFailure catch (error) {
          if (error.status != 409 || generation != _generation) rethrow;
          track = await api.active();
          if (track == null) rethrow;
        }
      }
      if (generation != _generation) return;
      await begin(draft ?? track);
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
    if (state.phase == TrackPhase.saving ||
        state.phase == TrackPhase.completed) {
      return;
    }
    final track = freeze();
    if (track == null) return;
    final generation = _generation;
    final elapsed = track.endedAt!.difference(track.startedAt);
    state = TrackView(TrackPhase.saving, track: track, elapsed: elapsed);
    try {
      final drafts = _drafts!;
      await drafts.save(track);
      if (generation != _generation) return;
      final api = ref.read(plogApiProvider);
      final photos = await drafts.lockPhotos(track.id);
      for (final id in photos) {
        final photo = await drafts.readPhoto(track.id, id);
        if (generation != _generation) return;
        await api.upload(track.id, id, photo.type, photo.bytes);
      }
      if (generation != _generation) return;
      await api.finish(track);
      await drafts.remove(track.id);
      if (generation == _generation) {
        state = TrackView(TrackPhase.completed, track: track, elapsed: elapsed);
      }
    } catch (error) {
      if (generation == _generation) {
        final conflict =
            error is ProtectedApiFailure &&
            (error.status == 404 || error.status == 409);
        state = TrackView(
          conflict ? TrackPhase.conflict : TrackPhase.saveError,
          track: track,
          elapsed: elapsed,
          error: conflict
              ? 'The server has a different result for this Plog. Your local route is still on this device.'
              : 'Could not confirm the save. Retry to send the same activity.',
        );
      }
    }
  }

  Future<void> discardConflict() async {
    if (state.phase != TrackPhase.conflict) return;
    final generation = _generation;
    final track = state.track!;
    try {
      await ref.read(plogDraftsProvider).remove(track.id);
      if (generation == _generation) clear();
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
    final age = DateTime.now().toUtc().difference(track.startedAt);
    _initial = age.isNegative ? Duration.zero : age;
    _clock
      ..reset()
      ..start();
    state = TrackView(TrackPhase.locating, track: track, elapsed: _elapsed);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      state = TrackView(
        state.phase,
        track: state.track,
        elapsed: _elapsed,
        error: state.error,
      );
    });
    await _listen();
  }

  Future<void> retryGps() async {
    if (state.phase == TrackPhase.gpsError) await _listen();
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
      state = TrackView(
        TrackPhase.tracking,
        track: state.track,
        elapsed: _elapsed,
      );
      _positions = source.fixes().listen(
        (point) {
          if (generation != _generation) return;
          final track = state.track!;
          if (track.route.length >= 20000) {
            failed('Route limit reached. Finish this Plog to save your fixes.');
            return;
          }
          final updated = track.append(point);
          if (identical(track, updated)) return;
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
    final stopped = track.finish(track.startedAt.add(_elapsed));
    state = TrackView(TrackPhase.stopped, track: stopped, elapsed: _elapsed);
    return stopped;
  }

  void clear() {
    _stop();
    state = const TrackView(TrackPhase.idle);
  }
}
