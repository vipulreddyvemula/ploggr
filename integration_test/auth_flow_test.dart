import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/core/config/app_config.dart';
import 'package:ploggr/core/config/app_config_provider.dart';
import 'package:ploggr/core/network/api_client_provider.dart';
import 'package:ploggr/core/network/protected_api.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/auth/session/session_store.dart';
import 'package:ploggr/features/profile/profile_controller.dart';
import 'package:ploggr/routes/app_router.dart';
import 'package:uuid/uuid.dart';

/// Run on a disposable Android emulator with a configured test backend.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android signup and login preserve identity, and logout revokes the device credentials',
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

      Future<void> waitForText(String label) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (find.text(label).evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text(label), findsOneWidget);
      }

      final client = container.read(apiClientProvider)!;
      final store = container.read(sessionStoreProvider)!;
      final router = container.read(appRouterProvider);
      final sessions = container.read(sessionControllerProvider.notifier);
      await sessions.accessToken();
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedOut,
      );
      await waitForText('Skip');
      await tap('Skip');
      await tap('Sign up');
      var email = '${const Uuid().v4()}@example.test';
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

      await tester.enterText(fields.at(0), 'invalid');
      await tester.enterText(fields.at(1), 'short');
      await tap('Create Account');
      await waitForText('Enter a valid email address');
      expect(find.text('Use at least 15 characters'), findsOneWidget);
      expect(await store.read() == null, isTrue);
      await enterCredentials();
      await tester.enterText(fields.at(2), password);
      await tap('Create Account');
      await waitForSignIn();
      final created = container.read(sessionControllerProvider).user!;
      expect(created.email, email);
      // Confirm an encrypted record exists and can be read through Android's
      // storage plugin. Never include the test credentials in assertion output.
      final access = (await sessions.accessToken())!;
      final refresh = (await store.read())!.refreshToken;
      final prefs = Directory(
        '${Directory.systemTemp.parent.path}/shared_prefs',
      );
      expect(
        await File('${prefs.path}/ploggr_sessions.xml').length(),
        greaterThan(0),
      );
      await for (final file in prefs.list()) {
        if (file is File && file.path.endsWith('.xml')) {
          final xml = await file.readAsString();
          expect(
            [password, access, refresh].any(xml.contains),
            isFalse,
            reason:
                'A session credential was present in plaintext Android preferences',
          );
        }
      }
      Future<void> checkSettings() async {
        router.push<void>('/profile/settings');
        await tester.pumpAndSettle();
        await waitForText(email);
        final identity = container.read(sessionControllerProvider).user!;
        final me = await container
            .read(protectedApiProvider)
            .request<Object?>('GET', 'auth/me');
        expect(me, {'id': identity.id, 'email': email});
      }

      await checkSettings();
      final anonymous = await client.get<Object?>(
        'auth/me',
        options: Options(validateStatus: (_) => true),
      );
      expect(anonymous.statusCode, 401);
      Future<void> logoutInSettings() async {
        final token = (await sessions.accessToken())!;
        final refresh = (await store.read())!.refreshToken;
        Future<int?> bearerStatus() async => (await client.get<Object?>(
          'auth/me',
          options: Options(
            headers: {'Authorization': 'Bearer $token'},
            validateStatus: (_) => true,
          ),
        )).statusCode;
        expect(await bearerStatus(), 200);

        // The screen signs out locally first. Observe the actual UI-triggered
        // server acknowledgement before asserting the same credentials are retired.
        final acknowledged = Completer<int?>();
        final observer = InterceptorsWrapper(
          onResponse: (response, handler) {
            if (response.requestOptions.uri.path.endsWith('/auth/logout') &&
                !acknowledged.isCompleted) {
              acknowledged.complete(response.statusCode);
            }
            handler.next(response);
          },
        );
        client.interceptors.add(observer);
        try {
          await tap('Log out');
          expect(
            await acknowledged.future.timeout(const Duration(seconds: 15)),
            204,
          );
        } finally {
          client.interceptors.remove(observer);
        }
        expect(await store.read() == null, isTrue);
        expect(await bearerStatus(), 401);
        final renewal = await client.post<Object?>(
          'auth/refresh',
          data: {'refreshToken': refresh, 'requestId': const Uuid().v4()},
          options: Options(validateStatus: (_) => true),
        );
        expect(renewal.statusCode, 401);
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (container.read(sessionControllerProvider).phase !=
                SessionPhase.signedOut &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
        expect(router.canPop(), isFalse);
        await router.routerDelegate.popRoute();
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
        await expectLater(
          container.read(protectedApiProvider).request('GET', 'auth/me'),
          throwsA(
            isA<ProtectedApiFailure>().having(
              (error) => error.status,
              'status',
              401,
            ),
          ),
        );
      }

      await logoutInSettings();
      await tap('Sign up');
      await enterCredentials();
      await tester.enterText(fields.at(2), password);
      await tap('Create Account');
      await waitForText('An account already uses this email. Try logging in.');
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedOut,
      );
      expect(await store.read() == null, isTrue);
      await tap('Login');
      await enterCredentials();
      await tester.enterText(fields.at(1), const Uuid().v4());
      await tap('Login');
      await waitForText('Incorrect email or password.');
      expect(container.read(sessionControllerProvider).user, isNull);
      expect(await store.read() == null, isTrue);
      // Submission dismissed the keyboard. Reopen the same field as a user would.
      await tester.tap(fields.at(1));
      await tester.pumpAndSettle();
      await tester.enterText(fields.at(1), password);
      await tap('Login');
      await waitForSignIn();
      expect(container.read(sessionControllerProvider).user, created);
      container.read(profileProvider.notifier).rename('First account only');
      await checkSettings();
      await logoutInSettings();
      final firstEmail = email;
      email = '${const Uuid().v4()}@example.test';
      await tap('Sign up');
      await enterCredentials();
      await tester.enterText(fields.at(2), password);
      await tap('Create Account');
      await waitForSignIn();
      expect(container.read(profileProvider), isNot('First account only'));
      expect(
        container.read(sessionControllerProvider).user?.id,
        isNot(created.id),
      );
      await checkSettings();
      expect(find.text(firstEmail), findsNothing);
      await logoutInSettings();
    },
  );
}
