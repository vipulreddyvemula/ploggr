import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../plogging/data/location_source.dart';
import '../plogging/data/plog_drafts.dart';
import 'spot_api.dart';
import 'spot_map.dart';

typedef ChosenPlace = ({RouteFix point, String name});
Future<ChosenPlace?> rememberedArea(PlogDrafts drafts) async {
  final raw = await drafts.preference('map-area');
  if (raw == null) return null;
  final d = jsonDecode(raw) as Map;
  return (
    point: (
      latitude: (d['lat'] as num).toDouble(),
      longitude: (d['lon'] as num).toDouble(),
    ),
    name: d['name'] as String,
  );
}

Future<void> rememberArea(PlogDrafts drafts, ChosenPlace p) => drafts.remember(
  'map-area',
  jsonEncode({
    'lat': p.point.latitude,
    'lon': p.point.longitude,
    'name': p.name,
  }),
);
Future<ChosenPlace?> choosePlace(
  BuildContext context, {
  ChosenPlace? initial,
  String title = 'Choose spot',
  ValueChanged<bool>? onLocationSource,
  bool initialGps = false,
}) => Navigator.of(context).push<ChosenPlace>(
  MaterialPageRoute(
    builder: (_) => _PlacePage(
      initial: initial,
      title: title,
      onLocationSource: onLocationSource,
      initialGps: initialGps,
    ),
  ),
);

class _PlacePage extends ConsumerStatefulWidget {
  const _PlacePage({
    required this.initial,
    required this.title,
    required this.onLocationSource,
    required this.initialGps,
  });
  final ChosenPlace? initial;
  final String title;
  final ValueChanged<bool>? onLocationSource;
  final bool initialGps;
  @override
  ConsumerState<_PlacePage> createState() => _PlaceState();
}

class _PlaceState extends ConsumerState<_PlacePage> {
  final search = TextEditingController();
  RouteFix? focus, center, gpsPoint;
  String label = '', notice = '';
  double? accuracy;
  DateTime? locatedAt;
  var results = <Map>[];
  bool locating = false,
      searching = false,
      interacted = false,
      accepting = false;
  Timer? debounce;
  int request = 0, cameraKey = 0;
  bool movingPin = false;
  late bool gpsSelected = widget.initialGps;
  @override
  void initState() {
    super.initState();
    focus = center = widget.initial?.point;
    label = widget.initial?.name ?? '';
    if (focus == null) unawaited(restoreArea());
  }

  Future<void> restoreArea() async {
    try {
      final saved = await rememberedArea(ref.read(plogDraftsProvider));
      if (!mounted || interacted) return;
      if (saved != null) {
        setState(() {
          focus = saved.point;
          cameraKey++;
        });
        return;
      }
      final cached = await ref.read(locationSourceProvider).cachedPoint();
      if (mounted && !interacted && cached != null) {
        setState(() {
          focus = cached;
          cameraKey++;
        });
      }
    } catch (_) {
      // Search and manual pin placement work without a saved area.
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> lookup(String query, int version) async {
    try {
      final found = await ref.read(spotApiProvider).places({'q': query});
      if (mounted && version == request) {
        setState(() {
          results = found;
          searching = false;
          notice = found.isEmpty
              ? 'No places found. Try a nearby street or tap the map.'
              : '';
        });
      }
    } catch (_) {
      if (mounted && version == request) {
        setState(() {
          searching = false;
          notice = 'Place search is unavailable. Tap the map to choose a spot.';
        });
      }
    }
  }

  void move(RouteFix p, String name, {bool gps = false}) {
    if (accepting) return;
    FocusManager.instance.primaryFocus?.unfocus();
    debounce?.cancel();
    request++;
    search.clear();
    setState(() {
      movingPin = false;
      focus = center = p;
      gpsSelected = gps;
      label = name;
      interacted = true;
      results = [];
      searching = false;
      notice = '';
      cameraKey++;
    });
  }

  Future<void> locate() async {
    final version = ++request;
    debounce?.cancel();
    setState(() {
      interacted = true;
      locating = true;
      searching = false;
      results = [];
    });
    try {
      final fix = await ref.read(locationSourceProvider).current();
      if (!mounted || version != request) return;
      gpsPoint = (latitude: fix.latitude, longitude: fix.longitude);
      accuracy = fix.accuracy;
      locatedAt = fix.timestamp;
      move(gpsPoint!, '', gps: true);
    } catch (_) {
      if (mounted && version == request) {
        setState(
          () => notice =
              'Location unavailable. Search for a place or move the map.',
        );
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  Future<void> accept() async {
    final p = center;
    if (p == null || accepting || movingPin) return;
    final selectedUsingGps = gpsSelected;
    setState(() => accepting = true);
    var name = label;
    if (name.isEmpty) {
      try {
        final rows = await ref
            .read(spotApiProvider)
            .places({'lat': p.latitude, 'lon': p.longitude})
            .timeout(const Duration(seconds: 2));
        name = rows.firstOrNull?['name'] as String? ?? '';
      } catch (_) {}
    }
    final place = (point: p, name: name.isEmpty ? 'Pinned on map' : name);
    if (!mounted) return;
    try {
      await rememberArea(ref.read(plogDraftsProvider), place);
    } catch (_) {}
    if (mounted) {
      widget.onLocationSource?.call(selectedUsingGps);
      Navigator.pop(context, place);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: search,
              enabled: !accepting,
              decoration: const InputDecoration(
                labelText: 'Search a park, street or landmark',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (s) {
                debounce?.cancel();
                final version = ++request;
                setState(() {
                  interacted = true;
                  results = [];
                  notice = '';
                  searching = s.trim().length >= 2;
                });
                if (searching) {
                  debounce = Timer(
                    const Duration(milliseconds: 350),
                    () => lookup(s.trim(), version),
                  );
                }
              },
            ),
          ),
          if (searching)
            const LinearProgressIndicator(semanticsLabel: 'Searching places'),
          if (notice.isNotEmpty && MediaQuery.viewInsetsOf(context).bottom > 0)
            Padding(
              padding: AppSpace.page,
              child: Text(notice, style: AppText.caption),
            ),
          if (results.isNotEmpty)
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final r in results)
                    ListTile(
                      leading: const Icon(Icons.place_outlined),
                      title: Text(r['name'] as String),
                      onTap: () => move((
                        latitude: (r['latitude'] as num).toDouble(),
                        longitude: (r['longitude'] as num).toDouble(),
                      ), r['name'] as String),
                    ),
                ],
              ),
            ),
          Expanded(
            flex: MediaQuery.sizeOf(context).height < 480 ? 1 : 2,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: SpotMap(
                    focus: focus,
                    cameraKey: cameraKey,
                    interactive: !accepting,
                    accuracy: accuracy,
                    accuracyPoint: gpsPoint,
                    onPin: (p) => move(p, ''),
                    onPan: () {
                      if (movingPin || accepting) return;
                      setState(() {
                        movingPin = true;
                        request++;
                        debounce?.cancel();
                        searching = false;
                        results = [];
                        interacted = true;
                        label = '';
                      });
                    },
                    onCenter: (p) {
                      if (movingPin && mounted) {
                        setState(() {
                          center = p;
                          gpsSelected = false;
                          movingPin = false;
                        });
                      }
                    },
                  ),
                ),
                IgnorePointer(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 40),
                    child: Icon(
                      Icons.location_pin,
                      size: 44,
                      color: context.colors.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (MediaQuery.viewInsetsOf(context).bottom == 0)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              notice.isNotEmpty
                                  ? notice
                                  : label.isNotEmpty
                                  ? label
                                  : 'Tap or move the map to place the pin.',
                              style: AppText.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (accuracy == null && notice.isEmpty)
                              const Text(
                                'Location access lets you place the pin near you. You can also place it by hand.',
                                style: AppText.caption,
                              ),
                            if (locatedAt case final DateTime time)
                              Text(
                                'Blue dot · GPS ±${accuracy?.round() ?? 0} m · fix at ${TimeOfDay.fromDateTime(time.toLocal()).format(context)}',
                                style: AppText.caption,
                              ),
                            TextButton.icon(
                              onPressed: locating || accepting ? null : locate,
                              icon: const Icon(Icons.my_location),
                              label: Text(
                                locating
                                    ? 'Finding location…'
                                    : 'Use my location',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    PrimaryButton(
                      accepting ? 'Saving location…' : 'Use this spot',
                      onPressed: center != null && !movingPin && !accepting
                          ? accept
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
