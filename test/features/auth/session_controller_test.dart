import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ploggr/features/auth/session/session_api.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/auth/session/session_store.dart';

import 'session_fakes.dart';

void main() {
  late MemoryStore store;
  late FakeApi api;
  late ProviderContainer container;
  ProviderContainer start() {
    final c = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(store),
        sessionApiProvider.overrideWithValue(api),
      ],
    );
    c.read(sessionControllerProvider);
    return c;
  }

  setUp(() {
    store = MemoryStore();
    api = FakeApi();
  });
  tearDown(() => container.dispose());

  test(
    'a fresh install signs in, persists only the refresh credential, and clears on logout',
    () async {
      container = start();
      final sessions = container.read(sessionControllerProvider.notifier);
      await sessions.accessToken();
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedOut,
      );
      await sessions.signup('a@example.test', 'test-password');
      expect(
        store.value!.encode(),
        '{"refreshToken":"$successor","requestId":null}',
      );
      expect(await sessions.accessToken(), 'access');
      await sessions.logout();
      expect(api.revoked, [successor]);
      expect(store.value, isNull);
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedOut,
      );
    },
  );

  test(
    'offline restart retries the persisted ID and concurrent callers share renewal',
    () async {
      store.value = StoredSession(token);
      api.onRefresh = () async => throw const AuthRequestFailure(null);
      container = start();
      await container.read(sessionControllerProvider.notifier).accessToken();
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.unavailable,
      );
      final pending = store.value!.requestId;
      expect(pending, isNotNull);
      container.dispose();
      container = start();
      api.onRefresh = null;
      final sessions = container.read(sessionControllerProvider.notifier);
      expect(
        await Future.wait([sessions.accessToken(), sessions.accessToken()]),
        ['access', 'access'],
      );
      expect(api.requests, [pending, pending]);
      expect(store.value!.requestId, isNull);
    },
  );

  test('logout wins against a late refresh response', () async {
    store.value = StoredSession(token);
    final response = Completer<SessionBundle>();
    final started = Completer<void>();
    api.onRefresh = () {
      started.complete();
      return response.future;
    };
    container = start();
    final sessions = container.read(sessionControllerProvider.notifier);
    final refresh = sessions.accessToken();
    await started.future;
    await sessions.logout();
    response.complete(bundle());
    expect(await refresh, isNull);
    expect(store.value, isNull);
    expect(
      container.read(sessionControllerProvider).phase,
      SessionPhase.signedOut,
    );
  });

  test('a temporary secure storage failure can be retried', () async {
    store.value = StoredSession(token);
    store.locked = true;
    container = start();
    final sessions = container.read(sessionControllerProvider.notifier);
    expect(await sessions.accessToken(), isNull);
    expect(
      container.read(sessionControllerProvider).phase,
      SessionPhase.unavailable,
    );
    expect(store.value!.refreshToken, token);
    expect(api.requests, isEmpty);

    store.locked = false;
    expect(await sessions.accessToken(), 'access');
    expect(
      container.read(sessionControllerProvider).phase,
      SessionPhase.signedIn,
    );
  });

  test(
    'offline logout clears the record and stays signed out after restart',
    () async {
      container = start();
      final sessions = container.read(sessionControllerProvider.notifier);
      await sessions.accessToken();
      await sessions.login('a@example.test', 'test-password');
      api.offline = true;
      await expectLater(sessions.logout(), throwsA(isA<AuthRequestFailure>()));
      expect(store.value, isNull);
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedOut,
      );
      container.dispose();
      container = start();
      expect(
        await container.read(sessionControllerProvider.notifier).accessToken(),
        isNull,
      );
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedOut,
      );
    },
  );

  test(
    'failed secure write prevents authenticated state and preserves the pending rotation',
    () async {
      store.value = StoredSession(
        token,
        'dc8fd4d5-8d64-4616-af1a-bd461af18abe',
      );
      store.failSave = true;
      container = start();
      expect(
        await container.read(sessionControllerProvider.notifier).accessToken(),
        isNull,
      );
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.unavailable,
      );
      expect(store.value!.refreshToken, token);
    },
  );

  for (final corrupt in [false, true]) {
    test('clears an unusable stored credential (corrupt=$corrupt)', () async {
      store.value = StoredSession(token);
      store.corrupt = corrupt;
      api.onRefresh = () async => throw const AuthRequestFailure(401);
      container = start();
      expect(
        await container.read(sessionControllerProvider.notifier).accessToken(),
        isNull,
      );
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.expired,
      );
      expect(store.value, isNull);
    });
  }
}
