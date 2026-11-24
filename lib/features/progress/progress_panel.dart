import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../shared/widgets/eco_art.dart';
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
        if (carbon == null && coverage)
          const Text(
            'CO₂e estimates require accepted pickup evidence and a supported disposal scenario.',
            style: AppText.caption,
          ),
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

class AccountStats extends ConsumerWidget {
  const AccountStats({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totals = ref.watch(totalsProvider);
    final activity = totals.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RewardData('progress?period=all', (data) {
          final impact = data['totals'] as Map;
          final carbon = impact['potentialCo2eKg'] as num?;
          final weights = [
            (impact['measuredKg'], 'Measured litter'),
            (impact['reviewedKg'], 'Reviewed estimate'),
            (impact['estimatedKg'], 'AI estimate'),
          ];
          final weight = weights.where((w) => w.$1 != null).firstOrNull;
          return EcoCard(
            color: context.colors.primaryContainer,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            child: AdaptiveTiles(
              minWidth: 72,
              spacing: 0,
              children: [
                for (final (icon, value, label) in [
                  (
                    Icons.directions_run,
                    '${activity?.count ?? impact['completedPlogs']}',
                    'Sessions',
                  ),
                  (
                    Icons.route_outlined,
                    activity?.tracked == 0
                        ? '—'
                        : formatWalkDistance(
                            activity?.meters ??
                                (impact['distanceMeters'] as num).toDouble(),
                          ),
                    'Distance',
                  ),
                  (
                    Icons.shopping_bag_outlined,
                    weight == null ? '—' : '${kgLabel(weight.$1)} kg',
                    weight?.$2 ?? 'Litter weight',
                  ),
                  (
                    Icons.cloud_outlined,
                    carbon == null
                        ? 'No estimate'
                        : '${kgLabel(carbon.abs())} kg',
                    carbon != null && carbon < 0
                        ? 'Potential CO₂e increase'
                        : 'Potential CO₂e savings',
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 2,
                    ),
                    child: Column(
                      children: [
                        Icon(icon, color: context.colors.primary),
                        const SizedBox(height: 4),
                        Text(
                          value,
                          style: AppText.label,
                          textAlign: TextAlign.center,
                        ),
                        Text(
                          label,
                          style: AppText.caption.copyWith(fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }),
        if (totals.hasError)
          TextButton(
            onPressed: () => ref.invalidate(totalsProvider),
            child: const Text('Retry activity totals'),
          ),
      ],
    );
  }
}
