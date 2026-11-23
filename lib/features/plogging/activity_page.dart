import '../../routes/app_routes.dart';
import '../home/activity_overview.dart';
import 'analysis_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import 'data/completed_plog.dart';
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
                final route = plog.route!;
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
                    if (route.isNotEmpty)
                      SpotMap(
                        fitRoute: true,
                        route: route,
                        breaks: plog.breaks,
                        focus: route.first,
                        points: {'start': route.first, 'finish': route.last},
                        height: 200,
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No route was recorded for this Plog.'),
                      ),
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
