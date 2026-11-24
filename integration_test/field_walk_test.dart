import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/core/config/app_config.dart';
import 'package:ploggr/core/config/app_config_provider.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/home/activity_overview.dart';
import 'package:ploggr/features/plogging/data/location_source.dart';
import 'package:ploggr/features/plogging/data/plog_api.dart';
import 'package:ploggr/features/plogging/activity_page.dart';
import 'package:ploggr/features/spots/photo_picker.dart';
import 'package:ploggr/features/spots/spot.dart';
import 'package:ploggr/features/spots/spot_api.dart';
import 'package:ploggr/features/spots/spot_map.dart';
import 'package:ploggr/routes/app_router.dart';
import 'package:uuid/uuid.dart';

class _DeniedGps extends Fake implements LocationSource {
  int locationRequests = 0;

  @override
  Future<RouteFix?> cachedPoint() async => null;

  @override
  Future<Never> current() async {
    locationRequests++;
    throw LocationFailure.denied;
  }

  @override
  Future<void> requestAccess() async {
    throw LocationFailure.denied;
  }

  @override
  RouteFix? get recentFix => null;
}

class _Gallery extends ImagePicker {
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    final file = await rootBundle.load('assets/images/demo/litter.png');
    return XFile.fromData(
      file.buffer.asUint8List(file.offsetInBytes, file.lengthInBytes),
      name: 'pickup.png',
      mimeType: 'image/png',
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'publish a pin, confirm a pickup without GPS, inspect analysis and share the cleanup',
    (tester) async {
      final marker = File('${Directory.systemTemp.path}/ploggr-field-result');
      Future<void> progress(String step) async {
        if (const bool.fromEnvironment('FIELD_QA_MARKER')) {
          await marker.writeAsString(step, flush: true);
        }
      }

      bool screenshotSurface = false;
      Future<void> capture(String name) async {
        if (!const bool.fromEnvironment('FIELD_QA_CAPTURES')) return;
        if (!screenshotSurface) {
          await binding.convertFlutterSurfaceToImage();
          screenshotSurface = true;
        }
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        final bytes = await binding.takeScreenshot(name);
        await File(
          '${Directory.systemTemp.path}/ploggr-qa-$name.png',
        ).writeAsBytes(bytes);
      }

      final gps = _DeniedGps();
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.fromEnvironment()),
          locationSourceProvider.overrideWithValue(gps),
          photoPickerProvider.overrideWithValue(_Gallery()),
        ],
      );
      Future<void> wait(
        bool Function() condition,
        String description, {
        Duration timeout = const Duration(seconds: 35),
      }) async {
        final deadline = DateTime.now().add(timeout);
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            final path = container
                .read(appRouterProvider)
                .routerDelegate
                .currentConfiguration
                .uri
                .path;
            throw StateError('Timed out waiting for $description on $path');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Finder label(String s) => find.text(s);
      Future<void> tap(String s) async {
        await tester.pump(const Duration(milliseconds: 200));
        await wait(() => label(s).evaluate().isNotEmpty, s);
        // As dashboard data arrives, cards above the target can change height.
        for (var attempt = 0; attempt < 8; attempt++) {
          await tester.ensureVisible(label(s).last);
          await tester.pump(const Duration(milliseconds: 250));
          if (label(s).hitTestable().evaluate().isNotEmpty) break;
        }
        await wait(() => label(s).hitTestable().evaluate().isNotEmpty, s);
        await tester.tap(label(s).hitTestable().last);
        await tester.pump(const Duration(milliseconds: 350));
      }

      final router = container.read(appRouterProvider),
          session = container.read(sessionControllerProvider.notifier);
      try {
        await progress('Starting isolated field test');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const PloggrApp(),
          ),
        );
        await session.accessToken();
        await wait(
          () =>
              container.read(sessionControllerProvider).phase.canSignIn ||
              container.read(sessionControllerProvider).user != null,
          'account gate',
        );
        if (container.read(sessionControllerProvider).user != null) {
          throw StateError('Use a fresh, isolated API URL for this test');
        }
        await session.signup(
          '${const Uuid().v4()}@example.test',
          const Uuid().v4(),
        );
        await wait(
          () => label('No reports yet').evaluate().isNotEmpty,
          'signed-in dashboard data',
        );
        await tap('Report litter');
        await tap('Choose photo');
        await tap('Continue to details');
        await tap('Continue to location');
        await tap('Choose spot');
        await progress('Map picker');
        expect(gps.locationRequests, 0);
        await tap('Use my location');
        await wait(
          () => find
              .textContaining('Location unavailable.')
              .evaluate()
              .isNotEmpty,
          'denied map location',
        );
        expect(gps.locationRequests, 1);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Use this spot'),
              )
              .onPressed,
          isNull,
        );
        final search = find.byType(TextField).last;
        await tester.enterText(search, 'Riverside Park');
        await wait(
          () => find.textContaining('Riverside Park,').evaluate().isNotEmpty,
          'place search',
        );
        await tester.tap(find.textContaining('Riverside Park,').first);
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          tester.getSize(find.byType(SpotMap).last).width,
          greaterThan(
            tester.view.physicalSize.width / tester.view.devicePixelRatio * .85,
          ),
        );
        final selectedPlace = (await container.read(spotApiProvider).places({
          'q': 'Riverside Park',
        })).first;
        await capture('choose-spot');
        await tap('Use this spot');
        await tap('Review report');
        await tap('Post report');
        await tap('Show on map');
        await wait(
          () => router.routerDelegate.currentConfiguration.uri.path == '/map',
          'published map',
        );
        final reports = container.read(spotApiProvider);
        final spot = (await reports.mine(null)).items.single;
        expect(spot.status, 'open');
        expect(
          router
              .routerDelegate
              .currentConfiguration
              .uri
              .queryParameters['spot'],
          spot.id,
        );
        expect(spot.place, contains('Riverside Park'));
        expect(
          spot.point.latitude,
          closeTo(selectedPlace['latitude'], 0.00001),
        );
        expect(
          spot.point.longitude,
          closeTo(selectedPlace['longitude'], 0.00001),
        );
        expect(
          (await reports.explore(world)).items.any((s) => s.id == spot.id),
          isTrue,
        );
        await wait(
          () => label('Other litter').evaluate().isNotEmpty,
          'visible spot details',
        );
        await tap('Heatmap');
        await wait(
          () => label(
            'Blue to red · lower to higher litter density',
          ).evaluate().isNotEmpty,
          'heatmap legend',
        );
        await tap('Heatmap');
        await tap('List');
        await tap('Cleaned');
        await wait(
          () => label(
            'No collected spots match this area and filters.',
          ).evaluate().isNotEmpty,
          'cleaned-only results',
        );
        expect(label('Other litter'), findsNothing);
        await tap('Active Litter');
        await wait(
          () => label('Other litter').evaluate().isNotEmpty,
          'active report in list',
        );
        await tap('Map view');
        await capture('reported-map');
        await progress('Published report appears on map');
        await session.logout();
        await wait(
          () => router.routerDelegate.currentConfiguration.uri.path == '/login',
          'sign-out navigation',
        );
        await session.signup(
          '${const Uuid().v4()}@example.test',
          const Uuid().v4(),
        );
        await wait(
          () => router.routerDelegate.currentConfiguration.uri.path == '/home',
          'second account home',
        );
        router.push('/spots/${spot.id}');
        await wait(
          () => label('Litter spot').hitTestable().evaluate().isNotEmpty,
          'opened spot details',
        );
        await tap('Plog this spot');
        await tap('Continue without a route');
        await wait(
          () => label('Recenter').evaluate().isNotEmpty,
          'in-map recenter control',
        );
        final map = find.byType(SpotMap).last;
        await tester.ensureVisible(map);
        await tester.pump(const Duration(milliseconds: 300));
        final recenter = find.descendant(of: map, matching: label('Recenter'));
        expect(recenter.hitTestable(), findsOneWidget);
        final start = tester.widget<SpotMap>(map);
        expect(start.focus, spot.point);
        await tester.dragFrom(tester.getCenter(map), const Offset(-80, 0));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.widget<SpotMap>(map).focus, isNull);
        await tap('Recenter');
        final centered = tester.widget<SpotMap>(map);
        expect(centered.focus, spot.point);
        expect(centered.cameraKey, start.cameraKey + 1);
        await capture('live-plog');
        await tap('Pause');
        await tap('Resume');
        await tap('Choose from gallery');
        await tap('Yes, it’s clean');
        await progress('Saved location-free pickup');
        await tap('Finish Plog');
        await tap('Keep plogging');
        await tap('Finish Plog');
        await tap('Finish Plog');
        await tap('Save Plog');
        await tap('View activity');
        // Activity is pushed above the tab. Inspect the displayed detail page.
        await wait(
          () => label('Plog details').evaluate().isNotEmpty,
          'saved activity',
        );
        final api = container.read(plogApiProvider);
        final id = tester
            .widget<PlogActivityPage>(find.byType(PlogActivityPage))
            .id!;
        final saved = await api.detail(id);
        expect(saved.route, isEmpty);
        expect(await api.evidence(id), hasLength(1));
        expect(
          (await container.read(spotApiProvider).detail(spot.id)).status,
          'open',
        );
        expect(saved.unverifiedCleanups, 1);
        if (const bool.fromEnvironment('FIELD_QA_LIVE_ANALYSIS')) {
          await wait(
            () =>
                label('Analysis ready').evaluate().isNotEmpty ||
                label('Analysis reviewed').evaluate().isNotEmpty ||
                label('Awaiting photo review').evaluate().isNotEmpty,
            'live vision result',
            timeout: const Duration(minutes: 6),
          );
        } else {
          await wait(
            () =>
                label(
                  'Waiting for photo analysis to be enabled',
                ).evaluate().isNotEmpty ||
                label('Waiting for analysis').evaluate().isNotEmpty,
            'queued analysis',
          );
        }
        await capture('activity');
        await tap('Share cleanup');
        await tester.enterText(
          find.byType(TextField).first,
          'Riverside cleanup complete',
        );
        await tap('Publish');
        await wait(
          () =>
              router.routerDelegate.currentConfiguration.uri.path ==
                  '/community' &&
              label('Feed').evaluate().isNotEmpty,
          'community feed',
        );
        await tap('My Posts');
        final sharedSummary = label(
          'Shared cleanup · ${formatWalkSummary(saved.seconds)}',
        );
        await wait(
          () =>
              sharedSummary.evaluate().isNotEmpty &&
              label('Riverside cleanup complete').evaluate().isNotEmpty,
          'published cleanup and its active time',
        );
        await capture('community');
        await tap('Leaderboard');
        await tap('Month');
        await tap('All time');
        await wait(
          () => label('Unranked').evaluate().isNotEmpty,
          'leaderboard',
        );
        await capture('leaderboard');
        router.go('/cleanups');
        await tap('Organize a cleanup');
        await tester.enterText(find.byType(TextField).first, 'Park sweep');
        await tester.pump(const Duration(milliseconds: 350));
        final hideKeyboard = find.byTooltip('Hide keyboard').hitTestable();
        if (hideKeyboard.evaluate().isNotEmpty) {
          await tester.tap(hideKeyboard);
        } else {
          await tester.testTextInput.receiveAction(TextInputAction.done);
        }
        await tester.pump(const Duration(milliseconds: 350));
        await tap('Choose meeting point');
        await tester.enterText(find.byType(TextField).last, 'Riverside Park');
        await wait(
          () => find.textContaining('Riverside Park,').evaluate().isNotEmpty,
          'meeting place',
        );
        await tester.tap(find.textContaining('Riverside Park,').first);
        await tester.pump(const Duration(milliseconds: 300));
        await tap('Use this spot');
        await tap('Save');
        await tap('Join cleanup');
        await tap('Joined');
        await wait(
          () => label('Park sweep').evaluate().isNotEmpty,
          'joined cleanup',
        );
        router.go('/challenges');
        await tap('Create a challenge');
        await tester.enterText(find.byType(TextField).first, 'Park walks');
        await tap('Save');
        await tap('Upcoming');
        await wait(
          () => label('Park walks').evaluate().isNotEmpty,
          'created challenge',
        );
        router.go('/badges');
        await wait(
          () => label('First Plog').evaluate().isNotEmpty,
          'earned badges',
        );
        expect(tester.takeException(), isNull);
        await session.logout();
        await progress('PASS');
      } catch (e) {
        await progress(
          'FAIL ${e.runtimeType} ${e is StateError
              ? e.message
              : e is TestFailure
              ? e.message
              : ""}',
        );
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      }
    },
  );
}
