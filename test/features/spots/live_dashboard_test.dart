import 'package:ploggr/features/community/field_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/features/auth/session/session_api.dart';
import 'package:ploggr/features/auth/session/session_store.dart';
import 'package:ploggr/features/home/activity_overview.dart';
import 'package:ploggr/features/spots/spot.dart';
import 'package:ploggr/features/spots/spot_api.dart';
import 'package:ploggr/routes/app_router.dart';
import 'package:ploggr/shared/widgets/eco_art.dart';
import 'package:ploggr/shared/widgets/ploggr_ui.dart';

import '../auth/live_app_harness.dart';
import '../auth/session_fakes.dart';

void main() {
  testWidgets(
    'landscape forms keep their primary action reachable above the keyboard',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 360);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      var saved = false;
      await tester.pumpWidget(
        MaterialApp(
          home: AppPage(
            title: 'Organize a cleanup',
            bottomAction: PrimaryButton('Save', onPressed: () => saved = true),
            child: const Column(
              children: [
                TextField(),
                SizedBox(height: 48),
                ListTile(title: Text('Choose meeting point')),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Park sweep');
      tester.view.viewInsets = const FakeViewPadding(bottom: 210);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Hide keyboard').hitTestable(), findsOneWidget);
      expect(find.text('Save').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('Choose meeting point'));
      expect(find.text('Choose meeting point').hitTestable(), findsOneWidget);
      await press(tester, 'Save');
      expect(saved, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'signed-in navigation and standings remain usable at large text on a compact phone',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialLocationProvider.overrideWithValue('/community'),
            sessionStoreProvider.overrideWithValue(
              MemoryStore()..value = StoredSession(token),
            ),
            sessionApiProvider.overrideWithValue(FakeApi()),
            fieldData('community/posts?mine=false').overrideWith(
              (_) async => {
                'items': [
                  {
                    'id': 'post',
                    'plogId': 'plog',
                    'author': 'Asha',
                    'body': 'Park cleanup',
                    'createdAt': '2026-11-22T10:00:00Z',
                    'seconds': 12,
                    'meters': 0,
                    'mine': true,
                    'likes': 0,
                    'comments': 0,
                  },
                ],
                'next': null,
              },
            ),
            for (final period in ['week', 'month'])
              fieldData('leaderboard?period=$period').overrideWith(
                (_) async => {
                  'rules': null,
                  'mine': null,
                  'pending': 0,
                  'items': [],
                },
              ),
          ],
          child: const PloggrApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Shared cleanup · 12 sec'), findsOneWidget);
      await press(tester, 'Leaderboard');
      expect(find.text('Unranked'), findsOneWidget);
      await press(tester, 'How scoring works');
      await press(tester, 'Month');
      expect(find.text('Unranked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('live dashboard, profile and community present signed-in data', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 740);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final report = Spot.fromJson({
      'id': 'spot',
      'category': 'Metal',
      'notes': 'Under the bridge',
      'status': 'open',
      'mine': true,
      'photoCount': 1,
      'latitude': 10,
      'longitude': 20,
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fieldData(
            'profile',
          ).overrideWith((_) async => {'name': 'Asha', 'moderator': false}),
          fieldData(
            'community/posts?mine=false',
          ).overrideWith((_) async => {'items': [], 'next': null}),
          fieldData('leaderboard?period=week').overrideWith(
            (_) async => {
              'items': [],
              'mine': null,
              'rules': null,
              'pending': 0,
            },
          ),
          initialLocationProvider.overrideWithValue('/home'),
          sessionStoreProvider.overrideWithValue(
            MemoryStore()..value = StoredSession(token),
          ),
          sessionApiProvider.overrideWithValue(FakeApi()),
          totalsProvider.overrideWith(
            (ref) async => (
              count: 2,
              meters: 3000.0,
              reports: 1,
              tracked: 2,
              verifiedCleanups: 0,
            ),
          ),
          mySpotsProvider(
            null,
          ).overrideWith((ref) async => (items: [report], next: null)),
          exploreProvider(
            world,
          ).overrideWith((ref) async => (items: <Spot>[], truncated: false)),
        ],
        child: const PloggrApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hi, Asha'), findsOneWidget);
    expect(find.text('Start Plog Session').hitTestable(), findsOneWidget);
    expect(find.text('Report litter').hitTestable(), findsOneWidget);
    expect(find.text('Explore').hitTestable(), findsOneWidget);
    expect(find.byType(LeafSprig), findsOneWidget);
    expect(find.byType(StatTile), findsNWidgets(3));
    expect(find.text('3.00 km'), findsOneWidget);
    expect(find.text('1.50 km'), findsOneWidget);
    expect(find.text('Campus Clean-up'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Metal litter'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Needs cleanup'), findsOneWidget);
    await press(tester, 'Community');
    expect(find.text('Community posts'), findsOneWidget);
    expect(
      find.text('No posts yet. Share a cleanup with the community.'),
      findsOneWidget,
    );
    await press(tester, 'Leaderboard');
    expect(find.text('Unranked'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await press(tester, 'Profile');
    expect(find.text('a@example.test'), findsOneWidget);
    expect(find.byType(StatTile), findsNWidgets(3));
    expect(find.text('3.00 km'), findsOneWidget);
    expect(find.byType(PreviewNote), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
