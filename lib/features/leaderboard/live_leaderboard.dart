import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../progress/progress_panel.dart';

class LiveLeaderboard extends StatefulWidget {
  const LiveLeaderboard({super.key});
  @override
  State<LiveLeaderboard> createState() => _BoardState();
}

class _BoardState extends State<LiveLeaderboard> {
  int period = 0;
  @override
  Widget build(BuildContext context) {
    final key = ['week', 'month', 'all'][period];
    return AppPage(
      title: 'Leaderboard',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterTabs(
            labels: const ['Week', 'Month', 'All time'],
            selected: period,
            onChanged: (i) => setState(() => period = i),
          ),
          RewardData('leaderboard?period=$key', (data) {
            final rules = data['rules'], mine = data['mine'];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionTitle('Your standing'),
                EcoCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mine == null
                            ? 'Unranked'
                            : '#${mine['rank']} · ${pointsLabel(mine['score'])} points',
                        style: AppText.heading,
                      ),
                      if (mine?['impact'] case final Map impact) ...[
                        const SizedBox(height: 6),
                        ImpactTotals(impact, coverage: false),
                      ],
                      if (data['pending'] > 0)
                        Text(
                          '${data['pending']} ${data['pending'] == 1 ? 'Plog' : 'Plogs'} awaiting analysis or review.',
                        ),
                      if (rules == null)
                        const Text(
                          'Rankings open when the scoring rules are published. Your completed Plogs are saved.',
                        ),
                    ],
                  ),
                ),
                const SectionTitle('Community standings'),
                if ((data['items'] as List).isEmpty)
                  const AppNotice('No ranked Plogs for this period.'),
                for (final r in data['items'])
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.sm),
                    child: EcoCard(
                      child: Row(
                        children: [
                          Text('#${r['rank']}', style: AppText.label),
                          const SizedBox(width: AppSpace.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r['name']),
                                Text(
                                  '${pointsLabel(r['score'])} pts',
                                  style: AppText.caption,
                                ),
                                if (r['impact'] case final Map impact)
                                  ImpactTotals(impact, coverage: false),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (rules is Map) PointsExplanation(rules),
              ],
            );
          }),
        ],
      ),
    );
  }
}
