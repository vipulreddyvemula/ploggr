import '../../shared/widgets/evidence_review.dart';
import '../spots/spot_draft.dart';
import '../spots/live_camera.dart';
import '../spots/photo_picker.dart';
import '../spots/spot_api.dart';
import '../spots/spot.dart';
import '../spots/explore_page.dart' show SpotPhotoTile;
import '../spots/place_picker.dart';
import 'data/location_source.dart';
import 'data/photo_capture.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'data/plog_drafts.dart';
import '../../shared/widgets/ploggr_ui.dart';

const _maxBytes = 8 * 1024 * 1024;

Future<String> photoType(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > _maxBytes) {
    throw const FormatException('Choose a photo of 8 MiB or less.');
  }
  final type = bytes.length > 8 && bytes[0] == 0xff && bytes[1] == 0xd8
      ? 'image/jpeg'
      : bytes.length > 8 &&
            bytes[0] == 137 &&
            bytes[1] == 80 &&
            bytes[2] == 78 &&
            bytes[3] == 71
      ? 'image/png'
      : null;
  if (type == null) throw const FormatException('Choose a JPEG or PNG photo.');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final image = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (image.width * image.height > 32000000) {
        throw const FormatException('Choose a smaller photo.');
      }
      final landscape = image.width >= image.height;
      final codec = await image.instantiateCodec(
        targetWidth: landscape && image.width > 96 ? 96 : null,
        targetHeight: !landscape && image.height > 96 ? 96 : null,
      );
      try {
        if (codec.frameCount != 1) {
          throw const FormatException('Choose a still photograph.');
        }
        (await codec.getNextFrame()).image.dispose();
      } finally {
        codec.dispose();
      }
    } finally {
      image.dispose();
    }
  } finally {
    buffer.dispose();
  }
  return type;
}

final _thumbnail = FutureProvider.autoDispose
    .family<Uint8List, (String, String)>(
      (ref, key) async =>
          (await ref.watch(plogDraftsProvider).readPhoto(key.$1, key.$2)).bytes,
      retry: (_, _) => null,
    );

class GarbagePhotos extends ConsumerStatefulWidget {
  const GarbagePhotos(
    this.plogId, {
    super.key,
    this.onSave,
    this.inlineAdd = true,
    this.onAvailable,
    this.editing = true,
    this.uploads = const {},
  });
  final bool inlineAdd, editing;
  final Map<String, double> uploads;
  final ValueChanged<bool>? onAvailable;
  final String plogId;
  final VoidCallback? onSave;
  @override
  ConsumerState<GarbagePhotos> createState() => GarbagePhotosState();
}

class GarbagePhotosState extends ConsumerState<GarbagePhotos> {
  late final picker = ref.read(photoPickerProvider);
  late final drafts = ref.read(plogDraftsProvider);
  List<String> ids = const [];
  List<Map<String, Object?>> observations = const [];
  String? status, selectedPhoto;
  bool preparing = false;
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    refresh(recover: true);
  }

  Future<void> refresh({bool recover = false}) async {
    final id = widget.plogId;
    try {
      final pending = recover ? await drafts.pendingPhoto(id) : null;
      if (pending != null) {
        try {
          final recovery = await PhotoRecovery.open(drafts.scope, pending);
          final shot = await recovery.recover(picker);
          if (shot == null) {
            await drafts.removePhoto(id, pending);
          } else {
            try {
              await saveSelection(id, pending, shot);
              status = 'Recovered your pickup photo.';
            } on FormatException {
              await recovery.clear();
              await drafts.removePhoto(id, pending);
              rethrow;
            }
            await recovery.clear();
          }
        } catch (e) {
          error = e is FormatException
              ? e.message
              : 'Could not recover the pickup photo. Check device storage and retry.';
        }
      }
      final previous = await SpotDraft.previousPickup(drafts.scope, id);
      if (previous != null) {
        try {
          if (previous.photos.isNotEmpty) {
            await drafts.recoverPickupPhotos(id, await previous.readPhotos());
            status = 'Recovered pickup photos from your earlier draft.';
          }
          await previous.clear();
        } on StateError catch (e) {
          error = e.message;
        }
      }
      ids = await drafts.photoIds(id);
      observations = await drafts.observations(plog: id);
    } catch (_) {
      error = 'Could not read your Plog draft.';
    }
    if (mounted) {
      setState(() => busy = false);
      widget.onAvailable?.call(ids.length < 6);
    }
  }

  Future<PhotoCapture> saveSelection(
    String plogId,
    String photoId,
    CameraPhoto shot,
  ) async {
    if (mounted) setState(() => preparing = true);
    try {
      final prepared = await preparePhoto(shot.file, capture: shot.capture);
      await drafts.storePhoto(
        plogId,
        photoId,
        'image/jpeg',
        prepared.bytes,
        capture: prepared.capture,
      );
      return prepared.capture;
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> add({bool gallery = false, String? replacing}) async {
    if (busy || !widget.editing) return;
    final activity = widget.plogId;
    widget.onAvailable?.call(false);
    setState(() {
      busy = true;
      error = null;
      status = null;
    });
    String? pending;
    var preserve = false;
    var retryRecovery = false;
    try {
      if (await drafts.pendingPhoto(activity) != null) {
        retryRecovery = true;
        return;
      }
      pending = await drafts.reservePhoto(activity, replacing: replacing);
      final recovery = await PhotoRecovery.open(drafts.scope, pending);
      if (!mounted) return;
      Object? result = gallery
          ? 'gallery'
          : await Navigator.push<Object?>(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    LiveCamera(recovery: recovery, title: 'Add pickup'),
              ),
            );
      if (result == 'gallery') {
        if (!mounted) return;
        result = await recovery.pickGallery(picker);
      }
      if (result is! CameraPhoto) return;
      preserve = true;
      if (!mounted) return;
      final photo = pending;
      late final PhotoCapture capture;
      try {
        capture = await saveSelection(activity, photo, result);
      } on FormatException {
        preserve = false;
        await recovery.clear();
        rethrow;
      }
      pending = null;
      await recovery.clear();
      if (!mounted) return;
      final saved = await drafts.photoIds(activity);
      if (!mounted) return;
      setState(() {
        ids = saved;
        selectedPhoto = photo;
        status = replacing == null
            ? 'Pickup saved on this phone.'
            : 'Replacement saved on this phone.';
      });
      final sample = capture.gps;
      await match(
        photo,
        fix: sample != null && sample.freshAt(capture.capturedAt)
            ? sample.point
            : null,
      );
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : e is StateError
              ? e.message
              : preserve
              ? 'Could not save the photo. Check device storage and tap Add pickup to retry.'
              : 'Could not add this photo. Try again.',
        );
      }
    } finally {
      if (pending != null && !preserve) {
        try {
          await drafts.removePhoto(activity, pending);
        } catch (_) {
          error ??=
              'Could not clear the photo selection. Retry adding the photo.';
        }
      }
      if (mounted) await refresh(recover: retryRecovery);
    }
  }

  Future<void> match(String photo, {RouteFix? fix, bool choose = false}) async {
    final activity = widget.plogId;
    final api = ref.read(spotApiProvider);
    final spots = <String, Spot>{};
    if (choose) {
      final place = await choosePlace(context, title: 'Find a reported spot');
      if (place == null) return;
      fix = place.point;
    }
    try {
      final linked = await drafts.pickups(activity);
      final done = (await drafts.observations(
        plog: activity,
      )).map((o) => o['report']).toSet();
      for (final p in linked) {
        final id = p['report_id'] as String;
        if (!done.contains(id)) {
          spots[id] = Spot.fromJson({
            ...p,
            'id': id,
            'mine': false,
            'status': 'open',
            'photoCount': 1,
          });
        }
      }
      if (fix != null && (spots.isEmpty || choose)) {
        for (final s
            in await api
                .nearby(fix.latitude, fix.longitude)
                .timeout(const Duration(seconds: 3))) {
          if (!done.contains(s.id)) spots[s.id] = s;
        }
      }
    } catch (_) {
      if (choose && mounted) {
        setState(() => status = 'Could not load spots. Your pickup is saved.');
      }
    }
    if (!mounted) return;
    if (spots.isEmpty) {
      if (choose) {
        setState(
          () => status = 'No open spots near that pin. Your pickup is saved.',
        );
      }
      return;
    }
    final action = await showModalBottomSheet<(Spot, String)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Did you clean up this spot?', style: AppText.title),
            for (final spot in spots.values) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SpotPhotoTile(spot.id, 0, small: true),
                title: Text('${spot.category} litter'),
                subtitle: Text(
                  [
                    spot.place,
                    spot.notes,
                    spot.statusLabel,
                  ].where((s) => s.isNotEmpty).join(' · '),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, (spot, 'cleaned')),
                child: const Text('Yes, it’s clean'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx, (spot, 'remains')),
                child: const Text('Some litter remains'),
              ),
            ],
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Different spot or skip'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    await drafts.queueObservation(
      action.$1.id,
      action.$2,
      plog: activity,
      photo: photo,
    );
    if (!mounted) return;
    setState(
      () => status =
          'Cleanup claim pending. It will be checked when this Plog saves.',
    );
  }

  Future<void> remove(String id) async {
    if (!await confirmPhotoRemoval(context) || !mounted || busy) return;
    setState(() => busy = true);
    try {
      await drafts.removePhoto(widget.plogId, id);
    } catch (_) {
      error = 'Could not remove photo.';
    }
    if (mounted) await refresh();
  }

  @override
  Widget build(BuildContext context) {
    final selected = ids.contains(selectedPhoto)
        ? selectedPhoto
        : ids.firstOrNull;
    final progress = widget.uploads[selected];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (preparing) const AppLoading('Preparing pickup photo'),
        if (widget.uploads.isNotEmpty)
          Text(
            '${widget.uploads.values.where((value) => value == 1).length} of ${ids.length} photos uploaded',
          ),

        if (status != null)
          AppNotice(
            status!,
            status: observations.any((o) => o['receipt'] == null)
                ? AppStatus.pending
                : AppStatus.success,
          ),
        if (error != null) AppNotice(error!, status: AppStatus.failure),
        EvidenceReview(
          title: 'Pickup photos',
          photos: ids,
          selected: selected,
          onSelect: (id) => setState(() => selectedPhoto = id),
          image: (id, thumbnail) => ref
              .watch(_thumbnail((widget.plogId, id)))
              .when(
                data: (bytes) => EvidenceImage(
                  image: MemoryImage(bytes),
                  thumbnail: thumbnail,
                  label: 'pickup photo ${ids.indexOf(id) + 1}',
                ),
                loading: () => const AppLoading('Loading photo'),
                error: (_, _) => TextButton(
                  onPressed: () =>
                      ref.invalidate(_thumbnail((widget.plogId, id))),
                  child: const Text('Retry photo'),
                ),
              ),
          status: progress != null && progress >= 0 && progress < 1
              ? LinearProgressIndicator(
                  value: progress,
                  semanticsLabel: 'Uploading pickup photo',
                )
              : Padding(
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: Text(switch (progress) {
                    final double value when value < 0 =>
                      'Upload failed · photo saved on this device',
                    1 => 'Uploaded',
                    _ => 'Saved on this device',
                  }, style: AppText.caption),
                ),
          actions: [
            if (widget.editing && selected != null) ...[
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        final gallery = await choosePhotoReplacement(context);
                        if (mounted && gallery != null) {
                          await add(gallery: gallery, replacing: selected);
                        }
                      },
                child: const Text('Retake or replace'),
              ),
              TextButton(
                onPressed: busy ? null : () => remove(selected),
                child: const Text('Remove photo'),
              ),
            ],
          ],
        ),
        if (widget.editing && ids.length < 6) ...[
          if (widget.inlineAdd)
            PrimaryButton('Add pickup', onPressed: busy ? null : () => add()),
          TextButton.icon(
            onPressed: busy ? null : () => add(gallery: true),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Choose from gallery'),
          ),
        ],
        if (widget.editing &&
            selected != null &&
            !observations.any((o) => o['photo'] == selected))
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await match(selected, choose: true);
                    } finally {
                      if (mounted) await refresh();
                    }
                  },
            child: const Text('Link pickup to a reported spot'),
          ),
        if (ids.isEmpty)
          const Text(
            'Add at least one photo to save your Plog.',
            style: AppText.caption,
          ),
        if (widget.onSave != null) ...[
          const SizedBox(height: 16),
          PrimaryButton(
            'Save Plog',
            onPressed: busy || ids.isEmpty ? null : widget.onSave,
          ),
        ],
      ],
    );
  }
}
