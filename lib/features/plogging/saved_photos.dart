import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'data/plog_api.dart';

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
              'Garbage photos (${ids.length})',
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
                      child: Image.memory(
                        bytes,
                        cacheWidth: 720,
                        height: 160,
                        fit: BoxFit.contain,
                        semanticLabel: 'Saved garbage photo ${index + 1}',
                        errorBuilder: (_, _, _) =>
                            Text('Photo ${index + 1} unavailable'),
                      ),
                    ),
                  ),
          ],
        ),
      );
}
