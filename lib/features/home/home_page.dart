import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../routes/app_routes.dart';
import '../../routes/auth_navigation.dart';
import '../plogging/application/active_track.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../shared/widgets/eco_art.dart';
import '../../shared/widgets/bottom_navigation.dart';
import '../plogging/application/session_controller.dart';
import '../profile/profile_controller.dart';
import '../community/field_data.dart';
import '../spots/spot_api.dart';
import 'activity_overview.dart';
import '../progress/progress_panel.dart';
import '../plogging/data/plog_drafts.dart';
import '../plogging/activity_page.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(authModeProvider) == AuthMode.live;
    final impact = live ? null : ref.watch(impactProvider);
    final session = live ? null : ref.watch(sessionProvider);
    final livePhase = live
        ? ref.watch(activeTrackProvider.select((s) => s.phase))
        : TrackPhase.idle;
    final draft = live ? ref.watch(resumablePlogProvider).value : false;
    final resume = live
        ? (livePhase == TrackPhase.idle && draft == true) ||
              ![
                TrackPhase.idle,
                TrackPhase.completed,
                TrackPhase.startError,
              ].contains(livePhase)
        : session!.active;
    final profile = live ? ref.watch(fieldData('profile')).value as Map? : null;
    final name = live
        ? (profile?['name'] as String?)
        : ref.watch(profileProvider).split(' ').first;
    void openPlog() {
      if (live) {
        ref.read(activeTrackProvider.notifier).startOrResume();
      } else if (!session!.active) {
        ref.read(sessionProvider.notifier).start();
      }
      openPage(context, AppRoutes.session);
    }

    return AppPage(
      title: 'Home',
      root: true,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
      bottomNavigation: const BottomNavBar(),
      tabHeader: TabHeader(
        action: IconButton(
          tooltip: 'My Activity',
          icon: const Icon(Icons.history_rounded),
          onPressed: () => openPage(context, AppRoutes.activity),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            live
                ? (name?.trim().isNotEmpty == true ? 'Hi, $name' : 'Welcome')
                : 'Hi, $name! 👋',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.title,
          ),
          const Text('Plog today. Change tomorrow.', style: AppText.body),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: AppRadius.card,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: Color(0xff195828)),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FractionallySizedBox(
                      widthFactor: .61,
                      heightFactor: 1,
                      child: Image.asset(
                        'assets/images/illustrations/plogging.png',
                        fit: BoxFit.cover,
                        alignment: const Alignment(.16, .3),
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0xff164e27),
                          Color(0xff195828),
                          Color(0x00195826),
                        ],
                        stops: [0, .43, .70],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        widthFactor: .58,
                        child: Text(
                          resume
                              ? 'Ready to continue your Plog?'
                              : 'Ready to make your surroundings cleaner?',
                          style: AppText.heading.copyWith(
                            color: Colors.white,
                            height: 1.16,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.forest,
                          shape: const StadiumBorder(),
                        ),
                        onPressed: openPlog,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          resume ? 'Resume Plog Session' : 'Start Plog Session',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          AdaptiveTiles(
            minWidth: 136,
            children: [
              for (final (label, detail, icon, route) in [
                (
                  'Scan Litter',
                  'Report litter with photo & location',
                  Icons.add_a_photo_outlined,
                  AppRoutes.scan,
                ),
                (
                  'Explore Map',
                  'Find nearby litter spots & cleanups',
                  Icons.map_outlined,
                  AppRoutes.map,
                ),
              ])
                EcoCard(
                  color: context.colors.primaryContainer,
                  padding: const EdgeInsets.all(12),
                  onTap: () => route == AppRoutes.map
                      ? switchPage(context, route)
                      : openPage(context, route),
                  child: Row(
                    children: [
                      Icon(icon, color: context.colors.primary, size: 29),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: AppText.label),
                            Text(
                              detail,
                              style: AppText.caption.copyWith(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          SectionTitle(
            'Your Impact',
            trailing: TextButton(
              onPressed: () => switchPage(context, AppRoutes.profile),
              child: const Text('View details'),
            ),
          ),
          if (live) ...[
            const AccountStats(),
            SectionTitle(
              'Continue Your Journey',
              trailing: TextButton(
                onPressed: () => openPage(context, AppRoutes.activity),
                child: const Text('View all'),
              ),
            ),
            const _RecentPlog(),
            const SizedBox(height: 8),
            const ProgressSnapshot(),
            const SectionTitle('Latest report'),
            const _LatestReport(),
            TextButton.icon(
              onPressed: () => openPage(context, AppRoutes.report),
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Report litter'),
            ),
          ] else ...[
            EcoCard(
              color: context.colors.primaryContainer,
              child: Text(
                '${impact!.sessions} sessions · ${impact.kg.toStringAsFixed(1)} kg collected',
                style: AppText.heading,
              ),
            ),
            const SectionTitle('Ongoing Challenge'),
            EcoCard(
              onTap: () => openPage(context, AppRoutes.challenges),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.eco_outlined),
                title: const Text('Campus Clean-up'),
                subtitle: Text('${impact.kg.toStringAsFixed(1)} / 20 kg'),
              ),
            ),
            const SectionTitle('Quick Actions'),
            Wrap(
              children: [
                for (final (label, route) in [
                  ('Nearby Clean-ups', AppRoutes.cleanups),
                  ('Leaderboard', AppRoutes.leaderboard),
                ])
                  TextButton(
                    onPressed: () => openPage(context, route),
                    child: Text(label),
                  ),
              ],
            ),
            const PreviewNote(),
          ],
        ],
      ),
    );
  }
}

class _LatestReport extends ConsumerWidget {
  const _LatestReport();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(mySpotsProvider(null));
    final latest = reports.value?.items.firstOrNull;
    final title = latest != null
        ? '${latest.category} litter'
        : reports.isLoading
        ? 'Loading your reports…'
        : reports.hasError
        ? 'Could not load reports'
        : 'No reports yet';
    final detail = latest != null
        ? latest.statusLabel
        : reports.hasError
        ? 'Tap to retry'
        : 'Photograph litter to mark a spot on the map.';
    return EcoCard(
      onTap: () {
        if (reports.hasError) {
          ref.invalidate(mySpotsProvider(null));
        } else {
          openPage(
            context,
            latest == null ? AppRoutes.report : '/spots/${latest.id}',
          );
        }
      },
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: context.colors.primaryContainer,
              borderRadius: AppRadius.small,
            ),
            child: Icon(
              Icons.location_on_outlined,
              color: context.colors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.label),
                if (!reports.isLoading) Text(detail, style: AppText.caption),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
    );
  }
}

class _RecentPlog extends ConsumerWidget {
  const _RecentPlog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(plogHistoryProvider(null));
    final plog = history.value?.items.firstOrNull;
    return EcoCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(Icons.directions_run, color: context.colors.primary),
        title: const Text('Recent Plog', style: AppText.label),
        subtitle: Text(
          plog != null
              ? '${MaterialLocalizations.of(context).formatShortMonthDay(plog.startedAt.toLocal())} · ${formatWalkSummary(plog.seconds, meters: plog.meters)}'
              : history.isLoading
              ? 'Loading activity…'
              : history.hasError
              ? 'Could not load history. Tap to retry.'
              : 'Your first completed Plog will appear here.',
          style: AppText.caption,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          if (history.hasError) {
            ref.invalidate(plogHistoryProvider(null));
            return;
          }
          openPage(
            context,
            plog == null
                ? AppRoutes.activity
                : '${AppRoutes.activity}/${plog.id}',
          );
        },
      ),
    );
  }
}
