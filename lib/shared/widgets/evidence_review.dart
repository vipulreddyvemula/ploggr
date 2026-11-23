import 'package:material_ui/material_ui.dart';

import 'ploggr_ui.dart';

Future<void> viewPhoto(BuildContext context, ImageProvider image) =>
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              InteractiveViewer(
                maxScale: 6,
                child: Image(image: image, fit: BoxFit.contain),
              ),
              PositionedDirectional(
                top: AppSpace.sm,
                end: AppSpace.sm,
                child: IconButton.filled(
                  autofocus: true,
                  tooltip: 'Close photo',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );

class EvidenceImage extends StatelessWidget {
  const EvidenceImage({
    super.key,
    required this.image,
    required this.label,
    this.thumbnail = false,
  });
  final ImageProvider image;
  final String label;
  final bool thumbnail;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: AppRadius.small,
    child: Ink(
      color: context.colors.surfaceContainer,
      child: InkWell(
        onTap: thumbnail ? null : () => viewPhoto(context, image),
        child: Image(
          image: ResizeImage.resizeIfNeeded(thumbnail ? 160 : 840, null, image),
          fit: thumbnail ? BoxFit.cover : BoxFit.contain,
          semanticLabel: thumbnail ? null : label,
          excludeFromSemantics: thumbnail,
          errorBuilder: (_, _, _) =>
              const Center(child: Text('Photo unavailable')),
        ),
      ),
    ),
  );
}

class EvidenceReview extends StatelessWidget {
  const EvidenceReview({
    super.key,
    required this.title,
    required this.photos,
    required this.selected,
    required this.onSelect,
    required this.image,
    this.status,
    this.actions = const [],
  });

  final String title;
  final List<String> photos;
  final String? selected;
  final ValueChanged<String> onSelect;
  final Widget Function(String id, bool thumbnail) image;
  final Widget? status;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle('$title (${photos.length}/6)'),
        if (selected case final String id) ...[
          SizedBox(height: 202, child: image(id, false)),
          ?status,
          if (photos.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  for (final (index, photo) in photos.indexed)
                    Semantics(
                      label: 'Photo ${index + 1} of ${photos.length}',
                      selected: photo == id,
                      button: true,
                      child: OutlinedButton(
                        onPressed: () => onSelect(photo),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: photo == id
                              ? context.colors.primaryContainer
                              : null,
                          side: BorderSide(
                            color: photo == id
                                ? context.colors.primary
                                : context.colors.outline,
                            width: photo == id ? 2 : 1,
                          ),
                          padding: const EdgeInsets.all(3),
                        ),
                        child: SizedBox(
                          width: AppSpace.target,
                          height: AppSpace.target,
                          child: image(photo, true),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (actions.isNotEmpty) Wrap(spacing: AppSpace.sm, children: actions),
        ],
      ],
    );
  }
}

Future<bool> confirmPhotoRemoval(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this photo?'),
        content: const Text('This removes it from the current draft.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep photo'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove photo'),
          ),
        ],
      ),
    ) ??
    false;

Future<bool?> choosePhotoReplacement(BuildContext context) =>
    showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Retake with camera'),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Replace from gallery'),
              onTap: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
