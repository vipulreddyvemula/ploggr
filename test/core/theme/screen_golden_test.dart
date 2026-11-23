import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../widget_test.dart' as existing;

void main() {
  setUpAll(() async {
    final font = FontLoader('NunitoSans')
      ..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'));
    await font.load();
    final fallback = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'));
    await fallback.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('preview home in ${brightness.name} theme', (tester) async {
      await existing.openApp(tester, '/home', brightness: brightness);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile('goldens/home_${brightness.name}.png'),
      );
    });
  }
}
