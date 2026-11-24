import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng, LatLngBounds;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../routes/app_routes.dart';
import '../../shared/widgets/bottom_navigation.dart';
import '../../shared/widgets/eco_art.dart';
import '../../shared/widgets/evidence_review.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../community/field_data.dart';
import '../home/activity_overview.dart';
import '../plogging/application/active_track.dart';
import '../plogging/data/location_source.dart';
import '../plogging/data/plog_drafts.dart';
import 'observation_sync.dart';
import 'place_picker.dart';
import 'report_sync.dart';
import 'spot.dart';
import 'spot_api.dart';
import 'spot_draft.dart';
import 'spot_editor.dart';
import 'spot_map.dart';
import 'spot_map_layers.dart';

class ExplorePage extends ConsumerStatefulWidget {
  const ExplorePage({
    super.key,
    this.own = false,
    this.community = false,
    this.initialSpot,
  });
  final bool own, community;
  final String? initialSpot;
  @override
  ConsumerState<ExplorePage> createState() => _ExploreState();
}

const _nearbyRadius = 5000;
const _initialBounds = (south: 8.0, west: 65.0, north: 34.0, east: 93.0);
const _defaultFilters = (
  status: SpotMapStatus.active,
  category: null,
  radius: null,
  ageDays: null,
  nearest: false,
);

class _ExploreState extends ConsumerState<ExplorePage> {
  MapViewport bounds = _initialBounds;
  MapViewport viewport = _initialBounds;
  SpotFilters filters = _defaultFilters;
  RouteFix? origin;
  RouteFix? focus;
  String? selected, notice;
  String area = 'Search location';
  Set<String> overlapping = {};
  int cameraKey = 0, locationRequest = 0, visibleCount = 10;
  bool originIsDevice = false;
  bool locating = false, initialized = false, heatmap = false;
  bool listView = !supportsSpotMap, mapFailed = false;
  Timer? viewportDebounce, refreshTimer, initialAreaTimer;
  ({SpotQuery query, SpotResults page})? lastLoaded;
  final selectedCard = GlobalKey();

  SpotQuery get query => (
    bounds: filters.radius == null ? bounds : world,
    filters: filters,
    origin: origin,
  );

  @override
  void initState() {
    super.initState();
    restore();
    if (!widget.own && !widget.community) {
      initialAreaTimer = Timer(const Duration(milliseconds: 400), () {
        if (mounted && !initialized) setState(() => initialized = true);
      });
      refreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted ||
            !initialized ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed ||
            ModalRoute.isCurrentOf(context) != true) {
          return;
        }
        final provider = mapSpotsProvider(query);
        if (!ref.read(provider).isLoading) ref.invalidate(provider);
      });
    }
  }

  @override
  void didUpdateWidget(ExplorePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSpot != widget.initialSpot &&
        widget.initialSpot != null) {
      restore();
    }
  }

  @override
  void dispose() {
    viewportDebounce?.cancel();
    refreshTimer?.cancel();
    initialAreaTimer?.cancel();
    super.dispose();
  }

  void interact() {
    locationRequest++;
    if (!initialized) setState(() => initialized = true);
  }

  Future<void> restore() async {
    if (widget.own || widget.community) return;
    final version = ++locationRequest;
    final id = widget.initialSpot;
    final source = ref.read(locationSourceProvider);
    if (id != null) {
      try {
        final spot = await ref.read(spotApiProvider).detail(id);
        if (!mounted || version != locationRequest) return;
        showArea((
          point: spot.point,
          name: spot.place.isEmpty ? 'Report area' : spot.place,
        ), report: spot);
        return;
      } catch (_) {
        if (!mounted || version != locationRequest) return;
        setState(() => notice = 'This report is unavailable.');
      }
    }

    RouteFix? cached;
    try {
      cached = await source.cachedPoint();
      if (!mounted || version != locationRequest) return;
      if (cached != null) {
        showArea(
          (point: cached, name: 'Last known area'),
          deviceLocation: true,
          keepNotice: true,
        );
      } else {
        final saved = await rememberedArea(ref.read(plogDraftsProvider));
        if (!mounted || version != locationRequest) return;
        if (saved != null) showArea(saved, keepNotice: true);
      }
    } catch (_) {
      // Discovery can still use a searched area or the map viewport.
    }
    if (!mounted || version != locationRequest) return;
    setState(() => initialized = true);

    try {
      final current = await source.currentIfPermitted();
      if (mounted && version == locationRequest && current != null) {
        showArea(
          (point: current, name: 'Near me'),
          deviceLocation: true,
          keepNotice: true,
        );
      }
    } catch (_) {
      // Keep showing the last known or chosen area while a fresh fix is unavailable.
    }
  }

  void showArea(
    ChosenPlace place, {
    Spot? report,
    bool keepNotice = false,
    bool deviceLocation = false,
  }) {
    viewportDebounce?.cancel();
    setState(() {
      initialized = true;
      if (!keepNotice) notice = null;
      origin = focus = place.point;
      originIsDevice = deviceLocation;
      area = place.name;
      selected = report?.id;
      overlapping = {};
      filters = (
        status: report?.mapStatus == SpotMapStatus.collected
            ? SpotMapStatus.collected
            : report == null
            ? filters.status
            : SpotMapStatus.active,
        category: report == null ? filters.category : null,
        radius: filters.radius ?? _nearbyRadius,
        ageDays: report == null ? filters.ageDays : null,
        nearest: true,
      );
      bounds = viewport = _around(place.point, filters.radius!);
      visibleCount = 10;
      cameraKey++;
    });
  }

  Future<void> pickArea() async {
    interact();
    final place = await choosePlace(
      context,
      title: 'Choose map area',
      initial: origin == null ? null : (point: origin!, name: area),
    );
    if (mounted && place != null) showArea(place);
  }

  Future<void> locate() async {
    final version = ++locationRequest;
    final source = ref.read(locationSourceProvider);
    setState(() => locating = true);
    try {
      final fix = await source.current();
      if (mounted && version == locationRequest) {
        showArea((
          point: (latitude: fix.latitude, longitude: fix.longitude),
          name: 'Near me',
        ), deviceLocation: true);
      }
    } catch (error) {
      if (!mounted || version != locationRequest) return;
      RouteFix? cached;
      try {
        cached = await source.cachedPoint();
      } catch (_) {}
      if (!mounted || version != locationRequest) return;
      if (cached != null) {
        showArea((
          point: cached,
          name: 'Last known area',
        ), deviceLocation: true);
      }
      setState(() {
        initialized = true;
        notice = cached != null
            ? 'Current location unavailable. Showing your last known area.'
            : error is LocationFailure
            ? '${error.message} You can also choose an area.'
            : 'Location unavailable. Search for an area or browse the map.';
      });
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  void updateViewport(MapViewport next) {
    if (listView ||
        !next.south.isFinite ||
        !next.north.isFinite ||
        !next.west.isFinite ||
        !next.east.isFinite) {
      return;
    }
    viewport = next;
    viewportDebounce?.cancel();
    if (filters.radius != null ||
        (_containsViewport(bounds, next) &&
            _longitudeWidth(bounds) < _longitudeWidth(next) * 3)) {
      return;
    }
    viewportDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || filters.radius != null) return;
      setState(() {
        initialized = true;
        bounds = _buffered(next);
        visibleCount = 10;
      });
    });
  }

  void applyFilters(SpotFilters next) {
    if (next == filters) return;
    interact();
    viewportDebounce?.cancel();
    setState(() {
      initialized = true;
      if (next.radius != filters.radius) {
        if (next.radius != null) {
          focus = origin;
          cameraKey++;
        } else {
          bounds = _buffered(viewport);
        }
      }
      filters = next;
      if (next.status == SpotMapStatus.collected) heatmap = false;
      selected = null;
      overlapping = {};
      visibleCount = 10;
    });
  }

  void selectSpot(String id) {
    interact();
    setState(() => selected = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (selectedCard.currentContext case final BuildContext card) {
        unawaited(
          Scrollable.ensureVisible(
            card,
            duration: const Duration(milliseconds: 220),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.own || widget.community) {
      return _ReportFeed(own: widget.own);
    }
    final provider = mapSpotsProvider(query);
    final AsyncValue<SpotResults> fetched = initialized
        ? ref.watch(provider)
        : const AsyncLoading<SpotResults>();
    if (fetched.asData case AsyncData(:final value)) {
      lastLoaded = (query: query, page: value);
    }
    final previous = lastLoaded;
    final page =
        fetched.value ??
        (previous?.query.filters == filters && previous?.query.origin == origin
            ? previous?.page
            : null);
    final spots = page?.items ?? const <Spot>[];
    final first = spots.where((spot) => spot.id == selected).firstOrNull;
    final display = overlapping.isEmpty
        ? spots
        : [
            ...spots.where((s) => overlapping.contains(s.id)),
            ...spots.where((s) => !overlapping.contains(s.id)),
          ];
    final collecting = filters.status == SpotMapStatus.collected;
    final cameraBounds = filters.radius != null && focus != null
        ? _cameraBounds(_around(focus!, filters.radius!))
        : null;
    final controlStyle = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      shape: const StadiumBorder(),
      backgroundColor: context.colors.surface,
      side: BorderSide(color: context.colors.outlineVariant),
    );
    return AppPage(
      title: 'Litter Map',
      root: true,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
      bottomNavigation: const BottomNavBar(),
      tabHeader: TabHeader(
        title: 'Litter Map',
        subtitle: 'Discover litter spots and cleanups nearby',
        action: PopupMenuButton<String>(
          tooltip: 'Map information and actions',
          icon: const Icon(Icons.info_outline),
          onSelected: (v) {
            if (v == 'refresh') ref.invalidate(provider);
            if (v == 'recenter') {
              interact();
              setState(() {
                focus = origin;
                cameraKey++;
              });
            }
          },
          itemBuilder: (_) => [
            for (final status in [
              SpotMapStatus.open,
              SpotMapStatus.verification,
              SpotMapStatus.collected,
            ])
              PopupMenuItem<String>(
                enabled: false,
                child: Row(
                  children: [
                    Icon(Icons.location_pin, color: spotMarkerColor(status)),
                    const SizedBox(width: 6),
                    Text(
                      status.label,
                      style: TextStyle(color: context.colors.onSurface),
                    ),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            if (origin != null && !listView)
              const PopupMenuItem(value: 'recenter', child: Text('Recenter')),
            const PopupMenuItem(value: 'refresh', child: Text('Refresh spots')),
          ],
        ),
      ),
      bottomAction: SizedBox(
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          onPressed: () => openPage(context, AppRoutes.scan),
          child: const Row(
            children: [
              Icon(Icons.add_a_photo_outlined, size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Scan Litter', style: AppText.heading),
                    Text(
                      'Report a new litter spot on the map',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    shape: const StadiumBorder(),
                    backgroundColor: context.colors.surface,
                    side: BorderSide(color: context.colors.outlineVariant),
                  ),
                  onPressed: pickArea,
                  icon: const Icon(Icons.search),
                  label: Text(
                    area,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: 'Find near me',
                onPressed: locating ? null : locate,
                icon: locating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FilterTabs(
            labels: [
              'Active Litter${!collecting && page != null ? ' (${spots.length}${page.truncated ? '+' : ''})' : ''}',
              'Cleaned${collecting && page != null ? ' (${spots.length}${page.truncated ? '+' : ''})' : ''}',
            ],
            selected: collecting ? 1 : 0,
            onChanged: (index) {
              applyFilters((
                status: index == 1
                    ? SpotMapStatus.collected
                    : SpotMapStatus.active,
                category: filters.category,
                radius: filters.radius,
                ageDays: filters.ageDays,
                nearest: filters.nearest,
              ));
            },
          ),
          const SizedBox(height: 6),
          AdaptiveTiles(
            minWidth: 85,
            spacing: 5,
            children: [
              OutlinedButton.icon(
                style: controlStyle,
                onPressed: () async {
                  interact();
                  final next = await showModalBottomSheet<SpotFilters>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (_) =>
                        _MapFilters(filters, hasOrigin: origin != null),
                  );
                  if (mounted && next != null) applyFilters(next);
                },
                icon: const Icon(Icons.tune),
                label: const Text('Filters'),
              ),
              if (supportsSpotMap)
                OutlinedButton.icon(
                  style: controlStyle,
                  onPressed: () {
                    interact();
                    setState(() => listView = !listView);
                  },
                  icon: Icon(listView ? Icons.map_outlined : Icons.list),
                  label: Text(listView ? 'Map view' : 'List'),
                ),
              if (!listView && !collecting)
                OutlinedButton.icon(
                  style: heatmap
                      ? controlStyle.copyWith(
                          backgroundColor: WidgetStatePropertyAll(
                            context.colors.primaryContainer,
                          ),
                        )
                      : controlStyle,
                  icon: const Icon(Icons.layers_outlined, size: 18),
                  label: const Text('Heatmap'),
                  onPressed: () {
                    interact();
                    setState(() => heatmap = !heatmap);
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (filters.category != null ||
              filters.radius != null ||
              filters.ageDays != null ||
              filters.nearest ||
              filters.status == SpotMapStatus.verification ||
              filters.status == SpotMapStatus.open)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                [
                  if (filters.category != null) filters.category!,
                  if (filters.status == SpotMapStatus.verification ||
                      filters.status == SpotMapStatus.open)
                    filters.status.label,
                  if (filters.radius != null)
                    'Within ${formatWalkDistance(filters.radius!.toDouble())}',
                  if (filters.ageDays != null) 'Last ${filters.ageDays} days',
                  if (filters.nearest) 'Nearest first',
                ].join(' · '),
                style: AppText.caption,
              ),
            ),
          if (supportsSpotMap)
            Offstage(
              offstage: listView,
              child: ClipRRect(
                borderRadius: AppRadius.card,
                child: SpotMap(
                  height:
                      (MediaQuery.sizeOf(context).height *
                              (first == null ? .44 : .32))
                          .clamp(176.0, 425.0),
                  reports: spots,
                  selected: selected,
                  heatmap: heatmap,
                  focus: focus,
                  cameraBounds: cameraBounds,
                  zoom: 12,
                  cameraKey: cameraKey,
                  onPan: interact,
                  onAvailable: () {
                    if (mounted && mapFailed) setState(() => mapFailed = false);
                  },
                  onUnavailable: () {
                    if (mounted) setState(() => mapFailed = true);
                  },
                  onViewport: updateViewport,
                  onSelect: selectSpot,
                  onClearSelection: () {
                    interact();
                    if (selected != null) setState(() => selected = null);
                  },
                  onOverlapping: (ids) {
                    if (!mounted || ids.isEmpty) return;
                    setState(() {
                      overlapping = ids;
                      visibleCount = 10;
                      listView = true;
                    });
                  },
                ),
              ),
            ),
          if (!listView && heatmap && !mapFailed)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'Blue to red · lower to higher litter density',
                style: AppText.caption,
              ),
            ),
          if (mapFailed && !listView)
            AppNotice(
              'The map could not load.',
              status: AppStatus.warning,
              actionLabel: 'Show sightings list',
              onAction: () => setState(() => listView = true),
            ),
          if (notice != null) AppNotice(notice!, status: AppStatus.warning),
          if (fetched.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Finding litter sightings…', style: AppText.caption),
            ),
          if (fetched.hasError)
            AppNotice(
              page != null
                  ? 'Showing the last loaded sightings.'
                  : 'Could not load sightings.',
              status: AppStatus.warning,
              actionLabel: 'Retry loading sightings',
              onAction: () => ref.invalidate(provider),
            ),
          if (page?.truncated == true)
            Text(
              filters.radius != null
                  ? 'Showing the first 500 spots. Narrow the distance or choose a category.'
                  : 'Showing the first 500 spots. Zoom in or narrow the filters.',
              style: AppText.caption,
            ),
          if (fetched.asData != null && spots.isEmpty)
            AppNotice(
              collecting
                  ? 'No collected spots match this area and filters.'
                  : 'No active litter spots match this area and filters.',
              actionLabel: collecting ? null : 'Log litter',
              onAction: collecting
                  ? null
                  : () => openPage(context, AppRoutes.scan),
            ),
          if (listView && overlapping.isNotEmpty)
            const Text(
              'Spots from the selected cluster appear first.',
              style: AppText.caption,
            ),
          for (final spot in listView ? display.take(visibleCount) : [?first])
            Padding(
              key: listView ? ValueKey(spot.id) : selectedCard,
              padding: const EdgeInsets.only(bottom: 10),
              child: _ReportCard(
                spot: spot,
                location: origin,
                feed: false,
                showDirections: !listView,
                quickDirections: listView,
                distanceFromArea: !originIsDevice,
              ),
            ),
          if (listView && spots.length > visibleCount)
            TextButton(
              onPressed: () => setState(() => visibleCount += 10),
              child: const Text('Show more spots'),
            ),
        ],
      ),
    );
  }
}

double _wrapLongitude(double value) => (value + 180) % 360 - 180;

double _longitudeWidth(MapViewport value) {
  final width = value.east - value.west;
  return width < 0 ? width + 360 : width;
}

MapViewport _around(RouteFix point, int meters) {
  final delta = meters / 111000;
  final lonDelta =
      delta / math.max(.01, math.cos(point.latitude * math.pi / 180));
  return (
    south: math.max(-90, point.latitude - delta),
    north: math.min(90, point.latitude + delta),
    west: _wrapLongitude(point.longitude - lonDelta),
    east: _wrapLongitude(point.longitude + lonDelta),
  );
}

LatLngBounds _cameraBounds(MapViewport value) => LatLngBounds(
  southwest: LatLng(value.south.clamp(-85, 85).toDouble(), value.west),
  northeast: LatLng(
    value.north.clamp(-85, 85).toDouble(),
    value.east < value.west ? value.east + 360 : value.east,
  ),
);

bool _containsViewport(MapViewport outer, MapViewport inner) =>
    inner.south >= outer.south &&
    inner.north <= outer.north &&
    (outer.west == -180 && outer.east == 180 ||
        (inner.west - outer.west + 360) % 360 + _longitudeWidth(inner) <=
            _longitudeWidth(outer));

MapViewport _buffered(MapViewport value) {
  final width = _longitudeWidth(value);
  final latitudePadding = (value.north - value.south) * .3;
  return (
    south: math.max(-90, value.south - latitudePadding),
    north: math.min(90, value.north + latitudePadding),
    west: width >= 225 ? -180 : _wrapLongitude(value.west - width * .3),
    east: width >= 225 ? 180 : _wrapLongitude(value.east + width * .3),
  );
}

class _MapFilters extends StatefulWidget {
  const _MapFilters(this.initial, {required this.hasOrigin});
  final SpotFilters initial;
  final bool hasOrigin;

  @override
  State<_MapFilters> createState() => _MapFiltersState();
}

class _MapFiltersState extends State<_MapFilters> {
  late SpotMapStatus status = widget.initial.status;
  late String category = widget.initial.category ?? '';
  late int radius = widget.initial.radius ?? 0;
  late int age = widget.initial.ageDays ?? 0;
  late bool nearest = widget.initial.nearest;

  Widget field<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T?>? change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final item in options.entries)
          DropdownMenuItem(value: item.key, child: Text(item.value)),
      ],
      onChanged: change,
    ),
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Map filters', style: AppText.heading),
          const SizedBox(height: 12),
          if (status != SpotMapStatus.collected)
            field('Cleanup status', status, {
              for (final s in SpotMapStatus.values)
                if (s != SpotMapStatus.collected) s: s.label,
            }, (value) => setState(() => status = value!)),
          field('Waste category', category, {
            '': 'All materials',
            for (final c in LitterTypePicker.types) c: c,
          }, (value) => setState(() => category = value!)),
          field<int>(
            'Distance',
            radius,
            const {
              0: 'Map area',
              1000: '1 km',
              5000: '5 km',
              10000: '10 km',
              25000: '25 km',
            },
            widget.hasOrigin
                ? (value) => setState(() => radius = value!)
                : null,
          ),
          field('Report age', age, const {
            0: 'Any time',
            7: 'Last 7 days',
            30: 'Last 30 days',
          }, (value) => setState(() => age = value!)),
          field<bool>(
            'Sort by',
            nearest,
            const {false: 'Newest', true: 'Nearest'},
            widget.hasOrigin
                ? (value) => setState(() => nearest = value!)
                : null,
          ),
          if (!widget.hasOrigin)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Find near me or choose an area to filter by distance or sort by nearest.',
              ),
            ),
          PrimaryButton(
            'Apply filters',
            onPressed: () => Navigator.pop(context, (
              status: status,
              category: category.isEmpty ? null : category,
              radius: radius == 0 ? null : radius,
              ageDays: age == 0 ? null : age,
              nearest: nearest,
            )),
          ),
        ],
      ),
    ),
  );
}

class _ReportFeed extends ConsumerStatefulWidget {
  const _ReportFeed({required this.own});
  final bool own;
  @override
  ConsumerState<_ReportFeed> createState() => _ReportFeedState();
}

class _ReportFeedState extends ConsumerState<_ReportFeed> {
  final cursors = <String?>[null];
  int tab = 0, visibleCount = 10;

  @override
  Widget build(BuildContext context) {
    final own = widget.own || tab == 1;
    final mine = mySpotsProvider(cursors.last);
    final nearby = exploreProvider(world);
    final fetched = own
        ? ref.watch(mine).whenData((page) => page.items)
        : ref.watch(nearby).whenData((page) => page.items);
    final spots = fetched.value ?? [];
    void refresh() => own ? ref.invalidate(mine) : ref.invalidate(nearby);
    return AppPage(
      title: widget.own ? 'My reports' : 'Community',
      root: !widget.own,
      backTo: own ? AppRoutes.profile : AppRoutes.home,
      bottomNavigation: const BottomNavBar(),
      actions: [
        IconButton(
          tooltip: 'Refresh spots',
          onPressed: refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.own)
            FilterTabs(
              labels: const ['Sightings', 'My reports'],
              selected: tab,
              onChanged: (value) => setState(() {
                tab = value;
                visibleCount = 10;
              }),
            ),
          if (own) const _PendingReports(),
          if (!own && ref.watch(nearby).value?.truncated == true)
            const Text('Explore the litter map to see more sightings.'),
          if (fetched.isLoading) const AppLoading('Finding litter sightings'),
          if (fetched.hasError)
            AppNotice(
              'Could not load spots.',
              status: AppStatus.warning,
              actionLabel: 'Retry',
              onAction: refresh,
            ),
          if (fetched.hasValue && spots.isEmpty)
            Text(
              own
                  ? 'Your posted litter spots will appear here.'
                  : 'No open litter spots in this area.',
            ),
          for (final spot in spots.take(visibleCount))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ReportCard(
                spot: spot,
                location: null,
                feed: !widget.own,
                showDirections: false,
              ),
            ),
          if (spots.length > visibleCount)
            TextButton(
              onPressed: () => setState(() => visibleCount += 10),
              child: const Text('Show more spots'),
            ),
          if (own && cursors.length > 1)
            TextButton(
              onPressed: () => setState(cursors.removeLast),
              child: const Text('Newer reports'),
            ),
          if (own && ref.watch(mine).value?.next != null)
            TextButton(
              onPressed: () =>
                  setState(() => cursors.add(ref.read(mine).requireValue.next)),
              child: const Text('Older reports'),
            ),
        ],
      ),
    );
  }
}

Future<void> _openDirections(BuildContext context, Spot spot) async {
  final point = spot.point;
  final coords = '${point.latitude},${point.longitude}';
  for (final uri in [
    Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': coords,
      'travelmode': 'walking',
    }),
    Uri.parse('geo:$coords?q=$coords'),
  ]) {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Try the next URI when the device has no handler for this one.
    }
  }
  if (context.mounted) {
    toast(context, 'Could not open directions in a maps app.');
  }
}

Future<void> _startAtSpot(
  BuildContext context,
  WidgetRef ref,
  Spot spot,
) async {
  await ref.read(activeTrackProvider.notifier).startOrResume();
  if (!context.mounted) return;
  final view = ref.read(activeTrackProvider), track = view.track;
  if (track == null ||
      ![
        TrackPhase.tracking,
        TrackPhase.locating,
        TrackPhase.gpsError,
        TrackPhase.noRoute,
        TrackPhase.paused,
      ].contains(view.phase)) {
    toast(
      context,
      view.error ?? 'Finish saving the current Plog before starting here.',
    );
    return;
  }
  await ref.read(plogDraftsProvider).linkSpot(track.id, spot);
  if (!context.mounted) return;
  ref.invalidate(linkedSpotsProvider(track.id));
  openPage(context, AppRoutes.session);
}

class _PendingReports extends ConsumerWidget {
  const _PendingReports();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queued = ref.watch(pendingSpotDraftsProvider);
    if (queued.hasError) {
      return TextButton(
        onPressed: () => ref.invalidate(pendingSpotDraftsProvider),
        child: const Text('Retry loading queued reports'),
      );
    }
    final drafts = queued.value ?? [];
    if (drafts.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final draft in drafts)
          ListTile(
            title: Text(draft.place.isEmpty ? draft.category : draft.place),
            subtitle: Text(draft.syncStatus),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: draft.discardRequested
                      ? 'Retry withdrawal'
                      : 'Retry report',
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    try {
                      await ref.read(reportSyncProvider).flush(draft);
                    } catch (_) {
                      if (context.mounted) {
                        toast(
                          context,
                          draft.discardRequested
                              ? 'Withdrawal still pending.'
                              : 'Report still queued. Check its sync status.',
                        );
                      }
                    }
                  },
                ),
                if (!draft.discardRequested)
                  IconButton(
                    tooltip: 'Discard report',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (!await confirmAction(
                            context,
                            'Discard this report?',
                            'Discard report',
                          ) ||
                          !context.mounted) {
                        return;
                      }
                      try {
                        await ref.read(reportSyncProvider).discard(draft);
                      } catch (_) {
                        if (context.mounted) {
                          toast(
                            context,
                            draft.discardRequested
                                ? 'Withdrawal queued. Ploggr will retry when connected.'
                                : 'Could not discard the report.',
                          );
                        }
                      }
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ReportCard extends ConsumerWidget {
  const _ReportCard({
    required this.spot,
    required this.location,
    required this.feed,
    required this.showDirections,
    this.quickDirections = false,
    this.distanceFromArea = false,
  });
  final Spot spot;
  final RouteFix? location;
  final bool feed, showDirections, quickDirections, distanceFromArea;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open() => openPage(context, '/spots/${spot.id}');
    final point = location;
    final distance =
        spot.distance ??
        (point == null
            ? null
            : Geolocator.distanceBetween(
                point.latitude,
                point.longitude,
                spot.point.latitude,
                spot.point.longitude,
              ));
    final status = spot.statusLabel;
    final description = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${spot.category} litter', style: AppText.label),
        const SizedBox(height: 4),
        if (distance != null || spot.place.isNotEmpty)
          Text(
            [
              if (spot.place.isNotEmpty &&
                  (!showDirections || distance == null))
                spot.place,
              if (distance != null)
                distanceFromArea && distance < 1
                    ? 'At selected location'
                    : '${formatWalkDistance(distance)} ${distanceFromArea ? 'from selected area' : 'away'}',
            ].join(' · '),
            style: AppText.caption,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: context.colors.primaryContainer,
              borderRadius: AppRadius.pill,
            ),
            child: Text(
              status,
              style: AppText.caption.copyWith(
                color: context.colors.onPrimaryContainer,
              ),
            ),
          ),
        ),
        if (spot.notes.isNotEmpty && !showDirections)
          Text(
            spot.notes,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppText.body,
          ),
      ],
    );
    return EcoCard(
      onTap: open,
      padding: const EdgeInsets.all(12),
      child: showDirections
          ? LayoutBuilder(
              builder: (context, box) {
                final nav = OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                  ),
                  onPressed: () => _openDirections(context, spot),
                  icon: const Icon(Icons.near_me_outlined, size: 17),
                  label: const Text('Navigate'),
                );
                final inline =
                    box.maxWidth >=
                    300 * MediaQuery.textScalerOf(context).scale(14) / 14;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      children: [
                        if (spot.photoCount > 0) ...[
                          SpotPhotoTile(spot.id, 0, small: true),
                          const SizedBox(width: 9),
                        ],
                        Expanded(child: description),
                        if (inline) nav,
                      ],
                    ),
                    if (!inline) nav,
                  ],
                );
              },
            )
          : feed
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                description,
                const SizedBox(height: 10),
                if (spot.photoCount > 0) SpotPhotoTile(spot.id, 0),
              ],
            )
          : Row(
              children: [
                if (spot.photoCount > 0) SpotPhotoTile(spot.id, 0, small: true),
                const SizedBox(width: 12),
                Expanded(child: description),
                if (quickDirections)
                  IconButton(
                    tooltip: 'Directions',
                    icon: const Icon(Icons.directions_outlined),
                    onPressed: () => _openDirections(context, spot),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    color: context.colors.primary,
                  ),
              ],
            ),
    );
  }
}

class OpenSightings extends ConsumerWidget {
  const OpenSightings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(exploreProvider(world))
      .when(
        loading: () => const AppLoading('Loading sightings'),
        error: (_, _) => AppNotice(
          'Could not load sightings.',
          status: AppStatus.failure,
          actionLabel: 'Retry loading sightings',
          onAction: () => ref.invalidate(exploreProvider(world)),
        ),
        data: (data) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (data.items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: AppNotice('No open sightings yet.'),
              ),
            for (final s in data.items.take(10))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: _ReportCard(
                  spot: s,
                  location: null,
                  feed: true,
                  showDirections: false,
                ),
              ),
            TextButton.icon(
              onPressed: () => switchPage(context, AppRoutes.map),
              icon: const Icon(Icons.map_outlined),
              label: const Text('Open litter map'),
            ),
          ],
        ),
      );
}

class SpotPhotoTile extends ConsumerWidget {
  const SpotPhotoTile(this.id, this.index, {super.key, this.small = false});
  final String id;
  final int index;
  final bool small;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = spotImageProvider((id, index));
    return SizedBox(
      height: small ? 76 : 180,
      width: small ? 70 : double.infinity,
      child: ref
          .watch(p)
          .when(
            data: (b) => GestureDetector(
              onTap: small ? null : () => viewPhoto(context, MemoryImage(b)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  b,
                  cacheWidth: small ? 120 : 720,
                  fit: BoxFit.cover,
                  semanticLabel: 'Litter photo ${index + 1}',
                ),
              ),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => IconButton(
              tooltip: 'Retry photo',
              onPressed: () => ref.invalidate(p),
              icon: const Icon(Icons.refresh),
            ),
          ),
    );
  }
}

class SpotPage extends ConsumerStatefulWidget {
  const SpotPage(this.id, {super.key});
  final String id;
  @override
  ConsumerState<SpotPage> createState() => _SpotPageState();
}

class _SpotPageState extends ConsumerState<SpotPage> {
  bool busy = false;
  String? notice;
  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await work();
    } catch (_) {
      if (mounted) {
        setState(
          () => notice =
              'Could not complete this action. Check the connection and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> link(Spot spot) => run(() => _startAtSpot(context, ref, spot));
  Future<void> sighting(Spot spot, {required bool missing}) => run(() async {
    final drafts = ref.read(plogDraftsProvider);
    GpsSample? gps;
    try {
      gps = await ref.read(locationSourceProvider).photographLocation();
    } catch (_) {}
    if (!mounted) return;
    final id = await drafts.queueObservation(
      spot.id,
      missing ? 'missing' : 'present',
      gps: gps,
    );
    if (!mounted) return;
    setState(() => notice = 'Saved on this phone. Waiting to sync.');
    try {
      await ref.read(observationSyncProvider).flush();
      final receipt = await drafts.observationReceipt(id);
      if (mounted) {
        setState(
          () => notice = receipt == 'verified'
              ? (missing ? 'Marked for checking.' : 'Sighting confirmed.')
              : receipt == 'rejected'
              ? 'This sighting is no longer available.'
              : 'Unverified sighting. Retry near the pin with location enabled.',
        );
      }
    } catch (_) {}
  });

  Future<void> history(Spot spot) => run(() async {
    final events = await ref.read(spotApiProvider).history(spot.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report history'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final event in events)
                ListTile(
                  title: Text(switch (event['status']) {
                    'uploading' => 'Draft received',
                    'open' => 'Published',
                    'collected' => 'Collected',
                    'hidden' => 'Hidden',
                    'withdrawn' => 'Withdrawn',
                    _ => '${event['status']}',
                  }),
                  subtitle: Text(
                    MaterialLocalizations.of(ctx).formatMediumDate(
                      DateTime.parse(event['changedAt'] as String).toLocal(),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  });

  @override
  Widget build(BuildContext context) {
    final provider = spotDetailProvider(widget.id);
    final spot = ref.watch(provider).value;
    return AppPage(
      title: 'Litter spot',
      backTo: AppRoutes.map,
      bottomAction: spot?.status == 'open'
          ? PrimaryButton(
              'Plog this spot',
              icon: Icons.directions_walk,
              onPressed: busy ? null : () => link(spot!),
            )
          : null,
      child: ref
          .watch(provider)
          .when(
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => TextButton(
              onPressed: () => ref.invalidate(provider),
              child: const Text('Spot unavailable · Retry'),
            ),
            data: (s) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  s.statusLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  '${s.category} litter',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                if (s.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(s.notes),
                  ),
                for (var i = 0; i < s.photoCount; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SpotPhotoTile(s.id, i),
                  ),
                Text(s.place.isEmpty ? 'Pinned on map' : s.place),
                if (s.createdAt != null)
                  Text(
                    'Reported ${MaterialLocalizations.of(context).formatMediumDate(s.createdAt!.toLocal())}',
                  ),
                if (s.status == 'open') ...[
                  TextButton(
                    onPressed: busy ? null : () => sighting(s, missing: false),
                    child: const Text('I can see this litter'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => sighting(s, missing: true),
                    child: const Text('I couldn’t find it'),
                  ),
                  if (s.mine)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => EditSpotPage(s),
                              ),
                            ),
                      child: const Text('Edit report'),
                    ),
                ],
                if (s.status == 'collected')
                  OutlinedButton(
                    onPressed: () =>
                        openPage(context, '${AppRoutes.report}?repeat=${s.id}'),
                    child: const Text('Report litter here again'),
                  ),
                if (s.previousReportId case final String previous)
                  TextButton(
                    onPressed: () => openPage(context, '/spots/$previous'),
                    child: const Text('View previous sighting'),
                  ),
                if (s.mine)
                  TextButton(
                    onPressed: busy ? null : () => history(s),
                    child: const Text('View report history'),
                  ),
                if (s.lastSeenAt != null)
                  Text(
                    'Last confirmed ${MaterialLocalizations.of(context).formatMediumDate(s.lastSeenAt!.toLocal())}',
                    style: AppText.caption,
                  ),
                OutlinedButton(
                  onPressed: busy ? null : () => _openDirections(context, s),
                  child: const Text('Open in Maps'),
                ),
                if (s.mine)
                  TextButton(
                    onPressed: () => run(() async {
                      if (await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Withdraw this spot?'),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Keep'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Withdraw'),
                                    ),
                                  ],
                                ),
                              ) !=
                              true ||
                          !mounted) {
                        return;
                      }
                      await ref.read(spotApiProvider).withdraw(s.id);
                      if (!mounted) return;
                      ref.invalidate(mySpotsProvider);
                      ref.invalidate(mapSpotsProvider);
                      ref.invalidate(totalsProvider);
                      ref.invalidate(exploreProvider);
                      Navigator.pop(this.context);
                    }),
                    child: const Text('Withdraw spot'),
                  )
                else
                  TextButton(
                    onPressed: () => run(() async {
                      await ref.read(spotApiProvider).flag(s.id);
                      if (mounted) {
                        setState(
                          () => notice = 'Reported for moderator review.',
                        );
                      }
                    }),
                    child: const Text('Report a concern'),
                  ),
                if (notice != null) Text(notice!),
              ],
            ),
          ),
    );
  }
}
