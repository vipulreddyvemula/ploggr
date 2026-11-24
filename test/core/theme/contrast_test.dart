import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../widget_test.dart' as existing;

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

void main() {
  setUpAll(() async {
    final font = FontLoader('NunitoSans')
      ..addFont(rootBundle.load('assets/fonts/NunitoSans.ttf'));
    await font.load();
  });

  testWidgets('scan shortcut icon has 3:1 contrast with its card', (
    tester,
  ) async {
    await existing.openApp(tester, '/home');
    final icon = tester.widget<Icon>(find.byIcon(Icons.add_a_photo_outlined));
    final card = tester.widget<Material>(
      find
          .ancestor(
            of: find.byIcon(Icons.add_a_photo_outlined),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(contrast(icon.color!, card.color!), greaterThanOrEqualTo(3));
  });
}
