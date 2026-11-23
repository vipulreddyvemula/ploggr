import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ploggr/core/network/protected_api.dart';
import 'package:ploggr/features/spots/report_sync.dart';
import 'package:ploggr/features/spots/spot.dart';
import 'package:ploggr/features/spots/spot_api.dart';
import 'package:ploggr/features/spots/spot_draft.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase extends Fake implements Database {}

class _Draft extends SpotDraft {
  _Draft()
    : super(
        _UnusedDatabase(),
        'account',
        'report',
        Directory.systemTemp,
        'Plastic',
        '',
        (latitude: 12.0, longitude: 77.0),
        true,
        false,
        false,
        {},
      );

  bool removed = false;

  @override
  Future<void> save() async {}

  @override
  Future<SpotDraft?> reload() async => removed ? null : this;

  @override
  Future<bool?> clear({bool keepDiscard = false}) async {
    removed = true;
    return true;
  }

  @override
  Future<void> setSyncFailure(SpotSyncFailure? value) async {
    syncFailure = value;
  }
}

class _Reports extends Fake implements SpotApi {
  int calls = 0;
  bool offline = false;

  @override
  Future<void> publish(
    String id,
    SpotDetails fields,
    List<SpotPhoto> photos, {
    void Function(int, int)? onProgress,
  }) async {
    calls++;
    if (offline) throw const ProtectedApiFailure(null);
  }
}

void main() {
  test(
    'foreground and background sync receive one published report ID',
    () async {
      final draft = _Draft();
      final api = _Reports();
      final sync = ReportSync(draft.scope, api, (_, _) {});
      final foreground = sync.submit(draft);
      final background = sync.flush(draft);

      expect(identical(foreground, background), isTrue);
      expect(
        await Future.wait([
          foreground,
          background,
        ]).timeout(const Duration(seconds: 2)),
        [draft.id, draft.id],
      );
      expect(api.calls, 1);
      expect(draft.removed, isTrue);
    },
  );

  test('an offline submission finishes with an error and can retry', () async {
    final draft = _Draft();
    final api = _Reports()..offline = true;
    final sync = ReportSync(draft.scope, api, (_, _) {});

    await expectLater(
      sync.submit(draft).timeout(const Duration(seconds: 2)),
      throwsA(isA<ProtectedApiFailure>()),
    );
    expect(draft.locked, isTrue);
    expect(draft.removed, isFalse);
    expect(draft.syncFailure, SpotSyncFailure.connection);

    api.offline = false;
    expect(
      await sync.submit(draft).timeout(const Duration(seconds: 2)),
      draft.id,
    );
    expect(api.calls, 2);
    expect(draft.removed, isTrue);
  });
}
