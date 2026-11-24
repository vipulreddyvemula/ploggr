import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/core/network/protected_api.dart';
import 'package:ploggr/features/community/field_data.dart';
import 'package:ploggr/features/plogging/analysis_panel.dart';
import 'package:ploggr/shared/widgets/ploggr_ui.dart';

class _DisposalApi extends Fake implements ProtectedApi {
  Object? saved;

  @override
  Future<T?> request<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    ResponseType? responseType,
    ProgressCallback? onSendProgress,
    bool idempotent = false,
    String? recordingDevice,
  }) async {
    expect(method, 'PUT');
    expect(path, 'plogs/pickup/disposal');
    saved = data;
    return null;
  }
}

void main() {
  testWidgets('saving weighed disposal refreshes CO₂e views immediately', (
    tester,
  ) async {
    const paths = [
      'plogs/pickup/analysis',
      'progress?period=all',
      'leaderboard?period=week',
    ];
    final reads = <String, int>{};
    final api = _DisposalApi();
    final container = ProviderContainer(
      overrides: [
        protectedApiProvider.overrideWithValue(api),
        for (final path in paths)
          fieldData(path).overrideWith((_) async {
            reads.update(path, (count) => count + 1, ifAbsent: () => 1);
            if (path != paths.first) return null;
            return {
              'state': 'ready',
              'result': {
                'items': [
                  {
                    'label': 'Glass jar',
                    'material': 'Glass',
                    'type': 'Jar',
                    'count': 1,
                    'certain': true,
                    'photoIds': [],
                  },
                ],
              },
            };
          }),
        fieldData('impact/factors').overrideWith(
          (_) async => [
            for (final pathway in ['Landfill', 'Recycling'])
              {
                'material': 'Glass',
                'region': 'Test region',
                'version': 'v1',
                'pathway': pathway,
              },
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    for (final path in paths.skip(1)) {
      container.listen(fieldData(path), (_, _) {});
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: AppPage(title: 'Plog details', child: AnalysisPanel('pickup')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> tap(String text) async {
      final target = find.text(text).last;
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    expect(
      find.textContaining('No CO₂e estimate is available'),
      findsOneWidget,
    );
    await tap('Add weighed material');
    await tap('Material and factor region');
    await tap('Glass · Test region · v1');
    await tester.enterText(find.byType(TextField), '2');
    await tap('Expected disposal without cleanup');
    await tap('Landfill');
    await tap('Actual disposal');
    await tap('Recycling');
    await tap('Save disposal');

    expect(api.saved, containsPair('massKg', 2.0));
    expect(find.text('Disposal details'), findsNothing);
    for (final path in paths) {
      expect(reads[path], 2, reason: path);
    }
  });

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
