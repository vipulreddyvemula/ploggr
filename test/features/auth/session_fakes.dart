import 'package:ploggr/features/auth/session/session_api.dart';
import 'package:ploggr/features/auth/session/session_store.dart';

final token = 'a' * 43;
final successor = 'b' * 43;
SessionBundle bundle() => SessionBundle(
  (id: 'id', email: 'a@example.test'),
  'access',
  successor,
  DateTime.now().add(const Duration(minutes: 15)),
);

class MemoryStore implements SessionStore {
  StoredSession? value;
  bool failSave = false;
  bool locked = false;
  bool corrupt = false;
  @override
  Future<StoredSession?> read() async {
    if (locked) throw StateError('Storage locked');
    if (corrupt) throw const FormatException();
    return value;
  }

  @override
  Future<void> save(StoredSession record) async {
    if (failSave) throw StateError('Storage locked');
    value = record;
  }

  @override
  Future<void> clear() async {
    corrupt = false;
    value = null;
  }
}

class FakeApi implements SessionApi {
  final requests = <String>[];
  final revoked = <String>[];
  Future<SessionBundle> Function()? onRefresh;
  bool offline = false;
  Future<SessionBundle> Function(String email, String password)? onAuthenticate;
  @override
  Future<SessionBundle> refresh(String token, String requestId) async {
    requests.add(requestId);
    return await (onRefresh?.call() ?? Future.value(bundle()));
  }

  @override
  Future<SessionBundle> login(String email, String password) async =>
      onAuthenticate == null
      ? bundle()
      : await onAuthenticate!(email, password);
  @override
  Future<SessionBundle> signup(String email, String password) async =>
      onAuthenticate == null
      ? bundle()
      : await onAuthenticate!(email, password);
  @override
  Future<void> logout(String token) async {
    if (offline) throw const AuthRequestFailure(null);
    revoked.add(token);
  }
}
