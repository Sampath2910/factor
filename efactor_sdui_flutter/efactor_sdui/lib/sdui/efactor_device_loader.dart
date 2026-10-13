import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A branded eFactor loading indicator featuring a central "E" logo
/// and a rotating segmented circular progress ring with rounded caps.
class EfactorDeviceLoader extends StatefulWidget {
  const EfactorDeviceLoader({
    super.key,
    this.size = 84.0,
    this.title,
    this.subtitle,
    this.statusText,
    this.accentColor = const Color(0xFFF15A24),
    this.trackColor = const Color(0xFFD1D5DB),
    this.showPulse = true,
  });

  /// Outer diameter of the circular loader.
  final double size;

  /// Primary title displayed below the loader (e.g., "Connecting Device").
  final String? title;

  /// Secondary subtitle displayed below the title (e.g., "Node 655").
  final String? subtitle;

  /// Minor status caption (e.g., "Loading live schema...").
  final String? statusText;

  /// Primary accent color for the active arc and letter "E".
  final Color accentColor;

  /// Color of the inactive segmented track arcs.
  final Color trackColor;

  /// Whether to subtly breathe/pulse the central "E".
  final bool showPulse;

  @override
  State<EfactorDeviceLoader> createState() => _EfactorDeviceLoaderState();
}

class _EfactorDeviceLoaderState extends State<EfactorDeviceLoader>
    with TickerProviderStateMixin {
  late final AnimationController _spinController;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    if (widget.showPulse) {
      _pulseAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
        CurvedAnimation(
          parent: _pulseController,
          curve: Curves.easeInOut,
        ),
      );
      _pulseController.repeat(reverse: true);
    } else {
      _pulseAnimation = const AlwaysStoppedAnimation<double>(1.0);
    }
  }

  @override
  void dispose() {
    _spinController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.title != null ||
        widget.subtitle != null ||
        widget.statusText != null;

    final spinner = SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Rotating segmented outer ring
          AnimatedBuilder(
            animation: _spinController,
            builder: (context, child) {
              return Transform.rotate(
                angle: _spinController.value * 2 * math.pi,
                child: CustomPaint(
                  size: Size(widget.size, widget.size),
                  painter: _EfactorSegmentedRingPainter(
                    accentColor: widget.accentColor,
                    trackColor: widget.trackColor,
                  ),
                ),
              );
            },
          ),

          // 2. Central eFactor "E" logo (stays upright with gentle pulse)
          ScaleTransition(
            scale: _pulseAnimation,
            child: SizedBox(
              width: widget.size * 0.52,
              height: widget.size * 0.52,
              child: Center(
                child: Image.asset(
                  'assets/branding/efactor_loader_center_e.png',
                  width: widget.size * 0.50,
                  height: widget.size * 0.50,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    // Fallback to stylized vector text if asset is still decoding
                    return FittedBox(
                      fit: BoxFit.contain,
                      child: Text(
                        'E',
                        style: GoogleFonts.poppins(
                          color: widget.accentColor,
                          fontWeight: FontWeight.w900,
                          fontSize: widget.size * 0.44,
                          height: 1.0,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (!hasText) {
      return spinner;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        spinner,
        if (widget.title != null) ...[
          const SizedBox(height: 22),
          Text(
            widget.title!,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
        if (widget.subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            widget.subtitle!,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: const Color(0xB3FFFFFF),
              fontSize: 13,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
        if (widget.statusText != null) ...[
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: widget.accentColor.withAlpha(217),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.statusText!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    color: widget.accentColor.withAlpha(217),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Custom painter for the 4-segment ring matching the eFactor spinner graphic.
/// 3 segments are silver/grey track, 1 segment is vibrant brand orange.
class _EfactorSegmentedRingPainter extends CustomPainter {
  const _EfactorSegmentedRingPainter({
    required this.accentColor,
    required this.trackColor,
  });

  final Color accentColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final strokeWidth = size.width * 0.082; // Proportional stroke width (~7px at 84px)
    final radius = (size.width - strokeWidth) / 2;

    final rect = Rect.fromCircle(center: center, radius: radius);

    // 4 segments around the circle.
    // Each segment has a sweep angle and a gap angle.
    // 360 / 4 = 90 deg per segment. Sweep: ~66 deg, Gap: ~24 deg.
    const segmentSweepDeg = 66.0;
    const segmentGapDeg = 24.0;
    const degToRad = math.pi / 180.0;
    const sweepAngleRad = segmentSweepDeg * degToRad;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final accentPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // Optional subtle outer glow on the active accent segment
    final glowPaint = Paint()
      ..color = accentColor.withAlpha(89)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * 1.5
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

    for (int i = 0; i < 4; i++) {
      final startAngleDeg = i * (segmentSweepDeg + segmentGapDeg) - 45.0;
      final startAngleRad = startAngleDeg * degToRad;

      // Index 3 is the active orange arc (matches the bottom/right arc in the design)
      if (i == 3) {
        canvas.drawArc(rect, startAngleRad, sweepAngleRad, false, glowPaint);
        canvas.drawArc(rect, startAngleRad, sweepAngleRad, false, accentPaint);
      } else {
        canvas.drawArc(rect, startAngleRad, sweepAngleRad, false, trackPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EfactorSegmentedRingPainter oldDelegate) {
    return oldDelegate.accentColor != accentColor ||
        oldDelegate.trackColor != trackColor;
  }
}

/// Full screen scaffold wrapper for device loading states.
/// Dynamically shows Design 4 (Smart Plug) for socket/plug models,
/// and Design 3 (Smart Hub) for fan/hub models.
class EfactorDeviceLoadingScreen extends StatelessWidget {
  const EfactorDeviceLoadingScreen({
    super.key,
    required this.modelId,
    required this.nodeId,
    this.statusText = 'Loading live schema...',
    this.onBack,
  });

  final String modelId;
  final String nodeId;
  final String statusText;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      appBar: onBack != null
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white70),
                onPressed: onBack,
                tooltip: 'Back',
              ),
            )
          : null,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
          child: DynamicModelLoadingView(
            modelId: modelId,
            nodeId: nodeId,
            statusText: statusText,
          ),
        ),
      ),
    );

    if (Navigator.maybeOf(context) != null) {
      return scaffold;
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: scaffold,
    );
  }
}

/// Dynamic loading view that picks Design 4 for sockets/plugs and Design 3 for fans/hubs.
class DynamicModelLoadingView extends StatefulWidget {
  const DynamicModelLoadingView({
    super.key,
    required this.modelId,
    required this.nodeId,
    this.statusText,
  });

  final String modelId;
  final String nodeId;
  final String? statusText;

  @override
  State<DynamicModelLoadingView> createState() => _DynamicModelLoadingViewState();
}

class _DynamicModelLoadingViewState extends State<DynamicModelLoadingView> {
  Timer? _tickerTimer;
  int _tickerIndex = 0;

  static const List<String> _hubTickerMessages = [
    'Connecting to server...',
    'Downloading model schema...',
    'Preparing controls & dials...',
    'Almost ready...',
  ];

  static const List<String> _plugTickerMessages = [
    'Connecting to server...',
    'Fetching socket telemetry...',
    'Setting up smart controls...',
    'Almost ready...',
  ];

  bool get _isSocketOrPlug {
    final lower = widget.modelId.toLowerCase();
    return lower.contains('socket') || lower.contains('plug');
  }

  @override
  void initState() {
    super.initState();
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (mounted) {
        setState(() {
          _tickerIndex = (_tickerIndex + 1) % 4;
        });
      }
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPlug = _isSocketOrPlug;
    final messages = isPlug ? _plugTickerMessages : _hubTickerMessages;
    final currentTicker = widget.statusText != null &&
            widget.statusText!.isNotEmpty &&
            widget.statusText != 'Loading live schema...'
        ? widget.statusText!
        : messages[_tickerIndex % messages.length];

    final title = isPlug
        ? 'Setting up smart controls...'
        : 'Warming up your device...';

    final primaryAccent =
        isPlug ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 1. Vector Character Animation (Design 3 or Design 4)
        SizedBox(
          width: 140,
          height: 155,
          child: isPlug
              ? const SmartPlugLoadingAnimation()
              : const SmartHubLoadingAnimation(),
        ),

        const SizedBox(height: 14),

        // 2. Playful Headline
        Text(
          title,
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),

        const SizedBox(height: 6),

        // 3. Subtitle with Model ID (matches test 'Connecting $modelId')
        Text(
          'Connecting ${widget.modelId}',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            color: const Color(0xB3FFFFFF),
            fontSize: 13,
            fontWeight: FontWeight.w400,
          ),
        ),

        const SizedBox(height: 2),

        // 4. Node identifier (matches test 'Node $nodeId')
        Text(
          'Node ${widget.nodeId}',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            color: const Color(0x66FFFFFF),
            fontSize: 11,
            fontWeight: FontWeight.w400,
          ),
        ),

        const SizedBox(height: 18),

        // 5. Sleek Indeterminate Progress Bar
        SizedBox(
          width: 220,
          height: 3.5,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: const _IndeterminateLoadingBar(),
          ),
        ),

        const SizedBox(height: 16),

        // 6. Dynamic Status Ticker Pill
        Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(10),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white.withAlpha(20)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: primaryAccent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: primaryAccent.withAlpha(128),
                      blurRadius: 4,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    currentTicker,
                    key: ValueKey<String>(currentTicker),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      color: const Color(0xFFCBD5E1),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// DESIGN 3: Smart Hub Waking Up with Wi-Fi Halo and Blinking Eyes
class SmartHubLoadingAnimation extends StatefulWidget {
  const SmartHubLoadingAnimation({super.key});

  @override
  State<SmartHubLoadingAnimation> createState() =>
      _SmartHubLoadingAnimationState();
}

class _SmartHubLoadingAnimationState extends State<SmartHubLoadingAnimation>
    with TickerProviderStateMixin {
  late final AnimationController _floatController;
  late final AnimationController _haloController;
  late final AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);

    _haloController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    )..repeat();
  }

  @override
  void dispose() {
    _floatController.dispose();
    _haloController.dispose();
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _floatController,
        _haloController,
        _blinkController,
      ]),
      builder: (context, child) {
        return CustomPaint(
          size: const Size(140, 155),
          painter: _SmartHubPainter(
            floatProgress: _floatController.value,
            haloProgress: _haloController.value,
            blinkProgress: _blinkController.value,
          ),
        );
      },
    );
  }
}

class _SmartHubPainter extends CustomPainter {
  const _SmartHubPainter({
    required this.floatProgress,
    required this.haloProgress,
    required this.blinkProgress,
  });

  final double floatProgress;
  final double haloProgress;
  final double blinkProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final floatY = math.sin(floatProgress * math.pi) * -8.0;
    final cy = (size.height * 0.58) + floatY;

    // 1. Soft Shadow
    final shadowScale = 1.0 - (floatY.abs() / 20.0);
    final shadowPaint = Paint()
      ..color = Colors.black.withAlpha((56 * shadowScale).round())
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, size.height - 12),
        width: 60 * shadowScale,
        height: 10 * shadowScale,
      ),
      shadowPaint,
    );

    // 2. Wi-Fi Halo Waves
    const waveColor = Color(0xFF38BDF8);
    for (int i = 0; i < 3; i++) {
      final phase = (haloProgress - (i * 0.28)) % 1.0;
      final waveAlpha = (math.sin(phase * math.pi)).clamp(0.15, 1.0);
      final wavePaint = Paint()
        ..color = waveColor.withAlpha((waveAlpha * 0.9 * 255).round().clamp(0, 255))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round;

      final waveRadius = 38.0 + (i * 9.0);
      final waveRect = Rect.fromCircle(
        center: Offset(cx, cy + 6),
        radius: waveRadius,
      );
      canvas.drawArc(waveRect, -math.pi * 0.72, math.pi * 0.44, false, wavePaint);
    }

    // 3. Smart Hub Outer Disk
    final diskPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2;

    const hubRadius = 34.0;
    canvas.drawCircle(Offset(cx, cy), hubRadius, diskPaint);
    canvas.drawCircle(Offset(cx, cy), hubRadius, borderPaint);

    // 4. Subtle Inner Bezel Curves
    final bezelPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: hubRadius - 6),
      math.pi * 0.15,
      math.pi * 0.7,
      false,
      bezelPaint,
    );

    // 5. Cute Eyes (with natural blink)
    final eyePaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    final isBlinking = blinkProgress > 0.47 && blinkProgress < 0.53;
    final eyeScaleY = isBlinking ? 0.1 : 1.0;

    canvas.save();
    canvas.translate(cx, cy - 4);
    canvas.scale(1.0, eyeScaleY);

    // Left eye curve
    final leftPath = Path()
      ..moveTo(-16, 0)
      ..quadraticBezierTo(-12, -4.5, -8, 0);
    canvas.drawPath(leftPath, eyePaint);

    // Right eye curve
    final rightPath = Path()
      ..moveTo(8, 0)
      ..quadraticBezierTo(12, -4.5, 16, 0);
    canvas.drawPath(rightPath, eyePaint);

    canvas.restore();

    // 6. Cute Smile
    final smilePath = Path()
      ..moveTo(cx - 5, cy + 5)
      ..quadraticBezierTo(cx, cy + 8.5, cx + 5, cy + 5);
    canvas.drawPath(smilePath, eyePaint);

    // 7. Bottom Status LED (Breathes between Cyan and Emerald)
    final ledCycle = (math.sin(haloProgress * math.pi * 2) + 1.0) / 2.0;
    final ledColor = Color.lerp(
      const Color(0xFF38BDF8),
      const Color(0xFF10B981),
      ledCycle,
    )!;

    final ledGlow = Paint()
      ..color = ledColor.withAlpha(128)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
    final ledCore = Paint()..color = ledColor;

    final ledCenter = Offset(cx, cy + 24);
    canvas.drawCircle(ledCenter, 4.5, ledGlow);
    canvas.drawCircle(ledCenter, 2.8, ledCore);
  }

  @override
  bool shouldRepaint(covariant _SmartHubPainter oldDelegate) {
    return oldDelegate.floatProgress != floatProgress ||
        oldDelegate.haloProgress != haloProgress ||
        oldDelegate.blinkProgress != blinkProgress;
  }
}

/// DESIGN 4: Minimalist Smart Plug with Wi-Fi Ripple and Blinking Eyes
class SmartPlugLoadingAnimation extends StatefulWidget {
  const SmartPlugLoadingAnimation({super.key});

  @override
  State<SmartPlugLoadingAnimation> createState() =>
      _SmartPlugLoadingAnimationState();
}

class _SmartPlugLoadingAnimationState extends State<SmartPlugLoadingAnimation>
    with TickerProviderStateMixin {
  late final AnimationController _floatController;
  late final AnimationController _wifiController;
  late final AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _wifiController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
  }

  @override
  void dispose() {
    _floatController.dispose();
    _wifiController.dispose();
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _floatController,
        _wifiController,
        _blinkController,
      ]),
      builder: (context, child) {
        return CustomPaint(
          size: const Size(140, 155),
          painter: _SmartPlugPainter(
            floatProgress: _floatController.value,
            wifiProgress: _wifiController.value,
            blinkProgress: _blinkController.value,
          ),
        );
      },
    );
  }
}

class _SmartPlugPainter extends CustomPainter {
  const _SmartPlugPainter({
    required this.floatProgress,
    required this.wifiProgress,
    required this.blinkProgress,
  });

  final double floatProgress;
  final double wifiProgress;
  final double blinkProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final floatY = math.sin(floatProgress * math.pi) * -8.5;
    final cy = (size.height * 0.58) + floatY;

    // 1. Soft Shadow
    final shadowScale = 1.0 - (floatY.abs() / 20.0);
    final shadowPaint = Paint()
      ..color = Colors.black.withAlpha((51 * shadowScale).round())
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, size.height - 12),
        width: 52 * shadowScale,
        height: 8 * shadowScale,
      ),
      shadowPaint,
    );

    // 2. Wi-Fi Waves
    const waveColor = Color(0xFFF59E0B);
    for (int i = 0; i < 3; i++) {
      final phase = (wifiProgress - (i * 0.28)) % 1.0;
      final waveAlpha = (math.sin(phase * math.pi)).clamp(0.15, 1.0);
      final wavePaint = Paint()
        ..color = waveColor.withAlpha((waveAlpha * 0.9 * 255).round().clamp(0, 255))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round;

      final waveRadius = 38.0 + (i * 9.0);
      final waveRect = Rect.fromCircle(
        center: Offset(cx, cy - 10),
        radius: waveRadius,
      );
      canvas.drawArc(waveRect, -math.pi * 0.72, math.pi * 0.44, false, wavePaint);
    }

    // 3. Plug Body (Rounded Rectangle)
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: 56, height: 66),
      const Radius.circular(16),
    );

    final fillPaint = Paint()..color = Colors.white;
    final strokePaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2;

    canvas.drawRRect(bodyRect, fillPaint);
    canvas.drawRRect(bodyRect, strokePaint);

    // 4. Side 3D Edge Bevel
    final bevelPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..style = PaintingStyle.fill;
    final bevelPath = Path()
      ..moveTo(cx + 20, cy - 24)
      ..lineTo(cx + 26, cy - 18)
      ..lineTo(cx + 26, cy + 20)
      ..lineTo(cx + 20, cy + 24)
      ..close();
    canvas.drawPath(bevelPath, bevelPaint);

    // Side Power Button (Warm Amber)
    final sideButton = Paint()..color = const Color(0xFFF59E0B);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx + 24, cy - 8, 4.5, 15),
        const Radius.circular(2),
      ),
      sideButton,
    );

    // 5. Cute Face & Eyes
    final isBlinking = blinkProgress > 0.47 && blinkProgress < 0.53;
    final eyePaint = Paint()..color = const Color(0xFF0F172A);

    if (isBlinking) {
      final blinkStroke = Paint()
        ..color = const Color(0xFF0F172A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(cx - 13, cy - 12),
        Offset(cx - 7, cy - 12),
        blinkStroke,
      );
      canvas.drawLine(
        Offset(cx + 7, cy - 12),
        Offset(cx + 13, cy - 12),
        blinkStroke,
      );
    } else {
      canvas.drawCircle(Offset(cx - 10, cy - 12), 3.0, eyePaint);
      canvas.drawCircle(Offset(cx + 10, cy - 12), 3.0, eyePaint);
    }

    // Smile
    final smilePaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    final smilePath = Path()
      ..moveTo(cx - 4, cy - 5)
      ..quadraticBezierTo(cx, cy - 2, cx + 4, cy - 5);
    canvas.drawPath(smilePath, smilePaint);

    // 6. Socket Pins (Two vertical slots + ground hole)
    final pinPaint = Paint()..color = const Color(0xFF0F172A);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx - 11, cy + 10), width: 4.5, height: 12),
        const Radius.circular(2),
      ),
      pinPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx + 11, cy + 10), width: 4.5, height: 12),
        const Radius.circular(2),
      ),
      pinPaint,
    );

    // Ground slot
    final groundPath = Path()
      ..moveTo(cx - 2.5, cy + 22)
      ..lineTo(cx + 2.5, cy + 22)
      ..lineTo(cx + 2.5, cy + 25)
      ..quadraticBezierTo(cx, cy + 27, cx - 2.5, cy + 25)
      ..close();
    canvas.drawPath(groundPath, pinPaint);

    // 7. Cord Tail
    final cordPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round;
    final cordPath = Path()
      ..moveTo(cx, cy + 33)
      ..quadraticBezierTo(cx, cy + 44, cx + 12, cy + 46);
    canvas.drawPath(cordPath, cordPaint);

    // Tiny Plug Head on Cord
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx + 12, cy + 41, 8, 9),
        const Radius.circular(2),
      ),
      pinPaint,
    );
    canvas.drawLine(
      Offset(cx + 20, cy + 43),
      Offset(cx + 23, cy + 43),
      Paint()
        ..color = const Color(0xFF0F172A)
        ..strokeWidth = 2.2,
    );
    canvas.drawLine(
      Offset(cx + 20, cy + 47),
      Offset(cx + 23, cy + 47),
      Paint()
        ..color = const Color(0xFF0F172A)
        ..strokeWidth = 2.2,
    );
  }

  @override
  bool shouldRepaint(covariant _SmartPlugPainter oldDelegate) {
    return oldDelegate.floatProgress != floatProgress ||
        oldDelegate.wifiProgress != wifiProgress ||
        oldDelegate.blinkProgress != blinkProgress;
  }
}

/// Smooth Indeterminate Progress Bar
class _IndeterminateLoadingBar extends StatefulWidget {
  const _IndeterminateLoadingBar({
    this.trackColor,
    this.thumbGradient,
  });

  final Color? trackColor;
  final Gradient? thumbGradient;

  @override
  State<_IndeterminateLoadingBar> createState() =>
      _IndeterminateLoadingBarState();
}

class _IndeterminateLoadingBarState extends State<_IndeterminateLoadingBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: widget.trackColor ?? Colors.white.withAlpha(20),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final x = _controller.value;
          return LayoutBuilder(
            builder: (context, constraints) {
              final thumbWidth = constraints.maxWidth * 0.4;
              final left = (constraints.maxWidth + thumbWidth) * x - thumbWidth;
              return Stack(
                children: [
                  Positioned(
                    left: left,
                    top: 0,
                    bottom: 0,
                    width: thumbWidth,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: widget.thumbGradient ??
                            const LinearGradient(
                              colors: [
                                Color(0xFF38BDF8),
                                Color(0xFF818CF8),
                              ],
                            ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// DESIGN 4 (In-Page Multi-Page Loader): Mini Orbit Satellite Helper
/// Features a compact spherical smart character with cute blinking eyes,
/// gentle floating bobbing, and an elliptical 3D tilted orbit ring with
/// an amber satellite beacon circling with authentic front/back depth sorting.
class MiniOrbitLoadingAnimation extends StatefulWidget {
  const MiniOrbitLoadingAnimation({
    super.key,
    this.size = 120.0,
    this.accentColor = const Color(0xFFF59E0B),
  });

  final double size;
  final Color accentColor;

  @override
  State<MiniOrbitLoadingAnimation> createState() =>
      _MiniOrbitLoadingAnimationState();
}

class _MiniOrbitLoadingAnimationState extends State<MiniOrbitLoadingAnimation>
    with TickerProviderStateMixin {
  late final AnimationController _floatController;
  late final AnimationController _orbitController;
  late final AnimationController _blinkController;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _floatController.dispose();
    _orbitController.dispose();
    _blinkController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _floatController,
        _orbitController,
        _blinkController,
        _pulseController,
      ]),
      builder: (context, child) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _MiniOrbitPainter(
            floatProgress: _floatController.value,
            orbitProgress: _orbitController.value,
            blinkProgress: _blinkController.value,
            pulseProgress: _pulseController.value,
            accentColor: widget.accentColor,
          ),
        );
      },
    );
  }
}

class _MiniOrbitPainter extends CustomPainter {
  const _MiniOrbitPainter({
    required this.floatProgress,
    required this.orbitProgress,
    required this.blinkProgress,
    required this.pulseProgress,
    required this.accentColor,
  });

  final double floatProgress;
  final double orbitProgress;
  final double blinkProgress;
  final double pulseProgress;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final floatY = math.sin(floatProgress * math.pi) * -6.0;
    final cy = (size.height * 0.52) + floatY;

    // 1. Soft Drop Shadow
    final shadowScale = (1.0 - (floatY.abs() / 16.0)).clamp(0.5, 1.0);
    final shadowPaint = Paint()
      ..color = Colors.black.withAlpha((45 * shadowScale).round())
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, size.height - 10),
        width: (size.width * 0.42) * shadowScale,
        height: 7.0 * shadowScale,
      ),
      shadowPaint,
    );

    // 2. Orbital Geometry
    const a = 42.0; // semi-major axis
    const b = 15.0; // semi-minor axis
    const tilt = -22.0 * (math.pi / 180.0); // -22 deg tilt angle

    final theta = orbitProgress * 2 * math.pi;
    final sinTheta = math.sin(theta);
    final cosTheta = math.cos(theta);

    // Unrotated ellipse coordinate
    final rawX = cosTheta * a;
    final rawY = sinTheta * b;

    // Tilted coordinate
    final satX = rawX * math.cos(tilt) - rawY * math.sin(tilt);
    final satY = rawX * math.sin(tilt) + rawY * math.cos(tilt);
    final satOffset = Offset(cx + satX, cy + satY);

    // In 3D orbital space, when sinTheta < 0, the satellite is behind the sphere
    final isSatelliteBehind = sinTheta < 0;

    // A. Back half of the orbit ring (behind the sphere)
    _drawOrbitHalf(canvas, cx, cy, a, b, tilt, isFront: false);

    // Satellite when BEHIND the sphere
    if (isSatelliteBehind) {
      _drawSatellite(canvas, satOffset, isFront: false);
    }

    // B. Central Sphere (The Smart Helper)
    const sphereRadius = 24.0;

    final sphereFill = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final sphereBorder = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.6;

    canvas.drawCircle(Offset(cx, cy), sphereRadius, sphereFill);
    canvas.drawCircle(Offset(cx, cy), sphereRadius, sphereBorder);

    // Forehead Green Pulse LED
    final ledAlpha = (140 + (pulseProgress * 115)).round().clamp(0, 255);
    final ledColor = const Color(0xFF10B981).withAlpha(ledAlpha);
    final ledGlow = Paint()
      ..color = ledColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
    final ledCenter = Offset(cx, cy - 16);
    canvas.drawCircle(ledCenter, 3.2, ledGlow);
    canvas.drawCircle(ledCenter, 2.0, Paint()..color = ledColor);

    // Face - Eyes & Smile
    final isBlinking = blinkProgress > 0.47 && blinkProgress < 0.53;
    final facePaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    if (isBlinking) {
      canvas.drawLine(Offset(cx - 10, cy - 2), Offset(cx - 6, cy - 2), facePaint);
      canvas.drawLine(Offset(cx + 6, cy - 2), Offset(cx + 10, cy - 2), facePaint);
    } else {
      final eyeFill = Paint()..color = const Color(0xFF0F172A);
      canvas.drawCircle(Offset(cx - 8, cy - 2), 2.4, eyeFill);
      canvas.drawCircle(Offset(cx + 8, cy - 2), 2.4, eyeFill);
    }

    // Cute Smile
    final smilePath = Path()
      ..moveTo(cx - 4, cy + 4)
      ..quadraticBezierTo(cx, cy + 7, cx + 4, cy + 4);
    canvas.drawPath(smilePath, facePaint);

    // C. Front half of the orbit ring (in front of the sphere)
    _drawOrbitHalf(canvas, cx, cy, a, b, tilt, isFront: true);

    // Satellite when IN FRONT of the sphere
    if (!isSatelliteBehind) {
      _drawSatellite(canvas, satOffset, isFront: true);
    }
  }

  void _drawOrbitHalf(
    Canvas canvas,
    double cx,
    double cy,
    double a,
    double b,
    double tilt, {
    required bool isFront,
  }) {
    final ringPaint = Paint()
      ..color = accentColor.withAlpha(isFront ? 180 : 100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isFront ? 2.4 : 1.9;

    final startAngle = isFront ? 0.0 : math.pi;
    final endAngle = isFront ? math.pi : 2 * math.pi;
    const step = 0.08;

    final path = Path();
    bool first = true;

    for (double t = startAngle; t <= endAngle; t += step) {
      final rx = math.cos(t) * a;
      final ry = math.sin(t) * b;
      final px = cx + (rx * math.cos(tilt) - ry * math.sin(tilt));
      final py = cy + (rx * math.sin(tilt) + ry * math.cos(tilt));

      if (first) {
        path.moveTo(px, py);
        first = false;
      } else {
        path.lineTo(px, py);
      }
    }

    canvas.drawPath(path, ringPaint);
  }

  void _drawSatellite(Canvas canvas, Offset satOffset, {required bool isFront}) {
    final glowPaint = Paint()
      ..color = accentColor.withAlpha(isFront ? 180 : 90)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isFront ? 6.0 : 3.0);
    final corePaint = Paint()
      ..color = accentColor.withAlpha(255);

    final radius = isFront ? 4.2 : 3.0;
    canvas.drawCircle(satOffset, radius * 1.8, glowPaint);
    canvas.drawCircle(satOffset, radius, corePaint);
  }

  @override
  bool shouldRepaint(covariant _MiniOrbitPainter oldDelegate) {
    return oldDelegate.floatProgress != floatProgress ||
        oldDelegate.orbitProgress != orbitProgress ||
        oldDelegate.blinkProgress != blinkProgress ||
        oldDelegate.pulseProgress != pulseProgress ||
        oldDelegate.accentColor != accentColor;
  }
}

/// Compact in-page loading card widget displayed inside multi-page containers
/// while Page 2, Page 3, etc. are fetching their live schema.
/// Styled with black headline and slate subtitle for clear contrast on light backgrounds.
class MiniOrbitPageLoadingView extends StatefulWidget {
  const MiniOrbitPageLoadingView({
    super.key,
    this.pageNo,
    this.pageTitle,
    this.accentColor = const Color(0xFFF59E0B),
    this.headlineColor,
    this.subtitleColor,
    this.isDark = false,
  });

  final int? pageNo;
  final String? pageTitle;
  final Color accentColor;
  final Color? headlineColor;
  final Color? subtitleColor;
  final bool isDark;

  @override
  State<MiniOrbitPageLoadingView> createState() =>
      _MiniOrbitPageLoadingViewState();
}

class _MiniOrbitPageLoadingViewState extends State<MiniOrbitPageLoadingView> {
  Timer? _tickerTimer;
  int _tickerIndex = 0;

  static const List<String> _tickerMessages = [
    'Connecting cloud socket...',
    'Buffering dials & switches...',
    'Calibrating telemetry...',
    'Almost ready...',
  ];

  @override
  void initState() {
    super.initState();
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
      if (mounted) {
        setState(() {
          _tickerIndex = (_tickerIndex + 1) % _tickerMessages.length;
        });
      }
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final headline = widget.pageNo != null
        ? 'Preparing Page ${widget.pageNo} Controls...'
        : 'Preparing Page Controls...';
    final subtitle = widget.pageTitle ?? 'Loading dials and telemetry';
    final currentTicker = _tickerMessages[_tickerIndex % _tickerMessages.length];

    // Responsive colors: Black & Slate on light/white background, white on dark
    final headlineColor = widget.headlineColor ??
        (widget.isDark ? Colors.white : const Color(0xFF0F172A));
    final subtitleColor = widget.subtitleColor ??
        (widget.isDark ? const Color(0xB3FFFFFF) : const Color(0xFF64748B));
    final trackColor = widget.isDark
        ? Colors.white.withAlpha(20)
        : const Color(0xFFE2E8F0);
    final pillBg = widget.isDark
        ? Colors.white.withAlpha(10)
        : const Color(0xFFF1F5F9);
    final pillBorder = widget.isDark
        ? Colors.white.withAlpha(20)
        : const Color(0xFFCBD5E1);
    final pillTextColor = widget.isDark
        ? const Color(0xFFCBD5E1)
        : const Color(0xFF334155);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Mini Orbit Character
          MiniOrbitLoadingAnimation(
            size: 110,
            accentColor: widget.accentColor,
          ),

          const SizedBox(height: 12),

          // 2. Headline (Black)
          Text(
            headline,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: headlineColor,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 4),

          // 3. Subtitle (Slate grey)
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              color: subtitleColor,
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),

          const SizedBox(height: 14),

          // 4. Slim Indeterminate Progress Bar
          SizedBox(
            width: 150,
            height: 3.0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _IndeterminateLoadingBar(
                trackColor: trackColor,
                thumbGradient: LinearGradient(
                  colors: [
                    widget.accentColor,
                    widget.accentColor.withAlpha(190),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 14),

          // 5. Dynamic Ticker Pill
          Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: pillBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: widget.accentColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: widget.accentColor.withAlpha(128),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: Text(
                      currentTicker,
                      key: ValueKey<String>(currentTicker),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        color: pillTextColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


