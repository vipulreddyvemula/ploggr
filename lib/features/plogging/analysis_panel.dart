import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../community/field_data.dart';
import 'saved_photos.dart';

class AnalysisPanel extends ConsumerStatefulWidget {
  const AnalysisPanel(this.id, {super.key});
  final String id;
  @override
  ConsumerState<AnalysisPanel> createState() => _AnalysisState();
}

class _AnalysisState extends ConsumerState<AnalysisPanel> {
  Timer? timer;
  String get path => 'plogs/${widget.id}/analysis';
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final data = ref.read(fieldData(path)).value;
      if (data is Map &&
          ['queued', 'processing', 'review'].contains(data['state'])) {
        ref.invalidate(fieldData(path));
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SectionTitle('Photo analysis'),
      FieldData(path, (data) {
        final items = (data['result']?['items'] as List?) ?? [];
        final List impacts = data['impacts'] ?? [];
        return EcoCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppNotice(
                switch (data['state']) {
                  'queued' => 'Waiting for analysis',
                  'processing' => 'Analyzing your pickup photos',
                  'ready' =>
                    data['reviewed'] == true
                        ? 'Analysis reviewed'
                        : 'Analysis ready',
                  'review' => 'Needs review',
                  'failed' => 'Photo analysis failed',
                  _ => 'Analysis unavailable for this Plog',
                },
                status: switch (data['state']) {
                  'queued' || 'processing' => AppStatus.pending,
                  'ready' => AppStatus.success,
                  'review' => AppStatus.warning,
                  'failed' => AppStatus.failure,
                  _ => AppStatus.information,
                },
              ),
              if (data['suspiciousEvidence'] == true &&
                  data['reviewed'] != true)
                const Text(
                  'Similar photos were detected. A reviewer will check the evidence before points are counted.',
                ),
              if (data['state'] == 'review')
                const Text(
                  'Uncertain results are held out of rankings until reviewed.',
                ),
              if (data['state'] == 'failed')
                FieldAction(
                  'Retry analysis',
                  () => writeField(ref, 'POST', '$path/retry', reload: [path]),
                ),
              if (items.isNotEmpty)
                SectionTitle(
                  data['reviewed'] == true
                      ? 'Reviewed item counts'
                      : 'AI estimates from photos',
                ),
              if (items.isNotEmpty)
                const Text(
                  'These findings describe what appears in the photos. Cleanup verification is shown separately.',
                  style: AppText.caption,
                ),
              for (final (index, i) in items.indexed)
                ExpansionTile(
                  key: PageStorageKey('finding-${widget.id}-$index'),
                  tilePadding: EdgeInsets.zero,
                  leading: const Icon(Icons.recycling),
                  title: Text('${i['count']} × ${i['label']}'),
                  subtitle: Text(
                    '${i['material']} · ${(i['photoIds'] as List).length} ${(i['photoIds'] as List).length == 1 ? 'photo' : 'photos'}${i['certain'] == true ? '' : ' · Uncertain'}',
                  ),
                  children: [
                    for (final (index, photo)
                        in (i['photoIds'] as List).indexed)
                      DetectionPhoto(
                        widget.id,
                        photo,
                        key: ValueKey(photo),
                        box: index == 0 ? i['box'] : null,
                      ),
                  ],
                ),
              if (data['state'] == 'ready')
                FieldAction(
                  'Request a review',
                  () => writeField(ref, 'POST', '$path/review', reload: [path]),
                ),
              if (items.isNotEmpty) ...[
                const SectionTitle('Avoided emissions'),
                if (impacts.isEmpty)
                  const Text(
                    'An estimate needs measured mass and disposal pathways with published factors.',
                  ),
                for (final d in impacts)
                  ExpansionTile(
                    key: PageStorageKey('impact-${widget.id}-${d['material']}'),
                    title: Text(
                      '${d['material']} · ${(d['avoidedKg'] as num).toStringAsFixed(3)} kg CO₂e',
                    ),
                    subtitle: Text(
                      'Estimate based on ${d['massKg']} kg weighed',
                    ),
                    children: [
                      Text(
                        '${d['massKg']} kg · ${d['region']}\n${d['baseline']} → ${d['actual']}\nFactors ${d['version']}\n${d['baselineSource']}\n${d['actualSource']}',
                      ),
                    ],
                  ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _Disposal(
                        widget.id,
                        items.map((i) => i['material'] as String).toSet(),
                      ),
                    ),
                  ),
                  child: const Text('Add weighed material'),
                ),
              ],
            ],
          ),
        );
      }),
    ],
  );
}

class _Disposal extends ConsumerStatefulWidget {
  const _Disposal(this.id, this.materials);
  final String id;
  final Set<String> materials;
  @override
  ConsumerState<_Disposal> createState() => _DisposalState();
}

class _DisposalState extends ConsumerState<_Disposal> {
  final mass = TextEditingController();
  String? batch, baseline, actual;
  @override
  void dispose() {
    mass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPage(
    title: 'Disposal details',
    child: FieldData('impact/factors', (data) {
      final groups = <String, List<Map>>{};
      for (final f in (data as List).cast<Map>()) {
        if (widget.materials.contains(f['material'])) {
          (groups['${f['material']} · ${f['region']} · ${f['version']}'] ??= [])
              .add(f);
        }
      }
      if (groups.isEmpty) {
        return const Text(
          'No published factors are available for the materials in this Plog.',
        );
      }
      final rows = groups[batch] ?? [];
      Widget select(
        String title,
        String? value,
        List<String> options,
        ValueChanged<String?> choose,
      ) => DropdownButtonFormField<String>(
        key: ValueKey('$title-$batch'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: title),
        items: [
          for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
        ],
        onChanged: choose,
      );
      final options = rows.map((r) => r['pathway'] as String).toList();
      final kg = double.tryParse(mass.text);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          select(
            'Material and factor region',
            batch,
            groups.keys.toList(),
            (v) => setState(() {
              batch = v;
              baseline = actual = null;
            }),
          ),
          TextField(
            controller: mass,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Measured mass (kg)'),
            onChanged: (_) => setState(() {}),
          ),
          select(
            'Expected disposal without cleanup',
            baseline,
            options,
            (v) => setState(() => baseline = v),
          ),
          select(
            'Actual disposal',
            actual,
            options,
            (v) => setState(() => actual = v),
          ),
          FieldAction(
            'Save disposal',
            kg == null ||
                    !kg.isFinite ||
                    kg < .001 ||
                    kg > 10000 ||
                    baseline == null ||
                    actual == null
                ? null
                : () async {
                    final f = rows.first;
                    await writeField(
                      ref,
                      'PUT',
                      'plogs/${widget.id}/disposal',
                      data: {
                        'material': f['material'],
                        'region': f['region'],
                        'version': f['version'],
                        'massKg': kg,
                        'actual': actual,
                        'baseline': baseline,
                      },
                      reload: ['plogs/${widget.id}/analysis'],
                    );
                    if (context.mounted) Navigator.pop(context);
                  },
            primary: true,
          ),
        ],
      );
    }),
  );
}
