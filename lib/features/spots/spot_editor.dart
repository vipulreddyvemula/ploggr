import '../../shared/widgets/evidence_review.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../core/network/protected_api.dart';
import 'report_sync.dart';
import 'place_picker.dart';
import 'photo_picker.dart';
import '../plogging/data/photo_capture.dart';
import '../plogging/data/plog_drafts.dart';
import 'live_camera.dart';
import 'spot.dart';
import 'spot_api.dart';
import 'spot_map.dart';
import '../plogging/data/location_source.dart';
import 'spot_draft.dart';
import '../../shared/widgets/bottom_navigation.dart';

class SpotEditor extends ConsumerWidget {
  const SpotEditor({
    super.key,
    this.openCamera = false,
    this.seed,
    this.repeatedReport,
  });
  final String? repeatedReport;
  final bool openCamera;
  final Uint8List? seed;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const key = 'sighting';
    return ref
        .watch(spotDraftProvider(key))
        .when(
          data: (draft) => _Editor(
            key: ValueKey(draft.id),
            draft: draft,
            openCamera: openCamera,
            seed: seed,
            repeatedReport: repeatedReport,
          ),
          loading: () => const AppPage(
            title: 'Report litter',
            root: true,
            bottomNavigation: BottomNavBar(),
            child: AppLoading('Opening report draft'),
          ),
          error: (_, _) => AppPage(
            title: 'Report litter',
            root: true,
            bottomNavigation: const BottomNavBar(),
            child: AppNotice(
              'Could not open the report draft.',
              status: AppStatus.failure,
              actionLabel: 'Retry opening draft',
              onAction: () => ref.invalidate(spotDraftProvider(key)),
            ),
          ),
        );
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({
    super.key,
    required this.draft,
    required this.openCamera,
    this.seed,
    this.repeatedReport,
  });
  final String? repeatedReport;
  final SpotDraft draft;
  final bool openCamera;
  final Uint8List? seed;
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  SpotDraft get d => widget.draft;
  late final notes = TextEditingController(text: d.notes);
  late final picker = ref.read(photoPickerProvider);
  late final recovery = PhotoRecovery.open(
    ref.read(plogDraftsProvider).scope,
    d.id,
  );
  bool busy = false, preparing = false;
  int step = 0;
  double? upload;
  String? message;
  AppStatus messageStatus = AppStatus.failure;
  String? selectedPhoto;
  Spot? nearbyReport;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || d.locked) return;
      var recovered = false;
      await run(() async {
        recovered = await recoverSelection(await recovery);
        if (mounted && !recovered && d.replacingPhoto != null) {
          d.replacingPhoto = null;
          await d.save();
        }
      });
      if (!mounted || recovered || message != null) return;
      if (widget.repeatedReport != null &&
          d.photos.isEmpty &&
          d.point == null &&
          d.notes.isEmpty) {
        await run(() async {
          final old = await ref
              .read(spotApiProvider)
              .detail(widget.repeatedReport!);
          if (!mounted || old.status != 'collected') return;
          d.point = old.point;
          d.place = old.place;
          d.category = old.category;
          d.previousReportId = old.id;
          await d.save();
        });
      } else if (widget.seed != null) {
        await run(
          () => addFile(
            XFile.fromData(widget.seed!),
            capture: PhotoCapture(PhotoSource.unknown, DateTime.now().toUtc()),
          ),
        );
      } else if (widget.openCamera && d.photos.isEmpty) {
        await capture();
      }
    });
  }

  @override
  void dispose() {
    notes.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
      messageStatus = AppStatus.failure;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        message = e is FormatException
            ? e.message
            : e is StateError
            ? e.message
            : 'Could not finish. Your draft is on this device. Retry when ready.';
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addFile(XFile file, {PhotoCapture? capture}) async {
    final photo = await preparePhoto(file, capture: capture);
    final id = const Uuid().v4();
    await d.add((
      id: id,
      type: 'image/jpeg',
      bytes: photo.bytes,
      capture: photo.capture,
    ));
    selectedPhoto = id;
  }

  Future<bool> recoverSelection(PhotoRecovery store) async {
    final photo = await store.recover(picker);
    if (photo == null || !mounted) return false;
    await saveSelection(store, photo);
    return true;
  }

  Future<void> saveSelection(PhotoRecovery store, CameraPhoto photo) async {
    if (d.photos.containsKey(photo.id)) {
      await store.clear();
      return;
    }
    late final PreparedPhoto prepared;
    if (mounted) setState(() => preparing = true);
    try {
      prepared = await preparePhoto(photo.file, capture: photo.capture);
    } on FormatException {
      await store.clear();
      d.replacingPhoto = null;
      await d.save();
      rethrow;
    } finally {
      if (mounted) setState(() => preparing = false);
    }
    final sample = prepared.capture.gps;
    if (d.point == null &&
        sample != null &&
        sample.freshAt(prepared.capture.capturedAt)) {
      d.point = sample.point;
      d.locationSource = 'gps';
    }
    await d.add((
      id: photo.id,
      type: 'image/jpeg',
      bytes: prepared.bytes,
      capture: prepared.capture,
    ), replace: d.replacingPhoto);
    selectedPhoto = photo.id;
    await store.clear();
  }

  Future<void> pin() => run(() async {
    final place = await choosePlace(
      context,
      initial: d.point == null ? null : (point: d.point!, name: d.place),
      initialGps: d.locationSource == 'gps',
      onLocationSource: (gps) => d.locationSource = gps ? 'gps' : 'manual',
    );
    if (place == null) return;
    d.point = place.point;
    d.place = place.name;
    d.confirmed = true;
    await d.save();
    nearbyReport = null;
    try {
      final point = place.point;
      final reports = await ref
          .read(spotApiProvider)
          .nearby(point.latitude, point.longitude)
          .timeout(const Duration(seconds: 2));
      if (mounted) {
        nearbyReport = reports
            .where(
              (report) =>
                  report.category == d.category &&
                  Geolocator.distanceBetween(
                        report.point.latitude,
                        report.point.longitude,
                        point.latitude,
                        point.longitude,
                      ) <=
                      30,
            )
            .firstOrNull;
      }
    } catch (_) {
      // A manual pin and offline draft still work without report suggestions.
    }
  });

  Future<void> capture() => selectPhoto();

  Future<void> selectPhoto({bool gallery = false, String? replacement}) =>
      run(() async {
        final store = await recovery;
        if (!mounted) return;
        if (await recoverSelection(store) || !mounted) return;
        d.replacingPhoto = replacement;
        await d.save();
        if (!mounted) return;
        Object? result = gallery
            ? 'gallery'
            : await Navigator.push<Object?>(
                context,
                MaterialPageRoute(builder: (_) => LiveCamera(recovery: store)),
              );
        if (!mounted) return;
        if (result == 'gallery') result = await store.pickGallery(picker);
        if (result is CameraPhoto) {
          await saveSelection(store, result);
        } else if (replacement != null) {
          d.replacingPhoto = null;
          await d.save();
        }
      });

  Future<void> replacePhoto(String id) async {
    final gallery = await choosePhotoReplacement(context);
    if (gallery != null && mounted) {
      await selectPhoto(gallery: gallery, replacement: id);
    }
  }

  Future<void> removePhoto(String id) async {
    if (await confirmPhotoRemoval(context) && mounted) {
      await run(() => d.remove(id));
    }
  }

  Future<void> submit() => run(() async {
    if (d.point == null || !d.confirmed || d.photos.isEmpty) return;
    // The editor can be replaced while a publish completes. Keep the
    // originating route so late replies never redirect another screen.
    final route = ModalRoute.of(context);
    final router = GoRouter.of(context);
    final origin = router.state.pageKey;
    final draft = d;
    try {
      final id = await ref
          .read(reportSyncProvider)
          .submit(
            draft,
            onProgress: (sent, total) {
              if (mounted && total > 0) {
                setState(() => upload = (sent / total).clamp(0, 1));
              }
            },
          );
      if (id != null &&
          route?.isCurrent == true &&
          router.state.pageKey == origin) {
        router.go('${AppRoutes.report}/published/$id', extra: true);
      }
    } on ProtectedApiFailure catch (error) {
      if (error.status == null || (error.status ?? 0) >= 500) {
        messageStatus = AppStatus.pending;
        message = 'Report pending. Ploggr will retry when connected.';
      } else if (error.status == 401) {
        messageStatus = AppStatus.warning;
        message = 'Sign in to the same account to retry this report.';
      } else if ([400, 413, 415, 422].contains(error.status)) {
        draft.locked = false;
        await draft.save();
        await draft.setSyncFailure(null);
        message = 'Check the report details and replace any unsupported photo.';
      } else if (error.status == 409) {
        message = 'The server has a different version of this report.';
      } else {
        rethrow;
      }
    } finally {
      if (mounted) setState(() => upload = null);
    }
  });

  Future<void> retryWithdrawal() => run(() async {
    try {
      await ref.read(reportSyncProvider).flush(d);
    } catch (_) {
      messageStatus = AppStatus.pending;
      message = 'Withdrawal queued. Ploggr will retry when connected.';
    }
  });

  @override
  Widget build(BuildContext context) {
    final point = d.point;
    final queued = d.locked || d.discardRequested;
    final stage = queued ? 3 : step;
    final editable = !queued && !busy;
    final feedback = message ?? (queued ? d.syncStatus : null);
    final ids = d.photos.keys.toList();
    final photo = ids.contains(selectedPhoto) ? selectedPhoto : ids.firstOrNull;
    final index = ids.indexOf(photo ?? '');
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;

    final (label, action) = switch (stage) {
      0 when ids.isEmpty => ('Add photo', capture),
      0 => ('Continue to details', () => setState(() => step = 1)),
      1 => ('Continue to location', () => setState(() => step = 2)),
      2 when !d.confirmed => ('Choose spot', pin),
      2 => ('Review report', () => setState(() => step = 3)),
      _ when d.discardRequested => ('Retry withdrawal', retryWithdrawal),
      _ => (queued ? 'Retry post' : 'Post report', submit),
    };

    return PopScope(
      canPop: step == 0 || queued,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && step > 0 && !queued && !busy) setState(() => step--);
      },
      child: AppPage(
        title: 'Report litter',
        root: true,
        bottomNavigation: const BottomNavBar(),
        bottomAction: PrimaryButton(
          preparing
              ? 'Preparing photo…'
              : busy
              ? 'Saving…'
              : label,
          onPressed:
              busy ||
                  (stage == 3 &&
                      !d.discardRequested &&
                      (!d.confirmed || ids.isEmpty))
              ? null
              : action,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!queued)
              Row(
                children: [
                  if (stage > 0)
                    IconButton(
                      tooltip: 'Previous report step',
                      onPressed: busy ? null : () => setState(() => step--),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  Expanded(
                    child: Text(
                      'Step ${stage + 1} of 4 · ${['Photos', 'Details', 'Location', 'Review'][stage]}',
                      style: AppText.label,
                    ),
                  ),
                ],
              ),
            if (feedback != null)
              AppNotice(
                queued && busy ? 'Uploading report…' : feedback,
                status: message != null
                    ? messageStatus
                    : d.discardRequested ||
                          (d.syncFailure?.canRetryAutomatically ?? true)
                    ? AppStatus.pending
                    : AppStatus.failure,
              ),
            if (preparing) const AppLoading('Preparing photo'),
            if (queued && busy)
              LinearProgressIndicator(
                value: upload,
                semanticsLabel: 'Uploading report',
              ),
            if (stage == 0 || stage == 3)
              EvidenceReview(
                title: 'Report photos',
                photos: ids,
                selected: photo,
                onSelect: (id) => setState(() => selectedPhoto = id),
                image: (id, thumbnail) => EvidenceImage(
                  image: FileImage(d.file(id)),
                  label: 'report photo ${ids.indexOf(id) + 1}',
                  thumbnail: thumbnail,
                ),
                status: const Padding(
                  padding: EdgeInsets.only(top: AppSpace.sm),
                  child: Text('Saved on this device', style: AppText.caption),
                ),
                actions: [
                  if (stage == 0 && photo != null) ...[
                    TextButton(
                      onPressed: editable ? () => replacePhoto(photo) : null,
                      child: const Text('Retake or replace'),
                    ),
                    TextButton(
                      onPressed: editable ? () => removePhoto(photo) : null,
                      child: const Text('Remove photo'),
                    ),
                    if (ids.length > 1) ...[
                      IconButton(
                        tooltip: 'Move photo earlier',
                        onPressed: editable && index > 0
                            ? () => run(() => d.movePhoto(photo, -1))
                            : null,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      IconButton(
                        tooltip: 'Move photo later',
                        onPressed: editable && index < ids.length - 1
                            ? () => run(() => d.movePhoto(photo, 1))
                            : null,
                        icon: const Icon(Icons.arrow_forward),
                      ),
                    ],
                  ],
                ],
              ),
            if (stage == 0 && ids.length < 6)
              Wrap(
                spacing: AppSpace.sm,
                children: [
                  TextButton.icon(
                    onPressed: editable ? capture : null,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Take photo'),
                  ),
                  TextButton.icon(
                    onPressed: editable
                        ? () => selectPhoto(gallery: true)
                        : null,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Choose photo'),
                  ),
                ],
              ),
            if (stage == 1) ...[
              const SectionTitle('What kind of litter is it?'),
              LitterTypePicker(
                selected: d.category,
                onChanged: editable
                    ? (category) => run(() async {
                        d.category = category;
                        nearbyReport = null;
                        await d.save();
                      })
                    : null,
              ),
              const SectionTitle('Description'),
              TextField(
                controller: notes,
                enabled: editable,
                maxLength: 250,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
                onChanged: (value) {
                  d.notes = value;
                  unawaited(
                    d.save().catchError((Object _) {
                      if (mounted) {
                        setState(() {
                          message = 'Could not save notes on this device.';
                          messageStatus = AppStatus.failure;
                        });
                      }
                    }),
                  );
                },
              ),
            ],
            if (stage == 2 || stage == 3) ...[
              SectionTitle(
                stage == 3 ? '${d.category} litter' : 'Where is the litter?',
              ),
              if (stage == 3 && d.notes.trim().isNotEmpty) Text(d.notes.trim()),
              if (d.confirmed && point != null && !keyboard)
                ClipRRect(
                  borderRadius: AppRadius.card,
                  child: SpotMap(
                    key: ValueKey(point),
                    focus: point,
                    points: {'selected': point},
                    height: 144,
                    interactive: false,
                  ),
                ),
              if (stage == 2)
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(
                    d.confirmed ? d.place : 'Choose a spot on the map',
                  ),
                  subtitle: const Text(
                    'Search a place or move the pin to the litter.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: editable ? pin : null,
                )
              else if (d.confirmed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                  child: Text(d.place),
                ),
              if (stage == 2)
                if (nearbyReport case final Spot matching)
                  OutlinedButton.icon(
                    onPressed: () => openPage(context, '/spots/${matching.id}'),
                    icon: const Icon(Icons.near_me_outlined),
                    label: const Text('View a similar nearby report'),
                  ),
              if (stage == 3)
                const AppNotice(
                  'Anyone viewing the report can see its photos, category, notes and pinned location.',
                ),
            ],
            if ((d.locked || d.discardRequested) && !busy)
              TextButton(
                onPressed: () => run(() async {
                  await d.detach();
                  if (mounted) {
                    ref.invalidate(pendingSpotDraftsProvider);
                    ref.invalidate(spotDraftProvider('sighting'));
                  }
                }),
                child: const Text('Start another report'),
              ),
            if (!busy && !d.discardRequested)
              TextButton(
                onPressed: () async {
                  final discard = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Discard this report?'),
                      content: Text(
                        d.locked
                            ? 'This will also withdraw the report if it has already reached the server.'
                            : 'The draft and its photos will be removed from this phone.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Keep draft'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Discard draft'),
                        ),
                      ],
                    ),
                  );
                  if (discard == true && mounted) {
                    await run(() async {
                      if (d.locked) {
                        try {
                          await ref.read(reportSyncProvider).discard(d);
                        } catch (_) {
                          if (!d.discardRequested) rethrow;
                          messageStatus = AppStatus.pending;
                          message =
                              'Withdrawal queued. Ploggr will retry when connected.';
                          return;
                        }
                      } else {
                        await d.clear();
                      }
                      if (mounted) {
                        ref.invalidate(spotDraftProvider('sighting'));
                      }
                    });
                  }
                },
                child: const Text('Discard local draft'),
              ),
          ],
        ),
      ),
    );
  }
}

class ReportPublishedPage extends StatelessWidget {
  const ReportPublishedPage(this.id, {super.key});
  final String id;

  @override
  Widget build(BuildContext context) {
    final map = Uri(path: AppRoutes.map, queryParameters: {'spot': id});
    return AppPage(
      title: 'Report published',
      backTo: AppRoutes.map,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppNotice(
            'Your sighting is visible to other ploggers.',
            status: AppStatus.success,
          ),
          const SizedBox(height: AppSpace.lg),
          PrimaryButton(
            'View published report',
            onPressed: () => openPage(context, '/spots/$id'),
          ),
          TextButton(
            onPressed: () => switchPage(context, map.toString()),
            child: const Text('Show on map'),
          ),
        ],
      ),
    );
  }
}

class EditSpotPage extends ConsumerStatefulWidget {
  const EditSpotPage(this.spot, {super.key});
  final Spot spot;
  @override
  ConsumerState<EditSpotPage> createState() => _EditSpotState();
}

class _EditSpotState extends ConsumerState<EditSpotPage> {
  late final notes = TextEditingController(text: widget.spot.notes);
  late RouteFix point = widget.spot.point;
  late String place = widget.spot.place;
  late String category = widget.spot.category;
  late bool gps = widget.spot.locationSource == 'gps';
  bool saving = false;
  String? error;

  @override
  void dispose() {
    notes.dispose();
    super.dispose();
  }

  Future<void> movePin() async {
    final selected = await choosePlace(
      context,
      initial: (point: point, name: place),
      initialGps: gps,
      onLocationSource: (value) => gps = value,
    );
    if (selected != null && mounted) {
      setState(() {
        point = selected.point;
        place = selected.name;
      });
    }
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final api = ref.read(spotApiProvider);
      await api.edit(
        widget.spot.id,
        SpotDetails(
          point,
          category,
          notes.text.trim(),
          place,
          gps ? 'gps' : 'manual',
        ),
      );
      if (!mounted) return;
      ref.invalidate(spotDetailProvider(widget.spot.id));
      ref.invalidate(mySpotsProvider);
      ref.invalidate(exploreProvider);
      ref.invalidate(clusterProvider);
      Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = 'Could not save the report changes. Retry when connected.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AppPage(
    title: 'Edit litter report',
    bottomAction: PrimaryButton(
      'Save changes',
      onPressed: saving ? null : save,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LitterTypePicker(
          selected: category,
          onChanged: saving
              ? null
              : (value) => setState(() => category = value),
        ),
        OutlinedButton.icon(
          onPressed: saving ? null : movePin,
          icon: const Icon(Icons.edit_location_alt_outlined),
          label: const Text('Correct map pin'),
        ),
        TextField(
          controller: notes,
          enabled: !saving,
          maxLength: 250,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Notes (optional)'),
        ),
        if (error != null) Text(error!),
      ],
    ),
  );
}
