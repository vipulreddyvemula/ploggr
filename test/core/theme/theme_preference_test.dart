import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/main.dart' as app;
import 'package:ploggr/routes/app_routes.dart';

void main() {
  testWidgets('fresh startup stays light when the system is dark', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await app.main();
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
    final screen = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(screen).brightness, Brightness.light);
  }, variant: TargetPlatformVariant.all());

  testWidgets('light is the default and Settings persists both themes', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    BuildContext screen() => tester.element(find.byType(Scaffold).first);
    final toggle = find.byType(SwitchListTile);

    Future<void> openSettings() async {
      await app.main();
      await tester.pump();
      GoRouter.of(screen()).go(AppRoutes.settings);
      await tester.pumpAndSettle();
    }

    await openSettings();
    expect(Theme.of(screen()).brightness, Brightness.light);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(find.text('Dark mode'));
    await tester.pumpAndSettle();
    expect(Theme.of(screen()).brightness, Brightness.dark);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await openSettings();
    expect(Theme.of(screen()).brightness, Brightness.dark);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(find.text('Dark mode'));
    await tester.pumpAndSettle();
    expect(Theme.of(screen()).brightness, Brightness.light);

    await tester.pumpWidget(const SizedBox.shrink());
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await openSettings();
    expect(Theme.of(screen()).brightness, Brightness.light);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
