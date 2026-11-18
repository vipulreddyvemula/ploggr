import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ploggr/core/constants/app_colors.dart';
import 'package:ploggr/core/theme/app_theme.dart';
import 'package:ploggr/features/auth/session/session_controller.dart';
import 'package:ploggr/routes/app_router.dart';

class PloggrApp extends ConsumerStatefulWidget {
  const PloggrApp({super.key});

  @override
  ConsumerState<PloggrApp> createState() => _PloggrAppState();
}

class _PloggrAppState extends ConsumerState<PloggrApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        final phase = ref.read(sessionControllerProvider).phase;
        if (phase == SessionPhase.unavailable ||
            phase == SessionPhase.signedIn) {
          unawaited(ref.read(sessionControllerProvider.notifier).accessToken());
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionControllerProvider.notifier);
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
