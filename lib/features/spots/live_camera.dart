import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../plogging/data/location_source.dart';
import '../plogging/data/photo_capture.dart';
import 'photo_picker.dart';
import '../../shared/widgets/litter_camera_frame.dart';
import 'package:camera/camera.dart';
import 'package:material_ui/material_ui.dart';

class LiveCamera extends ConsumerStatefulWidget {
  const LiveCamera({
    super.key,
    required this.recovery,
    this.title = 'Report litter',
  });
  final String title;
  final PhotoRecovery recovery;
  @override
  ConsumerState<LiveCamera> createState() => _LiveCameraState();
}

class _LiveCameraState extends ConsumerState<LiveCamera>
    with WidgetsBindingObserver {
  CameraController? camera;
  int version = 0;
  bool busy = false, flash = false, hasFlash = true;
  String? error, gpsError, captureError;
  List<CameraDescription> lenses = [];
  CameraDescription? selectedLens;
  bool guides = false, adjustingFlash = false;
  double minZoom = 1, maxZoom = 1, zoom = 1, startZoom = 1;
  Timer? zoomTimer, focusTimer;
  Offset? focusPoint;
  bool get ready =>
      camera?.value.isInitialized == true && error == null && !opening;
  bool opening = true;
  bool permissionDenied = false, returningFromSettings = false;
  GpsSample? gps;
  bool locating = false, foreground = true;
  Future<XFile>? shutter;
  Future<void> releases = Future.value();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    open();
  }

  void release() {
    version++;
    zoomTimer?.cancel();
    zoomTimer = null;
    focusTimer?.cancel();
    focusPoint = null;
    final old = camera;
    camera = null;
    if (old != null) {
      final capture = shutter;
      releases = releases.then((_) async {
        try {
          await capture;
        } catch (_) {}
        try {
          await old.dispose().timeout(const Duration(seconds: 5));
        } catch (_) {}
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      foreground = false;
      release();
      if (mounted) setState(() {});
    }
    if (state == AppLifecycleState.resumed) {
      foreground = true;
      if (camera == null && !busy && (error == null || returningFromSettings)) {
        returningFromSettings = false;
        unawaited(open());
      }
    }
  }

  Future<void> locate() async {
    if (locating) return;
    setState(() {
      locating = true;
      gpsError = null;
    });
    try {
      final sample = await ref
          .read(locationSourceProvider)
          .photographLocation();
      if (mounted) setState(() => gps = sample);
    } catch (e) {
      if (mounted) {
        setState(
          () => gpsError = e is LocationFailure
              ? e.message
              : 'Could not get a current location.',
        );
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    release();
    super.dispose();
  }

  Future<void> open() async {
    final attempt = ++version;
    if (mounted) {
      setState(() {
        opening = true;
        error = null;
        permissionDenied = false;
      });
    }
    try {
      await releases;
      final cameras = await availableCameras().timeout(
        const Duration(seconds: 12),
      );
      if (!mounted || attempt != version) return;
      lenses = cameras;
      selectedLens = cameras.contains(selectedLens)
          ? selectedLens
          : cameras
                    .where((c) => c.lensDirection == CameraLensDirection.back)
                    .firstOrNull ??
                cameras.firstOrNull;
      final lens = selectedLens;
      if (lens == null) throw StateError('No camera available');
      final device = CameraController(
        lens,
        ResolutionPreset.high,
        enableAudio: false,
      );
      camera = device;
      await device.initialize().timeout(const Duration(seconds: 15));
      if (!mounted || attempt != version) return;
      try {
        await device
            .setFlashMode(FlashMode.off)
            .timeout(const Duration(seconds: 3));
        hasFlash = lens.lensDirection != CameraLensDirection.front;
      } catch (_) {
        hasFlash = false;
      }
      var minimum = 1.0, maximum = 1.0;
      try {
        minimum = await device.getMinZoomLevel().timeout(
          const Duration(seconds: 2),
        );
        maximum = await device.getMaxZoomLevel().timeout(
          const Duration(seconds: 2),
        );
      } catch (_) {
        minimum = maximum = 1;
      }
      if (mounted && attempt == version) {
        setState(() {
          minZoom = minimum;
          maxZoom = maximum.clamp(minimum, minimum > 8 ? minimum : 8);
          zoom = 1.0.clamp(minZoom, maxZoom);
          opening = false;
          error = null;
          flash = false;
        });
        gps = ref.read(locationSourceProvider).recentSample;
      }
    } catch (failure) {
      if (mounted && attempt == version) {
        release();
        setState(() {
          opening = false;
          permissionDenied =
              failure is CameraException &&
              failure.code.startsWith('CameraAccess');
          error = permissionDenied
              ? 'Allow camera access in device settings or choose a gallery photo.'
              : 'Camera could not open. Retry or choose a gallery photo.';
        });
      }
    }
  }

  Future<void> take() async {
    final device = camera;
    if (busy || device == null || !ready) return;
    setState(() {
      busy = true;
      captureError = null;
    });
    final takenAt = DateTime.now().toUtc();
    final location = ref.read(locationSourceProvider);
    final initialSample = location.recentSample ?? gps;
    XFile? original;
    try {
      final nativeCapture = device.takePicture();
      final pending = nativeCapture.timeout(const Duration(seconds: 15));
      shutter = pending;
      try {
        original = await pending;
      } on TimeoutException {
        unawaited(
          nativeCapture.then(_removeCameraFile, onError: (Object _) {}),
        );
        rethrow;
      }
      final updated = location.recentSample;
      final sample = initialSample?.freshAt(takenAt) == true
          ? initialSample
          : updated?.freshAt(takenAt) == true
          ? updated
          : initialSample;
      final capture = PhotoCapture(PhotoSource.camera, takenAt, gps: sample);
      final shot = await widget.recovery.stage(original, capture);
      if (mounted) {
        Navigator.pop(context, shot);
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          captureError = switch (failure) {
            FormatException(:final message) => message,
            FileSystemException() =>
              'Could not save the photo. Free some device storage and retry.',
            _ => 'The photo was interrupted. Try taking it again.',
          };
          busy = false;
        });
      }
    } finally {
      shutter = null;
      if (original != null) unawaited(_removeCameraFile(original));
    }
  }

  Future<void> _removeCameraFile(XFile file) async {
    try {
      await File(file.path).delete();
    } on FileSystemException {
      // The cache can reclaim an unreferenced native camera file.
    }
  }

  Future<void> toggleFlash() async {
    final device = camera;
    if (device == null || busy || adjustingFlash || !ready) return;
    setState(() => adjustingFlash = true);
    try {
      await device.setFlashMode(flash ? FlashMode.off : FlashMode.always);
      if (mounted && identical(device, camera)) setState(() => flash = !flash);
    } on CameraException {
      if (mounted && identical(device, camera)) {
        setState(() => hasFlash = false);
      }
    } finally {
      if (mounted) setState(() => adjustingFlash = false);
    }
  }

  void switchCamera() {
    if (busy || !ready || adjustingFlash || lenses.length < 2) return;
    selectedLens = lenses[(lenses.indexOf(selectedLens!) + 1) % lenses.length];
    release();
    unawaited(open());
  }

  void scale(CameraController device, double value) {
    if (busy || !ready || !identical(device, camera) || minZoom == maxZoom) {
      return;
    }
    final next = (startZoom * value).clamp(minZoom, maxZoom);
    if ((next - zoom).abs() < .02) return;
    setState(() => zoom = next);
    zoomTimer ??= Timer(const Duration(milliseconds: 45), () async {
      zoomTimer = null;
      if (!mounted || !identical(camera, device) || busy) return;
      try {
        await device.setZoomLevel(zoom);
      } on CameraException {
        // Some lenses do not support zoom changes in their current mode.
      }
    });
  }

  Future<void> focus(CameraController device, Offset point) async {
    if (busy || !device.value.focusPointSupported) return;
    try {
      await device.setFocusPoint(point);
      if (!mounted || !identical(camera, device)) return;
      focusTimer?.cancel();
      setState(() => focusPoint = point);
      focusTimer = Timer(const Duration(seconds: 1), () {
        if (mounted) setState(() => focusPoint = null);
      });
    } on CameraException {
      // Continue in autofocus mode if the lens refuses a focus point.
    }
  }

  Widget preview(CameraController device) => ValueListenableBuilder(
    valueListenable: device,
    builder: (context, value, _) {
      final size = value.previewSize!;
      final landscape =
          value.deviceOrientation == DeviceOrientation.landscapeLeft ||
          value.deviceOrientation == DeviceOrientation.landscapeRight;
      final frame = landscape ? size : size.flipped;
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox.fromSize(
          size: frame,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (event) => unawaited(
              focus(
                device,
                Offset(
                  (event.localPosition.dx / frame.width).clamp(0, 1),
                  (event.localPosition.dy / frame.height).clamp(0, 1),
                ),
              ),
            ),
            onScaleStart: (_) => startZoom = zoom,
            onScaleUpdate: (event) {
              if (event.pointerCount > 1) scale(device, event.scale);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(device),
                if (focusPoint case final Offset point)
                  Positioned(
                    left: point.dx * frame.width - 32,
                    top: point.dy * frame.height - 32,
                    child: IgnorePointer(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final device = camera;

    return PopScope(
      canPop: !busy,
      child: LitterCameraFrame(
        title: widget.title,
        onBack: () {
          if (!busy) Navigator.pop(context);
        },
        background: ColoredBox(
          color: Colors.black,
          child: Center(
            child: ready && device != null
                ? preview(device)
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (opening) const CircularProgressIndicator(),
                        Text(
                          error ?? 'Opening camera…',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                        if (error != null)
                          TextButton(
                            onPressed: open,
                            child: const Text(
                              'Retry camera',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        if (permissionDenied)
                          TextButton(
                            onPressed: () async {
                              returningFromSettings = true;
                              if (!await Geolocator.openAppSettings()) {
                                returningFromSettings = false;
                              }
                            },
                            child: const Text(
                              'Open device settings',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ),
        capturing: busy,
        showGuide: ready && guides,
        showInstruction: false,
        help: IconButton(
          tooltip: guides ? 'Hide framing guide' : 'Show framing guide',
          onPressed: ready ? () => setState(() => guides = !guides) : null,
          icon: Icon(
            guides ? Icons.grid_off : Icons.grid_on,
            color: Colors.white,
          ),
        ),
        banner: ready
            ? Align(
                alignment: Alignment.topCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (captureError != null)
                      Text(
                        captureError!,
                        style: const TextStyle(
                          color: Colors.white,
                          backgroundColor: Colors.black,
                        ),
                      ),
                    FilledButton.tonalIcon(
                      onPressed: locating || busy ? null : locate,
                      icon: const Icon(Icons.my_location),
                      label: Text(
                        locating
                            ? 'Getting photo location…'
                            : gpsError != null
                            ? 'Location unavailable · Retry'
                            : gps?.freshAt(DateTime.now()) == true
                            ? 'Photo location ±${gps!.accuracyMeters.round()} m'
                            : 'Add photo location',
                      ),
                    ),
                    if (zoom > 1.05)
                      Text(
                        '${zoom.toStringAsFixed(1)}×',
                        style: const TextStyle(
                          color: Colors.white,
                          backgroundColor: Colors.black,
                        ),
                      ),
                  ],
                ),
              )
            : null,
        galleryLabel: 'Gallery',
        galleryIcon: const Icon(
          Icons.photo_library_outlined,
          color: Colors.white,
        ),
        onGallery: !busy ? () => Navigator.pop(context, 'gallery') : null,
        shutterLabel: 'Take picture',
        onCapture: ready && !busy ? take : null,
        flash: flash,
        flashLabel: !hasFlash
            ? 'Flash unavailable'
            : flash
            ? 'Flash on · Turn off'
            : 'Flash off · Turn on',
        onFlash: ready && hasFlash && !busy && !adjustingFlash
            ? toggleFlash
            : null,
        onSwitch: ready && !busy && !adjustingFlash && lenses.length > 1
            ? switchCamera
            : null,
      ),
    );
  }
}
