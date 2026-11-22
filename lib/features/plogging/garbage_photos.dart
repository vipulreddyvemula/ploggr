import 'application/active_track.dart';
import 'package:uuid/uuid.dart';
import '../spots/spot_draft.dart';
import 'dart:async';
import '../spots/live_camera.dart';
import '../spots/photo_picker.dart';
import '../spots/observation_sync.dart';
import '../spots/spot_api.dart';
import '../spots/spot.dart';
import '../spots/explore_page.dart' show SpotPhotoTile;
import '../spots/place_picker.dart';
import 'data/location_source.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'data/plog_drafts.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../spots/spot_editor.dart';

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
  });
  final bool inlineAdd;
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
  String? status;
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
          final lost = await picker.retrieveLostData();
          final file = lost.files?.firstOrNull;
          if (lost.exception != null) throw lost.exception!;
          if (file != null) {
            if (await file.length() > _maxBytes) {
              throw const FormatException('Choose a photo of 8 MiB or less.');
            }
            final bytes = await file.readAsBytes();
            await drafts.storePhoto(id, pending, await photoType(bytes), bytes);
          } else {
            await drafts.removePhoto(id, pending);
          }
        } catch (e) {
          await drafts.removePhoto(id, pending);
          error = e is FormatException
              ? e.message
              : 'That selection could not be recovered. Choose the photo again.';
        }
      }
      final previous = await SpotDraft.previousPickup(drafts.scope, id);
      if (previous != null) {
        try {
          if (previous.picking && recover) {
            final file = (await picker.retrieveLostData()).files?.firstOrNull;
            if (file != null && await file.length() <= _maxBytes) {
              final bytes = await file.readAsBytes();
              await previous.add((
                id: const Uuid().v4(),
                type: await photoType(bytes),
                bytes: bytes,
              ));
            }
            previous.picking = false;
            await previous.save();
          }
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

  Future<void> add({bool gallery = false}) async {
    if (busy) return;
    final activity = widget.plogId;
    widget.onAvailable?.call(false);
    setState(() {
      busy = true;
      error = null;
      status = null;
    });
    String? pending;
    try {
      pending = await drafts.reservePhoto(activity);
      if (!mounted) return;
      Object? result = gallery
          ? 'gallery'
          : await Navigator.push<Object?>(
              context,
              MaterialPageRoute(
                builder: (_) => const LiveCamera(title: 'Add pickup'),
              ),
            );
      final walk = ref.read(activeTrackProvider);
      final fix =
          result is XFile &&
              walk.phase == TrackPhase.tracking &&
              walk.track?.id == activity
          ? ref.read(locationSourceProvider).recentFix
          : null;
      if (result == 'gallery') {
        result = await picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 2400,
          maxHeight: 2400,
          imageQuality: 85,
          requestFullMetadata: false,
        );
      }
      if (result is! XFile) return;
      if (await result.length() > _maxBytes) {
        throw const FormatException('Choose a photo of 8 MiB or less.');
      }
      final bytes = await result.readAsBytes();
      final photo = pending;
      await drafts.storePhoto(activity, photo, await photoType(bytes), bytes);
      pending = null;
      if (!mounted) return;
      final saved = await drafts.photoIds(activity);
      if (!mounted) return;
      setState(() {
        ids = saved;
        status = 'Pickup saved on this phone.';
      });
      await match(photo, fix: fix);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : e is StateError
              ? e.message
              : 'Could not add this photo. Try again.',
        );
      }
    } finally {
      if (pending != null) await drafts.removePhoto(activity, pending);
      if (mounted) await refresh();
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
      () => status = 'Spot update saved on this phone. Waiting to sync.',
    );
    unawaited(
      ref
          .read(observationSyncProvider)
          .flush(plog: activity)
          .then((_) {
            if (mounted) {
              setState(() => status = 'Spot updated on the litter map.');
            }
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> remove(String id) async {
    setState(() => busy = true);
    try {
      await drafts.removePhoto(widget.plogId, id);
    } catch (_) {
      error = 'Could not remove photo.';
    }
    if (mounted) await refresh();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SectionTitle('Pickup photos (${ids.length}/6)'),
      if (status != null) Semantics(liveRegion: true, child: Text(status!)),
      if (error != null) Text(error!),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (i, id) in ids.indexed)
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ref
                      .watch(_thumbnail((widget.plogId, id)))
                      .when(
                        data: (b) => GestureDetector(
                          onTap: () => viewPhoto(context, MemoryImage(b)),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.memory(
                              b,
                              fit: BoxFit.cover,
                              cacheWidth: 200,
                              semanticLabel: 'Garbage photo ${i + 1}',
                            ),
                          ),
                        ),
                        loading: () => const CircularProgressIndicator(),
                        error: (_, _) => const Icon(Icons.broken_image),
                      ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton.filled(
                      tooltip: 'Remove photo ${i + 1}',
                      onPressed:
                          busy || observations.any((o) => o['photo'] == id)
                          ? null
                          : () => remove(id),
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      if (ids.length < 6) ...[
        if (widget.inlineAdd)
          PrimaryButton('Add pickup', onPressed: busy ? null : () => add()),
        TextButton.icon(
          onPressed: busy ? null : () => add(gallery: true),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Choose from gallery'),
        ),
      ],
      if (ids.isNotEmpty && !observations.any((o) => o['photo'] == ids.last))
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await match(ids.last, choose: true);
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
