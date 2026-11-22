import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_ui/material_ui.dart';
import '../plogging/data/location_source.dart';
import 'spot.dart';

LatLng coordinates(RouteFix p) => LatLng(p.latitude, p.longitude);

/// Default fallback location for India
const defaultIndiaCenter = LatLng(20.5937, 78.9629);
const defaultIndiaZoom = 4.5;

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
    this.route = const [],
    this.focus,
    this.fitRoute = false,
    this.onPin,
    this.onCenter,
    this.onPan,
    this.onUnavailable,
    this.selected,
    this.counts = const {},
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
  final List<RouteFix> route;
  final RouteFix? focus;
  final bool fitRoute;
  final ValueChanged<RouteFix>? onPin;
  final ValueChanged<String>? onSelect;
  final ValueChanged<MapViewport>? onViewport;
  final double height, zoom;
  final ValueChanged<RouteFix>? onCenter;
  final VoidCallback? onPan, onUnavailable;
  final String? selected;
  final Map<String, int> counts;
  final double? accuracy;
  final RouteFix? accuracyPoint;
  final List<int> breaks;
  final int cameraKey;
  @override
  State<SpotMap> createState() => _SpotMapState();
}

class _SpotMapState extends State<SpotMap> {
  MapLibreMapController? controller;
  bool ready = false, failed = false, drawing = false, dirty = false;
  int generation = 0;
  final icons = <String>{};
  double zoom = 16;
  Timer? timeout;
  @override
  void initState() {
    super.initState();
    armTimeout();
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
        (old.focus != widget.focus || old.cameraKey != widget.cameraKey) &&
        widget.focus != null) {
      controller?.moveCamera(
        CameraUpdate.newLatLngZoom(coordinates(widget.focus!), widget.zoom),
      );
    }
    if (!mapEquals(old.points, widget.points) ||
        old.route != widget.route ||
        old.selected != widget.selected ||
        !mapEquals(old.counts, widget.counts) ||
        old.accuracy != widget.accuracy ||
        old.accuracyPoint != widget.accuracyPoint) {
      unawaited(draw());
    }
  }

  Future<String> marker(
    MapLibreMapController map,
    String id,
    int count,
    bool selected,
  ) async {
    final routePoint = ['start', 'finish', 'latest'].contains(id);
    final text = count > 1
        ? '$count'
        : routePoint
        ? (id == 'start'
              ? 'S'
              : id == 'finish'
              ? 'F'
              : '•')
        : '';
    final key = 'pin-$text-$selected-$routePoint';
    if (icons.contains(key)) return key;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(2);
    final color = selected
        ? const Color(0xff103f20)
        : routePoint
        ? const Color(0xff145e91)
        : const Color(0xff976115);
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
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    try {
      while (mounted && dirty && identical(map, controller)) {
        dirty = false;
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
        }
        final ends = [
          0,
          ...widget.breaks.where((n) => n > 0 && n < route.length),
          route.length,
        ];
        for (var n = 1; n < ends.length; n++) {
          if (ends[n] - ends[n - 1] < 2) continue;
          await map.addLine(
            LineOptions(
              geometry: route
                  .sublist(ends[n - 1], ends[n])
                  .map(coordinates)
                  .toList(),
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
                  iconImage: await marker(
                    map,
                    e.key,
                    widget.counts[e.key] ?? 1,
                    e.key == widget.selected,
                  ),
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
    final focus = widget.focus ?? widget.route.lastOrNull;
    return SizedBox(
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerMove: widget.onPan == null ? null : (_) => widget.onPan!(),
            child: MapLibreMap(
              trackCameraPosition: true,
              gestureRecognizers:
                  widget.onPin != null || widget.onViewport != null
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
                controller = map;
                icons.clear();
                map.onSymbolTapped.add((circle) {
                  final id = circle.data?['id'];
                  if (id is String) widget.onSelect?.call(id);
                });
              },
              onStyleLoadedCallback: () async {
                if (!mounted) return;
                timeout?.cancel();
                setState(() {
                  ready = true;
                  failed = false;
                });
                final bounds = widget.fitRoute
                    ? routeBounds(widget.route)
                    : null;
                if (bounds != null) {
                  await controller?.moveCamera(
                    CameraUpdate.newLatLngBounds(
                      bounds,
                      left: 28,
                      right: 28,
                      top: 24,
                      bottom: 28,
                    ),
                  );
                } else if (widget.focus != null) {
                  await controller?.moveCamera(
                    CameraUpdate.newLatLngZoom(
                      coordinates(widget.focus!),
                      widget.zoom,
                    ),
                  );
                }
                if (!mounted) return;
                await draw();
                if (mounted) await viewport();
              },
              onCameraIdle: viewport,
              onMapClick: (_, p) => widget.onPin?.call((
                latitude: p.latitude,
                longitude: p.longitude,
              )),
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
