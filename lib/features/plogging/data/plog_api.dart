import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/protected_api.dart';
import '../../auth/session/session_controller.dart';
import 'plog_track.dart';

class PlogApi {
  const PlogApi(this.client, this.owner);
  final ProtectedApi client;
  final String owner;

  PlogTrack _activeTrack(Object? value) {
    if (value case {
      'id': String id,
      'userId': String userId,
      'startedAt': String started,
      'status': 'active',
    } when userId == owner) {
      return PlogTrack(id, DateTime.parse(started).toUtc());
    }
    throw const FormatException('Invalid active Plog');
  }

  Future<PlogTrack?> active() async {
    final value = await client.request<Object?>('GET', 'plogs/active');
    if (value case {'plog': final activity}) {
      return activity == null ? null : _activeTrack(activity);
    }
    throw const FormatException('Invalid active Plog response');
  }

  Future<PlogTrack> start() async =>
      _activeTrack(await client.request<Object?>('POST', 'plogs'));

  Future<void> finish(PlogTrack track) async {
    final end = track.endedAt!;
    final saved = await client.request<Object?>(
      'POST',
      'plogs/${track.id}/finish',
      data: {
        'endedAt': end.toUtc().toIso8601String(),
        'durationSeconds': end.difference(track.startedAt).inSeconds,
        'distanceMeters': track.distanceMeters,
        'route': [
          for (final fix in track.route)
            {'latitude': fix.latitude, 'longitude': fix.longitude},
        ],
      },
    );
    if (saved case {
      'id': String id,
      'userId': String userId,
      'status': 'completed',
    } when id == track.id && userId == owner) {
      return;
    }
    throw const FormatException('Invalid completion response');
  }
}

final plogApiProvider = Provider<PlogApi>((ref) {
  final owner = ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  if (owner == null) throw const ProtectedApiFailure(401);
  return PlogApi(ref.watch(protectedApiProvider), owner);
});
