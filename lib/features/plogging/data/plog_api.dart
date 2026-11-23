import 'dart:typed_data';
import 'dart:convert';
import 'photo_capture.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/protected_api.dart';
import '../../auth/session/session_controller.dart';
import 'plog_track.dart';
import 'plog_drafts.dart';
import '../../spots/spot.dart';
import 'completed_plog.dart';

class PlogApi {
  const PlogApi(this.client, this.owner, [this.drafts]);
  final ProtectedApi client;
  final String owner;
  final PlogDrafts? drafts;

  Future<String?> _device() async => await drafts?.recordingDevice();

  PlogTrack _activeTrack(Object? value, String? device) {
    if (value case {
      'id': String id,
      'userId': String userId,
      'startedAt': String started,
      'status': 'active',
    } when userId == owner) {
      return PlogTrack(
        id,
        DateTime.parse(started).toUtc(),
      ).useTimedRoute().deviceStatus(
        value['recordingDevice'] != null && value['recordingDevice'] != device,
      );
    }
    throw const FormatException('Invalid active Plog');
  }

  Future<PlogTrack?> active() async {
    final device = await _device();
    final value = await client.request<Object?>('GET', 'plogs/active');
    if (value case {'plog': final activity}) {
      return activity == null ? null : _activeTrack(activity, device);
    }
    throw const FormatException('Invalid active Plog response');
  }

  Future<PlogTrack> start() async {
    final device = await _device();
    return _activeTrack(
      await client.request<Object?>('POST', 'plogs', recordingDevice: device),
      device,
    );
  }

  Future<PlogTrack> transfer(String id) async {
    final device = await _device();
    return _activeTrack(
      await client.request<Object?>(
        'POST',
        'plogs/$id/transfer',
        recordingDevice: device,
      ),
      device,
    );
  }

  Future<List<SpotPhoto>> recoverEvidence(String plogId) async {
    final result = await client.request<Map>('GET', 'plogs/$plogId/evidence');
    final photos = <SpotPhoto>[];
    for (final item in (result?['items'] as List? ?? [])) {
      final id = item['id'] as String;
      final metadata = item['capture'];
      photos.add((
        id: id,
        type: item['mediaType'] as String,
        bytes: await image(plogId, id),
        capture: metadata == null
            ? null
            : PhotoCapture.fromJson(metadata as Map<String, dynamic>),
      ));
    }
    return photos;
  }

  Future<ActivityPageData> completed(String? before) async {
    final page = await client.request<Object?>(
      'GET',
      'plogs',
      queryParameters: before == null ? null : {'before': before},
    );
    if (page case {'items': List items, 'nextCursor': String? cursor}) {
      return (
        items: items.map((item) => CompletedPlog.parse(item, owner)).toList(),
        nextCursor: cursor,
      );
    }
    throw const FormatException('Invalid activity list');
  }

  Future<CompletedPlog> detail(String id) async {
    final result = CompletedPlog.parse(
      await client.request<Object?>('GET', 'plogs/$id'),
      owner,
      detail: true,
    );
    if (result.id != id) {
      throw const FormatException('Unexpected Plog identifier');
    }
    return result;
  }

  Future<List<String>> evidence(String plogId) async {
    final result = await client.request<Object?>(
      'GET',
      'plogs/$plogId/evidence',
    );
    if (result case {'items': List items}) {
      return [
        for (final item in items)
          switch (item) {
            {'id': String id} => id,
            _ => throw const FormatException('Invalid photo reference'),
          },
      ];
    }
    throw const FormatException('Invalid evidence list');
  }

  Future<Uint8List> image(String plogId, String photoId) async {
    final result = await client.request<List<int>>(
      'GET',
      'plogs/$plogId/evidence/$photoId',
      responseType: ResponseType.bytes,
    );
    if (result == null || result.isEmpty) {
      throw const FormatException('Missing image data');
    }
    return Uint8List.fromList(result);
  }

  Future<void> cancel(String plogId) async => client.request(
    'DELETE',
    'plogs/$plogId',
    idempotent: true,
    recordingDevice: await _device(),
  );

  Future<void> removePhoto(String plogId, String photoId) async =>
      client.request(
        'DELETE',
        'plogs/$plogId/evidence/$photoId',
        idempotent: true,
        recordingDevice: await _device(),
      );

  Future<void> upload(
    String plogId,
    String photoId,
    String type,
    Uint8List bytes, {
    PhotoCapture? capture,
    ProgressCallback? onProgress,
  }) async {
    final part = MultipartFile.fromBytes(
      bytes,
      filename: type == 'image/jpeg' ? 'photo.jpg' : 'photo.png',
      contentType: DioMediaType.parse(type),
    );
    final result = await client.request<Object?>(
      'PUT',
      'plogs/$plogId/evidence/$photoId',
      idempotent: true,
      recordingDevice: await _device(),
      onSendProgress: onProgress,
      data: FormData.fromMap({
        'photo': part,
        if (capture != null) 'capture': jsonEncode(capture.toJson()),
      }),
    );
    if (result case {
      'id': String id,
      'uploadedAt': String _,
    } when id == photoId) {
      return;
    }
    throw const FormatException('Invalid photo acknowledgement');
  }

  Future<void> publishCollection(String id, Map<String, dynamic> fields) async {
    final result = await client.request<Map>(
      'PUT',
      'litter-reports/$id/collection',
      data: fields,
      idempotent: true,
      recordingDevice: await _device(),
    );
    if (result?['id'] != id) {
      throw const FormatException('Missing collection acknowledgement');
    }
  }

  Future<CompletedPlog> finish(
    PlogTrack track, {
    List<String> pickupIds = const [],
  }) async {
    final end = track.endedAt!;
    final saved = await client.request<Object?>(
      'POST',
      'plogs/${track.id}/finish',
      idempotent: true,
      recordingDevice: await _device(),
      data: {
        'endedAt': end.toUtc().toIso8601String(),
        'durationSeconds': track.durationAt(end).inSeconds,
        'distanceMeters': track.distanceMeters,
        if (track.hasGpsMetadata)
          'pausedMilliseconds': track.pausedTime.inMilliseconds,
        if (pickupIds.isNotEmpty) 'pickupIds': pickupIds,
        if (track.breaks.isNotEmpty)
          'segmentStarts': track.breaks
              .where((i) => i < track.route.length)
              .toList(),
        'route': [
          for (final (index, fix) in track.route.indexed)
            track.sampleAt(index)?.toJson() ??
                {'latitude': fix.latitude, 'longitude': fix.longitude},
        ],
      },
    );
    if (saved case {
      'id': String id,
      'userId': String userId,
      'status': 'completed',
    } when id == track.id && userId == owner) {
      return CompletedPlog.parse(saved, owner);
    }
    throw const FormatException('Invalid completion response');
  }
}

final plogApiProvider = Provider<PlogApi>((ref) {
  final owner = ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  if (owner == null) throw const ProtectedApiFailure(401);
  return PlogApi(
    ref.watch(protectedApiProvider),
    owner,
    ref.watch(plogDraftsProvider),
  );
});
