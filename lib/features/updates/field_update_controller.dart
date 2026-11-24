import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'field_update_service.dart';

final fieldUpdateServiceProvider = Provider<FieldUpdateService>((ref) {
  final http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  ref.onDispose(() => http.close(force: true));
  return FieldUpdateService(http);
});

class FieldUpdateStatus {
  const FieldUpdateStatus({
    this.installedBuild,
    this.release,
    this.checking = false,
    this.updating = false,
    this.progress,
    this.message,
  });

  final int? installedBuild;
  final FieldRelease? release;
  final bool checking;
  final bool updating;
  final double? progress;
  final String? message;
}

final fieldUpdateProvider =
    NotifierProvider<FieldUpdateController, FieldUpdateStatus>(
      FieldUpdateController.new,
    );

class FieldUpdateController extends Notifier<FieldUpdateStatus> {
  static const _checkInterval = Duration(minutes: 5);
  final _timeSinceCheck = Stopwatch();

  @override
  FieldUpdateStatus build() => const FieldUpdateStatus();

  Future<void> check({bool automatic = false}) async {
    final previous = state;
    if (previous.checking || previous.updating) return;
    if (automatic &&
        _timeSinceCheck.isRunning &&
        _timeSinceCheck.elapsed < _checkInterval) {
      return;
    }
    _timeSinceCheck
      ..reset()
      ..start();

    final service = ref.read(fieldUpdateServiceProvider);
    var build = previous.installedBuild;
    state = FieldUpdateStatus(
      installedBuild: build,
      release: previous.release,
      checking: true,
    );
    try {
      build ??= await service.installedBuild();
      final release = await service.latestRelease(build);
      if (!ref.mounted) return;
      state = FieldUpdateStatus(
        installedBuild: build,
        release: release,
        message: !automatic && release == null ? 'Ploggr is up to date.' : null,
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = FieldUpdateStatus(
        installedBuild: build,
        release: previous.release,
        message: automatic ? null : 'Could not check for updates. Try again.',
      );
    }
  }

  Future<void> update() async {
    final previous = state;
    final release = previous.release;
    if (release == null || previous.checking || previous.updating) return;

    final service = ref.read(fieldUpdateServiceProvider);
    void downloading(double progress) {
      if (!ref.mounted) return;
      state = FieldUpdateStatus(
        installedBuild: previous.installedBuild,
        release: release,
        updating: true,
        progress: progress,
      );
    }

    downloading(0);
    String message;
    try {
      final result = await service.install(release, onProgress: downloading);
      message = switch (result) {
        FieldInstallResult.permissionRequired =>
          'Allow installs from Ploggr Field in Android settings, then tap Update again.',
        FieldInstallResult.installerOpened =>
          'Confirm the update in Android’s installer.',
      };
    } on FieldUpdateIntegrityException {
      message = 'The download failed verification. Tap Update to try again.';
    } on PlatformException catch (error) {
      message = error.code == 'invalid_update'
          ? 'This APK could not be verified as a Ploggr Field update.'
          : 'Could not open the Android installer. Try again.';
    } catch (_) {
      message = 'Could not download the update. Try again.';
    }
    if (!ref.mounted) return;
    state = FieldUpdateStatus(
      installedBuild: previous.installedBuild,
      release: release,
      message: message,
    );
  }
}
