import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_ui/material_ui.dart';

import '../plogging/data/location_source.dart';
import 'spot.dart';

Color spotMarkerColor(SpotMapStatus status) => switch (status) {
  SpotMapStatus.verification => const Color(0xffaa6316),
  SpotMapStatus.collected => const Color(0xff358322),
  _ => const Color(0xffc63728),
};

class SpotMapLayers {
  SpotMapLayers(this.map);
  final MapLibreMapController map;
  static const source = 'ploggr-spots';
  static const pins = 'ploggr-spot-pins';
  static const clusters = 'ploggr-spot-clusters';
  static const clusterLabels = 'ploggr-spot-counts';
  static const selection = 'ploggr-spot-selection';
  static const densitySource = 'ploggr-density-source';
  static const density = 'ploggr-density';
  static const maxZoom = 20.0;
  static const clusterFilter = ['has', 'point_count'];
  static const pointFilter = ['!', clusterFilter];
  static const empty = {'type': 'FeatureCollection', 'features': []};
  static const pinImage = ['get', 'pin'];

  Map<String, (RouteFix, SpotMapStatus)>? _points;
  bool _heatmap = false;
  bool _densityReady = false;
  String? _selected;

  Future<void> _addMarker(SpotMapStatus status, IconData glyph) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(2);
    final pin = Path()
      ..moveTo(16, 39)
      ..cubicTo(13, 33, 1, 22, 1, 16)
      ..arcToPoint(const Offset(31, 16), radius: const Radius.circular(15))
      ..cubicTo(31, 22, 19, 33, 16, 39)
      ..close();
    canvas.drawPath(pin, Paint()..color = spotMarkerColor(status));
    canvas.drawPath(
      pin,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final icon = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(glyph.codePoint),
        style: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontFamily: glyph.fontFamily,
        ),
      ),
    )..layout();
    icon.paint(canvas, Offset(16 - icon.width / 2, 15 - icon.height / 2));
    final picture = recorder.endRecording();
    final image = await picture.toImage(64, 82);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await map.addImage(
        'ploggr-${status.name}',
        bytes!.buffer.asUint8List(),
        false,
        2,
      );
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  Future<void> add() async {
    await map.addSource(
      source,
      const GeojsonSourceProperties(
        data: empty,
        cluster: true,
        clusterRadius: 44,
        clusterMaxZoom: maxZoom,
        maxzoom: maxZoom + 1,
      ),
    );
    await map.addCircleLayer(
      source,
      clusters,
      const CircleLayerProperties(
        circleColor: '#245d38',
        circleRadius: [
          'step',
          ['get', 'point_count'],
          18,
          25,
          22,
          100,
          25,
        ],
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 2,
      ),
      filter: clusterFilter,
    );
    await map.addSymbolLayer(
      source,
      clusterLabels,
      const SymbolLayerProperties(
        textField: [
          'to-string',
          ['get', 'point_count'],
        ],
        textFont: ['Noto Sans Regular'],
        textSize: 14,
        textColor: '#ffffff',
        textAllowOverlap: true,
        textIgnorePlacement: true,
      ),
      filter: clusterFilter,
      enableInteraction: false,
    );
    await _addMarker(SpotMapStatus.open, Icons.delete_outline_rounded);
    await _addMarker(SpotMapStatus.verification, Icons.priority_high_rounded);
    await _addMarker(SpotMapStatus.collected, Icons.check_rounded);
    for (final layer in [pins, selection]) {
      await map.addSymbolLayer(
        source,
        layer,
        SymbolLayerProperties(
          iconImage: pinImage,
          iconAnchor: 'bottom',
          iconSize: layer == selection ? 1.2 : .86,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        filter: layer == selection ? _selectionFilter(null) : pointFilter,
      );
    }
  }

  Future<void> _addDensity() async {
    await map.addGeoJsonSource(densitySource, empty);
    await map.addHeatmapLayer(
      densitySource,
      density,
      const HeatmapLayerProperties(
        heatmapRadius: [
          'interpolate',
          ['linear'],
          ['zoom'],
          4,
          14,
          16,
          38,
        ],
        heatmapOpacity: 0.82,
        heatmapColor: [
          'interpolate',
          ['linear'],
          ['heatmap-density'],
          0,
          'rgba(42,112,199,0)',
          0.18,
          '#2678ce',
          0.42,
          '#36b8b2',
          0.65,
          '#ffd14a',
          1,
          '#b92d36',
        ],
      ),
    );
    _densityReady = true;
  }

  static List<Object> _selectionFilter(String? id) => [
    '==',
    ['get', 'reportId'],
    id ?? '',
  ];

  Future<void> update(List<Spot> spots, String? selected, bool heatmap) async {
    final points = {
      for (final spot in spots) spot.id: (spot.point, spot.mapStatus),
    };
    final changed = !mapEquals(_points, points);
    if (changed) {
      await map.setGeoJsonSource(source, _geoJson(points.entries));
      _points = points;
    }
    if (_selected != selected) {
      await map.setLayerFilter(selection, _selectionFilter(selected));
      _selected = selected;
    }
    if (heatmap && (changed || !_heatmap)) {
      if (!_densityReady) await _addDensity();
      await map.setGeoJsonSource(
        densitySource,
        _geoJson(
          points.entries.where(
            (entry) => entry.value.$2 != SpotMapStatus.collected,
          ),
        ),
      );
    }
    if (heatmap != _heatmap) {
      for (final layer in [clusters, clusterLabels, pins, selection]) {
        await map.setLayerVisibility(layer, !heatmap);
      }
      await map.setLayerVisibility(density, heatmap);
      _heatmap = heatmap;
    }
  }

  static Map<String, dynamic> _geoJson(
    Iterable<MapEntry<String, (RouteFix, SpotMapStatus)>> points,
  ) => {
    'type': 'FeatureCollection',
    'features': [
      for (final MapEntry(key: id, value: (point, status)) in points)
        {
          'type': 'Feature',
          'id': id,
          'geometry': {
            'type': 'Point',
            'coordinates': [point.longitude, point.latitude],
          },
          'properties': {'reportId': id, 'pin': 'ploggr-${status.name}'},
        },
    ],
  };

  Future<void> expand(
    math.Point<double> point,
    ValueChanged<Set<String>>? onOverlapping,
  ) async {
    final hits = await map.queryRenderedFeatures(point, [clusters], null);
    final features = hits.isNotEmpty
        ? hits
        : await map.queryRenderedFeaturesInRect(
            Rect.fromCircle(center: Offset(point.x, point.y), radius: 28),
            [clusters],
            null,
          );
    if (features.isEmpty) return;
    final feature = features.first as Map;
    final properties = feature['properties'] as Map;
    final clusterId = (properties['cluster_id'] as num).toInt();
    final xy = (feature['geometry'] as Map)['coordinates'] as List;
    final target = LatLng((xy[1] as num).toDouble(), (xy[0] as num).toDouble());
    final zoom = map.cameraPosition?.zoom ?? 0;
    if (zoom >= maxZoom - 0.1) {
      final leaves = await map.getClusterLeaves(
        source,
        clusterId,
        limit: (properties['point_count'] as num).toInt(),
      );
      onOverlapping?.call({
        for (final leaf in leaves)
          if ((leaf['properties'] as Map?)?['reportId'] case final String id)
            id,
      });
      return;
    }
    final expansion = await map.getClusterExpansionZoom(source, clusterId);
    await map.animateCamera(
      CameraUpdate.newLatLngZoom(
        target,
        math.min(maxZoom, math.max(zoom + 1, expansion + 0.25)),
      ),
    );
  }
}
