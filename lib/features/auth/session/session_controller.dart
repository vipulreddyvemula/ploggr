import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'session_api.dart';
import 'session_store.dart';

enum SessionPhase {
  signedOut,
  restoring,
  submitting,
  signingOut,
  logoutFailed,
  expired,
  renewing,
  signedIn,
  unavailable;

  bool get canSignIn => this == signedOut || this == expired;
}

class _PendingLogout implements Exception {
  const _PendingLogout();
}

typedef AccessCredential = ({String token, int generation, int revision});
typedef SessionState = ({SessionPhase phase, SessionUser? user});

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);

class SessionController extends Notifier<SessionState> {
  SessionStore? _store;
  SessionApi? _api;
  SessionBundle? _active;
  Timer? _expiry;
  Future<String?>? _refreshing;
  Future<void> _storageQueue = Future.value();
  int _generation = 0;
  int _revision = 0;
  bool _logoutPending = false;
  bool _signingIn = false;

  @override
  SessionState build() {
    _logoutPending = false;
    _signingIn = false;
    _store = ref.watch(sessionStoreProvider);
    _api = ref.watch(sessionApiProvider);
    ref.onDispose(_invalidate);
    if (_store == null || _api == null) {
      return (phase: SessionPhase.signedOut, user: null);
    }
    final generation = _generation;
    scheduleMicrotask(() {
      if (generation == _generation) unawaited(accessToken());
    });
    return (phase: SessionPhase.restoring, user: null);
  }

  void _invalidate() {
    _generation++;
    _signingIn = false;
    _expiry?.cancel();
    _refreshing = null;
    _active = null;
  }

  // Serialize secure-record changes. Network requests never hold this queue.
  Future<T> _storage<T>(Future<T> Function() operation) {
    final result = _storageQueue.then((_) => operation());
    _storageQueue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> signup(String email, String password) =>
      _signIn(email, password, signup: true);
  Future<void> login(String email, String password) =>
      _signIn(email, password, signup: false);

  Future<void> _signIn(
    String email,
    String password, {
    required bool signup,
  }) async {
    final api = _api;
    if (api == null || _store == null) {
      throw StateError('Mobile authentication is unavailable');
    }
    if (!state.phase.canSignIn) {
      throw StateError('Finish the current session first');
    }
    _invalidate();
    _signingIn = true;
    final generation = _generation;
    state = (phase: SessionPhase.submitting, user: null);
    try {
      final SessionBundle bundle;
      try {
        bundle = signup
            ? await api.signup(email, password)
            : await api.login(email, password);
      } catch (_) {
        if (generation == _generation) {
          state = (phase: SessionPhase.signedOut, user: null);
        }
        rethrow;
      }
      bool accepted;
      try {
        accepted = await _accept(bundle, generation) != null;
      } catch (_) {
        // A failed write may already be visible to the store. A retry must
        // reconcile it before another login can replace the record.
        if (generation == _generation) {
          state = (phase: SessionPhase.unavailable, user: null);
        }
        await api.logout(bundle.refreshToken);
        rethrow;
      }
      if (!accepted) await api.logout(bundle.refreshToken);
    } finally {
      if (generation == _generation) _signingIn = false;
    }
  }

  bool owns(AccessCredential credential) =>
      credential.generation == _generation &&
      (state.phase == SessionPhase.signedIn ||
          state.phase == SessionPhase.renewing);

  /// Compare the rejected issuance, since two JWTs issued in one second can
  /// have the same text. All callers join the same in-flight rotation.
  Future<AccessCredential?> credential({AccessCredential? rejected}) async {
    if (state.phase != SessionPhase.signedIn &&
        state.phase != SessionPhase.renewing) {
      return null;
    }
    final generation = _generation;
    if (rejected != null) {
      if (!owns(rejected)) return null;
      if (rejected.revision == _revision) {
        _expiry?.cancel();
        _active = null;
      }
    }
    final token = await accessToken();
    if (generation != _generation || token == null || _active == null) {
      return null;
    }
    return (
      token: _active!.accessToken,
      generation: generation,
      revision: _revision,
    );
  }

  Future<void> rejectCredential(AccessCredential credential) async {
    if (owns(credential) && credential.revision == _revision) await logout();
  }

  Future<String?> accessToken() {
    if (state.phase.canSignIn ||
        _signingIn ||
        _logoutPending ||
        _store == null ||
        _api == null) {
      return Future.value();
    }
    final active = _active;
    if (active != null && active.expiresAt.isAfter(DateTime.now())) {
      return Future.value(active.accessToken);
    }
    final generation = _generation;
    return _refreshing ??= Future.microtask(() => _restore(generation))
        .whenComplete(() {
          if (generation == _generation) _refreshing = null;
        });
  }

  Future<String?> _restore(int generation) async {
    if (generation != _generation) return null;
    final store = _store!;
    final api = _api!;
    _active = null;
    final user = state.user;
    state = (
      phase: user == null ? SessionPhase.restoring : SessionPhase.renewing,
      user: user,
    );
    try {
      var corrupt = false;
      final record = await _storage(() async {
        if (generation != _generation) return null;
        if (await store.isLogoutPending()) throw const _PendingLogout();
        StoredSession? stored;
        try {
          stored = await store.read();
        } on FormatException {
          corrupt = true;
          await store.clear();
          return null;
        }
        if (stored == null || stored.requestId != null) return stored;
        final pending = StoredSession(stored.refreshToken, const Uuid().v4());
        await store.save(pending);
        return pending;
      });
      if (generation != _generation) return null;
      if (record == null) {
        if (corrupt || user != null) _invalidate();
        state = (
          phase: corrupt || user != null
              ? SessionPhase.expired
              : SessionPhase.signedOut,
          user: null,
        );
        return null;
      }
      try {
        return await _accept(
          await api.refresh(record.refreshToken, record.requestId!),
          generation,
        );
      } on AuthRequestFailure catch (failure) {
        if (failure.status != 401 && failure.status != 400) rethrow;
        await _storage(() async {
          if (generation == _generation) await store.clear();
        });
        if (generation == _generation) {
          _invalidate();
          state = (phase: SessionPhase.expired, user: null);
        }
        return null;
      }
    } on _PendingLogout {
      if (generation == _generation) {
        _logoutPending = true;
        state = (phase: SessionPhase.logoutFailed, user: null);
      }
      return null;
    } catch (_) {
      if (generation == _generation) {
        state = (phase: SessionPhase.unavailable, user: null);
      }
      return null;
    }
  }

  Future<String?> _accept(SessionBundle bundle, int generation) async {
    await _storage(() async {
      if (generation == _generation) {
        await _store!.save(StoredSession(bundle.refreshToken));
      }
    });
    if (generation != _generation) return null;
    final remaining = bundle.expiresAt.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw StateError('Received expired access token');
    }
    _active = bundle;
    _revision++;
    state = (phase: SessionPhase.signedIn, user: bundle.user);
    _expiry?.cancel();
    _expiry = Timer(remaining, () {
      _active = null;
      unawaited(accessToken());
    });
    return bundle.accessToken;
  }

  Future<void> logout() async {
    _invalidate();
    final generation = _generation;
    final store = _store;
    final api = _api;
    _logoutPending = true;
    state = (phase: SessionPhase.signingOut, user: null);
    StoredSession? prior;
    bool cleared = false;
    try {
      await _storage(() async {
        await store?.setLogoutPending(true);
        try {
          prior = await store?.read();
        } finally {
          await store?.clear();
          await store?.setLogoutPending(false);
          cleared = true;
        }
      });
    } finally {
      if (generation == _generation) {
        _logoutPending = !cleared;
        state = (
          phase: cleared ? SessionPhase.signedOut : SessionPhase.logoutFailed,
          user: null,
        );
      }
    }
    if (prior != null) await api?.logout(prior!.refreshToken);
  }
}
