import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/core/config/app_config.dart';
import 'package:ploggr/core/config/app_config_provider.dart';
import 'package:ploggr/core/network/protected_api.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/auth/session/session_store.dart';
import 'package:ploggr/features/community/field_data.dart';
import 'package:ploggr/routes/app_router.dart';

import '../test/features/auth/session_fakes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixturePath = String.fromEnvironment('M5_FIXTURE_PATH');
  testWidgets(
    'refreshes the real app after approval and revocation',
    skip: fixturePath.isEmpty,
    (tester) async {
      final fixture = jsonDecode(await File(fixturePath).readAsString()) as Map;
      final config = AppConfig.fromEnvironment();
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          sessionStoreProvider.overrideWithValue(
            MemoryStore()..onboarded = true,
          ),
        ],
      );
      final mod = Dio(
        BaseOptions(
          baseUrl: config.apiBaseUrl.toString(),
          headers: {'Authorization': 'Bearer ${fixture['moderatorToken']}'},
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        mod.close();
      });

      Future<void> waitText(String value) async {
        final target = find.text(value);
        final expires = DateTime.now().add(const Duration(seconds: 20));
        while (target.evaluate().isEmpty && DateTime.now().isBefore(expires)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(target, findsWidgets);
      }

      Future<void> tap(String value) async {
        await waitText(value);
        final target = find.text(value).last;
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      final session = container.read(sessionControllerProvider.notifier);
      final router = container.read(appRouterProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PloggrApp(),
        ),
      );
      await session.accessToken();
      await session.login(
        fixture['email'] as String,
        fixture['password'] as String,
      );
      final id = fixture['plogId'];
      final path = '/profile/activity/$id';
      router.go(path);
      await waitText('Points pending analysis or review');

      router.go('/profile');
      await tap('Set a goal');
      await tap('Save');
      await waitText('0 of 1 verified cleanups');

      await mod.put(
        'moderation/analysis/$id',
        data: {
          'items': [
            {
              'label': 'Glass jar',
              'material': 'Glass',
              'type': 'Jar',
              'count': 5,
              'photoIds': [fixture['photoId']],
            },
          ],
        },
      );
      container.invalidate(fieldData);
      await waitText('10 points');
      await waitText('1 of 1 verified cleanups');
      await waitText('Current streak · 1 day');
      router.go('/badges');
      await waitText('Challenge starter');
      expect(find.textContaining('Earned '), findsWidgets);
      router.go('/challenges');
      await waitText('Completed · +2 points earned');
      router.go('/leaderboard');
      await waitText('#1 · 10 points');
      router.go(path);
      await waitText('5 points earned');

      await container
          .read(protectedApiProvider)
          .request<Object>(
            'POST',
            'plogs/$id/analysis/review',
            data: {'note': 'Fixture review'},
          );
      await mod.put('moderation/analysis/$id', data: {'items': []});
      container.invalidate(fieldData);
      await waitText('Cleanup credit revoked');
      router.go('/leaderboard');
      await waitText('Unranked');
      router.go('/profile');
      await waitText('0 of 1 verified cleanups');
      await waitText('0 points');
    },
  );
}
