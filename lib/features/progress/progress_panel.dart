import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../community/field_data.dart';
import '../home/activity_overview.dart';

String pointsLabel(num points) => points == points.roundToDouble()
    ? points.toInt().toString()
    : points.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');

String? kgLabel(Object? value) => switch (value) {
  final num kg when kg != 0 && kg.abs() < .01 => kg < 0 ? '−<0.01' : '<0.01',
  final num kg => pointsLabel((kg * 100).round() / 100),
  _ => null,
};

class RewardData extends ConsumerStatefulWidget {
  const RewardData(this.path, this.render, {super.key});
  final String path;
  final Widget Function(dynamic) render;

  @override
  ConsumerState<RewardData> createState() => _RewardDataState();
}

class _RewardDataState extends ConsumerState<RewardData> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent == true) {
        ref.invalidate(fieldData(widget.path));
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FieldData(widget.path, widget.render);
}

class PointsExplanation extends StatelessWidget {
  const PointsExplanation(this.rules, {super.key});
  final Map rules;
  @override
  Widget build(BuildContext context) {
    final rates = (rules['material_points'] as Map?) ?? {};
    final standard = rules['version'] == 'm5-v1' || rules['version'] == 'm3-v1';
    return ExpansionTile(
      key: const PageStorageKey('points-explanation'),
      title: const Text('How points work'),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        const Text(
          'Points are your XP. Use the Plog camera to photograph what you collect. Accepted pickup evidence can earn points anywhere.',
        ),
        const SizedBox(height: 8),
        Text(
          standard
              ? 'Earn 1 point per accepted litter item.'
              : rates.entries
                    .map((e) => '${e.key} · ${e.value} points per item')
                    .join('\n'),
        ),
        Text(
          '${rules['carbon_points_per_kg']} points per modeled kg CO₂e, capped at ${rules['carbonPoints']} per Plog.',
        ),
        if (rules['movementPoints'] != null)
          Text(
            'Earn 1 point per full GPS kilometre and 1 per 20 GPS moving minutes. Movement is capped at ${rules['movementPoints']} points and at the litter-item points you earn.',
          ),
        Text(
          'Cleanup points are capped at ${rules['plogPoints']} per Plog. Official challenge bonuses are added separately.',
        ),
        const SizedBox(height: 8),
        const Text(
          'A correction or rejection can change points and challenge progress.',
        ),
      ],
    );
  }
}

class ProgressSnapshot extends StatelessWidget {
  const ProgressSnapshot({super.key});

  @override
  Widget build(BuildContext context) => RewardData('progress?period=week', (
    data,
  ) {
    final pending = data['pending'] as int;
    final challenges = (data['activeChallenges'] as List).cast<Map>();
    final challenge =
        challenges.where((c) => c['progress'] < c['goal']).firstOrNull ??
        challenges.firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pending > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '$pending ${pending == 1 ? 'cleanup pending' : 'cleanups pending'} analysis or review.',
              style: AppText.caption,
            ),
          ),
        if (challenge != null)
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined),
            title: Text(challenge['title']),
            subtitle: Text(
              '${challenge['progress']} of ${challenge['goal']} ${challenge['unit']} · +${challenge['bonus']} points',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openPage(context, AppRoutes.challenges),
          ),
      ],
    );
  });
}

class GoalCard extends ConsumerWidget {
  const GoalCard(this.goal, {super.key});
  final Map goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = goal['target'] as int?;
    final progress = goal['progress'] as int;
    final weekly = goal['cadence'] == 'week';
    final cadence = weekly ? 'week' : 'day';
    return EcoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            weekly ? 'Weekly cleanup goal' : 'Daily cleanup goal',
            style: AppText.heading,
          ),
          const SizedBox(height: 6),
          if (target != null) ...[
            Text('$progress of $target verified cleanups'),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: (progress / target).clamp(0, 1),
              semanticsLabel: 'Personal goal progress',
            ),
            const SizedBox(height: 6),
            Text(
              'Resets ${localDate(context, goal['endsAt'], time: true)}',
              style: AppText.caption,
            ),
          ] else
            const Text('Choose a target for verified cleanups.'),
          const SizedBox(height: 8),
          Text(
            'Current streak · ${goal['streak']} ${goal['streak'] == 1 ? cadence : '${cadence}s'}',
          ),
          Text(
            'Longest streak · ${goal['longestStreak']} ${goal['longestStreak'] == 1 ? cadence : '${cadence}s'}',
            style: AppText.caption,
          ),
          TextButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _GoalEditor(goal),
            ),
            icon: const Icon(Icons.flag_outlined),
            label: Text(target == null ? 'Set a goal' : 'Edit goal'),
          ),
        ],
      ),
    );
  }
}

class _GoalEditor extends ConsumerStatefulWidget {
  const _GoalEditor(this.goal);
  final Map goal;

  @override
  ConsumerState<_GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends ConsumerState<_GoalEditor> {
  late String cadence = widget.goal['cadence'];
  late final target = TextEditingController(
    text: (widget.goal['target'] ?? 1).toString(),
  );
  bool saving = false;
  bool failed = false;

  @override
  void dispose() {
    target.dispose();
    super.dispose();
  }

  Future<void> save(int count) async {
    setState(() {
      saving = true;
      failed = false;
    });
    try {
      await writeField(
        ref,
        'PUT',
        'profile/goal',
        data: {'cadence': cadence, 'target': count},
        reload: [
          for (final period in ['week', 'month', 'all'])
            'progress?period=$period',
        ],
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = int.tryParse(target.text.trim());
    return PopScope(
      canPop: !saving,
      child: AlertDialog(
        title: const Text('Cleanup goal'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: cadence,
              decoration: const InputDecoration(labelText: 'Repeats'),
              items: const [
                DropdownMenuItem(value: 'day', child: Text('Daily')),
                DropdownMenuItem(value: 'week', child: Text('Weekly')),
              ],
              onChanged: saving ? null : (v) => setState(() => cadence = v!),
            ),
            TextField(
              controller: target,
              enabled: !saving,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Verified cleanups',
                helperText: 'Choose 1 to 100.',
              ),
            ),
            if (failed)
              const AppNotice(
                'Could not save your goal.',
                status: AppStatus.failure,
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: saving || count == null || count < 1 || count > 100
                ? null
                : () => save(count),
            child: Text(saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}

class ProgressPanel extends StatefulWidget {
  const ProgressPanel({super.key});

  @override
  State<ProgressPanel> createState() => _ProgressPanelState();
}

class _ProgressPanelState extends State<ProgressPanel> {
  int period = 0;
  String metric = 'points';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SectionTitle('Your progress'),
      FilterTabs(
        labels: const ['Week', 'Month', 'All time'],
        selected: period,
        onChanged: (value) => setState(() => period = value),
      ),
      RewardData('progress?period=${['week', 'month', 'all'][period]}', (data) {
        final totals = data['totals'] as Map;
        final previous = data['previous'] as Map?;
        final series = (data['series'] as List).cast<Map>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EcoCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${pointsLabel(totals['points'])} points",
                    style: AppText.title,
                  ),
                  Text(
                    "${pointsLabel(totals['cleanupPoints'])} cleanup · ${pointsLabel(totals['challengePoints'])} challenge",
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "${totals['completedPlogs']} completed Plogs · ${totals['verifiedCleanups']} verified cleanups",
                  ),
                  Text(
                    "${formatWalkDistance((totals['distanceMeters'] as num).toDouble())} walked · ${formatWalkSummary(totals['activeSeconds'])} active",
                  ),
                  Text("${totals['items']} accepted litter items"),
                  const SizedBox(height: 10),
                  ImpactTotals(totals),
                  if (previous != null) ...[
                    const Divider(),
                    Text(
                      'Previous ${period == 0 ? 'week' : 'month'} at this point',
                      style: AppText.label,
                    ),
                    Text(
                      "${pointsLabel(previous['points'])} points · ${previous['verifiedCleanups']} verified cleanups · ${previous['items']} items",
                      style: AppText.caption,
                    ),
                    Text(
                      "${previous['completedPlogs']} Plogs · ${formatWalkDistance((previous['distanceMeters'] as num).toDouble())} walked",
                      style: AppText.caption,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            EcoCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    period == 2 ? 'Last 12 months' : 'Daily progress',
                    style: AppText.heading,
                  ),
                  DropdownButton<String>(
                    value: metric,
                    items: const [
                      DropdownMenuItem(value: 'points', child: Text('Points')),
                      DropdownMenuItem(
                        value: 'verifiedCleanups',
                        child: Text('Verified cleanups'),
                      ),
                      DropdownMenuItem(
                        value: 'items',
                        child: Text('Accepted items'),
                      ),
                    ],
                    onChanged: (value) => setState(() => metric = value!),
                  ),
                  _ProgressChart(
                    series: series,
                    metric: metric,
                    monthly: period == 2,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            GoalCard(data['goal']),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () => openPage(context, AppRoutes.leaderboard),
              icon: const Icon(Icons.leaderboard_outlined),
              label: const Text('Leaderboard and scoring'),
            ),
          ],
        );
      }),
    ],
  );
}

class ImpactTotals extends StatelessWidget {
  const ImpactTotals(this.data, {super.key, this.coverage = true});
  final Map data;
  final bool coverage;

  @override
  Widget build(BuildContext context) {
    final estimated = kgLabel(data['estimatedKg']);
    final reviewed = kgLabel(data['reviewedKg']);
    final measured = kgLabel(data['measuredKg']);
    final total = [
      data['estimatedKg'],
      data['reviewedKg'],
      data['measuredKg'],
    ].whereType<num>().toList();
    final co2 = data['potentialCo2eKg'] as num?;
    final carbon = kgLabel(co2?.abs());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (total.isEmpty)
          const Text('Litter weight unavailable')
        else ...[
          if (total.length > 1)
            Text(
              '${kgLabel(total.reduce((a, b) => a + b))} kg total litter weight',
            ),
          if (estimated != null) Text('$estimated kg AI-estimated weight'),
          if (reviewed != null) Text('$reviewed kg reviewer-estimated weight'),
          if (measured != null)
            Text('$measured kg self-reported measured weight'),
        ],
        Text(
          carbon == null
              ? 'Potential CO₂e savings unavailable'
              : '$carbon kg CO₂e potential ${co2! < 0 ? 'increase' : 'savings'}',
        ),
        if (carbon != null)
          const Text('Modeled disposal scenario', style: AppText.caption),
        if (coverage && (data['materials'] as num? ?? 0) > 0)
          Text(
            "Weight available for ${data['weightMaterials']} of ${data['materials']} material totals",
            style: AppText.caption,
          ),
      ],
    );
  }
}

class _ProgressChart extends StatelessWidget {
  const _ProgressChart({
    required this.series,
    required this.metric,
    required this.monthly,
  });
  final List<Map> series;
  final String metric;
  final bool monthly;

  @override
  Widget build(BuildContext context) {
    if (series.isEmpty) return const SizedBox.shrink();
    final values = series
        .map((bucket) => bucket['totals'][metric] as num)
        .toList();
    final max = values.fold<num>(0, (a, b) => a > b ? a : b);
    if (max == 0) return const Text('No progress for this period.');
    String date(Map bucket) {
      final dt = DateTime.parse(bucket['startsAt']).toUtc();
      final format = MaterialLocalizations.of(context);
      return monthly
          ? format.formatMonthYear(dt)
          : format.formatShortMonthDay(dt);
    }

    return Column(
      children: [
        SizedBox(
          height: 76,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (i, value) in values.indexed)
                Expanded(
                  child: Tooltip(
                    message: '${date(series[i])} UTC · ${pointsLabel(value)}',
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      height: value == 0 ? 2 : 4 + 72 * value / max,
                      color: value == 0
                          ? context.colors.outlineVariant
                          : context.colors.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          children: [
            Text(date(series.first), style: AppText.caption),
            if (series.length > 1)
              Text('${date(series.last)} · UTC', style: AppText.caption),
          ],
        ),
      ],
    );
  }
}
