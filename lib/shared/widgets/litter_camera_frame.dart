import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'ploggr_ui.dart';

class LitterCameraFrame extends StatelessWidget {
  const LitterCameraFrame({
    super.key,
    required this.background,
    required this.onBack,
    required this.galleryIcon,
    required this.galleryLabel,
    required this.onGallery,
    required this.shutterLabel,
    required this.onCapture,
    required this.flash,
    required this.flashLabel,
    required this.onFlash,
    this.title = 'Scan Litter',
    this.showGuide = true,
    this.banner,
    this.help,
    this.showInstruction = true,
    this.capturing = false,
    this.onSwitch,
  });
  final Widget background, galleryIcon;
  final Widget? banner, help;
  final String title;
  final String galleryLabel, shutterLabel, flashLabel;
  final VoidCallback onBack;
  final VoidCallback? onGallery, onCapture, onFlash;
  final bool flash, showGuide, showInstruction, capturing;
  final VoidCallback? onSwitch;
  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.light,
    child: Scaffold(
      backgroundColor: const Color(0xFF102014),
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: onBack,
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                ),
                Expanded(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
                help ?? const SizedBox(width: 48),
              ],
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  background,
                  if (banner != null)
                    Positioned(top: 18, left: 12, right: 12, child: banner!),
                  if (showGuide)
                    Center(
                      child: FractionallySizedBox(
                        widthFactor: .77,
                        heightFactor: .46,
                        child: IgnorePointer(
                          child: CustomPaint(painter: _ViewfinderPainter()),
                        ),
                      ),
                    ),
                  if (showGuide && showInstruction)
                    Positioned(
                      bottom: 22,
                      left: 24,
                      right: 24,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 13,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .68),
                          borderRadius: AppRadius.small,
                        ),
                        child: const Text(
                          'Take a photo of litter\n(e.g. plastic, paper, e-waste, etc.)',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (capturing)
              Semantics(
                liveRegion: true,
                child: Text(
                  'Saving photo…',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        tooltip: galleryLabel,
                        onPressed: onGallery,
                        icon: galleryIcon,
                      ),
                    ),
                  ),
                  Semantics(
                    label: shutterLabel,
                    enabled: onCapture != null,
                    button: true,
                    child: IconButton(
                      onPressed: onCapture,
                      padding: EdgeInsets.zero,
                      icon: Container(
                        width: 72,
                        height: 72,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: onCapture == null
                                ? Colors.white38
                                : Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (onSwitch != null)
                          IconButton(
                            tooltip: 'Switch camera',
                            onPressed: onSwitch,
                            icon: const Icon(
                              Icons.cameraswitch_outlined,
                              color: Colors.white,
                            ),
                          ),
                        IconButton(
                          tooltip: flashLabel,
                          onPressed: onFlash,
                          icon: Icon(
                            flash
                                ? Icons.flash_on_rounded
                                : Icons.flash_off_rounded,
                            color: onFlash == null
                                ? Colors.white38
                                : flash
                                ? AppColors.gold
                                : Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final point in [
      Offset.zero,
      Offset(s.width, 0),
      Offset(0, s.height),
      Offset(s.width, s.height),
    ]) {
      c.save();
      c.translate(point.dx, point.dy);
      c.scale(point.dx == 0 ? 1 : -1, point.dy == 0 ? 1 : -1);
      c.drawPath(
        Path()
          ..moveTo(0, 31)
          ..lineTo(0, 12)
          ..quadraticBezierTo(0, 0, 12, 0)
          ..lineTo(31, 0),
        p,
      );
      c.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
