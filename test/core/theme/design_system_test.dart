import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/core/theme/app_theme.dart';
import 'package:ploggr/shared/widgets/ploggr_ui.dart';

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

  for (final (name, theme) in [
    ('light', AppTheme.light),
    ('dark', AppTheme.dark),
  ]) {
    testWidgets('shared controls and statuses in $name theme', (tester) async {
      tester.view.physicalSize = const Size(400, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Report litter'),
                  const SizedBox(height: 8),
                  const AppField(label: 'Description', icon: Icons.edit),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () {},
                    child: const Text(
                      'Continue',
                      style: TextStyle(fontFamily: 'NunitoSans'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const EcoCard(child: Text('A report near you')),
                  const SizedBox(height: 8),
                  for (final (label, status) in [
                    ('Saved', AppStatus.success),
                    ('Check location', AppStatus.warning),
                    ('Waiting to sync', AppStatus.pending),
                    ('Could not upload', AppStatus.failure),
                  ]) ...[
                    AppNotice(label, status: status),
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/controls_$name.png'),
      );
    });
  }
}
