import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import '../features/auth/account_form.dart';
import '../features/auth/session/session_controller.dart';
import 'auth_navigation.dart';
import '../features/auth/login_page.dart';
import '../features/auth/signup_page.dart';
import '../features/home/end_session.dart';
import '../features/home/home_page.dart';
import '../features/home/in_session.dart';
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
  final navigation = AuthNavigation();
  ref.onDispose(navigation.dispose);
  ref.listen(sessionControllerProvider, navigation.sessionChanged);
  final router = GoRouter(
    refreshListenable: navigation,
    redirect: (_, state) => navigation.redirect(
      mode,
      ref.read(sessionControllerProvider).phase,
      state,
    ),
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
      GoRoute(path: AppRoutes.scan, builder: (_, _) => const ScanPage()),
      GoRoute(path: AppRoutes.report, builder: (_, _) => const ReportPage()),
      GoRoute(path: AppRoutes.map, builder: (_, _) => const LitterMapPage()),
      GoRoute(
        path: AppRoutes.session,
        builder: (_, _) => const InSessionPage(),
      ),
      GoRoute(
        path: AppRoutes.sessionSummary,
        builder: (_, _) => const EndSessionPage(),
      ),
      GoRoute(
        path: AppRoutes.cleanups,
        builder: (_, _) => const CleanupsPage(),
      ),
      GoRoute(
        path: AppRoutes.challenges,
        builder: (_, _) => const ChallengesPage(),
      ),
      GoRoute(
        path: AppRoutes.leaderboard,
        builder: (_, _) => const LeaderboardPage(),
      ),
      GoRoute(path: AppRoutes.badges, builder: (_, _) => const BadgesPage()),
      GoRoute(
        path: AppRoutes.community,
        builder: (_, _) => const CommunityPage(),
      ),
      GoRoute(path: AppRoutes.profile, builder: (_, _) => const ProfilePage()),
      GoRoute(
        path: AppRoutes.connection,
        builder: (_, _) => const ConnectionPage(),
      ),
      for (final section in ProfileSection.values)
        GoRoute(
          path: section.path,
          builder: (_, _) => ProfileDetailPage(section: section),
        ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class _SessionGate extends ConsumerWidget {
  const _SessionGate();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unavailable =
        ref.watch(sessionControllerProvider).phase == SessionPhase.unavailable;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: unavailable
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Could not verify your session.'),
                    TextButton(
                      onPressed: () => ref
                          .read(sessionControllerProvider.notifier)
                          .accessToken(),
                      child: const Text('Retry'),
                    ),
                  ],
                )
              : const CircularProgressIndicator(
                  semanticsLabel: 'Checking session',
                ),
        ),
      ),
    );
  }
}
