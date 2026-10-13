import 'package:flutter/material.dart';

/// Central responsive utility for screen-adaptive layout.
///
/// Usage:
///   final r = ResponsiveUtil.of(context);
///   double size = r.scale(48);   // scales 48px relative to device screen
///   int cols  = r.columnCount;   // 2 on phone, 3 on phablet, 4 on tablet
///
/// Breakpoints (logical pixels):
///   Phone    : width < 600
///   Phablet  : 600 <= width < 840
///   Tablet   : width >= 840
class ResponsiveUtil {
  const ResponsiveUtil._({
    required this.screenWidth,
    required this.screenHeight,
    required this.scaleFactor,
    required this.textScale,
    required this.isTablet,
    required this.isPhablet,
    required this.isPhone,
    required this.columnCount,
  });

  final double screenWidth;
  final double screenHeight;

  /// Scale multiplier relative to 375px baseline phone width.
  /// Clamped to [0.80 ... 1.50] to prevent extreme scaling.
  final double scaleFactor;

  /// Text scale factor (separate, clamped tighter [0.85 ... 1.30]).
  final double textScale;

  final bool isTablet;
  final bool isPhablet;
  final bool isPhone;

  /// Recommended grid column count for the current screen width.
  final int columnCount;

  /// Resolve from the nearest [BuildContext].
  static ResponsiveUtil of(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width;

    // Scale relative to 375px (iPhone SE / baseline phone).
    final raw = width / 375.0;
    final scale = raw.clamp(0.80, 1.50);
    final textS = raw.clamp(0.85, 1.30);

    final isTablet = width >= 840;
    final isPhablet = width >= 600 && width < 840;
    final isPhone = width < 600;

    final cols = isTablet ? 4 : (isPhablet ? 3 : 2);

    return ResponsiveUtil._(
      screenWidth: width,
      screenHeight: size.height,
      scaleFactor: scale,
      textScale: textS,
      isTablet: isTablet,
      isPhablet: isPhablet,
      isPhone: isPhone,
      columnCount: cols,
    );
  }

  /// Scale a dimension (width, height, padding, radius, etc.).
  double scale(double value) => value * scaleFactor;

  /// Scale a font size.
  double scaleText(double value) => value * textScale;

  /// Return a responsive EdgeInsets from a uniform value.
  EdgeInsets scaledPadding(double all) => EdgeInsets.all(scale(all));

  EdgeInsets scaledPaddingSymmetric({
    double horizontal = 0,
    double vertical = 0,
  }) => EdgeInsets.symmetric(
    horizontal: scale(horizontal),
    vertical: scale(vertical),
  );

  /// Clamp a schema pixel value through the scale factor.
  double scaleClamp(double value, {double max = double.infinity}) {
    return scale(value).clamp(0.0, max);
  }
}
