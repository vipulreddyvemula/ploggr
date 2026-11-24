import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_ui/material_ui.dart';
import '../plogging/data/location_source.dart';
import 'spot.dart';
import 'spot_map_layers.dart';

LatLng coordinates(RouteFix p) => LatLng(p.latitude, p.longitude);

/// Default fallback location for India
const defaultIndiaCenter = LatLng(20.5937, 78.9629);
const defaultIndiaZoom = 4.5;
bool get supportsSpotMap => kIsWeb || Platform.isAndroid || Platform.isIOS;

/// Fit a walking route around its first fix, including walks across the dateline.
LatLngBounds? routeBounds(List<RouteFix> route) {
  if (route.length < 2) return null;
  final start = route.first;
  var south = start.latitude,
      north = south,
      west = start.longitude,
      east = west;
  for (final point in route.skip(1)) {
    final lng =
        start.longitude + (point.longitude - start.longitude + 180) % 360 - 180;
    south = math.min(south, point.latitude);
    north = math.max(north, point.latitude);
    west = math.min(west, lng);
    east = math.max(east, lng);
  }
  if (north == south && east == west) return null;
  return LatLngBounds(
    southwest: LatLng(south, west),
    northeast: LatLng(north, east),
  );
}

class SpotMap extends StatefulWidget {
  const SpotMap({
    super.key,
    this.points = const {},
    this.reports,
    this.heatmap = false,
    this.onOverlapping,
    this.onClearSelection,
    this.route = const [],
    this.focus,
    this.cameraBounds,
    this.fitRoute = false,
    this.interactive = true,
    this.simplifyRoute = false,
    this.onPin,
    this.onCenter,
    this.onPan,
    this.onRecenter,
    this.onUnavailable,
    this.onAvailable,
    this.selected,
    this.accuracy,
    this.accuracyPoint,
    this.breaks = const [],
    this.cameraKey = 0,
    this.onSelect,
    this.onViewport,
    this.zoom = 16,
    this.height = 245,
  });
  final Map<String, RouteFix> points;
  final List<Spot>? reports;
  final bool heatmap;
  final ValueChanged<Set<String>>? onOverlapping;
  final VoidCallback? onClearSelection;
  final List<RouteFix> route;
  final RouteFix? focus;
  final LatLngBounds? cameraBounds;
  final bool fitRoute, simplifyRoute, interactive;
  final ValueChanged<RouteFix>? onPin;
  final ValueChanged<String>? onSelect;
  final ValueChanged<MapViewport>? onViewport;
  final double height, zoom;
  final ValueChanged<RouteFix>? onCenter;
  final VoidCallback? onPan, onRecenter, onUnavailable, onAvailable;
  final String? selected;
  final double? accuracy;
  final RouteFix? accuracyPoint;
  final List<int> breaks;
  final int cameraKey;
  @override
  State<SpotMap> createState() => _SpotMapState();
}

class _SpotMapState extends State<SpotMap> {
  MapLibreMapController? controller;
  SpotMapLayers? layers;
  bool ready = false, failed = false, drawing = false, dirty = false;
  int generation = 0;
  final icons = <String>{};
  double zoom = 16;
  Timer? timeout;
  @override
  void initState() {
    super.initState();
    if (supportsSpotMap) armTimeout();
  }

  void armTimeout() {
    timeout?.cancel();
    timeout = Timer(const Duration(seconds: 12), () {
      if (mounted && !ready) {
        setState(() => failed = true);
        widget.onUnavailable?.call();
      }
    });
  }

  @override
  void dispose() {
    timeout?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(SpotMap old) {
    super.didUpdateWidget(old);
    if (ready &&
        (old.focus != widget.focus ||
            old.fitRoute != widget.fitRoute ||
            old.cameraKey != widget.cameraKey)) {
      unawaited(moveCamera());
    }
    if (!mapEquals(old.points, widget.points) ||
        old.route != widget.route ||
        !listEquals(old.breaks, widget.breaks) ||
        old.simplifyRoute != widget.simplifyRoute ||
        old.selected != widget.selected ||
        old.reports != widget.reports ||
        old.heatmap != widget.heatmap ||
        old.accuracy != widget.accuracy ||
        old.accuracyPoint != widget.accuracyPoint) {
      unawaited(draw());
    }
  }

  Future<String> marker(
    MapLibreMapController map,
    String id,
    bool selected,
  ) async {
    final cleanup = id.startsWith('cleanup-');
    final text = switch (id) {
      'start' => 'S',
      'finish' => 'F',
      'start-finish' => 'S/F',
      'latest' => '•',
      _ => cleanup ? '✓' : '',
    };
    final key = 'pin-$text-$selected';
    if (icons.contains(key)) return key;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(2);
    final color = selected
        ? const Color(0xff103f20)
        : cleanup
        ? spotMarkerColor(SpotMapStatus.collected)
        : text.isNotEmpty
        ? const Color(0xff145e91)
        : const Color(0xff86551c);
    final path = Path()
      ..moveTo(18, 43)
      ..cubicTo(16, 37, 2, 25, 2, 18)
      ..arcToPoint(const Offset(34, 18), radius: const Radius.circular(16))
      ..cubicTo(34, 25, 20, 37, 18, 43)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final label = TextPainter(
      text: TextSpan(
        text: text.isEmpty
            ? String.fromCharCode(Icons.delete_outline.codePoint)
            : text,
        style: TextStyle(
          fontFamily: text.isEmpty
              ? Icons.delete_outline.fontFamily
              : 'NunitoSans',
          fontSize: text.length > 2 ? 11 : 18,
          color: Colors.white,
          fontWeight: text.isEmpty ? FontWeight.normal : FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(18 - label.width / 2, 18 - label.height / 2));
    final picture = recorder.endRecording();
    final image = await picture.toImage(72, 90);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    await map.addImage(key, data!.buffer.asUint8List());
    icons.add(key);
    return key;
  }

  Future<void> draw() async {
    dirty = true;
    if (drawing || !ready || controller == null) return;
    drawing = true;
    final map = controller!;
    final reportLayers = layers;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    try {
      while (mounted && dirty && identical(map, controller)) {
        dirty = false;
        if (reportLayers != null) {
          await reportLayers.update(
            widget.reports!,
            widget.selected,
            widget.heatmap,
          );
          continue;
        }
        final points = widget.points.entries.toList();
        final route = widget.route;
        await map.clearCircles();
        await map.clearLines();
        await map.clearSymbols();
        final location = widget.accuracyPoint;
        if (location != null && widget.accuracy != null) {
          final mpp =
              156543.03 *
              math.cos(location.latitude * math.pi / 180) /
              math.pow(2, zoom);
          await map.addCircle(
            CircleOptions(
              geometry: coordinates(location),
              circleRadius: (widget.accuracy! / mpp).clamp(3, 1000).toDouble(),
              circleColor: '#267da7',
              circleOpacity: 0.16,
              circleStrokeColor: '#267da7',
              circleStrokeWidth: 1,
            ),
          );
          await map.addCircle(
            CircleOptions(
              geometry: coordinates(location),
              circleRadius: 6,
              circleColor: '#146a93',
              circleStrokeColor: '#ffffff',
              circleStrokeWidth: 2,
            ),
          );
        }
        final ends = [
          0,
          ...widget.breaks.where((n) => n > 0 && n < route.length),
          route.length,
        ];
        for (var n = 1; n < ends.length; n++) {
          if (ends[n] - ends[n - 1] < 2) continue;
          final start = ends[n - 1];
          final end = ends[n];
          final stride = widget.simplifyRoute
              ? (route.length / 1000).ceil()
              : 1;
          await map.addLine(
            LineOptions(
              geometry: [
                for (var i = start; i < end - 1; i += stride)
                  coordinates(route[i]),
                coordinates(route[end - 1]),
              ],
              lineColor: '#156444',
              lineWidth: 5,
            ),
          );
        }
        if (points.isNotEmpty) {
          await map.setSymbolIconAllowOverlap(true);
          await map.setSymbolIconIgnorePlacement(true);
          await map.addSymbols(
            [
              for (final e in points)
                SymbolOptions(
                  geometry: coordinates(e.value),
                  iconImage: await marker(map, e.key, e.key == widget.selected),
                  iconAnchor: 'bottom',
                  iconSize: pixelRatio * (e.key == widget.selected ? 0.6 : 0.5),
                ),
            ],
            [
              for (final e in points) {'id': e.key},
            ],
          );
        }
      }
    } catch (_) {
      if (mounted && identical(map, controller)) {
        setState(() => failed = true);
        widget.onUnavailable?.call();
      }
    } finally {
      drawing = false;
      if (dirty && mounted && !identical(map, controller)) unawaited(draw());
    }
  }

  Future<void> moveCamera() async {
    final map = controller;
    final bounds =
        widget.cameraBounds ??
        (widget.fitRoute
            ? routeBounds([...widget.route, ...widget.points.values])
            : null);
    try {
      if (bounds != null) {
        await map?.moveCamera(
          CameraUpdate.newLatLngBounds(
            bounds,
            left: 24,
            right: 24,
            top: 26,
            bottom: 38,
          ),
        );
      } else if (widget.focus case final RouteFix point) {
        await map?.moveCamera(
          CameraUpdate.newLatLngZoom(coordinates(point), widget.zoom),
        );
      }
    } catch (_) {
      // A camera update can outlive a style retry or a dismissed map.
    }
  }

  Future<void> viewport() async {
    final map = controller;
    if (!ready || map == null) return;
    final pos = map.cameraPosition;
    if (pos != null) {
      widget.onCenter?.call((
        latitude: pos.target.latitude,
        longitude: pos.target.longitude,
      ));
      if (zoom != pos.zoom && widget.accuracy != null) {
        zoom = pos.zoom;
        unawaited(draw());
      }
    }
    if (widget.onViewport == null) return;
    try {
      final box = await map.getVisibleRegion();
      if (mounted && identical(map, controller)) {
        widget.onViewport!((
          south: box.southwest.latitude,
          west: box.southwest.longitude,
          north: box.northeast.latitude,
          east: box.northeast.longitude,
        ));
      }
    } catch (_) {
      /* Existing list remains accessible during a style reload. */
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!supportsSpotMap) {
      return SizedBox(
        height: math.min(96, widget.height),
        child: const Center(child: Text('Map unavailable on this platform.')),
      );
    }
    final focus = widget.focus ?? widget.route.lastOrNull;
    final currentGeneration = generation;
    return SizedBox(
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerMove: widget.onPan == null ? null : (_) => widget.onPan!(),
            child: MapLibreMap(
              scrollGesturesEnabled: widget.interactive,
              zoomGesturesEnabled: widget.interactive,
              rotateGesturesEnabled: widget.interactive,
              tiltGesturesEnabled: widget.interactive,
              trackCameraPosition: true,
              minMaxZoomPreference: widget.reports != null
                  ? const MinMaxZoomPreference(2, SpotMapLayers.maxZoom)
                  : MinMaxZoomPreference.unbounded,
              gestureRecognizers:
                  widget.onPin != null ||
                      widget.onViewport != null ||
                      widget.onSelect != null ||
                      widget.onPan != null ||
                      widget.reports != null
                  ? {
                      Factory<EagerGestureRecognizer>(
                        EagerGestureRecognizer.new,
                      ),
                    }
                  : null,
              key: ValueKey(generation),
              androidView: const AndroidMapView(
                surface: AndroidMapSurface.textureView,
              ),
              styleString: const String.fromEnvironment(
                'MAP_STYLE_URL',
                defaultValue: 'https://tiles.openfreemap.org/styles/liberty',
              ),
              initialCameraPosition: CameraPosition(
                target: focus == null ? defaultIndiaCenter : coordinates(focus),
                zoom: focus == null ? defaultIndiaZoom : widget.zoom,
              ),
              onMapCreated: (map) {
                if (!mounted || generation != currentGeneration) return;
                controller = map;
                icons.clear();
                map.onSymbolTapped.add((circle) {
                  final id = circle.data?['id'];
                  if (id is String) widget.onSelect?.call(id);
                });
                if (widget.reports != null) {
                  map.onFeatureTapped.add((point, _, id, layer, _) async {
                    if (layer == SpotMapLayers.pins ||
                        layer == SpotMapLayers.selection) {
                      widget.onSelect?.call(id);
                    } else if (layer == SpotMapLayers.clusters) {
                      widget.onPan?.call();
                      try {
                        await layers?.expand(point, widget.onOverlapping);
                      } catch (_) {
                        // A refresh can replace a cluster before it expands.
                      }
                    }
                  });
                }
              },
              onStyleLoadedCallback: () async {
                final map = controller;
                if (!mounted ||
                    generation != currentGeneration ||
                    map == null) {
                  return;
                }
                timeout?.cancel();
                try {
                  if (widget.reports != null) {
                    final reportLayers = SpotMapLayers(map);
                    await reportLayers.add();
                    if (!mounted || !identical(controller, map)) return;
                    layers = reportLayers;
                  }
                } catch (_) {
                  if (mounted && identical(controller, map)) {
                    setState(() => failed = true);
                    widget.onUnavailable?.call();
                  }
                  return;
                }
                setState(() {
                  ready = true;
                  failed = false;
                });
                widget.onAvailable?.call();
                await moveCamera();
                if (!mounted) return;
                await draw();
                if (mounted) await viewport();
              },
              onCameraIdle: viewport,
              onMapClick: (_, p) {
                widget.onClearSelection?.call();
                widget.onPin?.call((
                  latitude: p.latitude,
                  longitude: p.longitude,
                ));
              },
            ),
          ),
          if (!ready && !failed)
            const Center(
              child: CircularProgressIndicator(semanticsLabel: 'Loading map'),
            ),
          if (ready && !failed && widget.onRecenter != null)
            Positioned(
              top: 8,
              left: 8,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  minimumSize: const Size(48, 48),
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: widget.onRecenter,
                icon: const Icon(Icons.my_location_rounded, size: 19),
                label: const Text('Recenter'),
              ),
            ),
          const Positioned(
            bottom: 2,
            left: 4,
            child: IgnorePointer(
              child: ColoredBox(
                color: Color(0xeaffffff),
                child: Text(
                  'OpenFreeMap · © OpenMapTiles · © OpenStreetMap',
                  style: TextStyle(color: Colors.black, fontSize: 10),
                ),
              ),
            ),
          ),
          if (failed)
            Align(
              alignment: Alignment.topCenter,
              child: FilledButton.tonal(
                onPressed: () {
                  setState(() {
                    generation++;
                    ready = false;
                    failed = false;
                    controller = null;
                    layers = null;
                  });
                  armTimeout();
                },
                child: const Text('Map unavailable · Retry'),
              ),
            ),
        ],
      ),
    );
  }
}
