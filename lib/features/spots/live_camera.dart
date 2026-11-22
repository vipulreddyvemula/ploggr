import '../../shared/widgets/litter_camera_frame.dart';
import 'package:camera/camera.dart';
import 'package:material_ui/material_ui.dart';

class LiveCamera extends StatefulWidget {
  const LiveCamera({super.key, this.title = 'Report litter'});
  final String title;
  @override
  State<LiveCamera> createState() => _LiveCameraState();
}

class _LiveCameraState extends State<LiveCamera> with WidgetsBindingObserver {
  CameraController? camera;
  int version = 0;
  bool busy = false, flash = false, hasFlash = true;
  String? error;
  Future<void> releases = Future.value();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    open();
  }

  void release() {
    version++;
    final old = camera;
    camera = null;
    if (old != null) releases = releases.then((_) => old.dispose());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      release();
    }
    if (state == AppLifecycleState.resumed && camera == null) open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    release();
    super.dispose();
  }

  Future<void> open() async {
    final attempt = ++version;
    try {
      await releases;
      final cameras = await availableCameras();
      if (!mounted || attempt != version) return;
      final back =
          cameras
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .firstOrNull ??
          cameras.first;
      final device = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      camera = device;
      await device.initialize();
      if (!mounted || attempt != version) return;
      try {
        await device.setFlashMode(FlashMode.off);
        hasFlash = true;
      } on CameraException {
        hasFlash = false;
      }
      if (mounted && attempt == version) {
        setState(() {
          error = null;
          flash = false;
        });
      }
    } catch (_) {
      if (mounted && attempt == version) {
        release();
        setState(
          () => error =
              'Camera unavailable. Allow camera access in Android settings or choose a gallery photo.',
        );
      }
    }
  }

  Future<void> take() async {
    final device = camera;
    if (busy || device == null || !device.value.isInitialized) return;
    setState(() => busy = true);
    try {
      final shot = await device.takePicture();
      if (mounted) Navigator.pop(context, shot);
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'Could not take photo. Try again.';
          busy = false;
        });
      }
    }
  }

  Future<void> toggleFlash() async {
    final device = camera;
    if (device == null) return;
    try {
      await device.setFlashMode(flash ? FlashMode.off : FlashMode.always);
      if (mounted && identical(device, camera)) setState(() => flash = !flash);
    } on CameraException {
      if (mounted && identical(device, camera)) {
        setState(() => hasFlash = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = camera;
    final ready = device != null && device.value.isInitialized && error == null;
    return LitterCameraFrame(
      title: widget.title,
      onBack: () => Navigator.pop(context),
      background: ColoredBox(
        color: Colors.black,
        child: Center(
          child: ready
              ? SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: device.value.previewSize!.width,
                      child: CameraPreview(device),
                    ),
                  ),
                )
              : error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                      TextButton(
                        onPressed: () {
                          release();
                          setState(() => error = null);
                          open();
                        },
                        child: const Text(
                          'Retry camera',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
      showGuide: ready,
      galleryLabel: 'Gallery',
      galleryIcon: const Icon(
        Icons.photo_library_outlined,
        color: Colors.white,
      ),
      onGallery: !busy ? () => Navigator.pop(context, 'gallery') : null,
      shutterLabel: 'Take picture',
      onCapture: ready && !busy ? take : null,
      flash: flash,
      flashLabel: 'Toggle flash',
      onFlash: ready && hasFlash && !busy ? toggleFlash : null,
    );
  }
}
