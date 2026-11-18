import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ploggr/core/network/protected_api.dart';
import 'package:ploggr/features/auth/session/session_api.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/features/auth/session/session_store.dart';

import 'session_fakes.dart';

void main() {
  late HttpServer server;
  late Dio dio;
  late ProviderContainer container;
  late FakeApi api;
  late SessionController sessions;
  late ProtectedApi client;
  late FutureOr<int> Function(HttpRequest) status;
  late List<String?> headers;
  final unauthorized = throwsA(
    isA<ProtectedApiFailure>().having((e) => e.status, 'status', 401),
  );
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    headers = [];
    status = (_) => 200;
    server.listen((request) async {
      headers.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response.statusCode = await status(request);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'id': 'id', 'email': 'a@example.test'}),
      );
      await request.response.close();
    });
    final base = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/api/',
    );
    dio = Dio(BaseOptions(baseUrl: base.toString(), followRedirects: false));
    api = FakeApi();
    container = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(MemoryStore()),
        sessionApiProvider.overrideWithValue(api),
      ],
    );
    sessions = container.read(sessionControllerProvider.notifier);
    await sessions.accessToken();
    client = ProtectedApi(dio, sessions);
  });
  tearDown(() async {
    container.dispose();
    dio.close(force: true);
    await server.close(force: true);
  });

  test(
    'only signed-in API requests send the bearer header to relative API paths',
    () async {
      await expectLater(client.request('GET', 'auth/me'), unauthorized);
      expect(headers, isEmpty);
      await sessions.login('a@example.test', 'password');
      for (final path in [
        'https://example.test/api/me',
        '//example.test/me',
        '/me',
        '../me',
        '%2e%2e/me',
        'foo%2fbar',
      ]) {
        await expectLater(client.request('GET', path), throwsArgumentError);
      }
      expect(headers, isEmpty);
      await dio.get<Object?>('health');
      final body = await client.request<Map<String, dynamic>>('GET', 'auth/me');
      expect(body?['id'], 'id');
      expect(headers, [null, 'Bearer access']);
    },
  );

  test('two rejected reads share one rotation and retry once each', () async {
    await sessions.login('a@example.test', 'password');
    final both = Completer<void>();
    var rejected = 0;
    status = (request) async {
      if (request.headers.value(HttpHeaders.authorizationHeader) ==
          'Bearer renewed') {
        return 200;
      }
      if (++rejected == 2) both.complete();
      await both.future;
      return 401;
    };
    api.onRefresh = () async =>
        SessionBundle(bundle().user, 'renewed', successor, bundle().expiresAt);
    await Future.wait([
      client.request('GET', 'auth/me'),
      client.request('GET', 'auth/me'),
    ]);
    expect(api.requests, hasLength(1));
    expect(headers, hasLength(4));
  });

  test(
    'a second 401 ends the session, writes never replay, and 403 preserves the session',
    () async {
      await sessions.login('a@example.test', 'password');
      status = (_) => 403;
      await expectLater(
        client.request('GET', 'auth/me'),
        throwsA(
          isA<ProtectedApiFailure>().having((e) => e.status, 'status', 403),
        ),
      );
      expect(api.requests, isEmpty);
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedIn,
      );
      status = (_) => 401;
      await expectLater(
        client.request('POST', 'example', data: {'value': 1}),
        unauthorized,
      );
      expect(headers, hasLength(2));
      expect(api.requests, hasLength(1));
      await expectLater(client.request('GET', 'auth/me'), unauthorized);
      expect(headers, hasLength(4));
      expect(
        container.read(sessionControllerProvider).phase,
        SessionPhase.signedOut,
      );
    },
  );

  test('late responses from a previous login are discarded', () async {
    await sessions.login('a@example.test', 'password');
    final started = Completer<void>();
    final response = Completer<int>();
    status = (_) {
      started.complete();
      return response.future;
    };
    final pending = expectLater(client.request('GET', 'auth/me'), unauthorized);
    await started.future;
    await sessions.logout();
    await sessions.login('another@example.test', 'password');
    response.complete(200);
    await pending;
    expect(
      container.read(sessionControllerProvider).phase,
      SessionPhase.signedIn,
    );
  });

  test('a transport failure has no credentials and does not log out', () async {
    await sessions.login('a@example.test', 'password');
    await server.close(force: true);
    await expectLater(
      client.request('GET', 'auth/me'),
      throwsA(
        isA<ProtectedApiFailure>().having((e) => e.status, 'status', isNull),
      ),
    );
    expect(api.requests, isEmpty);
    expect(
      container.read(sessionControllerProvider).phase,
      SessionPhase.signedIn,
    );
  });
}
