import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/protected_api.dart';
import '../home/activity_overview.dart';
import '../plogging/data/plog_drafts.dart';
import 'spot.dart';
import 'spot_api.dart';
import 'spot_draft.dart';

class ReportSync {
  ReportSync(this.scope, this.api, this.changed);
  final String scope;
  final SpotApi api;
  final void Function(bool published, bool editor) changed;
  final _sending = <String, Future<String?>>{};

  Future<void> flushAll() async {
    final pending = await SpotDraft.pendingReports(scope);
    final available = pending
        .where(
          (draft) =>
              draft.discardRequested ||
              (draft.syncFailure?.canRetryAutomatically ?? true),
        )
        .iterator;
    Future<void> worker() async {
      while (available.moveNext()) {
        try {
          await flush(available.current);
        } catch (_) {
          // Failed drafts remain queued, including those whose upload was interrupted.
        }
      }
    }

    // Bound the number of large photo uploads held in memory at once.
    await Future.wait([worker(), worker()]);
  }

  Future<String?> submit(
    SpotDraft draft, {
    void Function(int, int)? onProgress,
  }) => _once(draft, () async {
    if (!draft.locked) {
      draft.locked = true;
      try {
        await draft.save();
      } catch (_) {
        draft.locked = false;
        rethrow;
      }
    }
    return _send(draft, onProgress: onProgress);
  });

  Future<String?> flush(SpotDraft draft) => _once(draft, () => _send(draft));

  Future<String?> _once(SpotDraft draft, Future<String?> Function() send) {
    _requireScope(draft);
    return _sending.putIfAbsent(
      draft.id,
      () => send().whenComplete(() {
        // The map holds this future. Returning remove() would await itself.
        _sending.remove(draft.id);
      }),
    );
  }

  Future<void> discard(SpotDraft draft) async {
    _requireScope(draft);
    await draft.requestDiscard();
    changed(false, false);
    try {
      await _sending[draft.id];
    } catch (_) {
      // A lost publication acknowledgement still needs cancellation.
    }
    await flush(draft);
  }

  void _requireScope(SpotDraft draft) {
    if (draft.scope != scope) throw const ProtectedApiFailure(401);
  }

  Future<String?> _send(
    SpotDraft queued, {
    void Function(int, int)? onProgress,
  }) async {
    final draft = await queued.reload();
    if (draft == null) return null;
    if (draft.discardRequested) {
      await api.cancelDraft(draft.id);
      final editor = await draft.clear();
      if (editor != null) changed(true, editor);
      return null;
    }
    if (!draft.locked || !draft.confirmed || draft.point == null) return null;
    final fields = SpotDetails(
      draft.point!,
      draft.category,
      draft.notes.trim(),
      draft.place,
      draft.locationSource,
      draft.previousReportId,
    );
    try {
      await api.publish(
        draft.id,
        fields,
        await draft.readPhotos(),
        onProgress: onProgress,
      );
    } catch (error) {
      final failure = _failure(error);
      if (draft.syncFailure != failure) {
        await draft.setSyncFailure(failure);
        changed(false, false);
      }
      rethrow;
    }
    final editor = await draft.clear(keepDiscard: true);
    if (editor == null) return null;
    changed(true, editor);
    return draft.id;
  }

  SpotSyncFailure _failure(Object error) => switch (error) {
    ProtectedApiFailure(status: null) => SpotSyncFailure.connection,
    ProtectedApiFailure(status: 401) => SpotSyncFailure.signIn,
    ProtectedApiFailure(status: 409) => SpotSyncFailure.conflict,
    ProtectedApiFailure(status: 400 || 413 || 415 || 422) =>
      SpotSyncFailure.invalidReport,
    FileSystemException() => SpotSyncFailure.localPhoto,
    _ => SpotSyncFailure.server,
  };
}

final reportSyncProvider = Provider(
  (ref) => ReportSync(
    ref.watch(plogDraftsProvider).scope,
    ref.watch(spotApiProvider),
    (published, editor) {
      if (!ref.mounted) return;
      if (published) {
        ref.invalidate(mySpotsProvider);
        ref.invalidate(totalsProvider);
        ref.invalidate(mapSpotsProvider);
        ref.invalidate(exploreProvider);
      }
      ref.invalidate(pendingSpotDraftsProvider);
      if (editor) ref.invalidate(spotDraftProvider('sighting'));
    },
  ),
);
