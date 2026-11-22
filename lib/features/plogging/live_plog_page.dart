import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../routes/app_routes.dart';
import '../community/field_data.dart';
import '../home/activity_overview.dart';
import '../spots/spot_map.dart';
import '../spots/spot_api.dart';
import 'application/active_track.dart';
import 'data/plog_drafts.dart';
import 'garbage_photos.dart';

class LivePlogPage extends ConsumerStatefulWidget {
  const LivePlogPage({super.key});
  @override
  ConsumerState<LivePlogPage> createState() => _LivePlogState();
}

class _LivePlogState extends ConsumerState<LivePlogPage> {
  final photos = GlobalKey<GarbagePhotosState>();
  bool canAdd = false, follow = true;
  int cameraKey = 0;
  Future<void> finish() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Finish this Plog?'),
        content: const Text(
          'Your walk will end. You can review and add pickup photos before saving.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep plogging'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Finish Plog'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(activeTrackProvider.notifier).selectEvidence();
    }
  }

  Future<void> save() async {
    await ref.read(activeTrackProvider.notifier).submit();
    if (!mounted) return;
    final view = ref.read(activeTrackProvider);
    if (view.phase == TrackPhase.completed) {
      ref.invalidate(resumablePlogProvider);
      ref.invalidate(exploreProvider);
      ref.invalidate(clusterProvider);
      ref.invalidate(mySpotsProvider);
      ref.invalidate(fieldData);
      switchPage(context, '${AppRoutes.activity}/${view.track!.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(activeTrackProvider),
        controller = ref.read(activeTrackProvider.notifier);
    final phase = view.phase, track = view.track;
    final linked = track == null
        ? null
        : ref.watch(linkedSpotsProvider(track.id)).value;
    final pins = {
      for (final p in linked ?? <Map<String, Object?>>[])
        p['report_id'] as String: (
          latitude: p['latitude'] as double,
          longitude: p['longitude'] as double,
        ),
    };
    final ongoing =
        track != null && track.endedAt == null && phase != TrackPhase.conflict;
    final ended = track?.endedAt != null;
    return AppPage(
      title: ended
          ? 'Review your Plog'
          : phase == TrackPhase.paused
          ? 'Plog paused'
          : 'Plogging in Progress',
      bottomAction: ongoing
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PrimaryButton(
                  'Add pickup',
                  icon: Icons.add_a_photo_outlined,
                  onPressed: canAdd ? () => photos.currentState?.add() : null,
                ),
                Wrap(
                  spacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: phase == TrackPhase.paused
                          ? controller.resume
                          : phase == TrackPhase.locating
                          ? null
                          : controller.pause,
                      icon: Icon(
                        phase == TrackPhase.paused
                            ? Icons.play_arrow
                            : Icons.pause,
                      ),
                      label: Text(
                        phase == TrackPhase.paused ? 'Resume' : 'Pause',
                      ),
                    ),
                    TextButton(
                      onPressed: finish,
                      child: const Text('Finish Plog'),
                    ),
                  ],
                ),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (track != null) ...[
            EcoCard(
              color: AppColors.paleGreen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ended ? 'Session summary' : 'Active time',
                    style: AppText.label,
                  ),
                  Text(
                    view.elapsed.toString().split('.').first.padLeft(8, '0'),
                    style: AppText.hero.copyWith(color: AppColors.forest),
                  ),
                  Text(
                    track.route.isEmpty
                        ? 'Distance unavailable'
                        : '${formatWalkDistance(track.distanceMeters)} recorded',
                    style: AppText.heading,
                  ),
                ],
              ),
            ),
            if (track.route.isNotEmpty || pins.isNotEmpty) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: AppRadius.card,
                child: SpotMap(
                  height: 210,
                  route: track.route,
                  breaks: track.breaks,
                  fitRoute: ended,
                  focus: follow
                      ? track.route.lastOrNull ?? pins.values.firstOrNull
                      : null,
                  cameraKey: cameraKey,
                  points: {...pins, 'latest': ?track.route.lastOrNull},
                  onPan: () {
                    if (follow) setState(() => follow = false);
                  },
                ),
              ),
              if (!follow)
                TextButton.icon(
                  onPressed: () => setState(() {
                    follow = true;
                    cameraKey++;
                  }),
                  icon: const Icon(Icons.my_location),
                  label: const Text('Recenter route'),
                ),
            ],
          ],
          if (view.error != null)
            Semantics(liveRegion: true, child: Text(view.error!)),
          if (phase == TrackPhase.locating)
            const Text('Checking location access…'),
          if (phase == TrackPhase.tracking && track!.route.isEmpty)
            const Text('Waiting for a GPS fix…'),
          if (phase == TrackPhase.noRoute)
            const Text('Plogging without a route.'),
          if ([TrackPhase.gpsError, TrackPhase.locating].contains(phase))
            TextButton(
              onPressed: controller.withoutRoute,
              child: const Text('Continue without a route'),
            ),
          if ([TrackPhase.gpsError, TrackPhase.noRoute].contains(phase))
            TextButton(
              onPressed: controller.retryGps,
              child: const Text('Retry GPS'),
            ),
          if (phase == TrackPhase.starting || phase == TrackPhase.saving)
            const LinearProgressIndicator(),
          if ([TrackPhase.idle, TrackPhase.startError].contains(phase))
            PrimaryButton(
              'Start or resume Plog',
              onPressed: controller.startOrResume,
            ),
          if (track != null && (ongoing || phase == TrackPhase.stopped))
            GarbagePhotos(
              track.id,
              key: photos,
              inlineAdd: !ongoing,
              onAvailable: (v) {
                if (mounted && v != canAdd) setState(() => canAdd = v);
              },
              onSave: phase == TrackPhase.stopped ? save : null,
            ),
          if (phase == TrackPhase.saveError)
            PrimaryButton('Retry save', onPressed: save),
          if (phase == TrackPhase.completed)
            PrimaryButton(
              'View activity',
              onPressed: () =>
                  openPage(context, '${AppRoutes.activity}/${track!.id}'),
            ),
          if (phase == TrackPhase.conflict)
            TextButton(
              onPressed: () async {
                if (await confirmAction(
                      context,
                      'Discard the local route and photos?',
                      'Discard draft',
                    ) &&
                    mounted) {
                  await controller.discardConflict();
                }
              },
              child: const Text('Discard local draft'),
            ),
        ],
      ),
    );
  }
}
