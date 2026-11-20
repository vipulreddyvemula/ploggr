import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'data/plog_drafts.dart';

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
      final codec = await image.instantiateCodec(targetWidth: 96);
      try {
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
  const GarbagePhotos(this.plogId, {super.key, this.onSave});
  final String plogId;
  final VoidCallback? onSave;
  @override
  ConsumerState<GarbagePhotos> createState() => _GarbagePhotosState();
}

class _GarbagePhotosState extends ConsumerState<GarbagePhotos> {
  final picker = ImagePicker();
  late final drafts = ref.read(plogDraftsProvider);
  List<String> ids = const [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    _select(null);
  }

  Future<void> _select(ImageSource? source) async {
    if (source != null && busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    final plog = widget.plogId;
    String? id;
    try {
      XFile? file;
      if (source == null) {
        id = await drafts.pendingPhoto(plog);
        if (id != null) {
          final lost = await picker.retrieveLostData();
          if (lost.exception != null) throw lost.exception!;
          file = lost.files?.firstOrNull;
        }
      } else {
        id = await drafts.reservePhoto(plog);
        file = await picker.pickImage(
          source: source,
          maxWidth: 2400,
          maxHeight: 2400,
          imageQuality: 85,
          requestFullMetadata: false,
        );
      }
      if (file != null && id != null) {
        if (await file.length() > _maxBytes) {
          throw const FormatException('Choose a photo of 8 MiB or less.');
        }
        final bytes = await file.readAsBytes();
        final type = await photoType(bytes);
        await drafts.storePhoto(plog, id, type, bytes);
        id = null;
      }
    } catch (failure) {
      error = failure is FormatException
          ? failure.message
          : failure is PlatformException
          ? 'Camera or gallery unavailable. Check app permissions and retry.'
          : 'Could not read the photo. Try choosing it again.';
    } finally {
      try {
        if (id != null) await drafts.removePhoto(plog, id);
        ids = await drafts.photoIds(plog);
      } catch (_) {
        error = 'Could not read photos from this device.';
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove(String id) async {
    setState(() => busy = true);
    try {
      await drafts.removePhoto(widget.plogId, id);
      ids = await drafts.photoIds(widget.plogId);
    } catch (_) {
      error = 'Could not remove the photo.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Garbage photos (${ids.length}/6)',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (error != null) Text(error!),
      for (final (index, id) in ids.indexed)
        ListTile(
          leading: ref
              .watch(_thumbnail((widget.plogId, id)))
              .when(
                data: (bytes) => Image.memory(
                  bytes,
                  width: 48,
                  height: 48,
                  cacheWidth: 96,
                  fit: BoxFit.cover,
                ),
                loading: () => const SizedBox(width: 48),
                error: (_, _) => const Icon(Icons.broken_image),
              ),
          title: Text('Garbage photo ${index + 1}'),
          trailing: IconButton(
            tooltip: 'Remove photo ${index + 1}',
            onPressed: busy ? null : () => _remove(id),
            icon: const Icon(Icons.close),
          ),
        ),
      if (ids.length < 6)
        Wrap(
          children: [
            TextButton(
              onPressed: busy ? null : () => _select(ImageSource.camera),
              child: const Text('Take photo'),
            ),
            TextButton(
              onPressed: busy ? null : () => _select(ImageSource.gallery),
              child: const Text('Choose photo'),
            ),
          ],
        ),
      if (widget.onSave != null)
        FilledButton(
          onPressed: busy || ids.isEmpty ? null : widget.onSave,
          child: const Text('Save Plog'),
        ),
    ],
  );
}
