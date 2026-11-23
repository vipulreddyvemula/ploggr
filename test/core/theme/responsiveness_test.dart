import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../widget_test.dart' as existing;

void main() {
  setUpAll(() async {
    final font = FontLoader('NunitoSans')
      ..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'));
    await font.load();
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final route in existing.screenRoutes.where((route) => route != '/')) {
      testWidgets('preview $route at 320dp, 200% text and $brightness', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await existing.openApp(
          tester,
          route,
          size: const Size(320, 640),
          textScale: 2,
          brightness: brightness,
        );
        final context = tester.element(find.byType(Scaffold).first);
        expect(MediaQuery.textScalerOf(context).scale(16), 32);
        expect(Theme.of(context).brightness, brightness);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
