import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/core/config/app_config.dart';
import 'package:ploggr/core/config/app_config_provider.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/routes/app_router.dart';
import 'package:uuid/uuid.dart';

/// Run on a disposable Android emulator with a configured test backend.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'the signup and login screens establish the same backend identity',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.fromEnvironment()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PloggrApp(),
        ),
      );
      Future<void> tap(String label) async {
        final target = find.text(label);
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      final router = container.read(appRouterProvider);
      final sessions = container.read(sessionControllerProvider.notifier);
      await sessions.accessToken();
      await sessions.logout();
      router.go('/login');
      await tester.pumpAndSettle();
      await tap('Sign up');
      final email = '${const Uuid().v4()}@example.test';
      final password = const Uuid().v4();
      final fields = find.byType(TextFormField);
      Future<void> enterCredentials() async {
        await tester.enterText(fields.at(0), email);
        await tester.enterText(fields.at(1), password);
      }

      Future<void> waitForSignIn() async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (container.read(sessionControllerProvider).phase !=
                SessionPhase.signedIn &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
      }

      await enterCredentials();
      await tester.enterText(fields.at(2), password);
      await tap('Create Account');
      await waitForSignIn();
      final created = container.read(sessionControllerProvider).user;
      expect(created?.email, email);
      await sessions.logout();
      router.go('/login');
      await tester.pumpAndSettle();
      await enterCredentials();
      await tap('Login');
      await waitForSignIn();
      expect(container.read(sessionControllerProvider).user, created);
      await sessions.logout();
    },
  );
}
