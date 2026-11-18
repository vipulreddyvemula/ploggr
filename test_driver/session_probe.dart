// Debug-only target for tool/test_android_session.sh on a disposable emulator.
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:ploggr/app.dart';
import 'package:ploggr/core/config/app_config.dart';
import 'package:ploggr/core/config/app_config_provider.dart';
import 'package:ploggr/core/network/api_client_provider.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/auth/session/session_store.dart';
import 'package:ploggr/features/auth/session/session_api.dart';
import 'package:ploggr/core/network/protected_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(
    overrides: [
      appConfigProvider.overrideWithValue(AppConfig.fromEnvironment()),
    ],
  );
  runApp(
    UncontrolledProviderScope(container: container, child: const PloggrApp()),
  );
  final result = File(
    '${Directory.systemTemp.parent.path}/cache/session-probe-result',
  );
  try {
    final input = File(
      '${Directory.systemTemp.parent.path}/cache/session-probe-command',
    );
    final command = await input.exists()
        ? (await input.readAsString()).trim()
        : 'inspect';
    final sessions = container.read(sessionControllerProvider.notifier);
    await sessions.accessToken();
    if (command == 'create') {
      await sessions.signup(
        '${const Uuid().v4()}@example.test',
        const Uuid().v4(),
      );
    } else if (command == 'logout') {
      await sessions.logout();
    } else if (command == 'offline-logout') {
      try {
        await sessions.logout();
      } on AuthRequestFailure catch (failure) {
        if (failure.status != null) rethrow;
      }
    } else if (command == 'revoke') {
      final record = await container.read(sessionStoreProvider)!.read();
      await container.read(sessionApiProvider)!.logout(record!.refreshToken);
      try {
        await container.read(protectedApiProvider).request('GET', 'auth/me');
        throw StateError('A revoked session was accepted');
      } on ProtectedApiFailure catch (failure) {
        if (failure.status != 401) rethrow;
      }
    } else if (command == 'renew') {
      final old = await sessions.accessToken();
      final identity = container.read(sessionControllerProvider).user!;
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      String? current;
      do {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        current = await sessions.accessToken();
      } while ((current == null || current == old) &&
          DateTime.now().isBefore(deadline));
      final client = container.read(apiClientProvider)!;
      Future<Response<Object?>> me(String? token) => client.get<Object?>(
        'auth/me',
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          validateStatus: (_) => true,
        ),
      );
      if ((await me(old)).statusCode != 401 ||
          (await me(current)).statusCode != 200 ||
          container.read(sessionControllerProvider).user != identity) {
        throw StateError('Expiration and renewal check failed');
      }
    }
    final state = container.read(sessionControllerProvider);
    await result.writeAsString(state.user?.id ?? state.phase.name, flush: true);
  } catch (error) {
    await result.writeAsString('failed-${error.runtimeType}', flush: true);
  }
}
