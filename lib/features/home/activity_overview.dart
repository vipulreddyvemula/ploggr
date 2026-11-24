import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/protected_api.dart';
import '../auth/session/session_controller.dart';
import '../plogging/application/active_track.dart';

final totalsProvider = FutureProvider.autoDispose((ref) async {
  ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  ref.watch(activeTrackProvider.select((s) => s.phase == TrackPhase.completed));
  final result = await ref
      .watch(protectedApiProvider)
      .request<Map>('GET', 'plogs/summary');
  return (
    count: result!['sessions'] as int,
    tracked: result['trackedSessions'] as int? ?? result['sessions'] as int,
    reports: result['reports'] as int? ?? 0,
    meters: (result['distanceMeters'] as num).toDouble(),
  );
}, retry: (_, _) => null);

String formatWalkDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(2)} km';

String formatWalkSummary(int seconds, {num? meters}) {
  final time = Duration(seconds: seconds);
  final duration = time.inHours > 0
      ? '${time.inHours} h ${time.inMinutes % 60} min'
      : time.inMinutes > 0
      ? '${time.inMinutes} min'
      : '$seconds sec';
  return meters == null || meters <= 0
      ? duration
      : '$duration · ${formatWalkDistance(meters.toDouble())}';
}
