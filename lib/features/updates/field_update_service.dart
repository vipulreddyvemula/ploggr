import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

bool get fieldUpdatesEnabled =>
    const bool.fromEnvironment('PLOGGR_FIELD_TEST') &&
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android;

const _repository = 'vipulreddyvemula/ploggr';
const _apkName = 'ploggr-field.apk';

class FieldRelease {
  const FieldRelease({
    required this.buildNumber,
    required this.apk,
    required this.bytes,
    required this.digest,
  });

  final int buildNumber;
  final Uri apk;
  final int bytes;
  final String digest;
}

enum FieldInstallResult { permissionRequired, installerOpened }

class FieldUpdateIntegrityException implements Exception {
  const FieldUpdateIntegrityException();
}

class FieldUpdateService {
  FieldUpdateService(this._http);

  static const _android = MethodChannel('ploggr/field-updates');
  static final _fieldTag = RegExp(r'^field-([1-9][0-9]*)$');
  static final _sha256Digest = RegExp(r'^sha256:([a-f0-9]{64})$');
  final Dio _http;

  Future<int> installedBuild() async {
    final info = await PackageInfo.fromPlatform();
    final build = int.tryParse(info.buildNumber);
    if (build == null || build < 1) {
      throw const FormatException('Invalid installed field build number');
    }
    return build;
  }

  Future<FieldRelease?> latestRelease(int installedBuild) async {
    final response = await _http.get<Object?>(
      'https://api.github.com/repos/$_repository/releases',
      queryParameters: {'per_page': 30},
      options: Options(headers: {'Accept': 'application/vnd.github+json'}),
    );
    final entries = response.data;
    if (entries is! List) {
      throw const FormatException('Invalid release listing');
    }

    FieldRelease? newest;
    for (final entry in entries.whereType<Map>()) {
      final tag = entry['tag_name'];
      final assets = entry['assets'];
      if (entry['draft'] != false || tag is! String || assets is! List) {
        continue;
      }
      final match = _fieldTag.firstMatch(tag);
      final build = match == null ? null : int.tryParse(match.group(1)!);
      if (build == null ||
          build > 2100000000 ||
          build <= (newest?.buildNumber ?? installedBuild)) {
        continue;
      }
      final expectedUrl =
          'https://github.com/$_repository/releases/download/$tag/$_apkName';
      for (final asset in assets.whereType<Map>()) {
        final size = asset['size'];
        final digest = asset['digest'];
        if (asset['name'] != _apkName ||
            asset['state'] != 'uploaded' ||
            asset['browser_download_url'] != expectedUrl ||
            size is! int ||
            size <= 0 ||
            digest is! String) {
          continue;
        }
        final checksum = _sha256Digest.firstMatch(digest)?.group(1);
        if (checksum == null) continue;
        newest = FieldRelease(
          buildNumber: build,
          apk: Uri.parse(expectedUrl),
          bytes: size,
          digest: checksum,
        );
        break;
      }
    }
    return newest;
  }

  Future<FieldInstallResult> install(
    FieldRelease release, {
    required void Function(double progress) onProgress,
  }) async {
    final path = await _android.invokeMethod<String>('apkPath');
    if (path == null) throw StateError('Update cache path unavailable');
    final apk = File(path);
    if (!await _matches(apk, release)) {
      final partial = File('$path.part');
      try {
        var lastPercent = -1;
        await _http.download(
          release.apk.toString(),
          partial.path,
          onReceiveProgress: (bytes, _) {
            final percent = (bytes * 100 ~/ release.bytes).clamp(0, 100);
            if (percent == lastPercent) return;
            lastPercent = percent;
            onProgress(percent / 100);
          },
        );
        if (!await _matches(partial, release)) {
          throw const FieldUpdateIntegrityException();
        }
        await partial.rename(apk.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
    final result = await _android.invokeMethod<String>('install', {
      'buildNumber': release.buildNumber,
    });
    return FieldInstallResult.values.byName(result!);
  }

  Future<bool> _matches(File apk, FieldRelease release) async {
    if (!await apk.exists() || await apk.length() != release.bytes) {
      return false;
    }
    return (await sha256.bind(apk.openRead()).first).toString() ==
        release.digest;
  }
}
