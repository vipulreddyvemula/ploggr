import '../features/community/live_community.dart';
import '../features/community/moderation_page.dart';
import '../features/cleanups/live_programs.dart';
import '../features/leaderboard/live_leaderboard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import '../features/auth/account_form.dart';
import '../features/auth/session/session_store.dart';
import '../features/auth/session/session_controller.dart';
import 'auth_navigation.dart';
import '../features/auth/login_page.dart';
import '../features/auth/logout.dart';
import '../features/auth/signup_page.dart';
import '../features/home/end_session.dart';
import '../features/home/home_page.dart';
import '../features/spots/explore_page.dart';
import '../features/spots/spot_editor.dart';
import '../features/home/in_session.dart';
import '../features/plogging/live_plog_page.dart';
import '../features/plogging/activity_page.dart';
import '../features/leaderboard/leaderboard_page.dart';
import '../features/splash/splash_screen.dart';
import '../features/onboarding/onboarding_page.dart';
import '../features/litter/scan_page.dart';
import '../features/litter/report_page.dart';
import '../features/litter/litter_map_page.dart';
import '../features/cleanups/cleanups_page.dart';
import '../features/challenges/challenges_page.dart';
import '../features/badges/badges_page.dart';
import '../features/community/community_page.dart';
import '../features/profile/profile_page.dart';
import '../features/connection/connection_page.dart';
import 'app_routes.dart';

/// Override in tests to open a specific route without changing production flow.
final initialLocationProvider = Provider<String>((ref) => AppRoutes.splash);
final appRouterProvider = Provider<GoRouter>((ref) {
  final mode = ref.watch(authModeProvider);
  final live = mode == AuthMode.live;
  final navigation = AuthNavigation();
  ref.onDispose(navigation.dispose);
  final router = GoRouter(
    refreshListenable: navigation,
    redirect: (_, state) async {
      if (live &&
          state.uri.path == AppRoutes.splash &&
          ref.read(sessionControllerProvider).phase == SessionPhase.signedOut) {
        try {
          navigation.onboardingSeen =
              await ref.read(sessionStoreProvider)?.seenOnboarding() ?? false;
        } catch (_) {
          navigation.onboardingSeen = false;
        }
      }
      if (!ref.mounted) return null;
      return navigation.redirect(
        mode,
        ref.read(sessionControllerProvider).phase,
        state,
      );
    },
    initialLocation: ref.read(initialLocationProvider),
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        builder: (_, _) =>
            mode == AuthMode.live ? const _SessionGate() : const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (_, state) => OnboardingPage(
          live: live,
          initialPage:
              int.tryParse(state.uri.queryParameters['page'] ?? '0') ?? 0,
        ),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (_, _) => switch (mode) {
          AuthMode.preview => const LoginPage(),
          AuthMode.live => const AccountForm(signup: false),
          AuthMode.unavailable => const Scaffold(
            body: SafeArea(
              child: Center(
                child: Text(
                  'Sign-in requires Android and a secure API connection.',
                ),
              ),
            ),
          ),
        },
      ),
      GoRoute(
        path: AppRoutes.signup,
        builder: (_, _) => mode == AuthMode.preview
            ? const SignupPage()
            : const AccountForm(signup: true),
      ),
      GoRoute(path: AppRoutes.home, builder: (_, _) => const HomePage()),
      GoRoute(
        path: AppRoutes.scan,
        builder: (_, _) =>
            live ? const SpotEditor(openCamera: true) : const ScanPage(),
      ),
      GoRoute(
        path: AppRoutes.report,
        builder: (_, _) => live ? const SpotEditor() : const ReportPage(),
      ),
      GoRoute(
        path: AppRoutes.map,
        builder: (_, state) => live
            ? ExplorePage(initialSpot: state.uri.queryParameters['spot'])
            : const LitterMapPage(),
      ),
      GoRoute(
        path: AppRoutes.session,
        builder: (_, _) => mode == AuthMode.live
            ? const LivePlogPage()
            : const InSessionPage(),
      ),
      GoRoute(
        path: AppRoutes.sessionSummary,
        builder: (_, _) => mode == AuthMode.live
            ? const LivePlogPage()
            : const EndSessionPage(),
      ),
      GoRoute(
        path: AppRoutes.cleanups,
        builder: (_, _) =>
            live ? const LivePrograms(events: true) : const CleanupsPage(),
      ),
      GoRoute(
        path: AppRoutes.challenges,
        builder: (_, _) =>
            live ? const LivePrograms(events: false) : const ChallengesPage(),
      ),
      GoRoute(
        path: AppRoutes.leaderboard,
        builder: (_, _) =>
            live ? const LiveLeaderboard() : const LeaderboardPage(),
      ),
      GoRoute(
        path: AppRoutes.badges,
        builder: (_, _) => live ? const LiveBadges() : const BadgesPage(),
      ),
      GoRoute(
        path: AppRoutes.community,
        builder: (_, _) => live ? const LiveCommunity() : const CommunityPage(),
      ),
      GoRoute(path: AppRoutes.profile, builder: (_, _) => const ProfilePage()),
      GoRoute(
        path: AppRoutes.connection,
        builder: (_, _) => const ConnectionPage(),
      ),
      if (live) ...[
        GoRoute(
          path: '/spots/:id',
          builder: (_, s) => SpotPage(s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/community/write',
          builder: (_, s) => PostComposer(plog: s.uri.queryParameters['plog']),
        ),
        GoRoute(
          path: '/community/post/:id',
          builder: (_, s) => PostComments(s.pathParameters['id']!),
        ),
        GoRoute(path: '/moderation', builder: (_, _) => const ModerationPage()),
      ],
      for (final section in ProfileSection.values)
        GoRoute(
          path: section.path,
          routes: [
            if (live && section == ProfileSection.activity)
              GoRoute(
                path: ':id',
                builder: (_, s) =>
                    PlogActivityPage(id: s.pathParameters['id']!),
              ),
          ],
          builder: (_, _) {
            if (!live) return ProfileDetailPage(section: section);
            return switch (section) {
              ProfileSection.saved => const ExplorePage(own: true),
              ProfileSection.activity => const PlogActivityPage(),
              ProfileSection.about || ProfileSection.help => Scaffold(
                appBar: AppBar(title: Text(section.title)),
                body: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Text(
                    section == ProfileSection.about
                        ? 'Ploggr connects litter sightings with people who pick them up on walks.'
                        : 'Report litter to share a photo and pin. During a Plog, add one to six pickup photos. You can walk without recording a route. Confirm a nearby cleanup to update the map.',
                  ),
                ),
              ),
              _ => ProfileDetailPage(section: section),
            };
          },
        ),
    ],
  );
  ref.listen(sessionControllerProvider, (previous, next) {
    if (previous?.phase == SessionPhase.signingOut &&
        next.phase == SessionPhase.signedOut) {
      // Drop the previous account's route from the navigation history as soon
      // as local sign-out completes, even when the next login happens quickly.
      router.go(AppRoutes.login);
    }
    navigation.sessionChanged(previous, next);
  });
  ref.onDispose(router.dispose);
  return router;
});

class _SessionGate extends ConsumerWidget {
  const _SessionGate();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(sessionControllerProvider).phase;
    final sessions = ref.read(sessionControllerProvider.notifier);
    final Widget content = switch (phase) {
      SessionPhase.unavailable => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Could not verify your session.'),
          TextButton(
            onPressed: sessions.accessToken,
            child: const Text('Retry'),
          ),
          TextButton(
            onPressed: () => logoutFromDevice(context, sessions),
            child: const Text('Log out'),
          ),
        ],
      ),
      SessionPhase.logoutFailed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Secure storage could not finish signing you out.'),
          TextButton(
            onPressed: () => logoutFromDevice(context, sessions),
            child: const Text('Retry logout'),
          ),
        ],
      ),
      _ => const CircularProgressIndicator(semanticsLabel: 'Checking session'),
    };
    return Scaffold(
      body: SafeArea(child: Center(child: content)),
    );
  }
}
