import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/session/session_api.dart';
import '../../features/auth/session/session_controller.dart';
import 'api_client_provider.dart';

/// Contains no credential-bearing Dio request or response.
class ProtectedApiFailure implements Exception {
  const ProtectedApiFailure(this.status);
  final int? status;
}

class ProtectedApi {
  const ProtectedApi(this._client, this._sessions);
  final Dio _client;
  final SessionController _sessions;

  Future<T?> request<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    final relative = Uri.parse(path);
    final base = Uri.parse(_client.options.baseUrl);
    final target = base.resolveUri(relative);
    if (path.isEmpty ||
        path.startsWith('/') ||
        relative.hasScheme ||
        relative.hasAuthority ||
        relative.hasFragment ||
        relative.hasQuery ||
        relative.pathSegments.any(
          (s) => s == '..' || s.contains('/') || s.contains('\\'),
        ) ||
        target.origin != base.origin ||
        !target.path.startsWith(base.path)) {
      throw ArgumentError('Expected a relative path within the configured API');
    }
    final verb = method.toUpperCase();
    final initial = await _sessions.credential();
    if (initial == null) throw const ProtectedApiFailure(401);
    var credential = initial;
    for (var attempt = 0; ; attempt++) {
      if (!_sessions.owns(credential)) throw const ProtectedApiFailure(401);
      try {
        final response = await _client.request<T>(
          target.toString(),
          data: data,
          queryParameters: queryParameters,
          cancelToken: cancelToken,
          options: Options(
            method: verb,
            followRedirects: false,
            headers: {'Authorization': 'Bearer ${credential.token}'},
          ),
        );
        if (!_sessions.owns(credential)) throw const ProtectedApiFailure(401);
        return response.data;
      } on DioException catch (failure) {
        final status = failure.response?.statusCode;
        if (!_sessions.owns(credential)) throw const ProtectedApiFailure(401);
        if (status != 401) throw ProtectedApiFailure(status);
        if (attempt == 1) {
          // Local access stops immediately, even if remote logout later fails.
          try {
            await _sessions.rejectCredential(credential);
          } catch (_) {
            // Secure deletion failures remain visible in the session state.
          }
          throw const ProtectedApiFailure(401);
        }
        final renewed = await _sessions.credential(rejected: credential);
        if (renewed == null || (verb != 'GET' && verb != 'HEAD')) {
          throw const ProtectedApiFailure(401);
        }
        credential = renewed;
      }
    }
  }
}

final protectedApiProvider = Provider<ProtectedApi>((ref) {
  final client = ref.watch(apiClientProvider);
  if (client == null) throw StateError('API is not configured');
  return ProtectedApi(client, ref.watch(sessionControllerProvider.notifier));
});

final currentIdentityProvider = FutureProvider.autoDispose<SessionUser>((
  ref,
) async {
  final id = ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  if (id == null) throw const ProtectedApiFailure(401);
  final cancellation = CancelToken();
  ref.onDispose(cancellation.cancel);
  final body = await ref
      .watch(protectedApiProvider)
      .request<Object?>('GET', 'auth/me', cancelToken: cancellation);
  if (body case {
    'id': String userId,
    'email': String email,
  } when userId == id) {
    return (id: userId, email: email);
  }
  throw const FormatException('Unexpected account identity');
}, retry: (_, _) => null);
