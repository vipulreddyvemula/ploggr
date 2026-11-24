import 'package:flutter/services.dart';
import 'package:ploggr/features/community/field_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/core/theme/theme_preference.dart';
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
                  'rules': {
                    'version': 'm5-v1',
                    'carbon_points_per_kg': 2,
                    'carbonPoints': 10,
                    'movementPoints': 5,
                    'plogPoints': 100,
                  },
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
      expect(find.text('Feed'), findsOneWidget);
      expect(find.text('Map'), findsOneWidget);
      expect(find.text('Shared cleanup · 12 sec'), findsOneWidget);
      // Platform sharing receives only the text the author published.
      const share = MethodChannel('ploggr/share');
      final messenger = tester.binding.defaultBinaryMessenger;
      MethodCall? shared;
      messenger.setMockMethodCallHandler(share, (call) async {
        shared = call;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(share, null));
      await tester.ensureVisible(find.byTooltip('Share post text'));
      await tester.tap(find.byTooltip('Share post text'));
      await tester.pumpAndSettle();
      expect(shared?.method, 'text');
      expect(shared?.arguments, 'Park cleanup');

      await tester.ensureVisible(find.byTooltip('Post options'));
      await tester.tap(find.byTooltip('Post options'));
      await tester.pumpAndSettle();
      await press(tester, 'Delete');
      expect(find.text('Delete this post?'), findsOneWidget);
      await press(tester, 'Cancel');
      expect(find.text('Park cleanup'), findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.chat_bubble_outline));
      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await tester.pumpAndSettle();
      expect(find.text('Comments'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await press(tester, 'Leaderboard');
      expect(find.text('Unranked'), findsOneWidget);
      await press(tester, 'How points work');
      await press(tester, 'Month');
      expect(find.text('Unranked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'compact dark tabs handle long names, keyboard and disjoint map results',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const name = 'Alexandria Montgomery Greenfield Rivera';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialLocationProvider.overrideWithValue('/profile'),
            initialThemeModeProvider.overrideWithValue(ThemeMode.dark),
            sessionStoreProvider.overrideWithValue(
              MemoryStore()..value = StoredSession(token),
            ),
            sessionApiProvider.overrideWithValue(FakeApi()),
            fieldData('profile').overrideWith((_) async => {'name': name}),
            fieldData('badges').overrideWith((_) async => []),
            mapSpotsProvider.overrideWith((ref, query) async {
              final cleaned = query.filters.status == SpotMapStatus.collected;
              return (
                items: [
                  Spot.fromJson({
                    'id': cleaned ? 'collected' : 'open',
                    'category': cleaned ? 'Glass' : 'Plastic',
                    'status': cleaned ? 'collected' : 'open',
                    'notes': '',
                    'mine': false,
                    'photoCount': 0,
                    'latitude': 10,
                    'longitude': 20,
                  }),
                ],
                truncated: false,
              );
            }),
          ],
          child: const PloggrApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(name), findsOneWidget);
      await tester.tap(find.byTooltip('Edit profile'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'A shorter name');
      await press(tester, 'Cancel');
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await press(tester, 'Map');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Plastic litter'), findsOneWidget);
      expect(find.text('Glass litter'), findsNothing);
      await press(tester, 'Cleaned');
      expect(find.text('Glass litter'), findsOneWidget);
      expect(find.text('Plastic litter'), findsNothing);
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
          for (final period in ['week', 'all'])
            fieldData('progress?period=$period').overrideWith(
              (_) async => {
                'totals': {
                  'points': 6.6,
                  'cleanupPoints': 3.6,
                  'challengePoints': 3,
                  'completedPlogs': 2,
                  'verifiedCleanups': 1,
                  'distanceMeters': 3000.0,
                  'activeSeconds': 3600,
                  'items': 3,
                  'estimatedKg': .9,
                  'measuredKg': 1.2,
                  'potentialCo2eKg': period == 'all' ? .3 : null,
                  'weightMaterials': 2,
                  'materials': 2,
                },
                'goal': {
                  'target': 2,
                  'cadence': 'week',
                  'progress': 1,
                  'streak': 1,
                  'longestStreak': 2,
                  'endsAt': '2026-11-30T00:00:00Z',
                },
                'series': [],
                'pending': 0,
                'activeChallenges': [
                  {
                    'title': 'Daily collection',
                    'progress': 3,
                    'goal': 5,
                    'unit': 'accepted items',
                    'bonus': 2,
                  },
                ],
              },
            ),
          fieldData('badges').overrideWith(
            (_) async => [
              {'name': 'First Plog', 'earned': '2026-11-22'},
              {'name': 'Collector', 'earned': null},
            ],
          ),
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
            (ref) async => (count: 2, meters: 3000.0, reports: 1, tracked: 2),
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
    expect(find.text('Scan Litter').hitTestable(), findsOneWidget);
    expect(find.text('Explore Map').hitTestable(), findsOneWidget);
    expect(find.byType(PloggrLogo), findsOneWidget);
    expect(find.text('Potential CO₂e savings'), findsOneWidget);
    expect(find.text('0.3 kg'), findsOneWidget);
    expect(find.text('3.00 km'), findsOneWidget);
    expect(find.text('1.2 kg'), findsOneWidget);
    expect(find.text('Campus Clean-up'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Daily collection'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Weekly cleanup goal'), findsNothing);
    expect(find.text('Daily cleanup goal'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Metal litter'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Needs cleanup'), findsOneWidget);
    await press(tester, 'Community');
    expect(find.text('Feed'), findsOneWidget);
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
    expect(find.text('First Plog'), findsOneWidget);
    expect(find.text('Daily cleanup goal'), findsNothing);
    expect(find.text('Weekly cleanup goal'), findsNothing);
    expect(find.text('Set a goal'), findsNothing);
    await tester.ensureVisible(find.text('Impact details'));
    await press(tester, 'Impact details');
    expect(find.text('6.6 points'), findsOneWidget);
    expect(find.text('0.9 kg AI-estimated weight'), findsOneWidget);
    expect(find.text('1.2 kg self-reported measured weight'), findsOneWidget);
    expect(find.text('Potential CO₂e savings unavailable'), findsOneWidget);
    expect(
      find.textContaining('a supported disposal scenario'),
      findsOneWidget,
    );
    expect(find.byType(PreviewNote), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
