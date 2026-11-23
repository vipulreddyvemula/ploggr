import '../../shared/widgets/evidence_review.dart';
import 'dart:math' as math;
import '../home/activity_overview.dart';
import 'dart:async';
import '../community/field_data.dart';
import 'place_picker.dart';
import 'observation_sync.dart';
import 'report_sync.dart';
import 'spot_draft.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../shared/widgets/bottom_navigation.dart';
import '../plogging/application/active_track.dart';
import '../plogging/data/location_source.dart';
import '../plogging/data/plog_drafts.dart';
import 'spot.dart';
import 'spot_api.dart';
import 'spot_map.dart';
import 'spot_editor.dart';

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

class _ExploreState extends ConsumerState<ExplorePage> {
  MapViewport bounds = world;
  int visibleCount = 10;
  int tab = 0;
  String? selected;
  final cursors = <String?>[null];
  RouteFix? location;
  RouteFix? focus;
  String area = 'Choose area';
  int cameraKey = 0;
  double zoom = 15;
  Timer? timer;
  bool interacted = false;
  int locationRequest = 0;

  void mapInteraction() {
    interacted = true;
    locationRequest++;
  }

  @override
  void initState() {
    super.initState();
    selected = widget.initialSpot;
    WidgetsBinding.instance.addPostFrameCallback((_) => restore());
    timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent == true) {
        refreshMap();
      }
    });
  }

  @override
  void didUpdateWidget(ExplorePage old) {
    super.didUpdateWidget(old);
    if (old.initialSpot != widget.initialSpot && widget.initialSpot != null) {
      selected = widget.initialSpot;
      locationRequest++;
      interacted = false;
      restore();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void refreshMap() {
    ref.invalidate(exploreProvider(bounds));
    ref.invalidate(clusterProvider(bounds));
    if (selected != null) ref.invalidate(spotDetailProvider(selected!));
    unawaited(
      ref.read(observationSyncProvider).flush().catchError((Object _) {}),
    );
  }

  Future<void> restore() async {
    if (widget.own) return;
    try {
      final id = widget.initialSpot;
      final saved = id == null
          ? await rememberedArea(ref.read(plogDraftsProvider))
          : null;
      final spot = id == null
          ? null
          : await ref.read(spotApiProvider).detail(id);
      if (!mounted || interacted || widget.initialSpot != id) return;
      if (saved != null || spot != null) {
        showArea((
          point: spot?.point ?? saved!.point,
          name: spot?.place ?? saved!.name,
        ));
      } else {
        final cached = await ref.read(locationSourceProvider).cachedPoint();
        if (mounted &&
            !interacted &&
            widget.initialSpot == id &&
            cached != null) {
          showArea((point: cached, name: 'Last known area'));
        }
      }
    } catch (_) {}
  }

  void showArea(ChosenPlace p) {
    final lat = p.point.latitude, lon = p.point.longitude;
    setState(() {
      focus = p.point;
      area = p.name.isEmpty ? 'Pinned area' : p.name;
      cameraKey++;
      bounds = (
        south: (lat - .04).clamp(-90, 90).toDouble(),
        north: (lat + .04).clamp(-90, 90).toDouble(),
        west: (lon - .04).clamp(-180, 180).toDouble(),
        east: (lon + .04).clamp(-180, 180).toDouble(),
      );
    });
  }

  Future<void> pickArea() async {
    mapInteraction();
    final p = await choosePlace(
      context,
      title: 'Choose map area',
      initial: focus == null ? null : (point: focus!, name: area),
    );
    if (p != null && mounted) {
      zoom = 15;
      showArea(p);
    }
  }

  bool locating = false;
  String? notice;
  Future<void> locate() async {
    mapInteraction();
    final request = locationRequest;
    setState(() => locating = true);
    try {
      final fix = await ref.read(locationSourceProvider).current();
      if (!mounted || request != locationRequest) return;
      location = (latitude: fix.latitude, longitude: fix.longitude);
      zoom = 15;
      notice = null;
      showArea((point: location!, name: 'Near me'));
    } catch (_) {
      if (mounted && request == locationRequest) {
        setState(
          () => notice =
              'Location unavailable. Explore the map or choose a spot from the list.',
        );
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final community = widget.community;
    final own = widget.own || (community && tab == 1);
    final explore = !community && !widget.own;
    final mapView = explore && tab == 0;
    final nearby = exploreProvider(bounds);
    final mine = mySpotsProvider(cursors.last);
    final fetched = own
        ? ref.watch(mine).whenData((v) => v.items)
        : ref.watch(nearby).whenData((v) => v.items);
    final list = fetched.value ?? [];
    final clusters = explore && mapView
        ? ref.watch(clusterProvider(bounds)).value
        : null;
    final marks = <String, RouteFix>{for (final s in list) s.id: s.point};
    final counts = <String, int>{};
    if (clusters != null) {
      marks.clear();
      for (final c in clusters) {
        final id =
            c['id'] as String? ?? 'cluster-${c['latitude']}-${c['longitude']}';
        marks[id] = (
          latitude: (c['latitude'] as num).toDouble(),
          longitude: (c['longitude'] as num).toDouble(),
        );
        counts[id] = c['count'] as int;
      }
    }
    final first =
        list.where((s) => s.id == selected).firstOrNull ??
        (selected == null
            ? null
            : ref.watch(spotDetailProvider(selected!)).value);

    if (first != null) marks[first.id] = first.point;
    final spots = [?first, ...list.where((s) => s.id != first?.id)];
    return AppPage(
      title: community
          ? 'Community'
          : own
          ? 'My reports'
          : 'Litter Map',
      root: explore || community,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
      backTo: own ? AppRoutes.profile : AppRoutes.home,
      bottomNavigation: const BottomNavBar(),
      actions: [
        IconButton(
          tooltip: 'Refresh spots',
          onPressed: () => own ? ref.invalidate(mine) : refreshMap(),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (explore)
            OutlinedButton.icon(
              onPressed: pickArea,
              icon: const Icon(Icons.search),
              label: Text(area, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          if (!widget.own) ...[
            FilterTabs(
              labels: community
                  ? const ['Sightings', 'My reports']
                  : const ['Map', 'List'],
              selected: tab,
              onChanged: (value) => setState(() {
                tab = value;
                visibleCount = 10;
              }),
            ),
            const SizedBox(height: 12),
          ],
          if (explore &&
              (bounds != world || fetched.hasValue || fetched.hasError))
            Offstage(
              offstage: !mapView,
              child: ClipRRect(
                borderRadius: AppRadius.card,
                child: SpotMap(
                  height: (MediaQuery.sizeOf(context).height * .42).clamp(
                    160.0,
                    425.0,
                  ),
                  points: marks,
                  counts: counts,
                  categories: {
                    for (final spot in spots) spot.id: spot.category,
                  },
                  selected: selected,
                  focus: focus,
                  zoom: zoom,
                  cameraKey: cameraKey,
                  onPan: mapInteraction,
                  onUnavailable: () {
                    if (mounted) {
                      setState(() {
                        tab = 1;
                        notice =
                            'Map unavailable. Showing sightings in this area.';
                      });
                    }
                  },
                  onViewport: (v) {
                    if (mounted && tab == 0 && bounds != v) {
                      setState(() {
                        bounds = v;
                        visibleCount = 10;
                      });
                    }
                  },
                  onSelect: (id) {
                    mapInteraction();
                    if ((counts[id] ?? 1) > 1) {
                      setState(() {
                        focus = marks[id];
                        final width = (bounds.east - bounds.west + 360) % 360;
                        zoom =
                            (math.log(360 / (width <= 0 ? 360 : width)) /
                                        math.ln2 +
                                    3)
                                .clamp(3, 20);
                        cameraKey++;
                        if (zoom >= 20) {
                          tab = 1;
                          notice = 'Choose a sighting from this location.';
                        }
                      });
                    } else {
                      setState(() => selected = id);
                    }
                  },
                ),
              ),
            ),
          if (explore)
            Wrap(
              children: [
                TextButton.icon(
                  onPressed: locating ? null : locate,
                  icon: const Icon(Icons.my_location),
                  label: Text(locating ? 'Finding location…' : 'Near Me'),
                ),
                if (mapView && (first != null || focus != null))
                  TextButton.icon(
                    onPressed: () => setState(() {
                      focus = first?.point ?? focus;
                      cameraKey++;
                    }),
                    icon: const Icon(Icons.center_focus_strong_outlined),
                    label: const Text('Recenter'),
                  ),
              ],
            ),
          if (notice != null) AppNotice(notice!, status: AppStatus.warning),
          if (own) const _PendingReports(),
          if (mapView) const SizedBox(height: 12),
          if (!own && ref.watch(nearby).value?.truncated == true)
            Text(
              community
                  ? 'Showing a selection of open sightings. Explore the map for a specific area.'
                  : 'Zoom in to see more spots.',
              style: AppText.caption,
            ),
          if (fetched.isLoading) const AppLoading('Finding litter sightings'),
          if (fetched.hasError)
            TextButton(
              onPressed: () =>
                  own ? ref.invalidate(mine) : ref.invalidate(nearby),
              child: const Text('Could not load spots · Retry'),
            ),
          if (fetched.hasValue && spots.isEmpty) ...[
            Text(
              own
                  ? 'Your posted litter spots will appear here.'
                  : 'No open litter spots in this area.',
            ),
            TextButton.icon(
              onPressed: () => openPage(context, AppRoutes.scan),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Log litter'),
            ),
          ],
          for (final spot in spots.take(mapView ? 1 : visibleCount))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ReportCard(
                spot: spot,
                location: location,
                feed: community,
                showDirections: mapView,
              ),
            ),
          if (!mapView && spots.length > visibleCount)
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
  try {
    if (await launchUrl(
      Uri.parse('geo:$coords?q=$coords'),
      mode: LaunchMode.externalApplication,
    )) {
      return;
    }
  } catch (_) {
    // Android also throws when no activity can handle geo URIs.
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
  });
  final Spot spot;
  final RouteFix? location;
  final bool feed, showDirections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open() => openPage(context, '/spots/${spot.id}');
    final point = location;
    final distance = point == null
        ? null
        : Geolocator.distanceBetween(
            point.latitude,
            point.longitude,
            spot.point.latitude,
            spot.point.longitude,
          ).round();
    final status = spot.statusLabel;
    final description = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${spot.category} litter', style: AppText.label),
        const SizedBox(height: 4),
        Text(
          [
            status,
            if (spot.place.isNotEmpty) spot.place,
            if (distance != null) '$distance m away',
          ].join(' · '),
          style: AppText.caption,
        ),
        if (spot.notes.isNotEmpty)
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
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SpotPhotoTile(spot.id, 0, small: true),
                    const SizedBox(width: 12),
                    Expanded(child: description),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: open,
                      child: const Text('View report'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _openDirections(context, spot),
                      icon: const Icon(Icons.directions_outlined),
                      label: const Text('Directions'),
                    ),
                    if (spot.status == 'open')
                      FieldAction(
                        'Plog this spot',
                        () => _startAtSpot(context, ref, spot),
                        icon: Icons.directions_walk,
                      ),
                  ],
                ),
              ],
            )
          : feed
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                description,
                const SizedBox(height: 10),
                SpotPhotoTile(spot.id, 0),
              ],
            )
          : Row(
              children: [
                SpotPhotoTile(spot.id, 0, small: true),
                const SizedBox(width: 12),
                Expanded(child: description),
                if (!showDirections)
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
                  feed: false,
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
                      ref.invalidate(clusterProvider);
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
