import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Dynamic Icon Registry for SDUI.
///
/// Resolves icons by schema icon names, Material icon names, fallback names,
/// and supports dynamic runtime registration of new icons.
class SduiIconRegistry {
  SduiIconRegistry._();
  static final SduiIconRegistry instance = SduiIconRegistry._();

  /// Registered dynamic icon map.
  final Map<String, IconData> _registry = <String, IconData>{
    // Directional & Navigation
    'arrow-left': Icons.arrow_back,
    'arrow_left': Icons.arrow_back,
    'arrowleft': Icons.arrow_back,
    'arrow-right': Icons.arrow_forward,
    'arrow_right': Icons.arrow_forward,
    'arrowright': Icons.arrow_forward,
    'chevron-left': Icons.chevron_left,
    'chevron_left': Icons.chevron_left,
    'chevron-right': Icons.chevron_right,
    'chevron_right': Icons.chevron_right,
    'menu': Icons.menu,
    'more': Icons.more_vert,
    'home': Icons.home_outlined,
    'map': Icons.map_outlined,

    // Status & Dashboard
    'gauge': Icons.speed,
    'speed': Icons.speed,
    'dashboard': Icons.dashboard,
    'info': Icons.info_outline,
    'file': Icons.description_outlined,
    'document': Icons.description_outlined,
    'inbox': Icons.inbox_outlined,
    'help-circle': Icons.help_outline,
    'help_circle': Icons.help_outline,
    'warning': Icons.warning_amber_outlined,
    'error': Icons.error_outline,
    'check': Icons.check,
    'close': Icons.close,
    'help': Icons.help_outline,

    // Connectivity & Networking
    'signal': Icons.wifi,
    'wifi': Icons.wifi,
    'wifi-off': Icons.wifi_off,
    'wifi_off': Icons.wifi_off,
    'bluetooth': Icons.bluetooth,
    'cellular': Icons.cell_tower,

    // Controls & Settings
    'settings': Icons.settings,
    'tune': Icons.tune,
    'sliders': Icons.tune,
    'power': Icons.power_settings_new,
    'lock': Icons.lock_outline,
    'unlock': Icons.lock_open,
    'edit': Icons.edit_outlined,
    'save': Icons.save_outlined,
    'delete': Icons.delete_outline,
    'trash': Icons.delete_outline,
    'trash-2': Icons.delete_outline,
    'trash_2': Icons.delete_outline,
    'add': Icons.add,
    'remove': Icons.remove,

    // Media & Devices
    'lightbulb': Icons.lightbulb_outline,
    'fan': Icons.air,
    'thermometer': Icons.thermostat,
    'camera': Icons.camera_alt_outlined,
    'video': Icons.videocam_outlined,
    'message-circle': Icons.chat_bubble_outline,
    'message_circle': Icons.chat_bubble_outline,
    'heart': Icons.favorite,
    'play': Icons.play_arrow,
    'pause': Icons.pause,
    'stop': Icons.stop,
    'refresh': Icons.refresh,
    'download': Icons.download,
    'upload': Icons.upload,
    'battery': Icons.battery_charging_full,
    'bolt': Icons.bolt,
    'flash': Icons.flash_on,
    'drop': Icons.water_drop,
    'timer': Icons.timer,

    // Scanning & Hardware
    'scan': Icons.qr_code_scanner,
    'qr': Icons.qr_code_2,
    'qrframe': Icons.qr_code_scanner,
    'qr_frame': Icons.qr_code_scanner,
    'qrcode': Icons.qr_code_2,
    'barcode': Icons.qr_code_scanner,
    'x': Icons.close,
    'device': Icons.devices_other,
    'adddevice': Icons.add_circle_outline,
    'add-device': Icons.add_circle_outline,
  };

  /// Register custom icon at runtime for future schema expansion.
  void registerIcon(String name, IconData iconData) {
    _registry[name.toLowerCase().trim()] = iconData;
  }

  /// Register multiple icons at once.
  void registerIcons(Map<String, IconData> icons) {
    icons.forEach((key, value) {
      _registry[key.toLowerCase().trim()] = value;
    });
  }

  /// Resolve icon dynamically with fallback.
  IconData resolve(
    String? name, {
    String? fallbackName,
    IconData defaultIcon = Icons.circle_outlined,
  }) {
    if (name != null) {
      final key = name.toLowerCase().trim();
      final icon = _registry[key] ?? _resolveMaterialIcon(key);
      if (icon != null) return icon;
    }

    if (fallbackName != null) {
      final key = fallbackName.toLowerCase().trim();
      final icon = _registry[key] ?? _resolveMaterialIcon(key);
      if (icon != null) return icon;
    }

    return defaultIcon;
  }

  /// Dynamic Material Icons name lookup for snake_case, kebab-case, and camelCase.
  IconData? _resolveMaterialIcon(String key) {
    final normalized = key.replaceAll('-', '_').replaceAll(' ', '_');
    switch (normalized) {
      case 'thermostat':
      case 'temperature':
        return Icons.thermostat;
      case 'air':
      case 'wind':
        return Icons.air;
      case 'speed':
      case 'gauge_icon':
        return Icons.speed;
      case 'wifi':
        return Icons.wifi;
      case 'wifi_off':
        return Icons.wifi_off;
      case 'info_outline':
      case 'info_icon':
        return Icons.info_outline;
      case 'warning':
      case 'warning_amber':
        return Icons.warning_amber_outlined;
      case 'error':
        return Icons.error_outline;
      case 'lock_outline':
        return Icons.lock_outline;
      case 'lock_open':
        return Icons.lock_open;
      case 'trash':
      case 'trash_2':
      case 'delete_outline':
        return Icons.delete_outline;
      case 'tune':
      case 'filter_list':
        return Icons.tune;
      case 'flash_on':
      case 'lightning':
        return Icons.flash_on;
      case 'water_drop':
      case 'humidity':
        return Icons.water_drop;
      case 'battery':
      case 'battery_full':
        return Icons.battery_full;
      case 'qr_code':
      case 'qr_scanner':
        return Icons.qr_code_scanner;
      case 'circle':
        return Icons.circle;
      default:
        return null;
    }
  }
}

/// Schema-driven SDUI icon widget.
///
/// If the schema declares `icons.library.source = inline-svg` and provides an
/// SVG fragment under `icons.library.paths[name]`, that exact vector is
/// rendered. Otherwise the semantic icon registry is used as a platform
/// fallback. No device/model-specific icon mapping is required.
class SduiIcon extends StatelessWidget {
  const SduiIcon({
    super.key,
    required this.schema,
    required this.name,
    this.size = 18,
    this.color,
    this.fallbackName,
  });

  final Map<String, dynamic> schema;
  final String name;
  final double size;
  final Color? color;
  final String? fallbackName;

  @override
  Widget build(BuildContext context) {
    final icons = schema['icons'];
    if (icons is Map) {
      final library = icons['library'];
      if (library is Map &&
          library['source']?.toString().trim().toLowerCase() == 'inline-svg') {
        final paths = library['paths'];
        if (paths is Map) {
          final fragment = paths[name]?.toString().trim();
          if (fragment != null && fragment.isNotEmpty) {
            final effectiveColor = color ?? IconTheme.of(context).color;
            final svg =
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
                'fill="none" stroke="currentColor" stroke-width="2" '
                'stroke-linecap="round" stroke-linejoin="round">'
                '$fragment</svg>';
            return SvgPicture.string(
              svg,
              width: size,
              height: size,
              colorFilter: effectiveColor == null
                  ? null
                  : ColorFilter.mode(effectiveColor, BlendMode.srcIn),
            );
          }
        }
      }
    }

    return Icon(
      sduiIcon(name, fallbackName: fallbackName),
      size: size,
      color: color,
    );
  }
}

/// Semantic icon mapping used across the SDUI engine.
///
/// Fully backwards-compatible function preserving existing signature.
IconData sduiIcon(String? name, {String? fallbackName}) {
  return SduiIconRegistry.instance.resolve(name, fallbackName: fallbackName);
}
