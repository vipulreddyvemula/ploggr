import '../../routes/app_routes.dart';
import '../home/activity_overview.dart';
import 'analysis_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import 'data/completed_plog.dart';
import 'data/location_source.dart';
import 'saved_photos.dart';
import '../spots/spot_map.dart';
import 'data/plog_api.dart';

final plogHistoryProvider = FutureProvider.autoDispose
    .family<ActivityPageData, String?>(
      (ref, before) => ref.watch(plogApiProvider).completed(before),
      retry: (_, _) => null,
    );
final _detail = FutureProvider.autoDispose.family<CompletedPlog, String>(
  (ref, id) => ref.watch(plogApiProvider).detail(id),
  retry: (_, _) => null,
);

class PlogActivityPage extends ConsumerStatefulWidget {
  const PlogActivityPage({super.key, this.id});
  final String? id;
  @override
  ConsumerState<PlogActivityPage> createState() => _ActivityState();
}

class _ActivityState extends ConsumerState<PlogActivityPage> {
  final pages = <String?>[null];
  String metrics(CompletedPlog p) {
    final distance = p.hasRoute == true || p.meters > 0
        ? formatWalkDistance(p.meters)
        : 'Distance unavailable';
    return '${formatWalkSummary(p.seconds)} · $distance';
  }

  String date(DateTime value) {
    final local = value.toLocal();
    return '${MaterialLocalizations.of(context).formatMediumDate(local)} · ${TimeOfDay.fromDateTime(local).format(context)}';
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
    if (id != null) {
      return AppPage(
        title: 'Plog details',
        backTo: AppRoutes.activity,
        child: ref
            .watch(_detail(id))
            .when(
              loading: () => const AppLoading('Loading Plog'),
              error: (_, _) => AppNotice(
                'Could not load this Plog.',
                status: AppStatus.failure,
                actionLabel: 'Retry loading Plog',
                onAction: () => ref.invalidate(_detail(id)),
              ),
              data: (plog) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EcoCard(
                      color: context.colors.primaryContainer,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(metrics(plog), style: AppText.title),
                          Text('Started ${date(plog.startedAt)}'),
                          Text('Finished ${date(plog.endedAt)}'),
                          if (plog.verifiedCleanups > 0)
                            Text('Verified cleanups: ${plog.verifiedCleanups}'),
                          if (plog.unverifiedCleanups > 0)
                            Text(
                              'Unverified cleanups: ${plog.unverifiedCleanups}',
                            ),
                          if (plog.alreadyCollected > 0)
                            Text(
                              'Previously collected: ${plog.alreadyCollected}',
                            ),
                        ],
                      ),
                    ),
                    _RecordedRoute(plog),
                    OutlinedButton.icon(
                      onPressed: () =>
                          openPage(context, '/community/write?plog=$id'),
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Share cleanup'),
                    ),
                    AnalysisPanel(id),
                    SavedPhotos(id),
                  ],
                );
              },
            ),
      );
    }
    return AppPage(
      title: 'My Activity',
      backTo: AppRoutes.profile,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final cursor in pages)
            ref
                .watch(plogHistoryProvider(cursor))
                .when(
                  loading: () => const AppLoading('Loading activities'),
                  error: (_, _) => AppNotice(
                    'Could not load your activities.',
                    status: AppStatus.failure,
                    actionLabel: 'Retry loading activities',
                    onAction: () => ref.invalidate(plogHistoryProvider(cursor)),
                  ),
                  data: (result) => Column(
                    children: [
                      if (result.items.isEmpty && cursor == null)
                        AppNotice(
                          'No completed Plogs yet.',
                          actionLabel: 'Start a Plog',
                          onAction: () => openPage(context, AppRoutes.session),
                        ),
                      for (final plog in result.items)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpace.sm),
                          child: EcoCard(
                            onTap: () => openPage(
                              context,
                              '${AppRoutes.activity}/${plog.id}',
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        date(plog.startedAt),
                                        style: AppText.heading,
                                      ),
                                      Text(metrics(plog)),
                                      if (plog.hasRoute
                                          case final bool hasRoute)
                                        Text(
                                          hasRoute
                                              ? 'GPS route recorded'
                                              : 'No GPS route',
                                        ),
                                      if (plog.photoCount case final int count)
                                        Text(
                                          '$count ${count == 1 ? 'pickup photo' : 'pickup photos'}',
                                        ),
                                      if (plog.pickupCount case final int count
                                          when count > 0)
                                        Text('$count linked sightings'),
                                      if (plog.analysisState
                                          case 'queued' || 'processing')
                                        const Text('Photo analysis pending'),
                                      if (plog.analysisState == 'review')
                                        const Text('Awaiting review'),
                                      if (plog.analysisState == 'failed')
                                        const Text(
                                          'Photo analysis unavailable',
                                        ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      if (cursor == pages.last && result.nextCursor != null)
                        TextButton(
                          onPressed: () =>
                              setState(() => pages.add(result.nextCursor)),
                          child: const Text('Load older activities'),
                        ),
                    ],
                  ),
                ),
        ],
      ),
    );
  }
}

class _RecordedRoute extends StatefulWidget {
  const _RecordedRoute(this.plog);
  final CompletedPlog plog;

  @override
  State<_RecordedRoute> createState() => _RecordedRouteState();
}

class _RecordedRouteState extends State<_RecordedRoute> {
  String? selected;
  RouteFix? focus;
  int cameraKey = 0;

  @override
  Widget build(BuildContext context) {
    final plog = widget.plog;
    final route = plog.route ?? const <RouteFix>[];
    final locations = plog.cleanupLocations;
    final points = {
      for (final location in locations)
        'cleanup-${location.id}': location.point,
      if (route.isNotEmpty)
        if (route.first == route.last)
          'start-finish': route.first
        else ...{
          'start': route.first,
          'finish': route.last,
        },
    };
    final selectedLocation = locations
        .where((value) => 'cleanup-${value.id}' == selected)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (points.isNotEmpty) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: AppRadius.card,
            child: SpotMap(
              fitRoute: focus == null,
              route: route,
              breaks: plog.breaks,
              focus: focus ?? route.firstOrNull ?? locations.first.point,
              points: points,
              height: 220,
              selected: selected,
              cameraKey: cameraKey,
              onSelect: (id) {
                if (id.startsWith('cleanup-')) setState(() => selected = id);
              },
            ),
          ),
          if (supportsSpotMap)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              children: [
                if (route.isNotEmpty) ...[
                  if (route.first == route.last)
                    const Text('S/F · Start and finish')
                  else ...[
                    const Text('S · Start'),
                    const Text('F · Finish'),
                  ],
                ],
                if (locations.isNotEmpty) const Text('✓ · Cleanup'),
                if (focus != null)
                  TextButton(
                    onPressed: () => setState(() {
                      focus = null;
                      selected = null;
                      cameraKey++;
                    }),
                    child: const Text('Fit route'),
                  ),
              ],
            ),
        ],
        if (route.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No route was recorded for this Plog.'),
          ),
        if (selectedLocation != null && supportsSpotMap)
          Text(
            selectedLocation.place.isEmpty
                ? '${selectedLocation.category} cleanup'
                : '${selectedLocation.category} cleanup · ${selectedLocation.place}',
          ),
        for (final location in locations)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.check_circle_outline),
            title: Text('${location.category} cleanup'),
            subtitle: Text(
              location.place.isNotEmpty
                  ? location.place
                  : '${location.point.latitude.toStringAsFixed(5)}, ${location.point.longitude.toStringAsFixed(5)}',
            ),
            onTap: supportsSpotMap
                ? () => setState(() {
                    focus = location.point;
                    selected = 'cleanup-${location.id}';
                    cameraKey++;
                  })
                : null,
          ),
      ],
    );
  }
}
