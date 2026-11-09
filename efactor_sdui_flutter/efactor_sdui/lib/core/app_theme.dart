import 'package:flutter/material.dart';

/// Central light/dark [ThemeData] for the native Flutter chrome (loaders,
/// scaffolds, dialogs, nav) that sits around the server-driven UI. The dark
/// theme mirrors the app's existing colors so enabling theming does not change
/// today's look; the light theme is the counterpart.
///
/// Server-driven surface colors still come from their schemas; this is the
/// Flutter-side baseline so every MaterialApp can follow the shared theme.
class AppTheme {
  AppTheme._();

  // Brand / surface colors taken from the current dark SDUI palette.
  static const Color _darkBg = Color(0xFF07131F); // app background navy
  static const Color _darkSurface = Color(0xFF0F172A); // cards / sheets
  static const Color _darkSurfaceAlt = Color(0xFF111827);
  static const Color _accent = Color(0xFF38BDF8); // cyan accent
  static const Color _accentDark = Color(0xFF0284C7); // accent for light bg

  static const Color _lightBg = Color(0xFFF8FAFC);
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightText = Color(0xFF0F172A);
  static const Color _lightTextMuted = Color(0xFF64748B);

  static ThemeData get dark {
    final scheme = const ColorScheme.dark(
      primary: _accent,
      secondary: _accent,
      surface: _darkSurface,
      onSurface: Colors.white,
      error: Color(0xFFFB7185),
    ).copyWith(
      surfaceContainerHighest: _darkSurfaceAlt,
      onSurfaceVariant: const Color(0xFF94A3B8),
    );
    return _base(scheme, _darkBg);
  }

  static ThemeData get light {
    final scheme = const ColorScheme.light(
      primary: _accentDark,
      secondary: _accentDark,
      surface: _lightSurface,
      onSurface: _lightText,
      error: Color(0xFFE11D48),
    ).copyWith(
      surfaceContainerHighest: const Color(0xFFF1F5F9),
      onSurfaceVariant: _lightTextMuted,
    );
    return _base(scheme, _lightBg);
  }

  static ThemeData _base(ColorScheme scheme, Color scaffoldBg) {
    final isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBg,
      canvasColor: scaffoldBg,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBg,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
      ),
      dividerColor: isDark ? const Color(0x1AFFFFFF) : const Color(0x14000000),
    );
  }
}
