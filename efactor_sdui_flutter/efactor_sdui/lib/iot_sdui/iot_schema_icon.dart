import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../sdui/icons.dart';

class IotSchemaIcon {
  const IotSchemaIcon(this.schema);

  final Map<String, dynamic> schema;

  Widget buildNamed(
    BuildContext context, {
    required String name,
    double? width,
    double? height,
    Color? color,
    double? opacity,
    String? semanticLabel,
  }) {
    final definition = resolveNamedDefinition(name);
    if (definition != null) {
      return buildDefinition(
        context,
        definition: definition,
        width: width,
        height: height,
        color: color,
        opacity: opacity,
        semanticLabel: semanticLabel,
      );
    }

    // Dynamic fallback to SduiIconRegistry / Material Icons when omitted from schema
    final fallbackIcon = SduiIconRegistry.instance.resolve(
      name,
      fallbackName: 'device',
      defaultIcon: Icons.widgets_outlined,
    );
    final effectiveSize = width ?? height ?? 24.0;
    Widget icon = Icon(
      fallbackIcon,
      size: effectiveSize,
      color: color,
    );

    final effectiveOpacity = (opacity ?? 1.0).clamp(0.0, 1.0).toDouble();
    if (effectiveOpacity != 1.0) {
      icon = Opacity(opacity: effectiveOpacity, child: icon);
    }

    if (semanticLabel != null && semanticLabel.trim().isNotEmpty) {
      icon = Semantics(image: true, label: semanticLabel, child: icon);
    }

    return icon;
  }

  /// Resolves either:
  ///   icons.<name>
  ///   icons.catalog.<name>
  /// without tying Flutter to a schema version.
  Map<String, dynamic>? resolveNamedDefinition(String name) {
    final icons = _map(schema['icons']);
    if (icons == null) return null;

    final direct = _map(icons[name]);
    if (direct != null) return direct;

    final catalog = _map(icons['catalog']);
    return _map(catalog?[name]);
  }

  Widget buildDefinition(
    BuildContext context, {
    required Map<String, dynamic> definition,
    double? width,
    double? height,
    Color? color,
    double? opacity,
    String? semanticLabel,
  }) {
    final type = definition['type']?.toString().trim().toLowerCase();
    final hasSvgMarkup =
        definition['svgMarkup']?.toString().trim().isNotEmpty == true;

    if (type != null && type.isNotEmpty && type != 'svg' && !hasSvgMarkup) {
      return _missingIcon(
        context,
        'Unsupported icon type ${definition['type']}',
      );
    }

    final svg = _svg(definition);
    if (svg == null || svg.trim().isEmpty) {
      return _missingIcon(context, 'Invalid SVG icon definition');
    }

    Widget icon = SvgPicture.string(
      svg,
      width:
          width ??
          _number(definition['iconSize']) ??
          _number(definition['width']),
      height:
          height ??
          _number(definition['iconSize']) ??
          _number(definition['height']),
      fit: BoxFit.contain,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
    );

    final effectiveOpacity = (opacity ?? 1.0).clamp(0.0, 1.0).toDouble();

    if (effectiveOpacity != 1.0) {
      icon = Opacity(opacity: effectiveOpacity, child: icon);
    }

    if (semanticLabel != null && semanticLabel.trim().isNotEmpty) {
      icon = Semantics(image: true, label: semanticLabel, child: icon);
    }

    return icon;
  }

  Map<String, dynamic>? deviceTypeMatch(String rawValue) {
    final icons = _map(schema['icons']);
    final rules = icons?['deviceTypeMap'];
    if (rules is! List) return null;

    final value = rawValue.trim();

    Map<String, dynamic>? defaultRule;

    for (final raw in rules) {
      final rule = _map(raw);
      if (rule == null) continue;

      if (rule['default'] == true) {
        defaultRule = rule;
      }

      final pattern = rule['match']?.toString();
      if (pattern == null || pattern.isEmpty) continue;

      try {
        if (RegExp(pattern, caseSensitive: false).hasMatch(value)) {
          return rule;
        }
      } catch (_) {
        continue;
      }
    }

    return defaultRule;
  }

  /// Renders a device icon using only schema data.
  ///
  /// Resolution order:
  /// 1. device.resolvedIcon
  /// 2. device.resolvedIconSvg
  /// 3. icons.deviceTypeMap + icons.catalog
  Widget buildForDevice(
    BuildContext context, {
    required Map<String, dynamic> device,
    required String matchValue,
    required double size,
    required Color color,
  }) {
    final resolvedIcon = _map(device['resolvedIcon']);
    if (resolvedIcon != null) {
      return buildDefinition(
        context,
        definition: resolvedIcon,
        width: size,
        height: size,
        color: color,
        semanticLabel: device['resolvedIconId']?.toString(),
      );
    }

    final resolvedSvg = device['resolvedIconSvg']?.toString().trim();
    if (resolvedSvg != null && resolvedSvg.isNotEmpty) {
      return buildDefinition(
        context,
        definition: <String, dynamic>{'type': 'svg', 'svgMarkup': resolvedSvg},
        width: size,
        height: size,
        color: color,
        semanticLabel: device['resolvedIconId']?.toString(),
      );
    }

    return buildDeviceType(
      context,
      deviceType: matchValue,
      size: size,
      color: color,
    );
  }

  Widget buildDeviceType(
    BuildContext context, {
    required String deviceType,
    required double size,
    required Color color,
  }) {
    final match = deviceTypeMatch(deviceType);
    final iconName = (match?['iconId'] ?? match?['icon'])?.toString().trim();
    final definition = iconName != null && iconName.isNotEmpty
        ? resolveNamedDefinition(iconName)
        : null;

    if (definition != null) {
      return buildDefinition(
        context,
        definition: definition,
        width: size,
        height: size,
        color: color,
        semanticLabel: match?['label']?.toString() ?? deviceType,
      );
    }

    final fallbackIcon = SduiIconRegistry.instance.resolve(
      iconName ?? deviceType,
      fallbackName: 'device',
      defaultIcon: Icons.devices_other,
    );
    return Icon(fallbackIcon, size: size, color: color);
  }

  String? _svg(Map<String, dynamic> definition) {
    // Prefer the exact SVG markup supplied by the schema.
    final markup = definition['svgMarkup']?.toString().trim();
    if (markup != null && markup.isNotEmpty) {
      return markup;
    }

    final viewBox = definition['viewBox']?.toString() ?? '0 0 24 24';
    final strokeWidth = _number(definition['strokeWidth']) ?? 2.0;
    final strokeLinecap = definition['strokeLinecap']?.toString() ?? 'round';
    final strokeLinejoin = definition['strokeLinejoin']?.toString() ?? 'round';
    final fill = definition['fill']?.toString() ?? 'none';

    final fragments = <String>[];

    final paths = definition['paths'];
    if (paths is List) {
      for (final raw in paths) {
        final path = raw?.toString();
        if (path == null || path.trim().isEmpty) continue;
        fragments.add('<path d="${_escape(path)}" />');
      }
    }

    final circles = definition['circles'];
    if (circles is List) {
      for (final raw in circles) {
        final circle = _map(raw);
        if (circle == null) continue;

        final cx = circle['cx'];
        final cy = circle['cy'];
        final r = circle['r'];
        if (cx == null || cy == null || r == null) continue;

        fragments.add(
          '<circle cx="$cx" cy="$cy" r="$r"'
          '${_svgAttr("fill", circle["fill"])}'
          '${_svgAttr("stroke", circle["stroke"])} />',
        );
      }
    }

    // Legacy/small status-dot style definition.
    final dot = _map(definition['dot']);
    if (dot != null) {
      final cx = dot['cx'];
      final cy = dot['cy'];
      final r = dot['r'];
      if (cx != null && cy != null && r != null) {
        fragments.add(
          '<circle cx="$cx" cy="$cy" r="$r"'
          '${_svgAttr("fill", dot["fill"] ?? "currentColor")}'
          '${_svgAttr("stroke", dot["stroke"] ?? "none")} />',
        );
      }
    }

    final rects = definition['rects'];
    if (rects is List) {
      for (final raw in rects) {
        final rect = _map(raw);
        if (rect == null) continue;

        final x = rect['x'];
        final y = rect['y'];
        final width = rect['width'];
        final height = rect['height'];
        if (x == null || y == null || width == null || height == null) {
          continue;
        }

        fragments.add(
          '<rect x="$x" y="$y" width="$width" height="$height"'
          '${_svgAttr("rx", rect["rx"])}'
          '${_svgAttr("ry", rect["ry"])}'
          '${_svgAttr("fill", rect["fill"])}'
          '${_svgAttr("stroke", rect["stroke"])} />',
        );
      }
    }

    if (fragments.isEmpty) return null;

    return '<svg xmlns="http://www.w3.org/2000/svg" '
        'viewBox="$viewBox" '
        'fill="${_escape(fill)}" '
        'stroke="currentColor" '
        'stroke-width="$strokeWidth" '
        'stroke-linecap="${_escape(strokeLinecap)}" '
        'stroke-linejoin="${_escape(strokeLinejoin)}">'
        '${fragments.join()}'
        '</svg>';
  }

  String _svgAttr(String key, dynamic value) {
    if (value == null) return '';
    return ' $key="${_escape(value.toString())}"';
  }

  Widget _missingIcon(BuildContext context, String message) {
    return Tooltip(
      message: 'IoT schema icon error: $message',
      child: SizedBox(
        width: 14,
        height: 14,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.error),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  String _escape(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}
