import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../community/field_data.dart';

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
          FieldData('leaderboard?period=$key', (data) {
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
                            : '#${mine['rank']} · ${mine['score']} points',
                        style: AppText.heading,
                      ),
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
                  const Text('No ranked Plogs for this period.'),
                for (final r in data['items'])
                  ListTile(
                    leading: Text('#${r['rank']}'),
                    title: Text(r['name']),
                    trailing: Text('${r['score']} pts'),
                  ),
                ExpansionTile(
                  key: const PageStorageKey('leaderboard-scoring'),
                  title: const Text('How scoring works'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        rules == null
                            ? 'Scores will use identified materials, quantities and supported avoided-carbon estimates.'
                            : 'Scoring version ${rules['version']}\n${(rules['material_points'] as Map).entries.map((e) => "${e.key} · ${e.value} points per item").join("\n")}\nAvoided emissions · ${rules['carbon_points_per_kg']} points/kg CO₂e.',
                      ),
                    ),
                  ],
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}
