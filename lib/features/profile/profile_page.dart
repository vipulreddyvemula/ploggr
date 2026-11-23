import 'package:package_info_plus/package_info_plus.dart';
import '../onboarding/onboarding_page.dart';
import '../community/field_data.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../routes/app_routes.dart';
import '../../routes/auth_navigation.dart';
import '../../core/network/protected_api.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../shared/widgets/eco_art.dart';
import '../../shared/widgets/bottom_navigation.dart';
import '../plogging/application/session_controller.dart';
import '../auth/logout.dart';
import '../auth/session/session_controller.dart' show sessionControllerProvider;
import '../litter/application/litter_controller.dart';
import 'profile_controller.dart';
import '../home/activity_overview.dart';

enum ProfileSection {
  activity(AppRoutes.activity, 'My Activity', Icons.work_history_outlined),
  saved(AppRoutes.saved, 'Saved Litter Spots', Icons.bookmark_border_rounded),
  settings(AppRoutes.settings, 'Settings', Icons.settings_outlined),
  help(AppRoutes.help, 'Help & Support', Icons.help_outline_rounded),
  about(AppRoutes.about, 'About ploggr', Icons.info_outline_rounded);

  const ProfileSection(this.path, this.title, this.icon);
  final String path;
  final String title;
  final IconData icon;
}

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(authModeProvider) == AuthMode.live;
    final email = live
        ? ref.watch(sessionControllerProvider.select((s) => s.user?.email))
        : null;
    final profile = live ? ref.watch(fieldData('profile')).value as Map? : null;
    final name = live
        ? (profile?['name'] as String? ?? 'Your account')
        : ref.watch(profileProvider);
    final impact = live ? null : ref.watch(impactProvider);
    return AppPage(
      title: 'Profile',
      root: live,
      bottomNavigation: const BottomNavBar(),
      child: Column(
        children: [
          Row(
            children: [
              if (live)
                CircleAvatar(
                  radius: 34,
                  backgroundColor: context.colors.primaryContainer,
                  child: Text(
                    name.characters.first.toUpperCase(),
                    style: AppText.hero.copyWith(color: context.colors.primary),
                  ),
                )
              else
                const PersonAvatar(index: 3, radius: 34),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: AppText.heading,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      live
                          ? ((email ?? '').endsWith('@identity.invalid')
                                ? 'Connected account'
                                : email ?? '')
                          : '@${name.split(' ').first.toLowerCase()}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit profile',
                onPressed: () => _edit(
                  context,
                  ref,
                  live ? (profile?['name'] ?? '') : name,
                  live: live,
                ),
                icon: const Icon(Icons.edit_outlined, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (live)
            const AccountStats(profile: true)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: StatTile(
                    value: '${impact!.kg.toStringAsFixed(1)} kg',
                    label: 'Litter Collected',
                    onTap: () => openPage(context, AppRoutes.activity),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(
                    value: '${impact.sessions}',
                    label: 'Sessions',
                    onTap: () => openPage(context, AppRoutes.activity),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(
                    value: '5',
                    label: 'Badges',
                    onTap: () => openPage(context, AppRoutes.badges),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 24),
          if (live) ...[
            const SectionTitle('Your activity'),
            EcoCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _row(context, ProfileSection.activity, 'My Activity'),
                  _row(context, ProfileSection.saved, 'My reports'),
                  ListTile(
                    leading: const Icon(Icons.workspace_premium_outlined),
                    title: const Text('My badges'),
                    onTap: () => openPage(context, AppRoutes.badges),
                  ),
                  ListTile(
                    leading: const Icon(Icons.leaderboard_outlined),
                    title: const Text('Leaderboard'),
                    onTap: () => openPage(context, AppRoutes.leaderboard),
                  ),
                  if (profile?['moderator'] == true)
                    ListTile(
                      leading: const Icon(Icons.fact_check_outlined),
                      title: const Text('Moderation'),
                      onTap: () => openPage(context, '/moderation'),
                    ),
                ],
              ),
            ),
            const SectionTitle('Account and support'),
          ],
          EcoCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final section
                    in live
                        ? [
                            ProfileSection.settings,
                            ProfileSection.help,
                            ProfileSection.about,
                          ]
                        : ProfileSection.values) ...[
                  if (!live && section != ProfileSection.values.first)
                    const Divider(),
                  _row(context, section, section.title),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (!live)
            const PreviewNote(
              text: 'Preview profile · your small steps make a big difference',
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, ProfileSection section, String title) =>
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        leading: Icon(section.icon, size: 22, color: context.colors.onSurface),
        title: Text(title, style: AppText.label.copyWith(fontSize: 14)),
        trailing: const Icon(Icons.chevron_right_rounded, size: 21),
        onTap: () => openPage(context, section.path),
      );

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    String current, {
    bool live = false,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EditProfileDialog(
        name: current,
        save: (name) async {
          if (live) {
            await writeField(
              ref,
              'PUT',
              'profile',
              data: {'name': name},
              reload: ['profile'],
            );
          } else {
            ref.read(profileProvider.notifier).rename(name);
          }
        },
      ),
    );
  }
}

class _EditProfileDialog extends StatefulWidget {
  const _EditProfileDialog({required this.name, required this.save});
  final String name;
  final Future<void> Function(String) save;
  @override
  State<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<_EditProfileDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.name,
  );
  bool saving = false;
  String? error;

  Future<void> save() async {
    if (saving || _name.text.trim().isEmpty) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.save(_name.text.trim());
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = 'Could not save your display name. Try again.';
        });
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: const Text('Edit profile'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            enabled: !saving,
            maxLength: 40,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => save(),
            decoration: const InputDecoration(
              labelText: 'Display name',
              helperText: 'Shown with your community posts.',
              helperMaxLines: 3,
            ),
          ),
          if (error != null) AppNotice(error!, status: AppStatus.failure),
        ],
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: saving || _name.text.trim().isEmpty ? null : save,
          child: Text(saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
  );
}

class ProfileDetailPage extends ConsumerStatefulWidget {
  const ProfileDetailPage({super.key, required this.section});
  final ProfileSection section;
  @override
  ConsumerState<ProfileDetailPage> createState() => _ProfileDetailPageState();
}

class _ProfileDetailPageState extends ConsumerState<ProfileDetailPage> {
  @override
  Widget build(BuildContext context) {
    final live = ref.watch(authModeProvider) == AuthMode.live;
    return AppPage(
      title: widget.section.title,
      backTo: AppRoutes.profile,
      child: switch (widget.section) {
        ProfileSection.activity => _activity(),
        ProfileSection.saved => _saved(),
        ProfileSection.settings => _settings(),
        ProfileSection.help when live => const _LiveHelp(),
        ProfileSection.about when live => const _LiveAbout(),
        ProfileSection.help => const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('A little help for your next plog', style: AppText.title),
            SizedBox(height: 20),
            ExpansionTile(
              key: PageStorageKey('What is plogging?'),
              title: Text('What is plogging?'),
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Plogging combines walking or jogging with picking up litter. Small steps help care for the places we share.',
                  ),
                ),
              ],
            ),
            ExpansionTile(
              key: PageStorageKey('How do I use this preview?'),
              title: Text('How do I use this preview?'),
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Start a sample session, capture a sample litter photo, join an event, or share a local post. Changes last until the app restarts.',
                  ),
                ),
              ],
            ),
            ExpansionTile(
              key: PageStorageKey('Does this use my camera or location?'),
              title: Text('Does this use my camera or location?'),
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No. Photos, maps, routes, and activity metrics are illustrative. No camera or location permissions are requested.',
                  ),
                ),
              ],
            ),
            ExpansionTile(
              key: PageStorageKey('How can I plog thoughtfully?'),
              title: Text('How can I plog thoughtfully?'),
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Be mindful of your surroundings and fellow walkers. Leave sharp or unknown items for local clean-up services.',
                  ),
                ),
              ],
            ),
          ],
        ),
        ProfileSection.about => const Column(
          children: [
            SizedBox(height: 32),
            PloggrLogo(),
            SizedBox(height: 24),
            Text(
              'Plog today. Change tomorrow.',
              style: AppText.heading,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 16),
            Text(
              'A cleaner planet, one step at a time. Ploggr brings movement, environmental care, and community together.',
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 24),
            PreviewNote(
              text:
                  'Version 1.0.0 · design preview\nBuilt with Flutter · all data is local and simulated',
            ),
          ],
        ),
      },
    );
  }

  Widget _activity() {
    final impact = ref.watch(impactProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${impact.sessions} sessions. A lasting impact.',
          style: AppText.title,
        ),
        const SizedBox(height: 8),
        Text(
          '${impact.kg.toStringAsFixed(1)} kg collected in your preview profile.',
        ),
        const SizedBox(height: 24),
        for (final session in impact.savedSessions) ...[
          EcoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Your latest plog', style: AppText.heading),
                const SizedBox(height: 6),
                Text(
                  '${session.kg.toStringAsFixed(1)} kg · ${session.duration} · ${session.litterType}',
                ),
                const SizedBox(height: 4),
                Text(
                  '${session.date.day}/${session.date.month}/${session.date.year} · saved locally',
                  style: AppText.caption,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        const EcoCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Lakeside morning plog', style: AppText.heading),
              SizedBox(height: 6),
              Text('2.1 kg · 3.2 km · 32 min'),
              SizedBox(height: 4),
              Text('Nov 15, 2026 · sample activity', style: AppText.caption),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const PreviewNote(),
      ],
    );
  }

  Widget _saved() => Column(
    children: [
      for (final report in ref.watch(litterProvider)) ...[
        EcoCard(
          onTap: () => openPage(context, AppRoutes.map),
          child: Row(
            children: [
              const LitterPhoto(width: 64, height: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${report.type} Litter', style: AppText.label),
                    Text(report.location, style: AppText.caption),
                    if (report.description.isNotEmpty)
                      Text(
                        report.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption,
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
      const PreviewNote(
        text: 'Your sample reports are saved here until restart.',
      ),
    ],
  );
  Widget _settings() {
    final live = ref.watch(authModeProvider) == AuthMode.live;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (live)
          const _AccountIdentity()
        else
          const EcoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('You’re exploring the preview', style: AppText.heading),
                SizedBox(height: 8),
                Text(
                  'Your preview activity and profile details stay on this device. '
                  'A connection check contacts the configured server. '
                  'Authentication, notifications, live tracking, and cloud storage are not connected.',
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        ListTile(
          leading: Icon(Icons.network_check, color: context.colors.primary),
          title: const Text('Connection check'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openPage(context, AppRoutes.connection),
        ),
        ListTile(
          leading: Icon(Icons.slideshow_rounded, color: context.colors.primary),
          title: const Text('Replay onboarding'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => OnboardingPage(live: live, replay: true),
            ),
          ),
        ),
        ListTile(
          leading: Icon(Icons.logout_rounded, color: context.colors.primary),
          title: Text(live ? 'Log out' : 'Leave preview'),
          subtitle: live ? null : const Text('Return to the welcome screen'),
          onTap: live
              ? () async {
                  if (await confirmAction(
                        context,
                        'Log out of Ploggr?',
                        'Confirm logout',
                      ) &&
                      mounted) {
                    await logoutFromDevice(
                      context,
                      ref.read(sessionControllerProvider.notifier),
                    );
                  }
                }
              : () => switchPage(context, AppRoutes.login),
        ),
        const SizedBox(height: 20),
        if (!live)
          const PreviewNote(text: 'Appearance follows your device theme.'),
      ],
    );
  }
}

class _AccountIdentity extends ConsumerWidget {
  const _AccountIdentity();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(currentIdentityProvider);
    return EcoCard(
      child: identity.when(
        data: (user) => ListTile(
          title: const Text('Signed in as'),
          subtitle: Text(user.email),
        ),
        loading: () => const Text('Checking account…'),
        error: (_, _) => Column(
          children: [
            const Text('Could not load your account.'),
            TextButton(
              onPressed: () => ref.invalidate(currentIdentityProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveHelp extends StatelessWidget {
  const _LiveHelp();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      AppNotice('Get help with camera access, GPS and syncing.'),
      _HelpTopic(
        'Camera and photo picker',
        'Allow camera access in your device settings or choose an image from the gallery. '
            'Use a still JPEG or PNG. If a photo cannot be saved, check how much space is available on the device.',
      ),
      _HelpTopic(
        'GPS and the report pin',
        'Go outdoors and check that location is enabled. You can start a Plog without recording a route. '
            'If the GPS estimate is off, search for a landmark or position the report pin yourself.',
      ),
      _HelpTopic(
        'Pending uploads',
        'Drafts that are waiting to sync stay on this device. Reconnect and sign in to the same account. '
            'You can retry a report from My reports or resume a Plog from Home.',
      ),
      _HelpTopic(
        'Who can see photos and locations?',
        'A published sighting includes its selected pin, photos, category, and any notes you add. '
            'Pickup photos and routes in your activity stay private to your account. Authorized reviewers can '
            'see evidence sent for review. A shared Plog post includes the walk’s summary.',
      ),
    ],
  );
}

class _HelpTopic extends StatelessWidget {
  const _HelpTopic(this.title, this.body);
  final String title, body;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: PageStorageKey(title),
    title: Text(title),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          0,
          AppSpace.lg,
          AppSpace.lg,
        ),
        child: Text(body),
      ),
    ],
  );
}

final _installedPackage = FutureProvider<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
  retry: (_, _) => null,
);

class _LiveAbout extends ConsumerWidget {
  const _LiveAbout();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Center(child: PloggrLogo(size: 56)),
      const SizedBox(height: AppSpace.xl),
      const Text(
        'Ploggr connects litter sightings with the people who pick up litter on their walks.',
        style: AppText.body,
      ),
      const SizedBox(height: AppSpace.lg),
      ref
          .watch(_installedPackage)
          .when(
            data: (info) =>
                Text('Version ${info.version} · Build ${info.buildNumber}'),
            loading: () => const AppLoading('Reading app version'),
            error: (_, _) => AppNotice(
              'Could not read app version.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(_installedPackage),
            ),
          ),
    ],
  );
}
