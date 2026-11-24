import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ploggr/features/updates/field_update_controller.dart';
import 'package:ploggr/features/updates/field_update_service.dart';

const _channel = MethodChannel('ploggr/field-updates');
const _releaseBase =
    'https://github.com/vipulreddyvemula/ploggr/releases/download';
const _apkBytes = <int>[3, 4, 5, 6];

String get _apkDigest => sha256.convert(_apkBytes).toString();

Map<String, Object> _githubRelease(
  int build, {
  bool draft = false,
  String? url,
  String? digest,
}) => {
  'tag_name': 'field-$build',
  'draft': draft,
  'prerelease': true,
  'assets': [
    {
      'name': 'ploggr-field.apk',
      'state': 'uploaded',
      'browser_download_url':
          url ?? '$_releaseBase/field-$build/ploggr-field.apk',
      'size': _apkBytes.length,
      'digest': digest ?? 'sha256:$_apkDigest',
    },
  ],
};

FieldRelease get _release => FieldRelease(
  buildNumber: 7,
  apk: Uri.parse('$_releaseBase/field-7/ploggr-field.apk'),
  bytes: _apkBytes.length,
  digest: _apkDigest,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Dio client;
  late FieldUpdateService service;
  late _StubAdapter adapter;

  setUp(() {
    adapter = _StubAdapter();
    client = Dio()..httpClientAdapter = adapter;
    service = FieldUpdateService(client);
    PackageInfo.setMockInitialValues(
      appName: 'Ploggr Field',
      packageName: 'com.example.ploggr.field',
      version: '1.0.0',
      buildNumber: '6',
      buildSignature: '',
    );
  });

  tearDown(() {
    client.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test(
    'finds the highest verifiable field pre-release by build number',
    () async {
      adapter.entries = [
        _githubRelease(9),
        _githubRelease(14, draft: true),
        _githubRelease(12, digest: 'missing checksum'),
        _githubRelease(11, url: 'https://example.com/ploggr-field.apk'),
        _githubRelease(10),
        _githubRelease(6),
      ];
      final release = await service.latestRelease(6);
      expect(release!.buildNumber, 10);
      expect(release.digest, _apkDigest);
      expect(await service.latestRelease(10), isNull);
    },
  );

  test('automatic checks are throttled and manual checks refresh', () async {
    adapter.entries = [_githubRelease(7)];
    final container = ProviderContainer.test(
      overrides: [fieldUpdateServiceProvider.overrideWithValue(service)],
    );
    final controller = container.read(fieldUpdateProvider.notifier);
    await controller.check(automatic: true);
    expect(container.read(fieldUpdateProvider).release?.buildNumber, 7);
    await controller.check(automatic: true);
    expect(adapter.checks, 1);
    await controller.check();
    expect(adapter.checks, 2);
  });

  test(
    'corrupted bytes never reach Android and the partial file is removed',
    () async {
      final directory = await Directory.systemTemp.createTemp('ploggr-update-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/ploggr-field.apk';
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call.method);
            return path;
          });
      adapter.downloadBytes = [0, 0, 0, 0];

      await expectLater(
        service.install(_release, onProgress: (_) {}),
        throwsA(isA<FieldUpdateIntegrityException>()),
      );
      expect(calls, ['apkPath']);
      expect(await directory.list().isEmpty, isTrue);
    },
  );

  test(
    'reuses the verified APK after returning from Android settings',
    () async {
      final directory = await Directory.systemTemp.createTemp('ploggr-update-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/ploggr-field.apk';
      var installCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'apkPath') return path;
            expect(call.method, 'install');
            expect(call.arguments, {'buildNumber': 7});
            expect(await File(path).readAsBytes(), _apkBytes);
            return ++installCalls == 1
                ? 'permissionRequired'
                : 'installerOpened';
          });
      expect(
        await service.install(_release, onProgress: (_) {}),
        FieldInstallResult.permissionRequired,
      );
      expect(
        await service.install(_release, onProgress: (_) {}),
        FieldInstallResult.installerOpened,
      );
      expect(adapter.downloads, 1);
    },
  );
}

class _StubAdapter implements HttpClientAdapter {
  List<Map<String, Object>> entries = [];
  List<int> downloadBytes = _apkBytes;
  int checks = 0;
  int downloads = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.host == 'api.github.com') {
      checks++;
      return ResponseBody.fromString(
        jsonEncode(entries),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    expect(options.uri, _release.apk);
    downloads++;
    return ResponseBody.fromBytes(
      downloadBytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['${downloadBytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
