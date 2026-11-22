import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/protected_api.dart';
import '../plogging/data/plog_drafts.dart';
import '../plogging/data/plog_api.dart';
import 'spot_api.dart';

class ObservationSync {
  ObservationSync(this.drafts, this.plogs, this.reports, this.changed);
  final PlogDrafts drafts;
  final PlogApi plogs;
  final SpotApi reports;
  final void Function() changed;
  Future<void> _tail = Future.value();
  Future<void> flush({String? plog}) {
    final work = _tail.then((_) async {
      for (final row in await drafts.observations(plog: plog, unsent: true)) {
        final id = row['id'] as String;
        final photo = row['photo'] as String?;
        if (photo != null) {
          final activity = row['plog'] as String;
          final bytes = await drafts.readPhoto(activity, photo);
          await plogs.upload(activity, photo, bytes.type, bytes.bytes);
        }
        try {
          await reports.observe(
            row['report'] as String,
            id,
            row['outcome'] as String,
            photo,
          );
        } on ProtectedApiFailure catch (e) {
          // A withdrawn sighting can no longer change. Keep its pickup photo.
          if (e.status != 404) rethrow;
        }
        await drafts.acknowledge(id);
        changed();
      }
    });
    _tail = work.catchError((Object _) {});
    return work;
  }
}

final observationSyncProvider = Provider(
  (ref) => ObservationSync(
    ref.watch(plogDraftsProvider),
    ref.watch(plogApiProvider),
    ref.watch(spotApiProvider),
    () {
      if (ref.mounted) {
        ref.invalidate(exploreProvider);
        ref.invalidate(clusterProvider);
        ref.invalidate(spotDetailProvider);
        ref.invalidate(mySpotsProvider);
      }
    },
  ),
);
