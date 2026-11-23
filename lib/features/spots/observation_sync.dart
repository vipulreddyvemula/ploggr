import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/protected_api.dart';
import '../plogging/data/location_source.dart';
import '../plogging/data/plog_drafts.dart';
import 'spot_api.dart';

class ObservationSync {
  ObservationSync(this.drafts, this.reports, this.changed);

  final PlogDrafts drafts;
  final SpotApi reports;
  final void Function(String report) changed;
  final _sending = <String, Future<void>>{};

  Future<void> flush({String? plog}) async {
    final rows = await drafts.observations(plog: plog, unsent: true);
    await Future.wait([
      for (final row in rows)
        if (row['plog'] == plog) _sendOnce(row),
    ]);
  }

  Future<void> flushSighting(String id) async {
    final rows = await drafts.observations(unsent: true);
    for (final row in rows) {
      if (row['id'] == id && row['plog'] == null) {
        await _sendOnce(row);
        return;
      }
    }
  }

  Future<void> _sendOnce(Map<String, Object?> row) {
    final id = row['id'] as String;
    return _sending.putIfAbsent(
      id,
      () => _send(row).whenComplete(() {
        _sending.remove(id);
      }),
    );
  }

  Future<void> _send(Map<String, Object?> row) async {
    final id = row['id'] as String;
    if (await drafts.observationReceipt(id) != null) return;
    final report = row['report'] as String;
    final plog = row['plog'] as String?;
    final raw = row['gps'] as String?;
    try {
      final receipt = await reports.observe(
        report,
        id,
        row['outcome'] as String,
        row['photo'] as String?,
        plog: plog,
        gps: raw == null ? null : GpsSample.fromJson(jsonDecode(raw)),
      );
      await drafts.acknowledge(id, receipt);
    } on ProtectedApiFailure catch (error) {
      if (![400, 404, 422].contains(error.status) &&
          !(plog == null && error.status == 409)) {
        rethrow;
      }
      await drafts.acknowledge(id, 'rejected');
    }
    changed(report);
  }
}

typedef SightingSyncStatus = ({String id, String outcome, String? verification});

final sightingSyncStatusProvider = FutureProvider.autoDispose.family<SightingSyncStatus?, String>(
  (ref, report) async {
    final observations = await ref.watch(plogDraftsProvider).observations();
    final row = observations.reversed.where((row) => row['plog'] == null && row['report'] == report).firstOrNull;
    return row == null ? null : (
      id: row['id'] as String,
      outcome: row['outcome'] as String,
      verification: row['receipt'] as String?,
    );
  },
  retry: (_, _) => null,
);

final observationSyncProvider = Provider(
  (ref) => ObservationSync(
    ref.watch(plogDraftsProvider),
    ref.watch(spotApiProvider),
    (report) {
      if (ref.mounted) {
        ref.invalidate(exploreProvider);
        ref.invalidate(mapSpotsProvider);
        ref.invalidate(spotDetailProvider(report));
        ref.invalidate(mySpotsProvider);
        ref.invalidate(sightingSyncStatusProvider(report));
      }
    },
  ),
);
