import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ploggr/core/config/app_config.dart';
import 'package:ploggr/core/config/app_config_provider.dart';
import 'package:ploggr/features/auth/session/session_api.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/auth/session/session_store.dart';
import 'package:ploggr/routes/app_router.dart';
import 'package:ploggr/routes/auth_navigation.dart';

import 'live_app_harness.dart';
import 'session_fakes.dart';

void main() {
  testWidgets(
    'live branding follows session restoration back to the requested route',
    (tester) async {
      final refresh = Completer<SessionBundle>();
      final container = await openLiveApp(
        tester,
        '/profile/help',
        MemoryStore()..value = StoredSession(token),
        FakeApi()..onRefresh = () => refresh.future,
      );
      expect(find.text('Plog today.'), findsOneWidget);
      expect(find.text('Change tomorrow.'), findsOneWidget);
      expect(find.bySemanticsLabel('Ploggr'), findsOneWidget);
      refresh.complete(bundle());
      await tester.pumpAndSettle();
      expect(container.read(appRouterProvider).state.uri.path, '/profile/help');
      expect(find.text('Change tomorrow.'), findsNothing);
    },
  );

  testWidgets('a new account starts on Home after explicit sign-out', (
    tester,
  ) async {
    final container = await openLiveApp(
      tester,
      '/profile/activity/old-account',
      MemoryStore()..value = StoredSession(token),
      FakeApi(),
    );
    final sessions = container.read(sessionControllerProvider.notifier);
    final router = container.read(appRouterProvider);
    await sessions.logout();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
    await sessions.signup('another@example.test', 'another-account-password');
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
  });

  testWidgets(
    'a returning signed-out user reaches login and a signed-in activity link has a list to return to',
    (tester) async {
      final signedOut = await openLiveApp(
        tester,
        '/',
        MemoryStore()..onboarded = true,
        FakeApi(),
      );
      expect(
        signedOut
            .read(appRouterProvider)
            .routerDelegate
            .currentConfiguration
            .uri
            .path,
        '/login',
      );
      await tester.pumpWidget(const SizedBox());
      final signedIn = await openLiveApp(
        tester,
        '/profile/activity/field-test',
        MemoryStore()..value = StoredSession(token),
        FakeApi(),
      );
      final router = signedIn.read(appRouterProvider);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/profile/activity/field-test',
      );
      expect(router.canPop(), isTrue);
      router.pop();
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/profile/activity',
      );
    },
  );
  testWidgets('Android without an API URL requires configuration', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [appConfigProvider.overrideWithValue(AppConfig.fromValues())],
    );
    addTearDown(container.dispose);
    expect(container.read(authModeProvider), AuthMode.unavailable);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'fresh live install opens onboarding and does not offer a guest path',
    (tester) async {
      final c = await openLiveApp(tester, '/', MemoryStore(), FakeApi());
      expect(
        c.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path,
        '/onboarding',
      );
      await press(tester, 'Skip');
      expect(find.text('Sign up'), findsOneWidget);
      expect(find.text('Explore the preview'), findsNothing);
    },
  );

  testWidgets(
    'an unsupported release configuration blocks all product and signup routes',
    (tester) async {
      final c = await openLiveApp(
        tester,
        '/profile/settings',
        MemoryStore(),
        FakeApi(),
        mode: AuthMode.unavailable,
      );
      final router = c.read(appRouterProvider);
      for (final location in ['/home', '/signup', '/onboarding', '/profile']) {
        router.go(location);
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
        expect(
          find.text('Sign-in requires Android and a secure API connection.'),
          findsOneWidget,
        );
        expect(find.text('Explore the preview'), findsNothing);
      }
    },
  );

  testWidgets(
    'an offline cold launch hides protected content and retry returns to the link',
    (tester) async {
      final store = MemoryStore()..value = StoredSession(token);
      final api = FakeApi()
        ..onRefresh = () async => throw const AuthRequestFailure(null);
      final c = await openLiveApp(tester, '/map', store, api);
      final router = c.read(appRouterProvider);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
      expect(find.text('Could not verify your session.'), findsOneWidget);
      expect(find.text('Explore the preview'), findsNothing);
      final pending = store.value!.requestId;
      api.onRefresh = null;
      await press(tester, 'Retry');
      expect(api.requests, [pending, pending]);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/map');
    },
  );

  testWidgets(
    'a rejected startup refresh opens login and unknown destinations are discarded',
    (tester) async {
      final store = MemoryStore()..value = StoredSession(token);
      final api = FakeApi()
        ..onRefresh = () async => throw const AuthRequestFailure(401);
      final c = await openLiveApp(tester, '/', store, api);
      final router = c.read(appRouterProvider);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
      expect(store.value, isNull);
      router.go('/unknown?next=https://example.test');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
      await c
          .read(sessionControllerProvider.notifier)
          .login('a@example.test', 'password');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
    },
  );

  testWidgets('deletion failure blocks the app until retry succeeds', (
    tester,
  ) async {
    final store = MemoryStore()..value = StoredSession(token);
    final c = await openLiveApp(tester, '/home', store, FakeApi());
    final sessions = c.read(sessionControllerProvider.notifier);
    store.failClear = true;
    await expectLater(sessions.logout(), throwsStateError);
    await tester.pumpAndSettle();
    expect(store.pendingLogout, isTrue);
    expect(find.text('Retry logout'), findsOneWidget);
    c.read(appRouterProvider).go('/map');
    await tester.pumpAndSettle();
    expect(find.text('Retry logout'), findsOneWidget);
    expect(await sessions.credential(), isNull);
    store.failClear = false;
    await press(tester, 'Retry logout');
    expect(store.value, isNull);
    expect(store.pendingLogout, isFalse);
    expect(
      c.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path,
      '/login',
    );
    expect(c.read(appRouterProvider).canPop(), isFalse);
  });

  testWidgets(
    'process restart with a pending logout cannot restore the old credential',
    (tester) async {
      final store = MemoryStore()
        ..value = StoredSession(token)
        ..pendingLogout = true;
      final api = FakeApi();
      final c = await openLiveApp(tester, '/map', store, api);
      expect(find.text('Retry logout'), findsOneWidget);
      expect(api.requests, isEmpty);
      await press(tester, 'Retry logout');
      expect(c.read(sessionControllerProvider).phase, SessionPhase.signedOut);
      expect(store.value, isNull);
      expect(api.requests, isEmpty);
    },
  );

  testWidgets(
    'background renewal preserves the route until a temporary failure locks it',
    (tester) async {
      final store = MemoryStore()..value = StoredSession(token);
      final api = FakeApi();
      final c = await openLiveApp(tester, '/map', store, api);
      final router = c.read(appRouterProvider);
      final sessions = c.read(sessionControllerProvider.notifier);
      final rejected = await sessions.credential();
      final pending = Completer<SessionBundle>();
      api.onRefresh = () => pending.future;
      final renewal = sessions.credential(rejected: rejected);
      await tester.pumpAndSettle();
      expect(c.read(sessionControllerProvider).phase, SessionPhase.renewing);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/map');
      pending.completeError(const AuthRequestFailure(null));
      await renewal;
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
      api.onRefresh = null;
      await press(tester, 'Retry');
      expect(router.routerDelegate.currentConfiguration.uri.path, '/map');
    },
  );
}
