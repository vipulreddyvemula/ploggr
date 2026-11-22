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
}) => Navigator.of(context).push<ChosenPlace>(
  MaterialPageRoute(
    builder: (_) => _PlacePage(initial: initial, title: title),
  ),
);

class _PlacePage extends ConsumerStatefulWidget {
  const _PlacePage({required this.initial, required this.title});
  final ChosenPlace? initial;
  final String title;
  @override
  ConsumerState<_PlacePage> createState() => _PlaceState();
}

class _PlaceState extends ConsumerState<_PlacePage> {
  final search = TextEditingController();
  RouteFix? focus, center, gpsPoint;
  String label = '', notice = '';
  double? accuracy;
  var results = <Map>[];
  bool locating = false,
      searching = false,
      interacted = false,
      accepting = false;
  Timer? debounce;
  int request = 0, cameraKey = 0;
  bool movingPin = false;
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
          focus = center = saved.point;
          label = saved.name;
        });
        return;
      }
      final cached = await ref.read(locationSourceProvider).cachedPoint();
      if (mounted && !interacted && cached != null) {
        setState(() => focus = cached);
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

  void move(RouteFix p, String name) {
    FocusManager.instance.primaryFocus?.unfocus();
    debounce?.cancel();
    request++;
    search.clear();
    setState(() {
      movingPin = false;
      focus = center = p;
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
      move(gpsPoint!, '');
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
    if (p == null) return;
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
    if (mounted) Navigator.pop(context, place);
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
          if (searching) const LinearProgressIndicator(),
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
            flex: 2,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: SpotMap(
                    focus: focus,
                    cameraKey: cameraKey,
                    accuracy: accuracy,
                    accuracyPoint: gpsPoint,
                    onPin: (p) => move(p, ''),
                    onPan: () {
                      if (movingPin) return;
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
                          movingPin = false;
                        });
                      }
                    },
                  ),
                ),
                const IgnorePointer(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 40),
                    child: Icon(
                      Icons.location_pin,
                      size: 44,
                      color: AppColors.forest,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (MediaQuery.viewInsetsOf(context).bottom == 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
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
                  TextButton.icon(
                    onPressed: locating ? null : locate,
                    icon: const Icon(Icons.my_location),
                    label: Text(
                      locating
                          ? 'Finding location…'
                          : accuracy == null
                          ? 'Use my location'
                          : 'Use my location · GPS ±${accuracy!.round()} m',
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
        ],
      ),
    ),
  );
}
