import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
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

  Future<void> reportPrediction() async {
    var note = '';
    final report = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Report incorrect results'),
        content: TextField(
          autofocus: true,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'What should we review? (optional)',
          ),
          onChanged: (value) => note = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, note.trim()),
            child: const Text('Send report'),
          ),
        ],
      ),
    );
    if (report == null || !mounted) return;
    await writeField(
      ref,
      'POST',
      '$path/review',
      data: {'note': report},
      reload: [
        path,
        for (final period in ['week', 'month', 'all'])
          'leaderboard?period=$period',
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SectionTitle('Photo analysis'),
      FieldData(path, (data) {
        final result = data['result'] as Map?;
        final items = (result?['items'] as List? ?? []).cast<Map>();
        final weights = items.map((i) => i['weight']).whereType<Map>().toList();
        final potential = items
            .map((i) => i['potentialImpact'])
            .whereType<Map>()
            .toList();
        final impacts = (data['impacts'] as List? ?? []).cast<Map>();
        final state = data['state'];
        final reward = data['reward'] as Map?;
        final configured = data['configured'] != false;
        return EcoCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppNotice(
                switch (state) {
                  'queued' when !configured =>
                    'Waiting for photo analysis to be enabled',
                  'queued' when data['retryAt'] != null =>
                    'Photo analysis is delayed. We’ll retry automatically.',
                  'queued' => 'Waiting for analysis',
                  'processing' => 'Analyzing your pickup photos',
                  'ready' when data['reviewed'] == true => 'Analysis reviewed',
                  'ready' => 'Analysis ready',
                  'review' when data['reported'] == true =>
                    'Prediction report submitted',
                  'review' => 'Awaiting photo review',
                  'failed' => 'Photo analysis failed',
                  _ => 'Analysis unavailable for this Plog',
                },
                status: switch (state) {
                  'queued' || 'processing' => AppStatus.pending,
                  'ready' => AppStatus.success,
                  'review' => AppStatus.warning,
                  'failed' => AppStatus.failure,
                  _ => AppStatus.information,
                },
              ),
              if (state == 'processing') const LinearProgressIndicator(),
              if (data['suspiciousEvidence'] == true &&
                  data['reviewed'] != true)
                const Text(
                  'Similar photos were detected. A reviewer will check the evidence.',
                ),
              if (configured &&
                  (state == 'failed' || data['canUpdate'] == true))
                FieldAction(
                  state == 'failed'
                      ? 'Retry analysis'
                      : 'Update photo analysis',
                  () => writeField(ref, 'POST', '$path/retry', reload: [path]),
                ),
              if (reward != null) ...[
                const SectionTitle('Cleanup points'),
                Text(switch (reward['status']) {
                  'earned' => "${reward['earnedPoints']} points earned",
                  'pending' when reward['pendingPoints'] != null =>
                    "${reward['pendingPoints']} points pending",
                  'pending' => 'Points pending analysis or review',
                  _ => '0 points earned',
                }, style: AppText.label),
                if (reward['status'] == 'ineligible')
                  const Text(
                    'Points require eligible detections supported by verified cleanup photos.',
                  ),
              ],
              if (items.isEmpty && result?['quality'] == 'empty')
                const Text('No litter detected.'),
              if (items.isNotEmpty) ...[
                SectionTitle(
                  data['reviewed'] == true
                      ? 'Reviewed items'
                      : 'Identified litter',
                ),
                Text(
                  "${_sum(items, 'count').toInt()} counted items"
                  "${items.any((i) => i['count'] == null) ? ' · Some items could not be counted' : ''}",
                  style: AppText.caption,
                ),
                Text(
                  weights.isEmpty
                      ? 'Weight could not be estimated from these photos.'
                      : "Estimated weight · ${_range(weights, 'estimateKg', 'kg')}"
                            "${weights.length < items.length ? ' · ${weights.length} of ${items.length} groups' : ''}",
                ),
                const SectionTitle('Potential carbon savings'),
                Text(
                  potential.isEmpty
                      ? 'No supported disposal estimate for these detections.'
                      : _range(potential, 'avoidedKg', 'kg CO₂e'),
                  style: AppText.label,
                ),
                if (potential.isNotEmpty)
                  Text(
                    'Unverified scenario estimate · ${potential.length} of ${items.length} groups',
                    style: AppText.caption,
                  ),
              ],
              for (final (index, item) in items.indexed) _item(index, item),
              if ((state == 'ready' || state == 'review') &&
                  data['reported'] != true)
                FieldAction('Report incorrect results', reportPrediction),
              if (impacts.isNotEmpty)
                const SectionTitle('Weighed disposal estimates'),
              for (final d in impacts)
                ExpansionTile(
                  key: PageStorageKey('impact-${widget.id}-${d['material']}'),
                  title: Text(
                    "${d['material']} · ${_amount(d['avoidedKg'])} kg CO₂e",
                  ),
                  subtitle: Text(
                    "Self-reported disposal · ${d['massKg']} kg weighed",
                  ),
                  children: [
                    Text(
                      "${d['region']} · ${d['baseline']} → ${d['actual']}\n"
                      "${d['version']}\n${d['baselineSource']}\n${d['actualSource']}",
                    ),
                  ],
                ),
              if (items.isNotEmpty)
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
          ),
        );
      }),
    ],
  );

  Widget _item(int index, Map item) {
    final photos = (item['photoIds'] as List).cast<String>();
    final weight = item['weight'] as Map?;
    final impact = item['potentialImpact'] as Map?;
    return ExpansionTile(
      key: PageStorageKey('finding-${widget.id}-$index'),
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.recycling),
      title: Text(
        item['count'] == null
            ? item['label']
            : "${item['count']} × ${item['label']}",
      ),
      subtitle: Text(
        [
          item['material'],
          if (item['type'] != null) item['type'],
          if (item['count'] == null) 'Count unavailable',
          if (item['certain'] != true) 'Uncertain',
          if (weight != null) "${_amount(weight['estimateKg'])} kg estimated",
        ].join(' · '),
      ),
      children: [
        Text(
          weight == null
              ? 'Weight unavailable'
              : "Estimated weight · ${_range([weight], 'estimateKg', 'kg')}",
        ),
        if (impact != null) ...[
          Text(
            "Potential savings · ${_range([impact], 'avoidedKg', 'kg CO₂e')}",
          ),
          Text(
            "${impact['baseline']} → ${impact['alternative']} · ${impact['region']}",
          ),
          TextButton(
            onPressed: () async {
              final opened = await launchUrl(
                Uri.parse(impact['source'] as String),
              );
              if (!opened && mounted) {
                toast(context, 'Could not open the factor source.');
              }
            },
            child: Text(impact['version']),
          ),
        ],
        for (final (photoIndex, photo) in photos.indexed)
          DetectionPhoto(
            widget.id,
            photo,
            key: ValueKey(photo),
            box: photoIndex == 0 ? item['box'] : null,
          ),
      ],
    );
  }
}

num _sum(List<Map> values, String key) =>
    values.fold<num>(0, (total, value) => total + (value[key] as num? ?? 0));

String _range(List<Map> values, String estimate, String unit) =>
    "${_amount(_sum(values, estimate))} $unit "
    "(${_amount(_sum(values, 'minKg'))}–${_amount(_sum(values, 'maxKg'))} $unit)";

String _amount(num value) =>
    value > 0 && value < .001 ? '<0.001' : value.toStringAsFixed(3);

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
