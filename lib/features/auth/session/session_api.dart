import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client_provider.dart';

typedef SessionUser = ({String id, String email});

class SessionBundle {
  const SessionBundle(
    this.user,
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
  );
  final SessionUser user;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  factory SessionBundle.fromJson(Object? body) {
    if (body case {
      'user': {'id': String id, 'email': String email},
      'accessToken': String access,
      'refreshToken': String refresh,
    }) {
      final parts = access.split('.');
      if (parts.length == 3 && validRefreshToken(refresh)) {
        // The API authenticates the session. This timestamp only schedules renewal.
        final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        if (claims case {
          'sub': String subject,
          'exp': int seconds,
        } when subject == id) {
          return SessionBundle(
            (id: id, email: email),
            access,
            refresh,
            DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
          );
        }
      }
    }
    throw const FormatException('Unexpected session response');
  }
}

bool validRefreshToken(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

class AuthRequestFailure implements Exception {
  const AuthRequestFailure(this.status);
  final int? status;
}

class SessionApi {
  const SessionApi(this._client);
  final Dio _client;

  Future<Object?> _post(String route, Map<String, String> body) async {
    try {
      return (await _client.post<Object?>('auth/$route', data: body)).data;
    } on DioException catch (error) {
      // DioException contains the original credential-bearing request.
      throw AuthRequestFailure(error.response?.statusCode);
    }
  }

  Future<Map> options() async => (await _client.get<Map>('auth/options')).data!;
  Future<void> requestReset(String email) async {
    await _post('password/request', {'email': email});
  }

  Future<void> reset(String email, String code, String password) async {
    await _post('password/reset', {
      'email': email,
      'code': code,
      'password': password,
    });
  }

  Future<SessionBundle> external(String code, String verifier) async =>
      SessionBundle.fromJson(
        await _post('external', {'code': code, 'verifier': verifier}),
      );

  Future<SessionBundle> signup(String email, String password) async =>
      SessionBundle.fromJson(
        await _post('signup', {'email': email, 'password': password}),
      );

  Future<SessionBundle> login(String email, String password) async =>
      SessionBundle.fromJson(
        await _post('login', {'email': email, 'password': password}),
      );

  Future<SessionBundle> refresh(String token, String requestId) async =>
      SessionBundle.fromJson(
        await _post('refresh', {'refreshToken': token, 'requestId': requestId}),
      );

  Future<void> logout(String token) async {
    await _post('logout', {'refreshToken': token});
  }
}

final sessionApiProvider = Provider<SessionApi?>((ref) {
  final client = ref.watch(apiClientProvider);
  return client == null ? null : SessionApi(client);
});
