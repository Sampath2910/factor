import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Resolves icons exclusively from the auth schema.
///
/// Supported current v4 contracts:
/// 1. component inline asset: iconAsset / leadingIconAsset /
///    trailingIconAssets[name]
/// 2. root library: icons.library.paths[name] + contract.iconContract
class AuthIconResolver {
  const AuthIconResolver(this.schema);

  final Map<String, dynamic> schema;

  Widget? build({
    required String name,
    Map<String, dynamic>? inlineAsset,
    Color? color,
    double? size,
  }) {
    final asset = inlineAsset ?? _libraryAsset(name);
    if (asset == null) return null;

    final type = asset['type']?.toString();
    if (type != null && type != 'inlineSvg') return null;

    final svg = _svgString(asset, name);
    if (svg == null || svg.isEmpty) return null;

    final resolvedSize =
        size ?? _number(asset['size']) ?? _number(schema['icons']?['size']);

    return SvgPicture.string(
      svg,
      width: resolvedSize,
      height: resolvedSize,
      fit: BoxFit.contain,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
    );
  }

  Map<String, dynamic>? _libraryAsset(String name) {
    final icons = _map(schema['icons']);
    final library = _map(icons?['library']);
    final paths = _map(library?['paths']);
    final fragment = paths?[name]?.toString();

    if (fragment == null || fragment.trim().isEmpty) {
      return null;
    }

    final contract = _map(schema['contract']?['iconContract']);

    return <String, dynamic>{
      'type': 'inlineSvg',
      'name': name,
      'viewBox': contract?['viewBox'] ?? '0 0 24 24',
      'stroke': contract?['stroke'] ?? 'currentColor',
      'strokeWidth': contract?['strokeWidth'],
      'strokeLinecap': contract?['strokeLinecap'],
      'strokeLinejoin': contract?['strokeLinejoin'],
      'fill': 'none',
      'path': fragment,
    };
  }

  String? _svgString(Map<String, dynamic> asset, String name) {
    final supplied = asset['svg']?.toString();
    if (supplied != null && supplied.trim().isNotEmpty) return supplied;

    final fragment = asset['path']?.toString();
    if (fragment == null || fragment.trim().isEmpty) return null;

    final contract = _map(schema['contract']?['iconContract']);

    final viewBox =
        asset['viewBox']?.toString() ??
        contract?['viewBox']?.toString() ??
        '0 0 24 24';

    final stroke =
        asset['stroke']?.toString() ??
        contract?['stroke']?.toString() ??
        'currentColor';

    final fill = asset['fill']?.toString() ?? 'none';

    final strokeWidth = asset['strokeWidth'] ?? contract?['strokeWidth'];
    final lineCap =
        asset['strokeLinecap']?.toString() ??
        contract?['strokeLinecap']?.toString();
    final lineJoin =
        asset['strokeLinejoin']?.toString() ??
        contract?['strokeLinejoin']?.toString();

    final attrs = <String>[
      'viewBox="$viewBox"',
      'fill="$fill"',
      'stroke="$stroke"',
      if (strokeWidth != null) 'stroke-width="$strokeWidth"',
      if (lineCap != null) 'stroke-linecap="$lineCap"',
      if (lineJoin != null) 'stroke-linejoin="$lineJoin"',
      'aria-label="$name"',
    ].join(' ');

    return '<svg $attrs>$fragment</svg>';
  }

  static Map<String, dynamic>? _map(dynamic value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
  }

  static double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}
