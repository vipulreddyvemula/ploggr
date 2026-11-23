import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../plogging/data/photo_capture.dart';
import '../plogging/data/location_source.dart';

final photoPickerProvider = Provider((ref) => ImagePicker());

class CameraPhoto {
  const CameraPhoto(this.id, this.file, this.capture);
  final String id;
  final XFile file;
  final PhotoCapture capture;
}

/// Keeps a selection recoverable while the app compresses and commits it.
/// Android stores lost picker results globally, so only their recorded owner
/// may attach them to a draft.
class PhotoRecovery {
  PhotoRecovery(this.directory, this.scope, this.key) {
    if (!RegExp(r'^[\w-]{1,80}$').hasMatch(key)) {
      throw ArgumentError('Invalid draft key');
    }
  }

  final Directory directory;
  final String scope, key;
  static bool _picking = false;
  static bool _swept = false;

  Directory get _stage => Directory('${directory.path}/$key');
  File get _image => File('${_stage.path}/photo');
  File get _metadata => File('${_stage.path}/metadata.json');
  File get _gallery => File('${directory.path}/gallery.json');

  static Future<PhotoRecovery> open(String scope, String key) async {
    final root = Directory(
      '${await getDatabasesPath()}/ploggr-tracks/photo-recovery',
    );
    await root.create(recursive: true);
    if (!_swept) {
      _swept = true;
      final expired = DateTime.now().subtract(const Duration(days: 7));
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory &&
            (await entry.stat()).modified.isBefore(expired)) {
          await _delete(entry);
        }
      }
    }
    return PhotoRecovery(root, scope, key);
  }

  static Future<void> _delete(FileSystemEntity entry) async {
    try {
      await entry.delete(recursive: true);
    } on FileSystemException {
      // Cleanup can be retried later and cannot undo the saved selection.
    }
  }

  Future<Map<String, dynamic>?> _read(File file) async {
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }

  Future<void> _write(File file, Map<String, Object?> value) async {
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  Future<CameraPhoto> stage(XFile original, PhotoCapture capture) async {
    if (await original.length() > _maximumInputBytes) {
      throw const FormatException('Choose a JPEG or PNG photo up to 24 MiB.');
    }
    final existing = await _read(_metadata);
    if (await _image.exists() ||
        (existing != null && existing['scope'] != scope)) {
      throw StateError('Recover the previous photo before adding another.');
    }
    final id = const Uuid().v4();
    await _stage.create(recursive: true);
    await _write(_metadata, {
      'scope': scope,
      'id': id,
      'capture': capture.toJson(),
    });
    // Publish the file only after it is complete and its metadata is on disk.
    final temporary = File('${_image.path}.part');
    await original.saveTo(temporary.path);
    await temporary.rename(_image.path);
    return CameraPhoto(id, XFile(_image.path), capture);
  }

  Future<CameraPhoto?> recover(ImagePicker picker) async {
    final record = await _read(_metadata);
    if (record?['scope'] == scope && await _image.exists()) {
      return CameraPhoto(
        record!['id'] as String,
        XFile(_image.path),
        PhotoCapture.fromJson(record['capture'] as Map<String, dynamic>),
      );
    }
    if (!Platform.isAndroid || _picking) return null;
    final request = await _read(_gallery);
    if (request?['scope'] != scope || request?['key'] != key) return null;
    return _recoverGallery(picker, request!);
  }

  Future<CameraPhoto?> _recoverGallery(
    ImagePicker picker,
    Map<String, dynamic> request,
  ) async {
    try {
      final lost = await picker.retrieveLostData();
      if (lost.exception != null) throw lost.exception!;
      final file = lost.files?.firstOrNull;
      return file == null ? null : await stage(file, _galleryCapture(request));
    } finally {
      await _delete(_gallery);
    }
  }

  PhotoCapture _galleryCapture(Map<String, dynamic> request) => PhotoCapture(
    PhotoSource.gallery,
    DateTime.parse(request['startedAt'] as String),
  );

  Future<CameraPhoto?> pickGallery(ImagePicker picker) async {
    if (_picking) throw StateError('Finish the current photo selection first.');
    _picking = true;
    try {
      final request = {
        'scope': scope,
        'key': key,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
      };
      if (Platform.isAndroid) {
        final previous = await _read(_gallery);
        if (previous != null) {
          final owner = PhotoRecovery(
            directory,
            previous['scope'] as String,
            previous['key'] as String,
          );
          // Stage an earlier process's result for its own draft before starting a new request.
          try {
            await owner._recoverGallery(picker, previous);
          } catch (_) {
            // The stale request must not block a new selection.
          }
        } else {
          // Results left by versions without an owner marker cannot be attributed.
          await picker.retrieveLostData();
        }
        await _write(_gallery, request);
      }
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      return file == null ? null : await stage(file, _galleryCapture(request));
    } finally {
      await _delete(_gallery);
      _picking = false;
    }
  }

  Future<void> clear() async {
    final record = await _read(_metadata);
    if (record?['scope'] == scope) {
      await _delete(_stage);
    }
  }
}

typedef PreparedPhoto = ({Uint8List bytes, PhotoCapture capture});
const _maximumInputBytes = 24 * 1024 * 1024;

Future<PreparedPhoto> preparePhoto(XFile file, {PhotoCapture? capture}) async {
  if (await file.length() > _maximumInputBytes) {
    throw const FormatException('Choose a JPEG or PNG photo up to 24 MiB.');
  }
  final metadata =
      capture ?? PhotoCapture(PhotoSource.gallery, DateTime.now().toUtc());
  return compute(_compressPhoto, (
    bytes: await file.readAsBytes(),
    capture: metadata,
  ));
}

PreparedPhoto _compressPhoto(PreparedPhoto input) {
  final bytes = input.bytes;
  final decoder = image.findDecoderForData(bytes);
  if (decoder is! image.JpegDecoder && decoder is! image.PngDecoder) {
    throw const FormatException('Choose a JPEG or PNG photo.');
  }
  try {
    final info = decoder!.startDecode(bytes);
    if (info == null ||
        info.numFrames != 1 ||
        info.width * info.height > 32000000) {
      throw const FormatException('Choose a still photo under 32 megapixels.');
    }
    final decoded = decoder.decodeFrame(0)!;
    final capture = input.capture.source == PhotoSource.gallery
        ? _galleryMetadata(decoded.exif, input.capture)
        : input.capture;
    var photo = image.bakeOrientation(decoded);
    if (photo.width > 1800 || photo.height > 1800) {
      photo = photo.width >= photo.height
          ? image.copyResize(photo, width: 1800)
          : image.copyResize(photo, height: 1800);
    }
    photo.exif = image.ExifData();
    return (bytes: image.encodeJpg(photo, quality: 85), capture: capture);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('This photo is damaged. Choose another image.');
  }
}

PhotoCapture _galleryMetadata(image.ExifData exif, PhotoCapture fallback) {
  final tags = exif.exifIfd;
  final original = tags[0x9003]?.toString().trim();
  final offset = tags[0x9011]?.toString().trim();
  // DateTimeOriginal lacks a timezone on some cameras. Keep import time in that case.
  final hasOffset =
      offset != null && RegExp(r'^[+-]\d{2}:\d{2}$').hasMatch(offset);
  final hasDate =
      original != null &&
      RegExp(r'^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$').hasMatch(original);
  final recorded = hasDate && hasOffset
      ? DateTime.tryParse(
          '${original.substring(0, 10).replaceAll(':', '-')}T${original.substring(11)}$offset',
        )
      : null;
  final gps = exif.gpsIfd;
  final latitude = _coordinate(gps[0x0002], gps.gpsLatitudeRef, 90, 'N', 'S');
  final longitude = _coordinate(
    gps[0x0004],
    gps.gpsLongitudeRef,
    180,
    'E',
    'W',
  );
  final RouteFix? location = latitude != null && longitude != null
      ? (latitude: latitude, longitude: longitude)
      : null;
  return PhotoCapture(
    PhotoSource.gallery,
    recorded ?? fallback.capturedAt,
    embeddedLocation: location,
    embeddedTime: recorded != null,
  );
}

double? _coordinate(
  image.IfdValue? value,
  String? direction,
  int limit,
  String positive,
  String negative,
) {
  if (value == null || (direction != positive && direction != negative)) {
    return null;
  }
  final degrees = value.toDouble();
  final decimal = value.length == 3
      ? degrees + value.toDouble(1) / 60 + value.toDouble(2) / 3600
      : degrees;
  if (!decimal.isFinite || decimal < 0 || decimal > limit) return null;
  return direction == negative ? -decimal : decimal;
}
