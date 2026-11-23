import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ploggr/features/spots/spot.dart';
import 'package:ploggr/features/spots/spot_map_layers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'clusters and selects native features and excludes cleanups from density',
    (tester) async {
      const center = LatLng(19.09, 72.88);
      const style =
          '{"version":8,"glyphs":"https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",'
          '"sources":{},"layers":['
          '{"id":"background","type":"background"}]}';
      Spot spot(String id, {double offset = 0, String status = 'open'}) =>
          Spot.fromJson({
            'id': id,
            'category': 'Glass',
            'status': status,
            'notes': '',
            'mine': false,
            'photoCount': 1,
            'latitude': center.latitude,
            'longitude': center.longitude + offset,
          });

      late MapLibreMapController map;
      var ready = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapLibreMap(
              styleString: style,
              androidView: const AndroidMapView(
                surface: AndroidMapSurface.textureView,
              ),
              initialCameraPosition: const CameraPosition(
                target: center,
                zoom: 12,
              ),
              trackCameraPosition: true,
              minMaxZoomPreference: const MinMaxZoomPreference(
                2,
                SpotMapLayers.maxZoom,
              ),
              onMapCreated: (controller) => map = controller,
              onStyleLoadedCallback: () => ready = true,
            ),
          ),
        ),
      );

      Future<void> waitFor(
        Future<bool> Function() condition,
        String description,
      ) async {
        for (var attempt = 0; attempt < 60; attempt++) {
          if (await condition()) return;
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('Timed out waiting for $description');
      }

      await waitFor(() async => ready, 'the map style');
      final layers = SpotMapLayers(map);
      await layers.add();
      final open = spot('open');
      await layers.update([open, spot('second', offset: .0004)], null, false);
      await map.moveCamera(CameraUpdate.newLatLngZoom(center, 12));

      Future<Point<double>> screenCenter() async {
        final position = await map.toScreenLocation(center);
        return Point(position.x.toDouble(), position.y.toDouble());
      }

      Future<List> rendered(String layer) async {
        final position = await screenCenter();
        return map.queryRenderedFeaturesInRect(
          Rect.fromCircle(center: Offset(position.x, position.y), radius: 28),
          [layer],
          null,
        );
      }

      await waitFor(
        () async => (await rendered(SpotMapLayers.clusters)).isNotEmpty,
        'a cluster at zoom 12',
      );
      await layers.expand(await screenCenter(), null);
      await waitFor(
        () async => (map.cameraPosition?.zoom ?? 0) > 12,
        'cluster expansion',
      );

      await map.moveCamera(
        CameraUpdate.newLatLngZoom(center, SpotMapLayers.maxZoom),
      );
      await layers.update([open, spot('second')], null, false);
      await waitFor(
        () async =>
            map.cameraPosition?.zoom == SpotMapLayers.maxZoom &&
            (await rendered(SpotMapLayers.clusters)).isNotEmpty,
        'a cluster of overlapping pins',
      );
      Set<String>? overlapping;
      await layers.expand(await screenCenter(), (ids) => overlapping = ids);
      expect(overlapping, {'open', 'second'});

      final collected = spot('cleaned', status: 'collected');
      await layers.update([open, collected], null, true);
      await waitFor(() async {
        final density = await map.querySourceFeatures(
          SpotMapLayers.densitySource,
          null,
          null,
        );
        return density.isNotEmpty && density.every((f) => f['id'] == 'open');
      }, 'only active points in the density source');
      expect(await rendered(SpotMapLayers.clusters), isEmpty);

      await layers.update([open], 'open', false);
      await waitFor(() async {
        final selected = await rendered(SpotMapLayers.selection);
        return selected.any((f) => f['id'] == 'open');
      }, 'the selected pin in the marker layer');
    },
  );
}
