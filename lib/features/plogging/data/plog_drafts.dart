import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../../core/config/app_config_provider.dart';
import '../../../core/network/protected_api.dart';
import '../../auth/session/session_controller.dart';
import 'plog_track.dart';
import '../../spots/spot.dart';

class PlogDrafts {
  PlogDrafts(this.scope);
  final String scope;
  Future<void> _queue = Future.value();

  Future<Database> _database() async => openDatabase(
    '${await getDatabasesPath()}/ploggr-tracks/drafts.db',
    version: 5,
    onUpgrade: (db, from, to) async {
      if (from < 2) await _addPhotos(db);
      if (from < 3) await _addSpots(db);
      if (from < 4) await _addFieldData(db);
      if (from < 5) await _addPickupPlace(db);
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
      await _addSpots(db);
      await _addFieldData(db);
      await _addPickupPlace(db);
    },
  );

  static Future<void> _addPickupPlace(Database db) => db.execute(
    "ALTER TABLE pickups ADD COLUMN place TEXT NOT NULL DEFAULT ''",
  );
  static Future<void> _addFieldData(Database db) async {
    await db.execute(
      "ALTER TABLE drafts ADD COLUMN pauses TEXT NOT NULL DEFAULT '{}'",
    );
    await db.execute(
      '''CREATE TABLE observations(id TEXT PRIMARY KEY,scope TEXT NOT NULL,report TEXT NOT NULL,
      outcome TEXT NOT NULL,plog TEXT,photo TEXT,sent INTEGER NOT NULL DEFAULT 0)''',
    );
    await db.execute(
      'CREATE TABLE preferences(scope TEXT NOT NULL,name TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(scope,name))',
    );
  }

  Future<String?> preference(String name) => _ordered(
    (db) async =>
        (await db.query(
              'preferences',
              where: 'scope=? AND name=?',
              whereArgs: [scope, name],
            )).firstOrNull?['value']
            as String?,
  );
  Future<void> remember(String name, String value) => _ordered((db) async {
    await db.insert('preferences', {
      'scope': scope,
      'name': name,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });
  Future<void> queueObservation(
    String report,
    String outcome, {
    String? plog,
    String? photo,
  }) => _ordered((db) async {
    await db.insert('observations', {
      'id': const Uuid().v4(),
      'scope': scope,
      'report': report,
      'outcome': outcome,
      'plog': plog,
      'photo': photo,
    });
  });
  Future<List<Map<String, Object?>>> observations({
    String? plog,
    bool unsent = false,
  }) => _ordered(
    (db) => db.query(
      'observations',
      where: [
        'scope=?',
        if (plog != null) 'plog=?',
        if (unsent) 'sent=0',
      ].join(' AND '),
      whereArgs: [scope, ?plog],
      orderBy: 'rowid',
    ),
  );
  Future<void> acknowledge(String id) => _ordered((db) async {
    await db.update(
      'observations',
      {'sent': 1},
      where: 'scope=? AND id=?',
      whereArgs: [scope, id],
    );
    await db.delete(
      'observations',
      where: 'scope=? AND id=? AND plog IS NULL',
      whereArgs: [scope, id],
    );
  });

  static Future<void> _addPhotos(Database db) async {
    await db.execute(
      'ALTER TABLE drafts ADD COLUMN photo_locked INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute('''CREATE TABLE photos (
      id TEXT PRIMARY KEY, scope TEXT NOT NULL REFERENCES drafts(scope) ON DELETE CASCADE,
      plog_id TEXT NOT NULL, media_type TEXT, bytes BLOB)''');
  }

  static Future<void> _addSpots(Database db) async {
    await db.execute('ALTER TABLE photos ADD COLUMN report_id TEXT');
    await db.execute('ALTER TABLE photos ADD COLUMN spot TEXT');
    await db.execute(
      'CREATE TABLE pickups(scope TEXT NOT NULL REFERENCES drafts(scope) ON DELETE CASCADE, report_id TEXT NOT NULL, category TEXT NOT NULL, notes TEXT NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL, selected INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(scope,report_id))',
    );
  }

  Future<void> addCollection(
    String plog,
    String reportId,
    SpotDetails spot,
    List<SpotPhoto> photos,
  ) => _ordered(
    (db) => db.transaction((tx) async {
      final draft = await tx.query(
        'drafts',
        columns: ['id'],
        where: 'scope=? AND id=? AND photo_locked=0',
        whereArgs: [scope, plog],
      );
      if (draft.isEmpty) throw StateError('Photo selection is closed.');
      final existing = await tx.rawQuery(
        'SELECT count(*) AS n FROM photos WHERE scope=? AND plog_id=? AND (report_id IS NULL OR report_id<>?)',
        [scope, plog, reportId],
      );
      if (photos.isEmpty || (existing.single['n'] as int) + photos.length > 6) {
        throw StateError('A Plog can contain up to six photos.');
      }
      for (final p in photos) {
        await tx.insert('photos', {
          'id': p.id,
          'scope': scope,
          'plog_id': plog,
          'report_id': reportId,
          'spot': jsonEncode(spot.toJson()),
          'media_type': p.type,
          'bytes': p.bytes,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }),
  );

  Future<Map<String, Map<String, dynamic>>> collectionGroups(String plog) =>
      _ordered((db) async {
        final rows = await db.query(
          'photos',
          columns: ['id', 'report_id', 'spot'],
          where: 'scope=? AND plog_id=? AND report_id IS NOT NULL',
          whereArgs: [scope, plog],
          orderBy: 'rowid',
        );
        final result = <String, Map<String, dynamic>>{};
        for (final r in rows) {
          final group = result.putIfAbsent(
            r['report_id'] as String,
            () => {
              ...jsonDecode(r['spot'] as String) as Map<String, dynamic>,
              'plogId': plog,
              'photoIds': <String>[],
            },
          );
          (group['photoIds'] as List<String>).add(r['id'] as String);
        }
        return result;
      });

  Future<List<Map<String, Object?>>> pickups(String plog) => _ordered(
    (db) => db.rawQuery(
      'SELECT p.report_id,p.category,p.notes,p.place,p.latitude,p.longitude,p.selected FROM pickups p JOIN drafts d ON p.scope=d.scope WHERE d.scope=? AND d.id=? ORDER BY p.report_id',
      [scope, plog],
    ),
  );
  Future<void> linkSpot(String plog, Spot spot) => _ordered((db) async {
    final result = await db.rawQuery(
      'SELECT id FROM drafts WHERE scope=? AND id=? AND photo_locked=0 AND ended IS NULL',
      [scope, plog],
    );
    if (result.isEmpty) throw StateError('Start an active Plog first.');
    await db.insert('pickups', {
      'scope': scope,
      'report_id': spot.id,
      'category': spot.category,
      'notes': spot.notes,
      'place': spot.place,
      'latitude': spot.point.latitude,
      'longitude': spot.point.longitude,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  });
  Future<void> selectPickup(
    String plog,
    String report,
    bool selected,
  ) => _ordered((db) async {
    await db.rawUpdate(
      'UPDATE pickups SET selected=? WHERE scope=? AND report_id=? AND EXISTS(SELECT 1 FROM drafts WHERE scope=? AND id=? AND photo_locked=0)',
      [selected ? 1 : 0, scope, report, scope, plog],
    );
  });

  Future<bool> photosLocked(String id) => _ordered((db) async {
    final rows = await db.query(
      'drafts',
      columns: ['photo_locked'],
      where: 'scope=? AND id=?',
      whereArgs: [scope, id],
    );
    return rows.single['photo_locked'] == 1;
  });

  Future<List<String>> lockPhotos(String id) => _ordered(
    (db) => db.transaction((tx) async {
      final rows = await tx.rawQuery(
        'SELECT id, bytes IS NOT NULL AS ready FROM photos WHERE scope=? AND plog_id=? ORDER BY rowid',
        [scope, id],
      );
      if (rows.isEmpty || rows.length > 6 || rows.any((r) => r['ready'] != 1)) {
        throw StateError('Select one to six photos before saving.');
      }
      await tx.update(
        'drafts',
        {'photo_locked': 1},
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
      return rows.map((r) => r['id'] as String).toList();
    }),
  );

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

  Future<void> recoverPickupPhotos(String plogId, List<SpotPhoto> photos) =>
      _ordered(
        (db) => db.transaction((tx) async {
          final editable = await tx.query(
            'drafts',
            columns: ['id'],
            where: 'scope=? AND id=? AND photo_locked=0',
            whereArgs: [scope, plogId],
          );
          if (editable.isEmpty) {
            throw StateError('The photo selection is closed.');
          }
          final ids = (await tx.query(
            'photos',
            columns: ['id'],
            where: 'scope=? AND plog_id=?',
            whereArgs: [scope, plogId],
          )).map((r) => r['id']).toSet();
          final missing = photos.where((p) => !ids.contains(p.id)).toList();
          if (ids.length + missing.length > 6) {
            throw StateError(
              'Remove a photo to recover your previous pickup draft.',
            );
          }
          for (final p in missing) {
            await tx.insert('photos', {
              'id': p.id,
              'scope': scope,
              'plog_id': plogId,
              'media_type': p.type,
              'bytes': p.bytes,
            });
          }
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
    if ((await db.query(
      'observations',
      columns: ['id'],
      where: 'scope=? AND photo=?',
      whereArgs: [scope, id],
      limit: 1,
    )).isNotEmpty) {
      throw StateError('This photo supports a confirmed pickup.');
    }
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
        pauses: Map<String, dynamic>.from(jsonDecode(row['pauses'] as String)),
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
        'pauses': jsonEncode(track.pauses),
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
      'observations',
      where: 'scope=? AND plog=? AND sent=1',
      whereArgs: [scope, id],
    );
    await db.delete(
      'drafts',
      where: 'scope = ? AND id = ?',
      whereArgs: [scope, id],
    );
  });
}

final resumablePlogProvider = FutureProvider.autoDispose(
  (ref) async => (await ref.watch(plogDraftsProvider).load()) != null,
  retry: (_, _) => null,
);
final linkedSpotsProvider = FutureProvider.autoDispose.family(
  (ref, String plog) => ref.watch(plogDraftsProvider).pickups(plog),
  retry: (_, _) => null,
);

final plogDraftsProvider = Provider<PlogDrafts>((ref) {
  final owner = ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  final base = ref.watch(appConfigProvider).apiBaseUrl;
  if (owner == null || base == null) throw const ProtectedApiFailure(401);
  return PlogDrafts(jsonEncode([base.toString(), owner]));
});
