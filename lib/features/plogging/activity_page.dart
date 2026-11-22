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

final _activities = FutureProvider.autoDispose
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
  String metrics(CompletedPlog p) =>
      formatWalkSummary(p.seconds, meters: p.meters);

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
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => TextButton(
                onPressed: () => ref.invalidate(_detail(id)),
                child: const Text('Retry loading Plog'),
              ),
              data: (plog) {
                final route = plog.route!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EcoCard(
                      color: AppColors.paleGreen,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(metrics(plog), style: AppText.title),
                          Text('Started ${date(plog.startedAt)}'),
                          Text('Finished ${date(plog.endedAt)}'),
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
                .watch(_activities(cursor))
                .when(
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => TextButton(
                    onPressed: () => ref.invalidate(_activities(cursor)),
                    child: const Text('Retry loading activities'),
                  ),
                  data: (result) => Column(
                    children: [
                      if (result.items.isEmpty && cursor == null)
                        const Text('No completed Plogs yet.'),
                      for (final plog in result.items)
                        ListTile(
                          title: Text(date(plog.startedAt)),
                          subtitle: Text(metrics(plog)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => openPage(
                            context,
                            '${AppRoutes.activity}/${plog.id}',
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
