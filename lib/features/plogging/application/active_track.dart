import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../data/location_source.dart';

class PlogTrack {
  const PlogTrack(
    this.id,
    this.startedAt, {
    this.route = const [],
    this.distanceMeters = 0,
    this.endedAt,
  });
  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<RouteFix> route;
  final double distanceMeters;

  PlogTrack append(RouteFix point) {
    final previous = route.lastOrNull;
    if (previous == point) return this;
    final segment = previous == null
        ? 0.0
        : Geolocator.distanceBetween(
            previous.latitude,
            previous.longitude,
            point.latitude,
            point.longitude,
          );
    return PlogTrack(
      id,
      startedAt,
      route: List.unmodifiable([...route, point]),
      distanceMeters: distanceMeters + segment,
    );
  }

  PlogTrack finish(DateTime end) => PlogTrack(
    id,
    startedAt,
    endedAt: end,
    route: route,
    distanceMeters: distanceMeters,
  );
}

enum TrackPhase { idle, locating, tracking, gpsError, stopped }

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
  Timer? _timer;
  StreamSubscription<RouteFix>? _positions;
  int _generation = 0;
  final _clock = Stopwatch();
  Duration _initial = Duration.zero;
  Duration get _elapsed => _initial + _clock.elapsed;

  @override
  TrackView build() {
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

  Future<void> begin(PlogTrack track) async {
    if (state.phase != TrackPhase.idle) return;
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
          : LocationFailure.unavailable.message;
      state = TrackView(
        TrackPhase.gpsError,
        track: state.track,
        elapsed: _elapsed,
        error: message,
      );
    }

    try {
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
          state = TrackView(
            TrackPhase.tracking,
            track: track.append(point),
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
