import 'package:material_ui/material_ui.dart';
import '../../shared/widgets/litter_camera_frame.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _flash = false;
  @override
  Widget build(BuildContext context) => LitterCameraFrame(
    onBack: () => goBack(context),
    help: IconButton(
      tooltip: 'About the sample camera',
      onPressed: () => previewNotice(
        context,
        'Sample camera',
        'This screen uses a bundled sample photo. No camera, gallery, flash, or AI detection is accessed. Tap the shutter to try reporting litter.',
      ),
      icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
    ),
    background: Image.asset(
      'assets/images/demo/litter.png',
      fit: BoxFit.cover,
      semanticLabel: 'Sample litter photo, not a live camera',
    ),
    banner: const PreviewNote(
      text: 'SAMPLE CAMERA · no camera access',
      light: true,
    ),
    galleryLabel: 'Choose sample photo',
    galleryIcon: const LitterPhoto(height: 44, width: 44),
    shutterLabel: 'Capture sample photo',
    onGallery: () => openPage(context, AppRoutes.report),
    onCapture: () => openPage(context, AppRoutes.report),
    flash: _flash,
    flashLabel: _flash ? 'Turn sample flash off' : 'Turn sample flash on',
    onFlash: () {
      setState(() => _flash = !_flash);
      toast(
        context,
        'Sample flash ${_flash ? 'on' : 'off'} · device flash is not used',
      );
    },
  );
}
