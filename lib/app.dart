import 'dart:async';
import 'features/spots/observation_sync.dart';
import 'features/spots/spot_api.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ploggr/core/constants/app_colors.dart';
import 'package:ploggr/core/theme/app_theme.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/routes/app_router.dart';
import 'package:ploggr/features/cleanups/cleanup_controller.dart';
import 'package:ploggr/features/community/community_controller.dart';
import 'package:ploggr/features/litter/application/litter_controller.dart';
import 'package:ploggr/features/plogging/application/session_controller.dart'
    show sessionProvider, impactProvider;
import 'package:ploggr/features/profile/profile_controller.dart';
import 'package:ploggr/features/plogging/application/active_track.dart';

class PloggrApp extends ConsumerStatefulWidget {
  const PloggrApp({super.key});

  @override
  ConsumerState<PloggrApp> createState() => _PloggrAppState();
}

class _PloggrAppState extends ConsumerState<PloggrApp> {
  late final AppLifecycleListener _lifecycle;
  String? _accountId;
  Timer? _sync;
  Future<void> sync() async {
    try {
      await ref.read(observationSyncProvider).flush();
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(sessionControllerProvider, (_, next) {
      final id = next.user?.id;
      if (_accountId != null &&
          (next.phase == SessionPhase.signingOut ||
              next.phase == SessionPhase.expired ||
              next.phase == SessionPhase.signedOut ||
              (id != null && id != _accountId))) {
        // Dispose per-account preview state, including any running plog timer.
        ref.invalidate(activeTrackProvider);
        ref.invalidate(sessionProvider);
        ref.invalidate(impactProvider);
        ref.invalidate(profileProvider);
        ref.invalidate(litterProvider);
        ref.invalidate(communityProvider);
        ref.invalidate(joinedCleanupsProvider);
        _accountId = null;
      }
      _sync?.cancel();
      if (id != null) {
        _accountId = id;
        if (next.phase == SessionPhase.signedIn) {
          unawaited(sync());
          _sync = Timer.periodic(const Duration(seconds: 30), (_) {
            if (WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
              unawaited(sync());
            }
          });
        }
      }
    }, fireImmediately: true);
    _lifecycle = AppLifecycleListener(
      onResume: () {
        final phase = ref.read(sessionControllerProvider).phase;
        if (phase == SessionPhase.signedIn) {
          unawaited(sync());
          ref.invalidate(exploreProvider);
          ref.invalidate(clusterProvider);
        }
        if (phase == SessionPhase.unavailable ||
            phase == SessionPhase.signedIn) {
          unawaited(ref.read(sessionControllerProvider.notifier).accessToken());
        }
      },
    );
  }

  @override
  void dispose() {
    _sync?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Ploggr',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: router,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(
          systemNavigationBarColor: AppColors.background,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: child!,
      ),
    );
  }
}
