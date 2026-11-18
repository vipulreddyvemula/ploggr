import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/features/auth/session/session_api.dart';
import 'package:ploggr/features/auth/session/session_store.dart';
import 'package:ploggr/routes/app_router.dart';

import 'package:ploggr/routes/auth_navigation.dart';

import 'session_fakes.dart';

Future<ProviderContainer> openLiveApp(
  WidgetTester tester,
  String path,
  MemoryStore store,
  FakeApi api, {
  AuthMode? mode,
}) async {
  final container = ProviderContainer(
    overrides: [
      initialLocationProvider.overrideWithValue(path),
      if (mode != null) authModeProvider.overrideWithValue(mode),
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
