import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/config/app_config_provider.dart';
import '../../../core/network/protected_api.dart';
import '../../auth/session/session_controller.dart';
import 'plog_track.dart';

class PlogDrafts {
  PlogDrafts(this.scope);
  final String scope;
  Future<void> _queue = Future.value();

  Future<Database> _database() async => openDatabase(
    '${await getDatabasesPath()}/ploggr-tracks/drafts.db',
    version: 1,
    onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    onCreate: (db, _) async {
      await db.execute('''CREATE TABLE drafts (
        scope TEXT PRIMARY KEY, id TEXT NOT NULL, started TEXT NOT NULL,
        ended TEXT, meters REAL NOT NULL, count INTEGER NOT NULL)''');
      await db.execute('''CREATE TABLE fixes (
        scope TEXT NOT NULL REFERENCES drafts(scope) ON DELETE CASCADE,
        sequence INTEGER NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
        PRIMARY KEY(scope, sequence))''');
    },
  );

  Future<T> _ordered<T>(Future<T> Function(Database) operation) {
    final result = _queue.then((_) async => operation(await _database()));
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<PlogTrack?> load() => _ordered(
    (db) => db.transaction((tx) async {
      final rows = await tx.query(
        'drafts',
        where: 'scope = ?',
        whereArgs: [scope],
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final points = await tx.query(
        'fixes',
        where: 'scope = ?',
        whereArgs: [scope],
        orderBy: 'sequence',
      );
      return PlogTrack(
        row['id'] as String,
        DateTime.parse(row['started'] as String),
        endedAt: row['ended'] == null
            ? null
            : DateTime.parse(row['ended'] as String),
        distanceMeters: (row['meters'] as num).toDouble(),
        route: List.unmodifiable(
          points.map(
            (p) => (
              latitude: (p['latitude'] as num).toDouble(),
              longitude: (p['longitude'] as num).toDouble(),
            ),
          ),
        ),
      );
    }),
  );

  Future<void> save(PlogTrack track) => _ordered(
    (db) => db.transaction((tx) async {
      final existing = await tx.query(
        'drafts',
        columns: ['id', 'count'],
        where: 'scope = ?',
        whereArgs: [scope],
      );
      final count = existing.isEmpty ? 0 : existing.single['count'] as int;
      if (existing.isNotEmpty &&
          (existing.single['id'] != track.id || count > track.route.length)) {
        throw StateError('Another local track already exists');
      }
      final values = {
        'ended': track.endedAt?.toIso8601String(),
        'meters': track.distanceMeters,
        'count': track.route.length,
      };
      if (existing.isEmpty) {
        await tx.insert('drafts', {
          'scope': scope,
          'id': track.id,
          'started': track.startedAt.toIso8601String(),
          ...values,
        });
      } else {
        await tx.update(
          'drafts',
          values,
          where: 'scope = ?',
          whereArgs: [scope],
        );
      }
      if (count == track.route.length) return;
      final batch = tx.batch();
      for (var i = count; i < track.route.length; i++) {
        final p = track.route[i];
        batch.insert('fixes', {
          'scope': scope,
          'sequence': i,
          'latitude': p.latitude,
          'longitude': p.longitude,
        });
      }
      await batch.commit(noResult: true);
    }),
  );

  Future<void> remove(String id) => _ordered((db) async {
    await db.delete(
      'drafts',
      where: 'scope = ? AND id = ?',
      whereArgs: [scope, id],
    );
  });
}

final plogDraftsProvider = Provider<PlogDrafts>((ref) {
  final owner = ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  final base = ref.watch(appConfigProvider).apiBaseUrl;
  if (owner == null || base == null) throw const ProtectedApiFailure(401);
  return PlogDrafts(jsonEncode([base.toString(), owner]));
});
