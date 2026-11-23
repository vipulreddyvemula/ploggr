import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/features/community/field_data.dart';
import 'package:ploggr/features/plogging/analysis_panel.dart';
import 'package:ploggr/shared/widgets/ploggr_ui.dart';

void main() {
  testWidgets(
    'shows potential ranges, pending points and prediction reporting',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 680);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            fieldData('plogs/pickup/analysis').overrideWith(
              (_) async => {
                'state': 'review',
                'reward': {'status': 'pending', 'pendingPoints': 2.1},
                'result': {
                  'quality': 'unclear',
                  'items': [
                    {
                      'label': 'Bottle',
                      'count': 2,
                      'material': 'PET plastic',
                      'type': 'Bottle',
                      'certain': true,
                      'photoIds': ['first', 'second'],
                      'weight': {
                        'estimateKg': 0.04,
                        'minKg': 0.03,
                        'maxKg': 0.06,
                      },
                      'potentialImpact': {
                        'avoidedKg': 0.047,
                        'minKg': 0.035,
                        'maxKg': 0.07,
                        'baseline': 'Landfill',
                        'alternative': 'Recycling',
                        'region': 'US national average',
                        'version': 'EPA WARM v16',
                        'source': 'https://www.epa.gov/warm',
                        'verification': 'unverified',
                      },
                    },
                    {
                      'label': 'Sealed bag',
                      'count': null,
                      'material': 'Unknown',
                      'type': 'Unsorted waste',
                      'certain': false,
                      'photoIds': ['second'],
                    },
                  ],
                },
              },
            ),
          ],
          child: const MaterialApp(
            home: AppPage(
              title: 'Plog details',
              child: AnalysisPanel('pickup'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2.1 points pending'), findsOneWidget);
      expect(find.textContaining('0.040 kg (0.030–0.060 kg)'), findsOneWidget);
      expect(find.textContaining('0.047 kg CO₂e'), findsOneWidget);
      expect(
        find.text('Unverified scenario estimate · 1 of 2 groups'),
        findsOneWidget,
      );
      expect(find.text('2 × Bottle'), findsOneWidget);
      expect(find.textContaining('Count unavailable'), findsOneWidget);

      final report = find.text('Report incorrect results');
      await tester.ensureVisible(report);
      await tester.tap(report);
      await tester.pumpAndSettle();
      expect(find.text('Send report'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
