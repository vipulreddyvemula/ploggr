import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../plogging/data/plog_drafts.dart';
import '../plogging/data/location_source.dart';
import 'spot.dart';
import '../plogging/data/photo_capture.dart';

enum SpotSyncFailure {
  connection,
  server,
  signIn,
  invalidReport,
  conflict,
  localPhoto;

  bool get canRetryAutomatically => switch (this) {
    connection || server || signIn => true,
    invalidReport || conflict || localPhoto => false,
  };

  String get message => switch (this) {
    connection => 'Waiting for a connection',
    server => 'Waiting for the server',
    signIn => 'Sign in to the same account to sync',
    invalidReport => 'Check the report details and photos',
    conflict => 'The server has a different version of this report',
    localPhoto => 'A photo could not be read on this device',
  };
}

/// One editable draft per account, API and purpose. The database directory is excluded from Android backup.
class SpotDraft {
  SpotDraft(
    this.db,
    this.scope,
    this.id,
    this.directory,
    this.category,
    this.notes,
    this.point,
    this.confirmed,
    this.locked,
    this.picking,
    this.photos,
  );
  final Database db;
  final String scope;
  final String id;
  final Directory directory;
  String category, notes;
  String place = '';
  String locationSource = 'manual';
  String? previousReportId;
  String? replacingPhoto;
  SpotSyncFailure? syncFailure;
  bool discardRequested = false;
  String get syncStatus => discardRequested
      ? 'Withdrawal pending'
      : syncFailure?.message ?? 'Waiting to sync';
  final captures = <String, PhotoCapture>{};
  RouteFix? point;
  bool confirmed, locked, picking;
  final Map<String, String> photos;
  Future<void> save() => db
      .update(
        'draft',
        {
          'body': jsonEncode({
            'category': category,
            'notes': notes,
            'place': place,
            'locationSource': locationSource,
            'previousReportId': previousReportId,
            'replacingPhoto': replacingPhoto,
            'captures': captures.map(
              (id, capture) => MapEntry(id, capture.toJson()),
            ),
            'lat': point?.latitude,
            'lon': point?.longitude,
            'confirmed': confirmed,
            'locked': locked,
            'picking': picking,
            'photos': photos,
          }),
        },
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      )
      .then((_) {});
  File file(String photo) => File('${directory.path}/$photo');
  Future<void> add(SpotPhoto photo, {String? replace}) async {
    if (photos.containsKey(photo.id)) return;
    if (locked ||
        (replace == null ? photos.length >= 6 : !photos.containsKey(replace))) {
      throw StateError('Photo selection closed');
    }
    final before = Map.of(photos);
    final previousCapture = captures[replace];
    final previousReplacement = replacingPhoto;
    try {
      await file(photo.id).writeAsBytes(photo.bytes, flush: true);
      if (replace == null) {
        photos[photo.id] = photo.type;
      } else {
        photos
          ..clear()
          ..addEntries(
            before.entries.map(
              (entry) =>
                  entry.key == replace ? MapEntry(photo.id, photo.type) : entry,
            ),
          );
        captures.remove(replace);
        replacingPhoto = null;
      }
      if (photo.capture != null) captures[photo.id] = photo.capture!;
      await save();
    } catch (_) {
      photos
        ..clear()
        ..addAll(before);
      captures.remove(photo.id);
      if (replace != null && previousCapture != null) {
        captures[replace] = previousCapture;
      }
      replacingPhoto = previousReplacement;
      await _deleteFile(photo.id);
      rethrow;
    }
    if (replace != null) await _deleteFile(replace);
  }

  Future<void> movePhoto(String photo, int offset) async {
    if (locked) return;
    final before = photos.entries.toList();
    final index = before.indexWhere((entry) => entry.key == photo);
    final target = index + offset;
    if (index < 0 || target < 0 || target >= before.length) return;
    final reordered = [...before];
    reordered.insert(target, reordered.removeAt(index));
    photos
      ..clear()
      ..addEntries(reordered);
    try {
      await save();
    } catch (_) {
      photos
        ..clear()
        ..addEntries(before);
      rethrow;
    }
  }

  Future<void> remove(String photo) async {
    if (locked) return;
    final before = Map.of(photos);
    final capture = captures[photo];
    photos.remove(photo);
    captures.remove(photo);
    try {
      await save();
    } catch (_) {
      photos
        ..clear()
        ..addAll(before);
      if (capture != null) captures[photo] = capture;
      rethrow;
    }
    await _deleteFile(photo);
  }

  Future<void> _deleteFile(String photo) async {
    try {
      await file(photo).delete();
    } on FileSystemException {
      // The draft might never have written this file, or it can be reclaimed later.
    }
  }

  Future<List<SpotPhoto>> readPhotos() async => [
    for (final entry in photos.entries)
      (
        id: entry.key,
        type: entry.value,
        bytes: await file(entry.key).readAsBytes(),
        capture: captures[entry.key],
      ),
  ];
  Future<void> detach() async {
    if (!locked) throw StateError('Only queued reports can leave the editor.');
    await db.update(
      'draft',
      {'purpose': 'queued:$id'},
      where: 'scope=? AND id=? AND purpose=?',
      whereArgs: [scope, id, 'sighting'],
    );
  }

  Future<SpotDraft?> reload() async {
    final row = (await db.query(
      'draft',
      where: 'scope=? AND id=?',
      whereArgs: [scope, id],
    )).firstOrNull;
    return row == null ? null : _fromRow(db, scope, directory, row);
  }

  Future<void> setSyncFailure(SpotSyncFailure? value) async {
    await db.update(
      'draft',
      {'sync_failure': value?.name},
      where: 'scope=? AND id=?',
      whereArgs: [scope, id],
    );
    syncFailure = value;
  }

  Future<void> requestDiscard() async {
    await db.transaction((tx) async {
      // A publish acknowledgement can remove the draft just before discard is tapped.
      await tx.insert('draft', {
        'id': id,
        'scope': scope,
        'purpose': 'queued:$id',
        'body': '{}',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.update(
        'draft',
        {'discard_requested': 1, 'sync_failure': null},
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
    });
    discardRequested = true;
    syncFailure = null;
  }

  /// Returns whether the editor draft was removed. A null result leaves it queued.
  Future<bool?> clear({bool keepDiscard = false}) async {
    final wasEditor = await db.transaction((tx) async {
      final rows = await tx.query(
        'draft',
        columns: ['purpose', 'discard_requested'],
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
      final row = rows.firstOrNull;
      if (row == null || keepDiscard && row['discard_requested'] == 1) {
        return null;
      }
      await tx.delete(
        'draft',
        where: 'scope=? AND id=?',
        whereArgs: [scope, id],
      );
      return row['purpose'] == 'sighting';
    });
    if (wasEditor == null) return null;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // A failed file deletion cannot undo a published or withdrawn report.
    }
    return wasEditor;
  }

  static Future<SpotDraft> open(String scope, String purpose) async =>
      (await _load(scope, purpose, true))!;
  static Future<List<SpotDraft>> pendingReports(String scope) async {
    final db = await _database();
    final rows = await db.query(
      'draft',
      where: "scope=? AND (purpose='sighting' OR purpose LIKE 'queued:%')",
      whereArgs: [scope],
      orderBy: 'rowid',
    );
    final root = await _root();
    return rows
        .map(
          (row) => _fromRow(
            db,
            scope,
            Directory('$root/spot-images/${row['id']}'),
            row,
          ),
        )
        .where((draft) => draft.locked || draft.discardRequested)
        .toList();
  }

  static Future<SpotDraft?> previousPickup(String scope, String plog) =>
      _load(scope, plog, false);

  static Future<String> _root() async =>
      '${await getDatabasesPath()}/ploggr-tracks';

  static Future<Database> _database() async => openDatabase(
    '${await _root()}/spots.db',
    version: 2,
    onCreate: (db, _) => db.execute(
      '''CREATE TABLE draft(id TEXT PRIMARY KEY,scope TEXT NOT NULL,purpose TEXT NOT NULL,
      body TEXT NOT NULL, discard_requested INTEGER NOT NULL DEFAULT 0, sync_failure TEXT,
      UNIQUE(scope,purpose))''',
    ),
    onUpgrade: (db, from, _) async {
      if (from < 2) {
        await db.execute(
          'ALTER TABLE draft ADD COLUMN discard_requested INTEGER NOT NULL DEFAULT 0',
        );
        await db.execute('ALTER TABLE draft ADD COLUMN sync_failure TEXT');
      }
    },
  );

  static Future<SpotDraft?> _load(
    String scope,
    String purpose,
    bool create,
  ) async {
    final db = await _database();
    final row = await db.transaction((tx) async {
      if (create) {
        await tx.insert('draft', {
          'id': const Uuid().v4(),
          'scope': scope,
          'purpose': purpose,
          'body': '{}',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return (await tx.query(
        'draft',
        where: 'scope=? AND purpose=?',
        whereArgs: [scope, purpose],
      )).firstOrNull;
    });
    if (row == null) return null;
    final id = row['id'] as String;
    final dir = Directory('${await _root()}/spot-images/$id');
    if (create) await dir.create(recursive: true);
    return _fromRow(db, scope, dir, row);
  }

  static SpotDraft _fromRow(
    Database db,
    String scope,
    Directory dir,
    Map<String, Object?> row,
  ) {
    final data = jsonDecode(row['body'] as String) as Map;
    return SpotDraft(
        db,
        scope,
        row['id'] as String,
        dir,
        data['category'] as String? ?? 'Other',
        data['notes'] as String? ?? '',
        data['lat'] == null
            ? null
            : (
                latitude: (data['lat'] as num).toDouble(),
                longitude: (data['lon'] as num).toDouble(),
              ),
        data['confirmed'] == true,
        data['locked'] == true,
        data['picking'] == true,
        Map<String, String>.from(data['photos'] as Map? ?? {}),
      )
      ..place = data['place'] as String? ?? ''
      ..locationSource = data['locationSource'] as String? ?? 'manual'
      ..previousReportId = data['previousReportId'] as String?
      ..replacingPhoto = data['replacingPhoto'] as String?
      ..discardRequested = row['discard_requested'] == 1
      ..syncFailure = SpotSyncFailure.values
          .where((failure) => failure.name == row['sync_failure'])
          .firstOrNull
      ..captures.addAll(
        (data['captures'] as Map<String, dynamic>? ?? {}).map(
          (id, value) => MapEntry(
            id,
            PhotoCapture.fromJson(value as Map<String, dynamic>),
          ),
        ),
      );
  }
}

final spotDraftProvider = FutureProvider.autoDispose.family(
  (ref, String purpose) =>
      SpotDraft.open(ref.watch(plogDraftsProvider).scope, purpose),
  retry: (_, _) => null,
);

final pendingSpotDraftsProvider = FutureProvider.autoDispose(
  (ref) => SpotDraft.pendingReports(ref.watch(plogDraftsProvider).scope),
  retry: (_, _) => null,
);
