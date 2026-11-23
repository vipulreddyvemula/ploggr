import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/network/protected_api.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';
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
    verifiedCleanups: result['verifiedCleanups'] as int? ?? 0,
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

class AccountStats extends ConsumerWidget {
  const AccountStats({super.key, this.profile = false});
  final bool profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totals = ref.watch(totalsProvider);
    final t = totals.value;
    final reportCount = t?.reports.toString() ?? '—';
    final distance = t == null || t.tracked == 0
        ? '—'
        : formatWalkDistance(profile ? t.meters : t.meters / t.tracked);
    Widget tile(
      String value,
      String label,
      IconData icon,
      String route, {
      Color? color,
    }) => Expanded(
      child: StatTile(
        value: value,
        label: label,
        icon: profile ? null : icon,
        color: color ?? context.colors.primary,
        onTap: () => openPage(context, route),
      ),
    );
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            tile(
              t == null ? '—' : '${t.count}',
              'Sessions',
              Icons.route_rounded,
              AppRoutes.activity,
            ),
            const SizedBox(width: 8),
            tile(
              reportCount,
              'My reports',
              Icons.location_on_outlined,
              AppRoutes.saved,
            ),
            const SizedBox(width: 8),
            tile(
              distance,
              profile ? 'Distance' : 'Avg. tracked walk',
              Icons.directions_walk_rounded,
              AppRoutes.activity,
              color: context.goldIcon,
            ),
          ],
        ),
        if (profile && t != null)
          Text(
            'Verified cleanups: ${t.verifiedCleanups}',
            style: AppText.caption,
          ),
        if (totals.isLoading)
          const LinearProgressIndicator(semanticsLabel: 'Loading activity'),
        if (totals.hasError)
          TextButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Retry activity totals'),
            onPressed: () {
              if (totals.hasError) ref.invalidate(totalsProvider);
            },
          ),
      ],
    );
  }
}
