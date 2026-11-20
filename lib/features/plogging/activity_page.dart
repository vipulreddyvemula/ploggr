import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import 'data/completed_plog.dart';
import 'saved_photos.dart';
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
  const PlogActivityPage({super.key});
  @override
  ConsumerState<PlogActivityPage> createState() => _PlogActivityPageState();
}

class _PlogActivityPageState extends ConsumerState<PlogActivityPage> {
  final _cursors = <String?>[null];
  String? _selected;

  String _localTime(DateTime time) {
    final local = time.toLocal();
    return '${MaterialLocalizations.of(context).formatMediumDate(local)} · ${TimeOfDay.fromDateTime(local).format(context)}';
  }

  @override
  Widget build(BuildContext context) {
    final id = _selected;
    final page = _activities(_cursors.last);
    if (id != null) {
      final provider = _detail(id);
      return AppPage(
        title: 'Plog details',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton(
              onPressed: () => setState(() => _selected = null),
              child: const Text('All activities'),
            ),
            ref
                .watch(provider)
                .when(
                  loading: () => const CircularProgressIndicator(),
                  error: (_, _) => TextButton(
                    onPressed: () => ref.invalidate(provider),
                    child: const Text('Retry loading Plog'),
                  ),
                  data: (plog) {
                    final route = plog.route!;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Started ${_localTime(plog.startedAt)}'),
                        Text('Finished ${_localTime(plog.endedAt)}'),
                        Text(
                          '${plog.seconds} s · ${plog.meters.toStringAsFixed(1)} m',
                        ),
                        Text('${route.length} GPS fixes'),
                        if (route.isNotEmpty)
                          Text(
                            'First fix   ${route.first.latitude}, ${route.first.longitude}',
                          ),
                        if (route.length > 1)
                          Text(
                            'Last fix   ${route.last.latitude}, ${route.last.longitude}',
                          ),
                        SavedPhotos(plog.id),
                      ],
                    );
                  },
                ),
          ],
        ),
      );
    }
    return AppPage(
      title: 'My Activity',
      child: ref
          .watch(page)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => TextButton(
              onPressed: () => ref.invalidate(page),
              child: const Text('Retry loading activities'),
            ),
            data: (result) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (result.items.isEmpty) const Text('No completed Plogs yet.'),
                for (final plog in result.items)
                  ListTile(
                    title: Text(_localTime(plog.startedAt)),
                    subtitle: Text(
                      '${plog.seconds} s · ${plog.meters.toStringAsFixed(1)} m',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _selected = plog.id),
                  ),
                if (_cursors.length > 1)
                  TextButton(
                    onPressed: () => setState(_cursors.removeLast),
                    child: const Text('Newer activities'),
                  ),
                if (result.nextCursor != null)
                  TextButton(
                    onPressed: () =>
                        setState(() => _cursors.add(result.nextCursor)),
                    child: const Text('Older activities'),
                  ),
              ],
            ),
          ),
    );
  }
}
