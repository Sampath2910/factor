import 'package:flutter/foundation.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class HomeIconResolver {
  HomeIconResolver(this.schema);

  final Map<String, dynamic> schema;

  static const Map<String, FaIconData> _fontAwesome = <String, FaIconData>{
    'bolt': FontAwesomeIcons.bolt,
    'bell': FontAwesomeIcons.bell,
    'star': FontAwesomeIcons.star,
    'heart': FontAwesomeIcons.heart,
    'droplet': FontAwesomeIcons.droplet,
    'tableCellsLarge': FontAwesomeIcons.tableCellsLarge,
    'lock': FontAwesomeIcons.lock,
    'cube': FontAwesomeIcons.cube,
    'users': FontAwesomeIcons.users,
    'moneyBill': FontAwesomeIcons.moneyBill,
    'clock': FontAwesomeIcons.clock,
    'fingerprint': FontAwesomeIcons.fingerprint,
    'qrcode': FontAwesomeIcons.qrcode,
    'idCard': FontAwesomeIcons.idCard,
    'shieldHalved': FontAwesomeIcons.shieldHalved,
    'key': FontAwesomeIcons.key,
    'plus': FontAwesomeIcons.plus,
    'mobileScreen': FontAwesomeIcons.mobileScreen,
    'check': FontAwesomeIcons.check,
    'phone': FontAwesomeIcons.phone,
    'image': FontAwesomeIcons.image,
    'compass': FontAwesomeIcons.compass,
    'user': FontAwesomeIcons.user,
    'profile': FontAwesomeIcons.userPen,
    'link': FontAwesomeIcons.link,
    'borderAll': FontAwesomeIcons.borderAll,
    'tableCells': FontAwesomeIcons.tableCells,
    'grid': FontAwesomeIcons.borderAll,
    'wifi': FontAwesomeIcons.wifi,
    'doorOpen': FontAwesomeIcons.doorOpen,
    'list': FontAwesomeIcons.list,
    'chartColumn': FontAwesomeIcons.chartColumn,
    'house': FontAwesomeIcons.house,
    'microphone': FontAwesomeIcons.microphone,
    'camera': FontAwesomeIcons.camera,
    'wallet': FontAwesomeIcons.wallet,
    'gear': FontAwesomeIcons.gear,
    'rotate': FontAwesomeIcons.rotate,
    'language': FontAwesomeIcons.language,
    'chevronRight': FontAwesomeIcons.chevronRight,
    'rightFromBracket': FontAwesomeIcons.rightFromBracket,
    'bagShopping': FontAwesomeIcons.bagShopping,
    'magnifyingGlass': FontAwesomeIcons.magnifyingGlass,
    'quoteLeft': FontAwesomeIcons.quoteLeft,
    'store': FontAwesomeIcons.store,
    'arrowRight': FontAwesomeIcons.arrowRight,
    'tags': FontAwesomeIcons.tags,
    'truck': FontAwesomeIcons.truck,
    'calendarCheck': FontAwesomeIcons.calendarCheck,
    'sliders': FontAwesomeIcons.sliders,
    'crown': FontAwesomeIcons.crown,
    'coins': FontAwesomeIcons.coins,
    'percent': FontAwesomeIcons.percent,
    'laptop': FontAwesomeIcons.laptop,
    'video': FontAwesomeIcons.video,
    'gifts': FontAwesomeIcons.gifts,
    'bed': FontAwesomeIcons.bed,
    'shoppingCart': FontAwesomeIcons.shoppingCart,
    'cartShopping': FontAwesomeIcons.cartShopping,
    'userPen': FontAwesomeIcons.userPen,
    'moon': FontAwesomeIcons.moon,
    'scanner': FontAwesomeIcons.expand,
    'cropFree': FontAwesomeIcons.expand,
    'viewfinder': FontAwesomeIcons.expand,
    'expand': FontAwesomeIcons.expand,
    'arrow-right': FontAwesomeIcons.arrowRight,
    'chevron-right': FontAwesomeIcons.chevronRight,
  };

  final Map<String, FaIconData> _resolved = <String, FaIconData>{};
  final Set<String> _warned = <String>{};

  FaIconData resolve(String? token) {
    final key = token?.trim() ?? '';
    final cached = _resolved[key];
    if (cached != null) return cached;
    final icon = _resolve(token, <String>{});
    _resolved[key] = icon;
    return icon;
  }

  FaIconData _resolve(String? token, Set<String> visited) {
    final normalized = token?.trim();

    if (normalized != null && normalized.isNotEmpty) {
      if (!visited.add(normalized)) {
        _warnOnce(
          normalized,
          '[HOME_SDUI][ICON] fallback cycle detected at "$normalized".',
        );
        return FontAwesomeIcons.cube;
      }

      // Schema iconRegistry is the source of truth. Direct Font Awesome names
      // are only a capability fallback for composer CSS tokens such as `fa-bell`.
      final registry = schema['iconRegistry'];
      if (registry is Map && registry.containsKey(normalized)) {
        final definition = registry[normalized];

        if (definition is Map) {
          final flutter = definition['flutter'];
          if (flutter is String && flutter.trim().isNotEmpty) {
            final named = _fontAwesome[flutter] ??
                _fontAwesome[_directFontAwesomeName(flutter)];
            if (named != null) return named;
            return _resolve(flutter, visited);
          }

          if (flutter is Map) {
            final pack = flutter['pack']?.toString();
            final name = flutter['name']?.toString();

            if (pack == 'font_awesome_flutter' &&
                name != null &&
                name.isNotEmpty) {
              final icon = _fontAwesome[name] ??
                  _fontAwesome[_directFontAwesomeName(name)];
              if (icon != null) {
                return icon;
              }

              _warnOnce(
                normalized,
                '[HOME_SDUI][ICON] schema token "$normalized" declares '
                'unsupported Flutter symbol "$name".',
              );
            }
          }
        } else if (definition != null) {
          _warnOnce(
            normalized,
            '[HOME_SDUI][ICON] schema iconRegistry token "$normalized" '
            'is not an object.',
          );
        }
      }

      final directName = _directFontAwesomeName(normalized);
      final directIcon = _fontAwesome[directName] ?? _fontAwesome[normalized];
      if (directIcon != null) return directIcon;
    }

    final fallback = schema['rendererRequirements']?['fallbacks']
            ?['unsupportedIcon']
        ?.toString();

    if (fallback != null && fallback.isNotEmpty && fallback != normalized) {
      return _resolve(fallback, visited);
    }

    return FontAwesomeIcons.cube;
  }

  void _warnOnce(String token, String message) {
    if (!kDebugMode || !_warned.add(token)) return;
    debugPrint(message);
  }

  String _directFontAwesomeName(String token) {
    var value = token.trim();
    if (value.startsWith('fa-')) {
      value = value.substring(3);
    }

    final parts = value
        .split(RegExp(r'[-_\s]+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);

    if (parts.isNotEmpty) {
      value = parts.first.toLowerCase() +
          parts.skip(1).map((part) {
            final lower = part.toLowerCase();
            return lower.isEmpty
                ? ''
                : lower[0].toUpperCase() + lower.substring(1);
          }).join();
    }

    // Aliases describe Font Awesome CSS-name/package-name differences only.
    // They are UI-library compatibility rules, not account/application data.
    return switch (value) {
      'home' => 'house',
      'th' || 'thLarge' => 'tableCellsLarge',
      'grid' || 'borderAll' => 'borderAll',
      'chartBar' || 'chartLine' || 'signal' => 'chartColumn',
      'qrCode' => 'qrcode',
      'projectDiagram' || 'shareAlt' => 'link',
      'userTie' => 'user',
      'calendar' || 'hourglassHalf' => 'clock',
      'mobileAlt' => 'mobileScreen',
      'fire' => 'bolt',
      'clipboardList' => 'list',
      'images' => 'image',
      'wifi' => 'wifi',
      'bluetoothB' => 'link',
      'redo' || 'redoAlt' => 'rotate',
    'shoppingBag' || 'bagShopping' || 'shoppingCart' => 'shoppingCart',
    'search' => 'magnifyingGlass',
    'mic' => 'microphone',
    'slidersH' => 'sliders',
    'tags' => 'tags',
    'truck' => 'truck',
    'calendarCheck' => 'calendarCheck',
    'storeAlt' => 'store',
    'shieldAlt' || 'shield' => 'shieldHalved',
    'logout' || 'signOut' || 'signOutAlt' => 'rightFromBracket',
    'alerts' || 'notification' || 'notifications' => 'bell',
    'appearance' || 'theme' => 'sliders',
    'scanner' || 'cropFree' || 'scan' || 'viewfinder' => 'expand',
    'arrowRight' || 'arrow-right' => 'arrowRight',
    'chevronRight' || 'chevron-right' => 'chevronRight',
    'videoCamera' || 'video' => 'video',
    'percentage' => 'percent',
    _ => value,
    };
  }
}
