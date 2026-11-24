import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../../routes/app_routes.dart';
import '../../shared/widgets/ploggr_ui.dart';
import '../../shared/widgets/eco_art.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) switchPage(context, AppRoutes.onboarding);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const BrandedSplash();
}

/// Shared by preview onboarding and the live session-restoration route.
/// Navigation and timing belong to the caller.
class BrandedSplash extends StatelessWidget {
  const BrandedSplash({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = context.colors.brightness == Brightness.dark;
    final background = dark
        ? context.colors.surfaceContainerLow
        : const Color(0xfff7faf3);
    return Scaffold(
      backgroundColor: background,
      body: LayoutBuilder(
        builder: (context, box) {
          return TweenAnimationBuilder<double>(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 240),
            tween: Tween(begin: .85, end: 1),
            builder: (context, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: Stack(
              children: [
                Positioned(
                  left: -4,
                  top: box.maxHeight * .019,
                  child: Image.asset(
                    'assets/images/brand/canopy.png',
                    width: box.maxWidth * .37,
                    excludeFromSemantics: true,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: box.maxHeight * .078,
                  child: ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.white, Colors.white],
                      stops: [0, .22, 1],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: Image.asset(
                      'assets/images/illustrations/splash.png',
                      width: box.maxWidth,
                      height: box.maxHeight * .43,
                      fit: BoxFit.cover,
                      alignment: Alignment.bottomCenter,
                      color: dark ? const Color(0xff70917a) : null,
                      colorBlendMode: BlendMode.modulate,
                      excludeFromSemantics: true,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: box.maxHeight * .145,
                  child: CustomPaint(painter: _ForegroundHills(dark)),
                ),
                SafeArea(
                  child: Align(
                    alignment: const Alignment(0, -.22),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PloggrLogo(size: (box.maxWidth * .23).clamp(52, 102)),
                          const SizedBox(height: 15),
                          Text(
                            'Plog today.',
                            textAlign: TextAlign.center,
                            style: AppText.title.copyWith(
                              fontSize: 28,
                              color: context.colors.onPrimaryContainer,
                            ),
                          ),
                          Text(
                            'Change tomorrow.',
                            textAlign: TextAlign.center,
                            style: AppText.title.copyWith(
                              fontSize: 28,
                              color: context.colors.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ForegroundHills extends CustomPainter {
  const _ForegroundHills(this.dark);
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 400, size.height / 100);
    void hill(Path path, Color day, Color night) {
      path
        ..lineTo(400, 100)
        ..lineTo(0, 100)
        ..close();
      canvas.drawPath(path, Paint()..color = dark ? night : day);
    }

    hill(
      Path()
        ..moveTo(0, 4)
        ..cubicTo(80, -10, 139, 51, 227, 49)
        ..cubicTo(296, 45, 349, 15, 400, 11),
      const Color(0xff94c666),
      const Color(0xff548250),
    );
    hill(
      Path()
        ..moveTo(0, 56)
        ..cubicTo(90, 12, 138, 28, 210, 59)
        ..cubicTo(299, 91, 347, 37, 400, 39),
      const Color(0xff74aa4b),
      const Color(0xff365e3b),
    );
    hill(
      Path()
        ..moveTo(0, 91)
        ..cubicTo(65, 38, 120, 48, 207, 85)
        ..cubicTo(291, 117, 343, 58, 400, 56),
      const Color(0xff508d36),
      const Color(0xff244b32),
    );
  }

  @override
  bool shouldRepaint(_ForegroundHills oldDelegate) => dark != oldDelegate.dark;
}
