import '../../shared/widgets/evidence_review.dart';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/network/protected_api.dart';
import '../../shared/widgets/ploggr_ui.dart';
import 'field_data.dart';

final _image = FutureProvider.autoDispose.family(
  (ref, String path) async => Uint8List.fromList(
    (await ref
        .watch(protectedApiProvider)
        .request<List<int>>('GET', path, responseType: ResponseType.bytes))!,
  ),
  retry: (_, _) => null,
);

class ModerationPage extends ConsumerWidget {
  const ModerationPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => AppPage(
    title: 'Moderation',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Flagged content'),
        FieldData(
          'moderation',
          (d) => Column(
            children: [
              if (d['posts'].isEmpty && d['reports'].isEmpty)
                const Text('No flagged content.'),
              for (final k in ['posts', 'reports'])
                for (final r in d[k])
                  EcoCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r['body'] ??
                              '${r['category']} litter · ${r['place']}',
                        ),
                        if (k == 'reports')
                          TextButton(
                            onPressed: () =>
                                openPage(context, '/spots/${r['id']}'),
                            child: const Text('View spot'),
                          ),
                        FieldAction(
                          'Keep visible',
                          () => writeField(
                            ref,
                            'PUT',
                            'moderation/$k/${r['id']}/keep',
                            reload: ['moderation'],
                          ),
                        ),
                        FieldAction('Hide from community', () async {
                          if (await confirmAction(
                                context,
                                'Hide this content?',
                                'Hide',
                              ) &&
                              context.mounted) {
                            await writeField(
                              ref,
                              'DELETE',
                              k == 'posts'
                                  ? 'community/posts/${r['id']}'
                                  : 'moderation/reports/${r['id']}',
                              reload: ['moderation'],
                            );
                          }
                        }),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        const SectionTitle('Photo reviews'),
        FieldData(
          'moderation/analysis',
          (rows) => Column(
            children: [
              if (rows.isEmpty) const Text('No pending photo reviews.'),
              for (final r in rows)
                ListTile(
                  title: Text(
                    r['reviewNote'] == null
                        ? 'Review pickup photos'
                        : 'Incorrect prediction reported',
                  ),
                  subtitle: Text(
                    '${(r['result']?['items'] as List? ?? []).length} proposed item groups',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => _Review(r)),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Review extends ConsumerStatefulWidget {
  const _Review(this.job);
  final Map job;
  @override
  ConsumerState<_Review> createState() => _ReviewState();
}

class _ReviewState extends ConsumerState<_Review> {
  late final items = [
    for (final i in widget.job['result']?['items'] ?? [])
      <String, dynamic>{
        'label': i['label'],
        'count': i['count'],
        'photoIds': List<String>.from(i['photoIds']),
        'material': i['material'],
        'type': i['type'] ?? 'Other',
      },
  ];
  @override
  Widget build(BuildContext context) {
    final path = 'moderation/analysis/${widget.job['id']}';
    return AppPage(
      title: 'Review pickup',
      child: FieldData(
        'impact/classification',
        (classification) => FieldData(
          '$path/photos',
          (photos) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.job['reviewNote'] case final String note)
                AppNotice(note, status: AppStatus.information),
              for (final p in photos)
                ref
                    .watch(_image('$path/photos/${p['id']}'))
                    .when(
                      data: (bytes) => InkWell(
                        onTap: () => viewPhoto(context, MemoryImage(bytes)),
                        child: Image.memory(
                          bytes,
                          height: 150,
                          cacheWidth: 640,
                        ),
                      ),
                      loading: () => const LinearProgressIndicator(),
                      error: (_, _) => TextButton(
                        onPressed: () =>
                            ref.invalidate(_image('$path/photos/${p['id']}')),
                        child: const Text('Retry photo'),
                      ),
                    ),
              for (final i in items)
                EcoCard(
                  key: ObjectKey(i),
                  child: Column(
                    children: [
                      TextFormField(
                        initialValue: i['label'],
                        maxLength: 80,
                        decoration: const InputDecoration(labelText: 'Item'),
                        onChanged: (v) => setState(() => i['label'] = v.trim()),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: i['material'],
                        decoration: const InputDecoration(
                          labelText: 'Material',
                        ),
                        items: [
                          for (final m
                              in (classification['materials'] as List)
                                  .cast<String>())
                            DropdownMenuItem(value: m, child: Text(m)),
                        ],
                        onChanged: (v) => setState(() => i['material'] = v),
                      ),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: i['type'],
                        decoration: const InputDecoration(labelText: 'Type'),
                        items: [
                          for (final type
                              in (classification['types'] as List)
                                  .cast<String>())
                            DropdownMenuItem(value: type, child: Text(type)),
                        ],
                        onChanged: (v) => setState(() => i['type'] = v),
                      ),
                      TextFormField(
                        initialValue: i['count']?.toString() ?? '',
                        decoration: const InputDecoration(
                          labelText: 'Count (blank if unknown)',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (v) => setState(
                          () => i['count'] = v.trim().isEmpty
                              ? null
                              : int.tryParse(v) ?? 0,
                        ),
                      ),
                      TextFormField(
                        initialValue:
                            (widget.job['result']?['items'] as List? ?? [])
                                .where((entry) => entry['label'] == i['label'])
                                .firstOrNull?['weight']?['estimateKg']
                                ?.toString(),
                        decoration: const InputDecoration(
                          labelText: 'Estimated group weight in kg',
                          helperText: 'Clear the field to remove an estimate.',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (v) => setState(
                          () => i['weightKg'] = v.trim().isEmpty
                              ? null
                              : double.tryParse(v) ?? 0,
                        ),
                      ),
                      Wrap(
                        children: [
                          for (final (n, p) in (photos as List).indexed)
                            FilterChip(
                              label: Text('Photo ${n + 1}'),
                              selected: i['photoIds'].contains(p['id']),
                              onSelected: (v) => setState(() {
                                if (v) {
                                  i['photoIds'].add(p['id']);
                                } else {
                                  i['photoIds'].remove(p['id']);
                                }
                              }),
                            ),
                        ],
                      ),
                      TextButton(
                        onPressed: () => setState(() => items.remove(i)),
                        child: const Text('Remove group'),
                      ),
                    ],
                  ),
                ),
              TextButton(
                onPressed: () => setState(
                  () => items.add({
                    'label': '',
                    'count': 1,
                    'photoIds': <String>[],
                    'material': 'Other',
                    'type': 'Other',
                  }),
                ),
                child: const Text('Add item group'),
              ),
              FieldAction(
                items.isEmpty
                    ? 'Confirm no identifiable litter'
                    : 'Approve reviewed items',
                items.any(
                      (i) =>
                          i['label'] == '' ||
                          (i['count'] != null &&
                              (i['count'] < 1 || i['count'] > 1000)) ||
                          i['photoIds'].isEmpty,
                    )
                    ? null
                    : () async {
                        await writeField(
                          ref,
                          'PUT',
                          path,
                          data: {'items': items},
                          reload: ['moderation/analysis'],
                        );
                        if (context.mounted) Navigator.pop(context);
                      },
                primary: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
