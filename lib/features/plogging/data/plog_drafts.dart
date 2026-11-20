import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
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
    version: 2,
    onUpgrade: (db, from, to) async {
      if (from < 2) await _addPhotos(db);
    },
    onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    onCreate: (db, _) async {
      await db.execute('''CREATE TABLE drafts (
        scope TEXT PRIMARY KEY, id TEXT NOT NULL, started TEXT NOT NULL,
        ended TEXT, meters REAL NOT NULL, count INTEGER NOT NULL)''');
      await db.execute('''CREATE TABLE fixes (
        scope TEXT NOT NULL REFERENCES drafts(scope) ON DELETE CASCADE,
        sequence INTEGER NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
        PRIMARY KEY(scope, sequence))''');
      await _addPhotos(db);
    },
  );

  static Future<void> _addPhotos(Database db) async {
    await db.execute(
      'ALTER TABLE drafts ADD COLUMN photo_locked INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute('''CREATE TABLE photos (
      id TEXT PRIMARY KEY, scope TEXT NOT NULL REFERENCES drafts(scope) ON DELETE CASCADE,
      plog_id TEXT NOT NULL, media_type TEXT, bytes BLOB)''');
  }

  Future<List<String>> photoIds(String plogId) => _ordered(
    (db) async => (await db.query(
      'photos',
      columns: ['id'],
      where: 'scope=? AND plog_id=? AND bytes IS NOT NULL',
      whereArgs: [scope, plogId],
      orderBy: 'rowid',
    )).map((row) => row['id'] as String).toList(),
  );

  Future<String?> pendingPhoto(String plogId) => _ordered(
    (db) async =>
        (await db.query(
              'photos',
              columns: ['id'],
              where: 'scope=? AND plog_id=? AND bytes IS NULL',
              whereArgs: [scope, plogId],
              limit: 1,
            )).firstOrNull?['id']
            as String?,
  );

  Future<String> reservePhoto(String plogId) => _ordered(
    (db) => db.transaction((tx) async {
      final editable = await tx.query(
        'drafts',
        columns: ['id'],
        where: 'scope=? AND id=? AND photo_locked=0',
        whereArgs: [scope, plogId],
      );
      if (editable.isEmpty) throw StateError('Photo selection is closed.');
      final rows = await tx.rawQuery(
        'SELECT count(*) AS n, count(bytes) AS ready FROM photos WHERE scope=? AND plog_id=?',
        [scope, plogId],
      );
      final count = rows.single['n'] as int;
      if (count >= 6 || count != rows.single['ready']) {
        throw StateError('Finish the current selection or remove a photo.');
      }
      final id = const Uuid().v4();
      await tx.insert('photos', {'id': id, 'scope': scope, 'plog_id': plogId});
      return id;
    }),
  );

  Future<void> storePhoto(
    String plogId,
    String id,
    String type,
    Uint8List bytes,
  ) => _ordered((db) async {
    final count = await db.update(
      'photos',
      {'bytes': bytes, 'media_type': type},
      where: 'scope=? AND plog_id=? AND id=? AND bytes IS NULL',
      whereArgs: [scope, plogId, id],
    );
    if (count != 1) throw StateError('The Plog draft has changed.');
  });

  Future<void> removePhoto(String plogId, String id) => _ordered((db) async {
    await db.delete(
      'photos',
      where:
          'scope=? AND plog_id=? AND id=? AND scope IN (SELECT scope FROM drafts WHERE photo_locked=0)',
      whereArgs: [scope, plogId, id],
    );
  });

  Future<({String type, Uint8List bytes})> readPhoto(
    String plogId,
    String id,
  ) => _ordered((db) async {
    final args = [scope, plogId, id];
    final rows = await db.rawQuery(
      'SELECT media_type, length(bytes) AS size FROM photos WHERE scope=? AND plog_id=? AND id=?',
      args,
    );
    final row = rows.single;
    final size = row['size'] as int;
    final data = BytesBuilder(copy: false);
    // Keep each result below Android's SQLite CursorWindow size.
    while (data.length < size) {
      final part = await db.rawQuery(
        'SELECT substr(bytes, ?, 524288) AS part FROM photos WHERE scope=? AND plog_id=? AND id=?',
        [data.length + 1, ...args],
      );
      data.add(part.single['part'] as Uint8List);
    }
    return (type: row['media_type'] as String, bytes: data.takeBytes());
  });

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
