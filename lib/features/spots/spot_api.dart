import 'dart:typed_data';
import 'dart:convert';
import '../plogging/data/location_source.dart';
import '../plogging/data/plog_drafts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../core/network/protected_api.dart';
import '../auth/session/session_controller.dart';
import 'spot.dart';

class SpotApi {
  const SpotApi(this.client, [this.drafts]);
  final ProtectedApi client;
  final PlogDrafts? drafts;
  Future<({List<Spot> items, bool truncated})> explore(
    MapViewport bounds,
  ) async {
    final result = await client.request<Map>(
      'GET',
      'litter-reports',
      queryParameters: {
        'south': bounds.south,
        'north': bounds.north,
        'west': bounds.west,
        'east': bounds.east,
      },
    );
    return (
      items: (result!['items'] as List).cast<Map>().map(Spot.fromJson).toList(),
      truncated: result['truncated'] as bool,
    );
  }

  Future<({List<Spot> items, String? next})> mine(String? before) async {
    final result = await client.request<Map>(
      'GET',
      'litter-reports/mine',
      queryParameters: before == null ? null : {'before': before},
    );
    return (
      items: (result!['items'] as List).cast<Map>().map(Spot.fromJson).toList(),
      next: result['nextCursor'] as String?,
    );
  }

  Future<Spot> detail(String id) async =>
      Spot.fromJson((await client.request<Map>('GET', 'litter-reports/$id'))!);
  Future<Uint8List> image(String id, int index) async => Uint8List.fromList(
    (await client.request<List<int>>(
      'GET',
      'litter-reports/$id/photos/$index',
      responseType: ResponseType.bytes,
    ))!,
  );
  Future<void> publish(
    String id,
    SpotDetails fields,
    List<SpotPhoto> photos, {
    ProgressCallback? onProgress,
  }) async {
    final body = FormData.fromMap({
      ...fields.toJson(),
      'captures': jsonEncode([
        for (final photo in photos) photo.capture?.toJson(),
      ]),
    });
    for (final p in photos) {
      body.files.add(
        MapEntry(
          'photos',
          MultipartFile.fromBytes(
            p.bytes,
            filename: p.type == 'image/png' ? 'litter.png' : 'litter.jpg',
            contentType: DioMediaType.parse(p.type),
          ),
        ),
      );
    }
    final result = await client.request<Map>(
      'PUT',
      'litter-reports/$id',
      data: body,
      onSendProgress: onProgress,
      idempotent: true,
    );
    if (result?['id'] != id ||
        !['open', 'collected'].contains(result?['status'])) {
      throw const FormatException('Missing report acknowledgement');
    }
  }

  Future<List<Spot>> nearby(double lat, double lon) async =>
      ((await client.request<List>(
        'GET',
        'litter-reports/nearby',
        queryParameters: {'lat': lat, 'lon': lon},
      ))!).cast<Map>().map(Spot.fromJson).toList();

  Future<List<Map>> clusters(MapViewport b) async =>
      ((await client.request<List>(
        'GET',
        'litter-reports/clusters',
        queryParameters: {
          'south': b.south,
          'west': b.west,
          'north': b.north,
          'east': b.east,
        },
      ))!).cast<Map>();

  Future<List<Map>> places(Map<String, dynamic> params) async =>
      ((await client.request<List>(
        'GET',
        'places',
        queryParameters: params,
      ))!).cast<Map>();
  Future<String> observe(
    String report,
    String id,
    String outcome,
    String? photo, {
    String? plog,
    GpsSample? gps,
  }) async {
    final r = await client.request<Map>(
      'PUT',
      'litter-reports/$report/observations/$id',
      idempotent: true,
      recordingDevice: plog == null ? null : await drafts?.recordingDevice(),
      data: {
        'outcome': outcome,
        'photoId': ?photo,
        'plogId': ?plog,
        'gps': ?gps?.toJson(),
      },
    );
    if (r?['id'] != id) {
      throw const FormatException('Missing observation receipt');
    }
    return r!['verification'] as String? ?? 'unverified';
  }

  Future<void> edit(String id, SpotDetails fields) => client.request(
    'PATCH',
    'litter-reports/$id',
    data: fields.toJson(),
    idempotent: true,
  );

  Future<List<Map>> history(String id) async => (await client.request<List>(
    'GET',
    'litter-reports/$id/history',
  ))!.cast<Map>();

  Future<void> withdraw(String id) =>
      client.request('DELETE', 'litter-reports/$id', idempotent: true);

  Future<void> cancelDraft(String id) =>
      client.request('DELETE', 'litter-reports/$id/draft', idempotent: true);
  Future<void> flag(String id) =>
      client.request('POST', 'litter-reports/$id/flags');
}

final spotApiProvider = Provider((ref) {
  ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  return SpotApi(
    ref.watch(protectedApiProvider),
    ref.watch(plogDraftsProvider),
  );
});
final exploreProvider = FutureProvider.autoDispose.family(
  (ref, MapViewport bounds) => ref.watch(spotApiProvider).explore(bounds),
  retry: (_, _) => null,
);
final clusterProvider = FutureProvider.autoDispose.family(
  (ref, MapViewport bounds) => ref.watch(spotApiProvider).clusters(bounds),
  retry: (_, _) => null,
);
final mySpotsProvider = FutureProvider.autoDispose.family(
  (ref, String? before) => ref.watch(spotApiProvider).mine(before),
  retry: (_, _) => null,
);
final spotDetailProvider = FutureProvider.autoDispose.family(
  (ref, String id) => ref.watch(spotApiProvider).detail(id),
  retry: (_, _) => null,
);
final spotImageProvider = FutureProvider.autoDispose.family(
  (ref, (String, int) key) => ref.watch(spotApiProvider).image(key.$1, key.$2),
  retry: (_, _) => null,
);
