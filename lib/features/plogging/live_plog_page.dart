import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../routes/app_routes.dart';
import 'application/active_track.dart';
import 'garbage_photos.dart';

class LivePlogPage extends ConsumerWidget {
  const LivePlogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(activeTrackProvider);
    final controller = ref.read(activeTrackProvider.notifier);
    final track = view.track;
    final phase = view.phase;
    return AppPage(
      title: phase == TrackPhase.completed ? 'Plog saved' : 'Plog session',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (track != null) ...[
            Text(
              '${view.elapsed.inMinutes} min ${view.elapsed.inSeconds % 60} s',
              textAlign: TextAlign.center,
              style: AppText.hero,
            ),
            const SizedBox(height: 12),
            Text(
              '${track.distanceMeters.toStringAsFixed(0)} m · ${track.route.length} GPS fixes',
              textAlign: TextAlign.center,
              style: AppText.label,
            ),
            const SizedBox(height: 16),
          ],
          if (view.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(view.error!),
            ),
          if (phase == TrackPhase.starting)
            const Text('Checking your active Plog…'),
          if (phase == TrackPhase.locating)
            const Text('Checking location access…'),
          if (phase == TrackPhase.tracking && track!.route.isEmpty)
            const Text('Waiting for a GPS fix…'),
          if (phase == TrackPhase.gpsError)
            TextButton(
              onPressed: controller.retryGps,
              child: const Text('Retry GPS'),
            ),
          if ([TrackPhase.idle, TrackPhase.startError].contains(phase))
            PrimaryButton(
              'Start or resume Plog',
              onPressed: controller.startOrResume,
            ),
          if ([
            TrackPhase.locating,
            TrackPhase.tracking,
            TrackPhase.gpsError,
          ].contains(phase))
            PrimaryButton('Finish Plog', onPressed: controller.selectEvidence),
          if (track != null && phase == TrackPhase.stopped)
            GarbagePhotos(
              track.id,
              key: ValueKey(track.id),
              onSave: controller.submit,
            ),
          if (phase == TrackPhase.completed)
            PrimaryButton(
              'View activity',
              onPressed: () => openPage(context, AppRoutes.activity),
            ),
          if (phase == TrackPhase.saving) const Text('Saving your Plog…'),
          if (phase == TrackPhase.conflict)
            TextButton(
              onPressed: () async {
                final discard = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Discard local route?'),
                    content: const Text(
                      'This removes the route from this device.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Keep route'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Discard'),
                      ),
                    ],
                  ),
                );
                if (discard == true && context.mounted) {
                  await controller.discardConflict();
                }
              },
              child: const Text('Discard local draft'),
            ),
          if (phase == TrackPhase.saveError)
            PrimaryButton('Retry save', onPressed: controller.submit),
        ],
      ),
    );
  }
}
