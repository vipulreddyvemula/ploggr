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
import 'data/plog_track.dart';
import 'garbage_photos.dart';

class LivePlogPage extends ConsumerStatefulWidget {
  const LivePlogPage({super.key});
  @override
  ConsumerState<LivePlogPage> createState() => _LivePlogState();
}

class _LivePlogState extends ConsumerState<LivePlogPage> {
  final photos = GlobalKey<GarbagePhotosState>();
  bool canAdd = false, follow = true, finishing = false;
  int cameraKey = 0;
  Future<void> finish() async {
    if (finishing) return;
    finishing = true;
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
    try {
      if (ok == true && mounted) {
        await ref.read(activeTrackProvider.notifier).selectEvidence();
      }
    } finally {
      finishing = false;
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(
          activeTrackProvider.select(
            (v) => (
              phase: v.phase,
              track: v.track,
              error: v.error,
              uploads: v.uploads,
              completion: v.completion,
            ),
          ),
        ),
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
        track != null &&
        track.endedAt == null &&
        phase != TrackPhase.conflict &&
        phase != TrackPhase.otherDevice;
    final ended = track?.endedAt != null;
    final saved = phase == TrackPhase.completed;
    final offline = ref.watch(plogOfflineProvider);
    final recovering =
        phase == TrackPhase.idle &&
        ref.watch(resumablePlogProvider).value == true;
    final recording = switch (phase) {
      TrackPhase.tracking =>
        track!.route.isEmpty ? 'Waiting for GPS' : 'Recording route',
      TrackPhase.noRoute => 'Route recording off',
      TrackPhase.gpsError => 'GPS unavailable',
      TrackPhase.paused => 'Recording paused',
      TrackPhase.locating => 'Checking location access',
      _ => null,
    };
    return AppPage(
      title: saved
          ? 'Plog saved'
          : ended
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
          if (recovering)
            const AppNotice(
              'A Plog is saved on this device. Resume to recover your route and pickups.',
            ),
          if (saved)
            const AppNotice(
              'Your Plog is saved to your account.',
              status: AppStatus.success,
            ),
          if (offline && !saved)
            AppNotice(
              ongoing
                  ? 'Offline · This Plog stays on this device while you walk.'
                  : 'Offline · Your local draft stays on this device.',
              status: AppStatus.pending,
            ),
          if (track != null) ...[
            EcoCard(
              color: context.colors.primaryContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ended ? 'Session summary' : 'Active time',
                    style: AppText.label,
                  ),
                  Consumer(
                    builder: (context, ref, _) {
                      final elapsed = ref.watch(
                        activeTrackProvider.select((v) => v.elapsed),
                      );
                      return FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          elapsed.toString().split('.').first.padLeft(8, '0'),
                          style: AppText.hero.copyWith(
                            color: context.colors.onPrimaryContainer,
                          ),
                        ),
                      );
                    },
                  ),
                  Text(
                    view.completion != null && track.route.isNotEmpty
                        ? '${formatWalkDistance(view.completion!.meters)} recorded by GPS'
                        : track.route.isEmpty
                        ? 'Distance unavailable'
                        : '${formatWalkDistance(track.distanceMeters)} · GPS estimate on this device',
                    style: AppText.heading,
                  ),
                  if (recording != null) Text(recording, style: AppText.label),
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
                  simplifyRoute: !ended,
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
            AppNotice(
              view.error!,
              status: phase == TrackPhase.gpsError
                  ? AppStatus.warning
                  : AppStatus.failure,
            ),

          if ([TrackPhase.gpsError, TrackPhase.locating].contains(phase))
            TextButton(
              onPressed: controller.withoutRoute,
              child: const Text('Continue without a route'),
            ),
          if (phase == TrackPhase.tracking)
            TextButton(
              onPressed: controller.withoutRoute,
              child: const Text('Stop tracking GPS'),
            ),
          if ([TrackPhase.gpsError, TrackPhase.noRoute].contains(phase) &&
              track!.route.length < PlogTrack.maxPoints)
            TextButton(
              onPressed: controller.retryGps,
              child: const Text('Retry GPS'),
            ),
          if ([
            TrackPhase.starting,
            TrackPhase.saving,
            TrackPhase.cancelling,
          ].contains(phase))
            AppLoading(switch (phase) {
              TrackPhase.saving => 'Saving Plog',
              TrackPhase.cancelling => 'Discarding Plog',
              _ => 'Starting Plog',
            }),
          if ([TrackPhase.idle, TrackPhase.startError].contains(phase))
            PrimaryButton(
              recovering ? 'Resume Plog Session' : 'Start or resume Plog',
              onPressed: controller.startOrResume,
            ),
          if (track != null &&
              (ongoing ||
                  [
                    TrackPhase.stopped,
                    TrackPhase.saving,
                    TrackPhase.saveError,
                  ].contains(phase)))
            GarbagePhotos(
              track.id,
              key: photos,
              inlineAdd: !ongoing,
              editing:
                  phase != TrackPhase.saving && phase != TrackPhase.saveError,
              uploads: view.uploads,
              onAvailable: (v) {
                if (mounted && v != canAdd) setState(() => canAdd = v);
              },
              onSave: phase == TrackPhase.stopped ? save : null,
            ),
          if (ended && !saved)
            const Text(
              'Item and material estimates appear after photo analysis.',
              style: AppText.caption,
            ),
          if (ended && !saved && linked != null)
            Text(
              '${linked.where((item) => item['selected'] == 1).length} linked litter sightings',
            ),
          if (phase == TrackPhase.saveError) ...[
            PrimaryButton('Retry save', onPressed: save),
            TextButton(
              onPressed: controller.editPhotos,
              child: const Text('Edit photos'),
            ),
          ],
          if (phase == TrackPhase.otherDevice)
            PrimaryButton(
              'Continue on this device',
              onPressed: () async {
                if (await confirmAction(
                      context,
                      'Continue this Plog on this device?',
                      'Continue here',
                    ) &&
                    mounted) {
                  await controller.takeOver();
                }
              },
            ),
          if (phase == TrackPhase.cancelPending)
            PrimaryButton('Retry discard', onPressed: controller.cancel),
          if (track != null &&
              (ongoing ||
                  phase == TrackPhase.stopped ||
                  phase == TrackPhase.saveError))
            TextButton(
              onPressed: () async {
                if (await confirmAction(
                      context,
                      'Discard this Plog and its photos?',
                      'Discard Plog',
                    ) &&
                    mounted) {
                  await controller.cancel();
                }
              },
              child: const Text('Discard Plog'),
            ),
          if (saved) ...[
            const SizedBox(height: AppSpace.lg),
            PrimaryButton(
              'View activity',
              icon: Icons.history_rounded,
              onPressed: () =>
                  openPage(context, '${AppRoutes.activity}/${track!.id}'),
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  openPage(context, '/community/write?plog=${track!.id}'),
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share cleanup'),
            ),
            TextButton(
              onPressed: () => switchPage(context, AppRoutes.home),
              child: const Text('Return Home'),
            ),
          ],
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
