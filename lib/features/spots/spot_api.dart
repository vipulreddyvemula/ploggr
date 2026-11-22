import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import '../../core/network/protected_api.dart';
import '../auth/session/session_controller.dart';
import 'spot.dart';

class SpotApi {
  const SpotApi(this.client);
  final ProtectedApi client;
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
    List<SpotPhoto> photos,
  ) async {
    final body = FormData.fromMap(fields.toJson());
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
    );
    if (result?['id'] != id) {
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
  Future<void> observe(
    String report,
    String id,
    String outcome,
    String? photo,
  ) async {
    final r = await client.request<Map>(
      'PUT',
      'litter-reports/$report/observations/$id',
      data: {'outcome': outcome, 'photoId': ?photo},
    );
    if (r?['id'] != id) {
      throw const FormatException('Missing observation receipt');
    }
  }

  Future<void> withdraw(String id) =>
      client.request('DELETE', 'litter-reports/$id');
  Future<void> flag(String id) =>
      client.request('POST', 'litter-reports/$id/flags');
}

final spotApiProvider = Provider((ref) {
  ref.watch(sessionControllerProvider.select((s) => s.user?.id));
  return SpotApi(ref.watch(protectedApiProvider));
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
