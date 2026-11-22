import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/session/session_controller.dart';
import '../features/auth/session/session_store.dart';
import 'app_routes.dart';

enum AuthMode { live, preview, unavailable }

final authModeProvider = Provider<AuthMode>((ref) {
  if (ref.watch(sessionStoreProvider) != null) return AuthMode.live;
  if (!kDebugMode) return AuthMode.unavailable;
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      !const bool.fromEnvironment('PLOGGR_PREVIEW')) {
    return AuthMode.unavailable;
  }
  return AuthMode.preview;
});

/// Owned by one router. Destinations come only from recognized app routes.
class AuthNavigation extends ChangeNotifier {
  bool onboardingSeen = false;
  String? _destination;
  bool _returnToLogin = false;

  void sessionChanged(SessionState? previous, SessionState next) {
    if (next.phase == SessionPhase.signingOut) {
      _destination = null;
      _returnToLogin = true;
    }
    notifyListeners();
  }

  String? redirect(AuthMode mode, SessionPhase phase, GoRouterState state) {
    if (mode == AuthMode.preview) return null;
    final path = state.uri.path;
    if (mode == AuthMode.unavailable) {
      return path == AppRoutes.login ? null : AppRoutes.login;
    }
    final entry =
        path == AppRoutes.login ||
        path == AppRoutes.signup ||
        path == AppRoutes.onboarding;
    final splash = path == AppRoutes.splash;
    if (phase == SessionPhase.signingOut ||
        phase == SessionPhase.logoutFailed) {
      return splash ? null : AppRoutes.splash;
    }
    if (_returnToLogin && phase == SessionPhase.signedOut) {
      if (path != AppRoutes.login) return AppRoutes.login;
      _returnToLogin = false;
    }
    final known =
        state.error == null &&
        !state.uri.hasScheme &&
        !state.uri.hasAuthority &&
        state.fullPath != null;
    final protected = known && !entry && !splash;
    if (phase == SessionPhase.signedIn || phase == SessionPhase.renewing) {
      if (protected) return null;
      final destination = _destination ?? AppRoutes.home;
      _destination = null;
      return destination;
    }
    if (protected) _destination = state.uri.toString();
    if (phase == SessionPhase.unavailable || phase == SessionPhase.restoring) {
      if (entry && phase == SessionPhase.restoring) return null;
      return splash ? null : AppRoutes.splash;
    }
    if (entry) return null;
    if (splash && _destination == null && phase != SessionPhase.expired) {
      return onboardingSeen ? AppRoutes.login : AppRoutes.onboarding;
    }
    return AppRoutes.login;
  }
}
