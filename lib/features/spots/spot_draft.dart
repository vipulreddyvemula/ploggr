import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../plogging/data/plog_drafts.dart';
import '../plogging/data/location_source.dart';
import 'spot.dart';

/// One editable draft per account, API and purpose. The database directory is excluded from Android backup.
class SpotDraft {
  SpotDraft(
    this.db,
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
  final String id;
  final Directory directory;
  String category, notes;
  String place = '';
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
            'lat': point?.latitude,
            'lon': point?.longitude,
            'confirmed': confirmed,
            'locked': locked,
            'picking': picking,
            'photos': photos,
          }),
        },
        where: 'id=?',
        whereArgs: [id],
      )
      .then((_) {});
  File file(String photo) => File('${directory.path}/$photo');
  Future<void> add(SpotPhoto photo) async {
    if (photos.length >= 6 || locked) {
      throw StateError('Photo selection closed');
    }
    await file(photo.id).writeAsBytes(photo.bytes, flush: true);
    photos[photo.id] = photo.type;
    await save();
  }

  Future<void> remove(String photo) async {
    if (locked) return;
    photos.remove(photo);
    await save();
    if (await file(photo).exists()) await file(photo).delete();
  }

  Future<List<SpotPhoto>> readPhotos() async => [
    for (final entry in photos.entries)
      (
        id: entry.key,
        type: entry.value,
        bytes: await file(entry.key).readAsBytes(),
      ),
  ];
  Future<void> clear() async {
    await db.delete('draft', where: 'id=?', whereArgs: [id]);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static Future<SpotDraft> open(String scope, String purpose) async =>
      (await _load(scope, purpose, true))!;
  static Future<SpotDraft?> previousPickup(String scope, String plog) =>
      _load(scope, plog, false);

  static Future<SpotDraft?> _load(
    String scope,
    String purpose,
    bool create,
  ) async {
    final root = '${await getDatabasesPath()}/ploggr-tracks';
    final db = await openDatabase(
      '$root/spots.db',
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE draft(id TEXT PRIMARY KEY,scope TEXT NOT NULL,purpose TEXT NOT NULL,body TEXT NOT NULL,UNIQUE(scope,purpose))',
      ),
    );
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
    final data = jsonDecode(row['body'] as String) as Map;
    final dir = await Directory(
      '$root/spot-images/$id',
    ).create(recursive: true);
    return SpotDraft(
      db,
      id,
      dir,
      data['category'] as String? ?? 'Other',
      data['notes'] as String? ?? '',
      data['lat'] == null
          ? null
          : (latitude: data['lat'] as double, longitude: data['lon'] as double),
      data['confirmed'] == true,
      data['locked'] == true,
      data['picking'] == true,
      Map<String, String>.from(data['photos'] as Map? ?? {}),
    )..place = data['place'] as String? ?? '';
  }
}

final spotDraftProvider = FutureProvider.autoDispose.family(
  (ref, String purpose) =>
      SpotDraft.open(ref.watch(plogDraftsProvider).scope, purpose),
  retry: (_, _) => null,
);
