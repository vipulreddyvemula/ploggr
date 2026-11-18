import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/features/auth/session/session_api.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/auth/session/session_store.dart';
import 'package:ploggr/routes/app_router.dart';

import 'session_fakes.dart';

Future<ProviderContainer> openLiveApp(
  WidgetTester tester,
  String path,
  MemoryStore store,
  FakeApi api,
) async {
  final container = ProviderContainer(
    overrides: [
      initialLocationProvider.overrideWithValue(path),
      sessionStoreProvider.overrideWithValue(store),
      sessionApiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const PloggrApp()),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> press(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('protected link survives switching forms and one secure signup', (
    tester,
  ) async {
    final store = MemoryStore();
    final api = FakeApi();
    final container = await openLiveApp(tester, '/map', store, api);
    expect(find.text('Explore the preview'), findsNothing);
    await press(tester, 'Sign up');
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), '  a@example.test ');
    await tester.enterText(fields.at(1), 'a' * 14);
    await tester.enterText(fields.at(2), 'different');
    await press(tester, 'Create Account');
    expect(find.text('Use at least 15 characters'), findsOneWidget);
    expect(find.text('Passwords must match'), findsOneWidget);
    const password = ' 1234567890123 ';
    final delayed = Completer<SessionBundle>();
    var calls = 0;
    api.onAuthenticate = (email, rawPassword) {
      calls++;
      expect(email, 'a@example.test');
      expect(rawPassword, password);
      return delayed.future;
    };
    await tester.enterText(fields.at(1), password);
    await tester.enterText(fields.at(2), password);
    await press(tester, 'Create Account');
    expect(find.text('Creating account…'), findsOneWidget);
    tester.widget<TextField>(find.byType(TextField).last).onSubmitted!('');
    expect(calls, 1);
    expect(store.value, isNull);
    delayed.complete(bundle());
    await tester.pumpAndSettle();
    expect(store.value, isNotNull);
    expect(
      container
          .read(appRouterProvider)
          .routerDelegate
          .currentConfiguration
          .uri
          .path,
      '/map',
    );
  });

  testWidgets(
    'failed login and duplicate signup stay editable with actionable errors',
    (tester) async {
      final api = FakeApi();
      final container = await openLiveApp(tester, '/login', MemoryStore(), api);
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.first, 'a@example.test');
      await tester.enterText(fields.last, 'x' * 129);
      await press(tester, 'Login');
      expect(find.text('Use at most 128 characters'), findsOneWidget);
      await tester.enterText(fields.last, 'x');
      for (final error in [
        (401, 'Incorrect email or password.'),
        (null, 'Cannot reach the server. Check your connection and retry.'),
      ]) {
        api.onAuthenticate = (_, _) async => throw AuthRequestFailure(error.$1);
        await press(tester, 'Login');
        expect(find.text(error.$2), findsOneWidget);
      }
      await press(tester, 'Sign up');
      await tester.enterText(fields.at(0), 'a@example.test');
      await tester.enterText(fields.at(1), 'x' * 128);
      await tester.enterText(fields.at(2), 'x' * 128);
      api.onAuthenticate = (_, _) async => throw const AuthRequestFailure(409);
      await press(tester, 'Create Account');
      expect(
        find.text('An account already uses this email. Try logging in.'),
        findsOneWidget,
      );
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedOut,
      );
    },
  );
}
