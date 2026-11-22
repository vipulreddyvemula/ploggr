import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config_provider.dart';
import 'session_api.dart';

class StoredSession {
  const StoredSession(this.refreshToken, [this.requestId]);
  final String refreshToken;
  final String? requestId;

  factory StoredSession.decode(String value) {
    if (jsonDecode(value)
        case {'refreshToken': String token, 'requestId': String? requestId}
        when validRefreshToken(token) &&
            (requestId == null || Uuid.isValidUUID(fromString: requestId))) {
      return StoredSession(token, requestId);
    }
    throw const FormatException('Invalid stored session');
  }

  String encode() =>
      jsonEncode({'refreshToken': refreshToken, 'requestId': requestId});
}

class SessionStore {
  SessionStore(Uri backend)
    : _key =
          'ploggr.session.v1.${base64Url.encode(utf8.encode(backend.toString()))}';
  final String _key;
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      storageNamespace: 'ploggr_sessions',
      resetOnError: false,
    ),
  );

  Future<bool> seenOnboarding() async =>
      await _storage.read(key: 'ploggr.onboarded') == 'yes';
  Future<void> markOnboarding() =>
      _storage.write(key: 'ploggr.onboarded', value: 'yes');
  Future<StoredSession?> read() async {
    final value = await _storage.read(key: _key);
    return value == null ? null : StoredSession.decode(value);
  }

  static const _channel = MethodChannel('ploggr/session-storage');

  Future<bool> isLogoutPending() async =>
      (await _channel.invokeMethod<bool>('isLogoutPending', {'scope': _key}))!;
  Future<void> setLogoutPending(bool pending) => _channel.invokeMethod<void>(
    'setLogoutPending',
    {'scope': _key, 'pending': pending},
  );

  Future<void> save(StoredSession record) async {
    await _storage.write(key: _key, value: record.encode());
    await _channel.invokeMethod<void>('flush');
  }

  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _channel.invokeMethod<void>('flush');
  }
}

final sessionStoreProvider = Provider<SessionStore?>((ref) {
  final base = ref.watch(appConfigProvider).apiBaseUrl;
  if (base == null ||
      (kReleaseMode && base.scheme != 'https') ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  return SessionStore(base);
});
