import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Converts the production SDUI visual contract into Flutter primitives.
///
/// Handles design tokens, hex/rgba colors, linear/radial gradients, spacing,
/// borders, shadows, alignment, and typography with strict null-safety and
/// graceful fallback behaviour.
class SduiStyle {
  SduiStyle(Map? json, {Map<String, dynamic>? tokens})
    : s = json == null ? const {} : Map<String, dynamic>.from(json),
      tokens = tokens ?? const {};

  final Map<String, dynamic> s;
  final Map<String, dynamic> tokens;

  /// Resolves value or theme token reference (e.g. "{theme.colors.primary}").
  dynamic value(String key) => _resolveToken(s[key]);

  dynamic _resolveToken(dynamic raw) {
    if (raw is! String) return raw;
    final match = RegExp(r'^\{([^}]+)\}$').firstMatch(raw.trim());
    if (match == null) return raw;

    dynamic current = tokens;
    for (final part in match.group(1)!.split('.')) {
      if (current is! Map || !current.containsKey(part)) return raw;
      current = current[part];
    }
    return current;
  }

  /// Parses color strings in formats: hex (#RGB, #RGBA, #RRGGBB, #AARRGGBB),
  /// rgb(), rgba(), named transparent, or returns null safely.
  static Color? color(dynamic value) {
    if (value == null) return null;
    if (value is Color) return value;
    final raw = value.toString().trim();
    if (raw.isEmpty || raw == 'transparent') {
      return raw == 'transparent' ? Colors.transparent : null;
    }

    // RGBA / RGB regex
    final rgbaMatch = RegExp(
      r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+))?\s*\)$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (rgbaMatch != null) {
      try {
        final r = int.parse(rgbaMatch.group(1)!).clamp(0, 255);
        final g = int.parse(rgbaMatch.group(2)!).clamp(0, 255);
        final b = int.parse(rgbaMatch.group(3)!).clamp(0, 255);
        final alpha = (double.tryParse(rgbaMatch.group(4) ?? '1') ?? 1.0).clamp(
          0.0,
          1.0,
        );
        return Color.fromARGB((alpha * 255).round(), r, g, b);
      } catch (_) {
        return null;
      }
    }

    // Hex parsing (#RGB, #RGBA, #RRGGBB, #AARRGGBB, or without #)
    var hex = raw.startsWith('#') ? raw.substring(1) : raw;
    if (hex.length == 3) {
      hex = '${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
    } else if (hex.length == 4) {
      hex =
          '${hex[3]}${hex[3]}${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
    }

    if (hex.length == 6) {
      hex = 'FF$hex';
    }

    if (hex.length == 8) {
      final parsed = int.tryParse(hex, radix: 16);
      return parsed == null ? null : Color(parsed);
    }

    return null;
  }

  Color? get backgroundColor =>
      color(_resolveToken(s['backgroundColor'] ?? s['color']));

  static double? _dimension(dynamic value) {
    if (value is num) return value.toDouble();
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return null;

    final simple = RegExp(
      r'^(-?[0-9]+(?:\.[0-9]+)?)\s*(?:px|dp|sp)?$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (simple != null) return double.tryParse(simple.group(1)!);

    final calc = RegExp(
      r'^calc\(\s*(-?[0-9]+(?:\.[0-9]+)?)\s*(?:px|dp)?\s*([+-])\s*'
      r'(-?[0-9]+(?:\.[0-9]+)?)\s*(?:px|dp)?\s*\)$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (calc != null) {
      final a = double.tryParse(calc.group(1)!)!;
      final b = double.tryParse(calc.group(3)!)!;
      return calc.group(2) == '-' ? a - b : a + b;
    }
    return null;
  }

  EdgeInsets _edge(String key) {
    final raw = _resolveToken(s[key]);
    final all = _dimension(raw);
    if (all != null) return EdgeInsets.all(all);

    if (raw is String) {
      final parts = raw
          .trim()
          .split(RegExp(r'\s+'))
          .map(_dimension)
          .toList(growable: false);
      if (parts.isNotEmpty && parts.every((v) => v != null)) {
        if (parts.length == 2) {
          return EdgeInsets.symmetric(
            vertical: parts[0]!,
            horizontal: parts[1]!,
          );
        }
        if (parts.length == 3) {
          return EdgeInsets.fromLTRB(
            parts[1]!,
            parts[0]!,
            parts[1]!,
            parts[2]!,
          );
        }
        if (parts.length == 4) {
          return EdgeInsets.fromLTRB(
            parts[3]!,
            parts[0]!,
            parts[1]!,
            parts[2]!,
          );
        }
      }
    }

    if (raw is Map) {
      final horizontal = _dimension(raw['horizontal']);
      final vertical = _dimension(raw['vertical']);
      return EdgeInsets.only(
        top: _dimension(raw['top']) ?? vertical ?? 0,
        right: _dimension(raw['right']) ?? horizontal ?? 0,
        bottom: _dimension(raw['bottom']) ?? vertical ?? 0,
        left: _dimension(raw['left']) ?? horizontal ?? 0,
      );
    }
    return EdgeInsets.zero;
  }

  EdgeInsets get padding => _edge('padding');
  EdgeInsets get margin => _edge('margin');

  double? dim(String key) => _dimension(_resolveToken(s[key]));

  BorderRadius get borderRadius {
    final raw = _resolveToken(s['borderRadius']);
    final radiusValue = _dimension(raw);
    if (radiusValue != null) return BorderRadius.circular(radiusValue);
    if (raw is Map) {
      return BorderRadius.only(
        topLeft: Radius.circular(_dimension(raw['topLeft']) ?? 0),
        topRight: Radius.circular(_dimension(raw['topRight']) ?? 0),
        bottomLeft: Radius.circular(_dimension(raw['bottomLeft']) ?? 0),
        bottomRight: Radius.circular(_dimension(raw['bottomRight']) ?? 0),
      );
    }
    return BorderRadius.zero;
  }

  Border? get border {
    final nested = s['border'];
    final width = nested is Map
        ? _dimension(nested['width'])
        : _dimension(s['borderWidth']);
    final rawColor = nested is Map ? nested['color'] : s['borderColor'];
    final borderColor = color(_resolveToken(rawColor));
    if ((width ?? 0) <= 0 || borderColor == null) return null;
    return Border.all(width: width!, color: borderColor);
  }

  List<BoxShadow>? get shadow {
    final raw = s['shadow'];
    if (raw is! Map) return null;
    final shadowColor = color(_resolveToken(raw['color']));
    if (shadowColor == null) return null;
    return <BoxShadow>[
      BoxShadow(
        color: shadowColor,
        offset: Offset(
          ((raw['x'] ?? raw['offsetX']) as num?)?.toDouble() ?? 0,
          ((raw['y'] ?? raw['offsetY']) as num?)?.toDouble() ?? 0,
        ),
        blurRadius:
            ((raw['blur'] ?? raw['blurRadius']) as num?)?.toDouble() ?? 0,
        spreadRadius:
            ((raw['spread'] ?? raw['spreadRadius']) as num?)?.toDouble() ?? 0,
      ),
    ];
  }

  Gradient? get gradient {
    final legacy = s['gradient'];
    if (legacy is Map) {
      final colors = (legacy['colors'] as List? ?? const [])
          .map((item) => color(_resolveToken(item)))
          .whereType<Color>()
          .toList();
      if (colors.length >= 2) {
        final begin = _alignment(legacy['begin']);
        final end = _alignment(legacy['end']);
        if (begin == null || end == null) return null;
        return LinearGradient(begin: begin, end: end, colors: colors);
      }
    }

    final background = s['background'];
    if (background is! Map) return null;
    return _gradientFromBackground(Map<String, dynamic>.from(background));
  }

  Gradient? _gradientFromBackground(Map<String, dynamic> background) {
    final type = background['type']?.toString();
    if (type == 'layered') {
      final layers = background['layers'] as List? ?? const [];
      final maps = layers.whereType<Map>().map(Map<String, dynamic>.from);
      for (final layer in maps.toList().reversed) {
        final result = _gradientFromBackground(layer);
        if (result != null) return result;
      }
      return null;
    }

    final stops = background['stops'] as List? ?? const [];
    final colors = <Color>[];
    final positions = <double>[];
    for (final raw in stops.whereType<Map>()) {
      final parsed = color(_resolveToken(raw['color']));
      if (parsed == null) continue;
      colors.add(parsed);
      final offset = (raw['offset'] as num?)?.toDouble();
      if (offset == null) return null;
      positions.add(offset);
    }
    if (colors.length < 2) return null;

    if (type == 'radialGradient') {
      final center = background['center'] as Map?;
      final centerX = (center?['x'] as num?)?.toDouble();
      final centerY = (center?['y'] as num?)?.toDouble();
      final radius = (background['radius'] as num?)?.toDouble();
      if (centerX == null || centerY == null || radius == null) return null;
      return RadialGradient(
        center: Alignment(centerX * 2 - 1, centerY * 2 - 1),
        radius: radius,
        colors: colors,
        stops: positions,
      );
    }

    if (type != 'linearGradient') return null;
    final angle = (background['angle'] as num?)?.toDouble();
    if (angle == null) return null;
    final radians = angle * math.pi / 180;
    final dx = math.cos(radians);
    final dy = math.sin(radians);
    return LinearGradient(
      begin: Alignment(-dx, -dy),
      end: Alignment(dx, dy),
      colors: colors,
      stops: positions,
    );
  }

  static Alignment? _alignment(dynamic value) {
    switch (value?.toString()) {
      case 'topLeft':
        return Alignment.topLeft;
      case 'top':
      case 'topCenter':
        return Alignment.topCenter;
      case 'topRight':
        return Alignment.topRight;
      case 'centerLeft':
        return Alignment.centerLeft;
      case 'center':
        return Alignment.center;
      case 'centerRight':
        return Alignment.centerRight;
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottom':
      case 'bottomCenter':
        return Alignment.bottomCenter;
      case 'bottomRight':
        return Alignment.bottomRight;
      default:
        return null;
    }
  }

  Alignment? get alignment => _alignment(s['alignment']);

  BoxDecoration? get decoration {
    final background = backgroundColor;
    final resolvedGradient = gradient;
    final resolvedBorder = border;
    final resolvedShadow = shadow;
    final radius = borderRadius;

    if (background == null &&
        resolvedGradient == null &&
        resolvedBorder == null &&
        resolvedShadow == null &&
        radius == BorderRadius.zero) {
      return null;
    }

    return BoxDecoration(
      color: resolvedGradient == null ? background : null,
      gradient: resolvedGradient,
      borderRadius: radius == BorderRadius.zero ? null : radius,
      border: resolvedBorder,
      boxShadow: resolvedShadow,
    );
  }

  TextStyle? textStyle(TextStyle base) {
    final nested = s['textStyle'];
    final raw = nested is Map ? nested : s;

    final size = _dimension(raw['fontSize']);
    final lineHeight = _dimension(raw['lineHeight']);
    final textColor = color(_resolveToken(raw['color'] ?? raw['textColor']));

    if (size == null &&
        lineHeight == null &&
        textColor == null &&
        raw['fontWeight'] == null &&
        raw['letterSpacing'] == null) {
      return null;
    }

    return base.copyWith(
      fontSize: size,
      height: lineHeight,
      letterSpacing: _dimension(raw['letterSpacing']),
      color: textColor,
      fontWeight: fontWeight(raw['fontWeight']),
      fontFamily: raw['fontFamily']?.toString(),
    );
  }

  /// Applies a schema-declared font family without assuming that the font is
  /// installed on the Android/iOS device. Google Fonts is already a project
  /// dependency; unsupported families gracefully fall back to Flutter's normal
  /// family lookup rather than introducing a model-specific font rule.
  static TextStyle withFontFamily(TextStyle base, dynamic family) {
    final name = family?.toString().trim();
    if (name == null || name.isEmpty) return base;
    try {
      return GoogleFonts.getFont(name, textStyle: base);
    } catch (_) {
      return base.copyWith(fontFamily: name);
    }
  }

  static FontWeight? fontWeight(dynamic value) {
    if (value is num) {
      final index = (value.toInt() ~/ 100 - 1).clamp(0, 8);
      return FontWeight.values[index];
    }

    switch (value?.toString().toLowerCase()) {
      case 'normal':
      case 'regular':
      case 'w400':
      case '400':
        return FontWeight.w400;
      case 'medium':
      case 'w500':
      case '500':
        return FontWeight.w500;
      case 'semibold':
      case 'semi-bold':
      case 'w600':
      case '600':
        return FontWeight.w600;
      case 'bold':
      case 'w700':
      case '700':
        return FontWeight.w700;
      case 'extrabold':
      case 'extra-bold':
      case 'w800':
      case '800':
        return FontWeight.w800;
      case 'black':
      case 'w900':
      case '900':
        return FontWeight.w900;
      default:
        return null;
    }
  }

  static Map<String, dynamic> deepMerge(Map? base, Map? overlay) {
    final result = Map<String, dynamic>.from(base ?? const {});
    for (final entry in (overlay ?? const {}).entries) {
      final existing = result[entry.key];
      if (existing is Map && entry.value is Map) {
        result[entry.key.toString()] = deepMerge(existing, entry.value as Map);
      } else {
        result[entry.key.toString()] = entry.value;
      }
    }
    return result;
  }
}
