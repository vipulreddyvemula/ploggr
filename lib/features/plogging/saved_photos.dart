import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'data/plog_api.dart';
import '../spots/spot_editor.dart';

final _photos = FutureProvider.autoDispose.family<List<String>, String>(
  (ref, id) => ref.watch(plogApiProvider).evidence(id),
  retry: (_, _) => null,
);
final _image = FutureProvider.autoDispose.family<Uint8List, (String, String)>(
  (ref, key) => ref.watch(plogApiProvider).image(key.$1, key.$2),
  retry: (_, _) => null,
);

class SavedPhotos extends ConsumerWidget {
  const SavedPhotos(this.id, {super.key});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(_photos(id))
      .when(
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => TextButton(
          onPressed: () => ref.invalidate(_photos(id)),
          child: const Text('Retry loading photos'),
        ),
        data: (ids) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Text(
              'Pickup photos (${ids.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final (index, photoId) in ids.indexed)
              ref
                  .watch(_image((id, photoId)))
                  .when(
                    loading: () => const LinearProgressIndicator(),
                    error: (_, _) => TextButton(
                      onPressed: () => ref.invalidate(_image((id, photoId))),
                      child: Text('Photo ${index + 1} unavailable · Retry'),
                    ),
                    data: (bytes) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          GestureDetector(
                            onTap: () => viewPhoto(context, MemoryImage(bytes)),
                            child: Image.memory(
                              bytes,
                              cacheWidth: 720,
                              height: 160,
                              fit: BoxFit.contain,
                              semanticLabel: 'Saved pickup photo ${index + 1}',
                              errorBuilder: (_, _, _) =>
                                  Text('Photo ${index + 1} unavailable'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ],
        ),
      );
}

class DetectionPhoto extends ConsumerWidget {
  const DetectionPhoto(this.plog, this.id, {super.key, this.box});
  final String plog, id;
  final List? box;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = _image((plog, id));
    return ref
        .watch(provider)
        .when(
          data: (bytes) => _DetectionImage(bytes, box),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => TextButton(
            onPressed: () => ref.invalidate(provider),
            child: const Text('Retry photo'),
          ),
        );
  }
}

class _DetectionImage extends StatefulWidget {
  const _DetectionImage(this.bytes, this.box);
  final Uint8List bytes;
  final List? box;
  @override
  State<_DetectionImage> createState() => _DetectionImageState();
}

class _DetectionImageState extends State<_DetectionImage> {
  late final size = readSize();
  Future<double> readSize() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(widget.bytes);
    try {
      final d = await ui.ImageDescriptor.encoded(buffer);
      try {
        return d.width / d.height;
      } finally {
        d.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<double>(
    future: size,
    builder: (_, s) {
      if (!s.hasData) {
        return s.hasError
            ? const Text('Photo unavailable')
            : const LinearProgressIndicator();
      }
      final box = widget.box;
      return AspectRatio(
        aspectRatio: s.data!,
        child: LayoutBuilder(
          builder: (ctx, c) => Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: () => viewPhoto(context, MemoryImage(widget.bytes)),
                child: Image.memory(
                  widget.bytes,
                  cacheWidth: 720,
                  fit: BoxFit.fill,
                ),
              ),
              if (box != null && box.length == 4)
                Positioned(
                  left: box[1] * c.maxWidth / 1000,
                  top: box[0] * c.maxHeight / 1000,
                  width: (box[3] - box[1]) * c.maxWidth / 1000,
                  height: (box[2] - box[0]) * c.maxHeight / 1000,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.amber, width: 3),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
