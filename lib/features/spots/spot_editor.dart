import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../home/activity_overview.dart';
import 'place_picker.dart';
import 'photo_picker.dart';
import '../plogging/garbage_photos.dart' show photoType;
import 'live_camera.dart';
import 'spot.dart';
import 'spot_api.dart';
import 'spot_draft.dart';
import '../../shared/widgets/bottom_navigation.dart';

Future<void> viewPhoto(BuildContext context, ImageProvider image) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  maxScale: 6,
                  child: Image(image: image, fit: BoxFit.contain),
                ),
              ),
              IconButton.filled(
                tooltip: 'Close photo',
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );

class SpotEditor extends ConsumerWidget {
  const SpotEditor({super.key, this.openCamera = false, this.seed});
  final bool openCamera;
  final Uint8List? seed;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const key = 'sighting';
    return ref
        .watch(spotDraftProvider(key))
        .when(
          data: (draft) =>
              _Editor(draft: draft, openCamera: openCamera, seed: seed),
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (_, _) => Scaffold(
            appBar: AppBar(),
            body: Center(
              child: TextButton(
                onPressed: () => ref.invalidate(spotDraftProvider(key)),
                child: const Text('Retry opening draft'),
              ),
            ),
          ),
        );
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({required this.draft, required this.openCamera, this.seed});
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
  bool busy = false;
  String? message;
  String? selectedPhoto;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || d.locked) return;
      if (d.picking) {
        await run(() async {
          try {
            final lost = await picker.retrieveLostData();
            if (lost.exception != null) throw lost.exception!;
            final file = lost.files?.firstOrNull;
            if (file != null) await addFile(file);
          } finally {
            d.picking = false;
            await d.save();
          }
        });
      } else if (widget.seed != null) {
        await run(() => addBytes(widget.seed!));
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

  Future<void> addBytes(Uint8List bytes) async {
    final type = await photoType(bytes);
    final id = const Uuid().v4();
    await d.add((id: id, type: type, bytes: bytes));
    selectedPhoto = id;
  }

  Future<void> addFile(XFile file) async {
    if (await file.length() > 8 * 1024 * 1024) {
      throw const FormatException('Choose a photo of 8 MiB or less.');
    }
    await addBytes(await file.readAsBytes());
  }

  Future<void> gallery() async {
    d.picking = true;
    await d.save();
    try {
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 85,
        requestFullMetadata: false,
      );
      if (file != null) await addFile(file);
    } finally {
      d.picking = false;
      await d.save();
    }
  }

  Future<void> pin() => run(() async {
    final place = await choosePlace(
      context,
      initial: d.point == null ? null : (point: d.point!, name: d.place),
    );
    if (place == null) return;
    d.point = place.point;
    d.place = place.name;
    d.confirmed = true;
    await d.save();
  });

  Future<void> capture() => run(() async {
    final photo = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => const LiveCamera(title: "Report litter"),
      ),
    );
    if (!mounted) return;
    if (photo == 'gallery') {
      await gallery();
    } else if (photo is XFile) {
      await addFile(photo);
    }
  });
  Future<void> submit() => run(() async {
    if (d.point == null || !d.confirmed || d.photos.isEmpty) return;
    final fields = SpotDetails(d.point!, d.category, d.notes.trim(), d.place);
    final images = await d.readPhotos();
    if (!mounted) return;
    d.locked = true;
    await d.save();
    if (!mounted) return;
    await ref.read(spotApiProvider).publish(d.id, fields, images);
    await d.clear();
    if (!mounted) return;
    ref.invalidate(mySpotsProvider);
    ref.invalidate(totalsProvider);
    ref.invalidate(clusterProvider);
    ref.invalidate(exploreProvider);
    ref.invalidate(spotDraftProvider('sighting'));
    switchPage(context, '${AppRoutes.map}?spot=${d.id}');
  });
  @override
  Widget build(BuildContext context) {
    final point = d.point;
    final editable = !d.locked && !busy;
    final photo = d.photos.containsKey(selectedPhoto)
        ? selectedPhoto
        : d.photos.keys.firstOrNull;
    return AppPage(
      title: 'Report litter',
      root: true,
      bottomNavigation: const BottomNavBar(caller: 'scan'),
      bottomAction: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          PrimaryButton(
            busy
                ? 'Saving…'
                : d.locked
                ? 'Retry post'
                : d.photos.isEmpty
                ? 'Add photo'
                : !d.confirmed
                ? 'Choose spot'
                : 'Post report',
            onPressed: busy
                ? null
                : d.photos.isEmpty
                ? capture
                : !d.confirmed
                ? pin
                : submit,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Text(
              'Photos (${d.photos.length}/6)',
              style: AppText.caption,
            ),
          ),
          if (photo != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: SizedBox(
                  width: 208,
                  height: 150,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        onTap: () =>
                            viewPhoto(context, FileImage(d.file(photo))),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.file(
                            d.file(photo),
                            height: 150,
                            width: double.infinity,
                            semanticLabel: 'Selected litter photo',
                            cacheWidth: 640,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      if (editable)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: IconButton.filled(
                            tooltip: 'Remove photo',
                            onPressed: () => run(() => d.remove(photo)),
                            icon: const Icon(Icons.close),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (d.photos.length > 1)
            SizedBox(
              height: 62,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: d.photos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final id = d.photos.keys.elementAt(i);
                  return Semantics(
                    button: true,
                    selected: id == photo,
                    label: 'Select photo ${i + 1}',
                    child: InkWell(
                      onTap: () => setState(() => selectedPhoto = id),
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          border: Border.all(
                            width: 2,
                            color: id == photo
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.file(
                            d.file(id),
                            width: 52,
                            cacheWidth: 120,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          if (d.photos.length < 6 && !d.locked)
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: editable ? capture : null,
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Take photo'),
                ),
                TextButton.icon(
                  onPressed: editable ? () => run(gallery) : null,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Choose photo'),
                ),
              ],
            ),
          const SectionTitle('Litter type'),
          LitterTypePicker(
            selected: d.category,
            onChanged: editable
                ? (category) => run(() async {
                    d.category = category;
                    await d.save();
                  })
                : null,
          ),
          const SectionTitle('Where is the litter?'),
          EcoCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_outlined),
              title: Text(
                point == null
                    ? 'Choose a spot on the map'
                    : d.place.isEmpty
                    ? 'Pinned on map'
                    : d.place,
              ),
              subtitle: const Text(
                'Search a place or move the pin to the litter.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: editable ? pin : null,
            ),
          ),
          const SectionTitle('Description'),
          TextField(
            controller: notes,
            enabled: editable,
            maxLength: 250,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
            onChanged: (value) {
              d.notes = value;
              unawaited(
                d.save().catchError((Object _) {
                  if (mounted) {
                    setState(
                      () => message = 'Could not save notes on this device.',
                    );
                  }
                }),
              );
            },
          ),
          Text(
            'Other ploggers can see your photos, notes and pinned location.',
            style: AppText.caption,
          ),
          if (d.locked && !busy)
            TextButton(
              onPressed: () async {
                final discard = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Discard this local draft?'),
                    content: const Text(
                      'If the server received your post, it will still appear in My reports.',
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
                    await d.clear();
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
    );
  }
}
