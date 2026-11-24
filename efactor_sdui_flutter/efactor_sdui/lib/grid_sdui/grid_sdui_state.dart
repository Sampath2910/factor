import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme_controller.dart';
import '../services/grid_notifications_service.dart';

class GridSduiState extends ChangeNotifier {
  static String? persistedSelectedQrMode;
  static final Map<String, String> _persistedSelectedFilters = <String, String>{};

  GridSduiState(
    Map<String, dynamic> source, {
    Brightness? platformBrightness,
  })  : _platformBrightness =
            platformBrightness ?? PlatformDispatcher.instance.platformBrightness,
        schema = source['schema'] is Map
            ? Map<String, dynamic>.from(
                (source['schema'] as Map).cast<dynamic, dynamic>(),
              )
            : Map<String, dynamic>.from(source) {
    if (source['schema'] is Map) {
      for (final metaKey in const [
        'schema_rev',
        'schema_version',
        'schemaVersion',
        'theme',
        'typography',
        'layoutPolicy',
      ]) {
        if (source.containsKey(metaKey) && !schema.containsKey(metaKey)) {
          schema[metaKey] = source[metaKey];
        }
      }
    }

    if (persistedSelectedQrMode != null &&
        persistedSelectedQrMode!.isNotEmpty) {
      schema['_clientSelectedQrMode'] = persistedSelectedQrMode;
    }
    for (final entry in _persistedSelectedFilters.entries) {
      final key = '_clientSelectedFilter_${entry.key}';
      if (entry.value.isNotEmpty) {
        schema[key] = entry.value;
      }
    }

    // Deep-merge dynamic content if passed via root envelope
    final sourceContent = source['content'];
    if (sourceContent is Map) {
      final schemaContent = schema['content'];
      if (schemaContent is Map) {
        schema['content'] = <String, dynamic>{
          ...Map<String, dynamic>.from(schemaContent.cast<dynamic, dynamic>()),
          ...Map<String, dynamic>.from(
            sourceContent.cast<dynamic, dynamic>(),
          ),
        };
      } else {
        schema['content'] = Map<String, dynamic>.from(
          sourceContent.cast<dynamic, dynamic>(),
        );
      }
    }

    // Deep-merge dynamic components if passed via root envelope
    final sourceComponents = source['components'];
    final schemaComponents = schema['components'];
    if (sourceComponents is Map &&
        schemaComponents is Map &&
        !identical(sourceComponents, schemaComponents)) {
      final merged = Map<String, dynamic>.from(
        schemaComponents.cast<dynamic, dynamic>(),
      );
      for (final entry in sourceComponents.entries) {
        final key = entry.key?.toString();
        if (key == null) continue;
        final value = entry.value;
        if (value is Map) {
          final existing = merged[key];
          if (existing is Map) {
            merged[key] = <String, dynamic>{
              ...Map<String, dynamic>.from(existing.cast<dynamic, dynamic>()),
              ...Map<String, dynamic>.from(value.cast<dynamic, dynamic>()),
            };
          } else {
            merged[key] = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
          }
        }
      }
      schema['components'] = merged;
    }

    _synthesizeStatsRowIfMissing();
    _synthesizeExploringItemsIfMissing();
    _synthesizeNotificationsIfAvailable();
  }

  void _synthesizeNotificationsIfAvailable() {
    final cached = GridNotificationsService.instance.notifications.value;
    if (cached.isNotEmpty) {
      applyNotifications(cached, notify: false);
    }
  }

  /// Ingests notification rows fetched from [GridNotificationsService]
  /// and synthesizes or updates them in `grid-explore-row`.
  void applyNotifications(
    List<Map<String, dynamic>> notificationRows, {
    int? unreadCount,
    bool notify = true,
  }) {
    if (notificationRows.isEmpty) return;

    final compMap = Map<String, dynamic>.from(components);
    final rowComp = compMap['grid-explore-row'];
    if (rowComp is! Map) return;

    final existingChildren = (rowComp['children'] is List)
        ? List<dynamic>.from(rowComp['children'] as List)
        : <dynamic>[];

    final updatedChildren = <dynamic>[];

    for (final rawItem in notificationRows) {
      final notifId = rawItem['id'];
      final rawType = (rawItem['type'] ?? '').toString().toLowerCase();
      final title = (rawItem['title'] ?? '').toString();
      final body = (rawItem['body'] ?? '').toString();
      final link = (rawItem['link'] ?? '').toString();
      final isReadRaw = rawItem['is_read'];
      final isUnread =
          isReadRaw == 0 || isReadRaw == false || isReadRaw == '0';
      final createdAt = rawItem['created_at'];
      final relativeTime =
          GridNotificationsService.formatRelativeTime(createdAt);
      final actorName = rawItem['actor_name']?.toString();
      final actorAvatar = rawItem['actor_avatar']?.toString();
      final initials = GridNotificationsService.getInitials(actorName);

      // Determine space: Circle Connect vs Professional
      final isCircle = rawType.contains('circle') ||
          rawType.contains('chat') ||
          link.contains('grid-chat') ||
          link.contains('/chat');
      final space = isCircle ? 'circle' : 'professional';
      final badgeText = isCircle ? 'Chat' : 'Professional';

      // Deep link navigation: origin + '/index.php' + row['link']
      String fullUrl = link;
      if (!link.startsWith('http')) {
        final cleanLink = link.startsWith('/') ? link : '/$link';
        fullUrl = cleanLink.startsWith('/index.php')
            ? 'https://efactor.tech$cleanLink'
            : 'https://efactor.tech/index.php$cleanLink';
      }

      final compId = 'grid-notif-$notifId';
      final cardComponent = <String, dynamic>{
        'id': compId,
        'type': 'featureCard',
        'style': 'softCard',
        'title': title,
        'subtitle': body.isNotEmpty ? body : title,
        'time': relativeTime,
        'label': initials,
        'initial': initials,
        'initials': initials,
        'iconToken': isCircle ? 'message' : 'bell',
        'imageUrl': actorAvatar ?? '',
        'image': actorAvatar ?? '',
        'color': isCircle ? '#f97316' : '#7c3aed',
        'badge': badgeText,
        'space': space,
        'unread': isUnread,
        'is_read': isUnread ? 0 : 1,
        'notificationId': notifId,
        'actionId': 'grid-open-notification-item',
        'url': fullUrl,
        'route': fullUrl,
        'openIn': 'inAppWebView',
        'layout': <String, dynamic>{
          'direction': 'horizontal',
          'alignItems': 'center',
          'crossAxisAlignment': 'center',
          'mainAxisSize': 'max',
          'gap': 12,
          'height': 74,
          'minHeight': 74,
          'width': 'fill',
        },
        'appearance': <String, dynamic>{
          'borderRadius': 16,
          'backgroundColor': isUnread ? '#f0fdf4' : '#eef2ff',
          'iconPosition': 'leading',
          'titlePosition': 'besideIcon',
          'showIcon': true,
          'showAvatar': true,
          'iconSize': 42,
          'titleFontSize': 14.5,
          'subtitleFontSize': 12,
          'padding': 12,
        },
        'appearanceDark': <String, dynamic>{
          'borderRadius': 16,
          'backgroundColor': isUnread ? '#14231b' : '#141824',
          'titleColor': '#f8fafc',
          'subtitleColor': '#94a3b8',
        },
      };

      compMap[compId] = cardComponent;
      updatedChildren.add(compId);
    }

    // Preserve any existing non-notification items
    for (final child in existingChildren) {
      if (!child.toString().startsWith('grid-notif-') &&
          !updatedChildren.contains(child)) {
        updatedChildren.add(child);
      }
    }

    final updatedRow = Map<String, dynamic>.from(rowComp);
    updatedRow['children'] = updatedChildren;
    compMap['grid-explore-row'] = updatedRow;

    // Update section badge if count is supplied
    final sectionComp = compMap['grid-explore-section'];
    if (sectionComp is Map) {
      final updatedSection = Map<String, dynamic>.from(sectionComp);
      final count = unreadCount ??
          notificationRows.where((r) {
            final isRead = r['is_read'];
            return isRead == 0 || isRead == false || isRead == '0';
          }).length;
      if (count > 0) {
        updatedSection['badge'] = '$count new';
        updatedSection['headerBadge'] = <String, dynamic>{
          'label': '$count new',
          'backgroundColor': '#dcfce7',
          'color': '#16a34a',
        };
      } else {
        updatedSection['badge'] = '';
        updatedSection['headerBadge'] = null;
      }
      compMap['grid-explore-section'] = updatedSection;
    }

    schema['components'] = compMap;
    if (notify) {
      notifyListeners();
    }
  }

  void _markNotificationItemLocallyRead(dynamic notifId) {
    final compId = 'grid-notif-$notifId';
    final compMap = Map<String, dynamic>.from(components);
    final comp = compMap[compId];
    if (comp is Map) {
      final updated = Map<String, dynamic>.from(comp);
      updated['unread'] = false;
      updated['is_read'] = 1;
      final appearance = Map<String, dynamic>.from(
          _map(updated['appearance']) ?? const <String, dynamic>{});
      appearance['backgroundColor'] = '#eef2ff';
      updated['appearance'] = appearance;
      final appearanceDark = Map<String, dynamic>.from(
          _map(updated['appearanceDark']) ?? const <String, dynamic>{});
      appearanceDark['backgroundColor'] = '#141824';
      updated['appearanceDark'] = appearanceDark;
      compMap[compId] = updated;

      // Update badge count in grid-explore-section
      final sectionComp = compMap['grid-explore-section'];
      if (sectionComp is Map) {
        final updatedSection = Map<String, dynamic>.from(sectionComp);
        final currentBadge = (updatedSection['badge'] ?? '').toString();
        final match = RegExp(r'\d+').firstMatch(currentBadge);
        if (match != null) {
          final count = (int.tryParse(match.group(0) ?? '') ?? 1) - 1;
          if (count > 0) {
            updatedSection['badge'] = '$count new';
            updatedSection['headerBadge'] = <String, dynamic>{
              'label': '$count new',
              'backgroundColor': '#dcfce7',
              'color': '#16a34a',
            };
          } else {
            updatedSection['badge'] = '';
            updatedSection['headerBadge'] = null;
          }
          compMap['grid-explore-section'] = updatedSection;
        }
      }

      schema['components'] = compMap;
      notifyListeners();
    }
  }

  void _synthesizeExploringItemsIfMissing() {
    final exploring = _map(content['exploring']);
    final items = exploring?['items'];
    if (items is! List || items.isEmpty) return;

    final compMap = Map<String, dynamic>.from(components);
    final rowComp = compMap['grid-explore-row'];
    if (rowComp is! Map) return;

    final existingChildren = (rowComp['children'] is List)
        ? List<dynamic>.from(rowComp['children'] as List)
        : <dynamic>[];

    final updatedChildren = List<dynamic>.from(existingChildren);

    for (final rawItem in items) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem.cast<dynamic, dynamic>());
      final rawId = item['id']?.toString().trim() ?? '';
      if (rawId.isEmpty) continue;

      final compId = compMap.containsKey(rawId)
          ? rawId
          : (compMap.containsKey('grid-explore-$rawId')
              ? 'grid-explore-$rawId'
              : rawId);

      final synthesized = <String, dynamic>{
        'id': compId,
        'type': 'featureCard',
        'style': 'softCard',
        'title': item['title'] ?? '',
        'subtitle': item['subtitle'] ?? item['preview'] ?? '',
        'label': item['initials'] ?? '',
        'initial': item['initials'] ?? '',
        'iconToken': item['iconToken'] ?? 'message',
        'imageUrl': item['imageUrl'] ?? item['image'] ?? '',
        'image': item['image'] ?? item['imageUrl'] ?? '',
        'color': item['color'] ?? item['avatarColor'] ?? '#5b6cff',
        'badge': item['badge'] ?? '',
        'space': item['space'] ?? '',
        'unread': item['unread'] ?? false,
        'actionId': item['actionId'],
        'url': item['url'] ?? item['route'],
        'route': item['route'] ?? item['url'],
        'openIn': item['openIn'] ?? 'inAppWebView',
        'layout': <String, dynamic>{
          'direction': 'horizontal',
          'alignItems': 'center',
          'crossAxisAlignment': 'center',
          'mainAxisSize': 'max',
          'gap': 12,
          'height': 72,
          'minHeight': 72,
          'width': 'fill',
        },
        'appearance': <String, dynamic>{
          'borderRadius': 16,
          'backgroundColor': item['backgroundColor'] ?? '#eef2ff',
          'iconPosition': 'leading',
          'titlePosition': 'besideIcon',
          'showIcon': true,
          'showAvatar': true,
          'iconSize': 42,
          'titleFontSize': 15,
          'subtitleFontSize': 12,
          'padding': 12,
        },
      };

      if (!compMap.containsKey(compId)) {
        compMap[compId] = synthesized;
        if (compId != rawId) compMap[rawId] = synthesized;
      } else {
        final existing = Map<String, dynamic>.from(
            (compMap[compId] as Map).cast<dynamic, dynamic>());
        if (item.containsKey('space')) existing['space'] = item['space'];
        if (item.containsKey('unread')) existing['unread'] = item['unread'];
        if (item.containsKey('actionId')) existing['actionId'] = item['actionId'];
        if (item.containsKey('url')) existing['url'] = item['url'];
        if (item.containsKey('route')) existing['route'] = item['route'];
        compMap[compId] = existing;
        if (compId != rawId) compMap[rawId] = existing;
      }

      if (!updatedChildren.contains(compId) &&
          !updatedChildren.contains(rawId)) {
        updatedChildren.add(compId);
      }
    }

    final updatedRow = Map<String, dynamic>.from(rowComp);
    updatedRow['children'] = updatedChildren;
    compMap['grid-explore-row'] = updatedRow;
    schema['components'] = compMap;
  }

  void _synthesizeStatsRowIfMissing() {
    final stats = content['stats'];
    if (stats is List && stats.isNotEmpty) {
      final compMap = Map<String, dynamic>.from(components);
      if (!compMap.containsKey('grid-stats-row')) {
        compMap['grid-stats-row'] = <String, dynamic>{
          'id': 'grid-stats-row',
          'type': 'statusSummary',
          'items': stats,
          'layout': <String, dynamic>{'gap': 8.0},
          'appearance': <String, dynamic>{
            'borderRadius': 16.0,
            'valueFontSize': 20.0,
            'labelFontSize': 12.0,
            'paddingVertical': 14.0,
            'paddingHorizontal': 16.0,
          },
        };
        schema['components'] = compMap;
        final page = compMap['grid-page'];
        if (page is Map && page['children'] is List) {
          final pageChildren = List<dynamic>.from(page['children'] as List);
          if (!pageChildren.contains('grid-stats-row')) {
            final idx = pageChildren.indexOf('grid-share-qr');
            if (idx != -1) {
              pageChildren.insert(idx, 'grid-stats-row');
            } else {
              pageChildren.add('grid-stats-row');
            }
            final updatedPage = Map<String, dynamic>.from(page);
            updatedPage['children'] = pageChildren;
            compMap['grid-page'] = updatedPage;
            schema['components'] = compMap;
          }
        }
      } else {
        // Keep existing grid-stats-row items synchronized with latest live stats
        final existingRow = compMap['grid-stats-row'];
        if (existingRow is Map) {
          final updated = Map<String, dynamic>.from(existingRow.cast<dynamic, dynamic>());
          updated['items'] = stats;
          compMap['grid-stats-row'] = updated;
          schema['components'] = compMap;
        }
      }
    }
  }

  Map<String, dynamic> schema;
  Brightness _platformBrightness;
  String? lastError;
  bool _disposed = false;

  Brightness get platformBrightness => _platformBrightness;

  void updatePlatformBrightness(
    Brightness brightness, {
    bool notify = true,
  }) {
    if (_platformBrightness == brightness) return;
    _platformBrightness = brightness;
    if (notify) {
      notifyListeners();
    }
  }

  Map<String, dynamic>? get themeConfig => _map(schema['theme']);

  /// Configured mode: `light`, `dark`, or `system`.
  ///
  /// The app-wide [ThemeController] (the Profile → Appearance switch) is the
  /// single source of truth so Grid follows the same light/dark/system choice
  /// as every other screen. The schema's `theme.defaultMode` is only a fallback
  /// used before the controller has loaded its persisted value.
  String get configuredThemeMode {
    if (ThemeController.instance.isLoaded) {
      switch (ThemeController.instance.mode) {
        case AppThemeMode.light:
          return 'light';
        case AppThemeMode.dark:
          return 'dark';
        case AppThemeMode.system:
          return 'system';
      }
    }
    final theme = themeConfig;
    final raw = theme?['defaultMode']?.toString().trim().toLowerCase() ?? '';
    if (raw == 'light' || raw == 'dark' || raw == 'system') {
      return raw;
    }
    if (raw == 'auto') return 'system';
    return theme != null ? 'system' : 'light';
  }

  /// Active theme mode (`light` or `dark`) after resolving `system` against
  /// the current device platform brightness.
  String get resolvedThemeMode {
    final configured = configuredThemeMode;
    if (configured == 'dark') return 'dark';
    if (configured == 'light') return 'light';
    return _platformBrightness == Brightness.dark ? 'dark' : 'light';
  }

  bool get isDarkMode => resolvedThemeMode == 'dark';

  /// Resolves a component's effective appearance map for the active theme mode.
  Map<String, dynamic> resolvedAppearance(Map<String, dynamic> component) {
    final light = _map(component['appearance']) ?? const <String, dynamic>{};
    if (!isDarkMode) {
      return Map<String, dynamic>.from(light);
    }
    final dark = _map(component['appearanceDark']);
    if (dark == null || dark.isEmpty) {
      return Map<String, dynamic>.from(light);
    }

    final merged = Map<String, dynamic>.from(light);
    if (dark.containsKey('backgroundColor') &&
        !dark.containsKey('backgroundGradient')) {
      merged.remove('backgroundGradient');
    }
    for (final entry in dark.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is Map && merged[key] is Map) {
        merged[key] = <String, dynamic>{
          ...Map<String, dynamic>.from((merged[key] as Map).cast<dynamic, dynamic>()),
          ...Map<String, dynamic>.from(value.cast<dynamic, dynamic>()),
        };
      } else {
        merged[key] = value;
      }
    }
    return merged;
  }

  /// Host opens schema `openIn: inAppWebView` destinations inside the app
  /// (embedded WebView). When null, falls back to url_launcher Custom Tabs.
  Future<bool> Function(Uri uri, {String? title})? inAppWebViewOpener;

  /// Native camera scanner opener for QR and barcode scanning.
  Future<bool> Function()? nativeScannerOpener;

  /// Host handler to refresh Grid data sources from the live schema endpoint.
  Future<void> Function()? refreshHandler;

  Map<String, dynamic> get components => schema['components'] is Map
      ? Map<String, dynamic>.from(
          (schema['components'] as Map).cast<dynamic, dynamic>(),
        )
      : const <String, dynamic>{};

  Map<String, dynamic> get actions => schema['actions'] is Map
      ? Map<String, dynamic>.from(
          (schema['actions'] as Map).cast<dynamic, dynamic>(),
        )
      : const <String, dynamic>{};

  Map<String, dynamic> get content => schema['content'] is Map
      ? Map<String, dynamic>.from(
          (schema['content'] as Map).cast<dynamic, dynamic>(),
        )
      : const <String, dynamic>{};

  Map<String, dynamic> get designTokens => schema['designTokens'] is Map
      ? Map<String, dynamic>.from(
          (schema['designTokens'] as Map).cast<dynamic, dynamic>(),
        )
      : const <String, dynamic>{};

  Map<String, dynamic> get iconRegistry => schema['iconRegistry'] is Map
      ? Map<String, dynamic>.from(
          (schema['iconRegistry'] as Map).cast<dynamic, dynamic>(),
        )
      : const <String, dynamic>{};

  String get rootComponentId {
    final fromPage = _map(schema['page'])?['rootComponentId']?.toString();
    if (fromPage != null && fromPage.isNotEmpty) return fromPage;
    return schema['rootComponentId']?.toString() ?? '';
  }

  String get selectedQrMode {
    final fromState = schema['_clientSelectedQrMode']?.toString().trim();
    if (fromState != null && fromState.isNotEmpty) return fromState;
    if (persistedSelectedQrMode != null &&
        persistedSelectedQrMode!.isNotEmpty) {
      return persistedSelectedQrMode!;
    }
    final share = _map(content['shareQr']) ?? _map(components['grid-share-qr']);
    return share?['selectedMode']?.toString().trim() ?? 'professional';
  }

  String selectedFilter(String sectionId) {
    final key = '_clientSelectedFilter_$sectionId';
    final fromState = schema[key]?.toString().trim();
    if (fromState != null && fromState.isNotEmpty) return fromState;
    final persisted = _persistedSelectedFilters[sectionId]?.trim();
    if (persisted != null && persisted.isNotEmpty) return persisted;
    final sec = component(sectionId);
    final filters = sec?['filters'] ?? sec?['modes'];
    if (filters is List) {
      for (final f in filters) {
        if (f is Map && f['selected'] == true) {
          return f['id']?.toString() ?? 'all';
        }
      }
    }
    return 'all';
  }

  void setSelectedFilter(String sectionId, String filterId) {
    final key = '_clientSelectedFilter_$sectionId';
    _persistedSelectedFilters[sectionId] = filterId;
    schema[key] = filterId;
    notifyListeners();
  }

  Map<String, dynamic>? component(String id) {
    final raw = components[id];
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
  }

  Map<String, dynamic>? action(String id) {
    final raw = actions[id];
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
  }

  Future<void> dispatch(String? actionId, {Map<String, dynamic>? extra}) async {
    final id = actionId?.trim() ?? '';
    if (id.isEmpty) return;

    if (id == 'grid-see-all-exploring' ||
        id == 'open-grid-exploring-all' ||
        id == 'open-grid-notifications') {
      await _openUrl(<String, dynamic>{
        'type': 'open-url',
        'url': 'https://efactor.tech/index.php/grid/notifications',
        'openIn': 'inAppWebView',
      }, extra: extra);
      return;
    }

    if (id == 'grid-open-notification-item') {
      final notifId = extra?['notificationId'];
      if (notifId != null) {
        final parsedId = int.tryParse(notifId.toString());
        unawaited(GridNotificationsService.instance.markRead(id: parsedId));
        _markNotificationItemLocallyRead(notifId);
      }
      final targetUrl = extra?['url'] ?? extra?['route'] ?? '';
      if (targetUrl.isNotEmpty) {
        await _openUrl(<String, dynamic>{
          'type': 'open-url',
          'url': targetUrl,
          'openIn': extra?['openIn'] ?? 'inAppWebView',
        }, extra: extra);
        return;
      }
    }

    final action = this.action(id);
    if (action == null) {
      lastError = 'Unknown Grid action "$id".';
      notifyListeners();
      return;
    }
    await _execute(id, action, extra: extra);
  }

  Future<void> _execute(
    String actionId,
    Map<String, dynamic> action, {
    Map<String, dynamic>? extra,
  }) async {
    lastError = null;

    if (actionId == 'grid-see-all-exploring' ||
        actionId == 'open-grid-exploring-all' ||
        actionId == 'open-grid-notifications') {
      final notifAction = Map<String, dynamic>.from(action);
      notifAction['url'] = 'https://efactor.tech/index.php/grid/notifications';
      notifAction['route'] =
          'https://efactor.tech/index.php/grid/notifications';
      await _openUrl(notifAction, extra: extra);
      return;
    }

    if (actionId == 'grid-open-notification-item') {
      final notifId = extra?['notificationId'] ?? action['notificationId'];
      if (notifId != null) {
        final parsedId = int.tryParse(notifId.toString());
        unawaited(GridNotificationsService.instance.markRead(id: parsedId));
        _markNotificationItemLocallyRead(notifId);
      }
      await _openUrl(action, extra: extra);
      return;
    }
    final type = action['type']?.toString();
    final actionIdLower = actionId.toLowerCase();
    if (actionIdLower == 'grid-open-scanner' ||
        actionIdLower == 'open-scanner' ||
        actionIdLower == 'openscanner' ||
        type == 'open-scanner' ||
        type == 'openScanner' ||
        type == 'qrScanner') {
      final opener = nativeScannerOpener;
      if (opener != null) {
        final handled = await opener();
        if (handled) return;
      }
    }

    switch (type) {
      case 'open-url':
        await _openUrl(action, extra: extra);
        return;
      case 'host-action':
        await _hostAction(action, extra: extra);
        return;
      case 'sequence':
        final steps = action['actions'];
        if (steps is List) {
          for (final step in steps) {
            if (step is Map) {
              await _execute(
                actionId,
                Map<String, dynamic>.from(step.cast<dynamic, dynamic>()),
                extra: extra,
              );
            }
          }
        }
        return;
      case 'set-state':
        return;
      case 'refresh-data-source':
        final handler = refreshHandler;
        if (handler != null) {
          await handler();
        }
        return;
      case 'navigate':
        lastError =
            'Grid schema navigate "${_map(action['destination'])?['routeId']}" '
            'has no page in this document.';
        notifyListeners();
        return;
      default:
        lastError = 'Unsupported Grid action type "$type" at $actionId.';
        notifyListeners();
    }
  }

  Future<void> _openUrl(
    Map<String, dynamic> action, {
    Map<String, dynamic>? extra,
  }) async {
    final candidates = <dynamic>[
      extra?['url'],
      extra?['route'],
      action['url'],
      action['route'],
      _map(action['destination'])?['url'],
    ];

    // Prefer candidate that already contains signed grid_sso query parameter
    var raw = '';
    for (final c in candidates) {
      final str = c?.toString().trim() ?? '';
      if (str.isNotEmpty && str.contains('grid_sso=')) {
        raw = str;
        break;
      }
    }
    if (raw.isEmpty) {
      raw = _firstNonEmpty(candidates);
    }
    if (raw.isEmpty) {
      lastError = 'Grid open-url is missing url/route.';
      notifyListeners();
      return;
    }

    while (raw.contains('/index.php/index.php/')) {
      raw = raw.replaceAll('/index.php/index.php/', '/index.php/');
    }

    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme) {
      lastError = 'Grid open-url is not a valid URL.';
      notifyListeners();
      return;
    }

    final openIn = (action['openIn']?.toString() ??
            _map(action['destination'])?['openIn']?.toString() ??
            extra?['openIn']?.toString() ??
            '')
        .trim();
    final openInLower = openIn.toLowerCase();
    // Prefer in-app WebView unless the schema explicitly asks for an external
    // browser. Missing openIn previously launched Chrome and broke "same as
    // other screens" Grid navigation.
    final forceExternal = openInLower == 'external' ||
        openInLower == 'browser' ||
        openInLower == 'externalapplication' ||
        openInLower == 'external_application' ||
        openInLower == 'systembrowser';
    final inApp = !forceExternal;
    final title = _firstNonEmpty(<dynamic>[
      extra?['title'],
      action['title'],
      _map(action['destination'])?['title'],
    ]);

    var opened = false;
    if (inApp) {
      final opener = inAppWebViewOpener;
      if (opener != null) {
        try {
          opened = await opener(
            uri,
            title: title.isEmpty ? null : title,
          );
        } catch (e, stack) {
          debugPrint('[GRID_SDUI] inAppWebViewOpener failed: $e\n$stack');
          opened = false;
        }
      }
      // Do not fall back to Custom Tabs / external browser for in-app opens —
      // that is what produced the browser chrome the product asked to avoid.
      if (!opened) {
        lastError =
            'Unable to open in-app WebView for $raw. '
            'Host inAppWebViewOpener is missing or failed.';
        notifyListeners();
      }
      return;
    }

    try {
      opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      lastError = 'Unable to open $raw';
      notifyListeners();
    }
  }

  Future<void> _hostAction(
    Map<String, dynamic> action, {
    Map<String, dynamic>? extra,
  }) async {
    final hostId = action['actionId']?.toString().trim() ?? '';
    switch (hostId) {
      case 'select-grid-qr-mode':
        final mode = extra?['mode']?.toString().trim() ??
            extra?['id']?.toString().trim() ??
            '';
        if (mode.isEmpty) return;
        persistedSelectedQrMode = mode;
        schema['_clientSelectedQrMode'] = mode;
        notifyListeners();
        return;
      case 'select-grid-filter':
        final sectionId = extra?['sectionId']?.toString().trim() ?? 'grid-explore-section';
        final filterId = extra?['filterId']?.toString().trim() ??
            extra?['id']?.toString().trim() ??
            'all';
        setSelectedFilter(sectionId, filterId);
        return;
      case 'share-grid-qr':
        final payload = qrPayloadForMode(selectedQrMode);
        if (payload.isEmpty) {
          lastError = 'Grid share payload is missing.';
          notifyListeners();
          return;
        }
        await Clipboard.setData(ClipboardData(text: payload));
        lastError = null;
        schema['_clientShareCopied'] = true;
        notifyListeners();
        return;
      case 'open-grid-circle-connect':
        final nestedUrl = extra?['url']?.toString().trim() ??
            extra?['route']?.toString().trim() ??
            '';
        if (nestedUrl.isNotEmpty) {
          await _openUrl(action, extra: extra);
          return;
        }
        lastError =
            'Grid host action "$hostId" has no destination in the schema yet.';
        notifyListeners();
        return;
      case 'open-grid-search':
      case 'open-grid-find-talent':
      case 'open-grid-join-circles':
        lastError =
            'Grid host action "$hostId" has no destination in the schema yet.';
        notifyListeners();
        return;
      case 'open-grid-exploring-all':
      case 'open-grid-notifications':
        await _openUrl(<String, dynamic>{
          'type': 'open-url',
          'url': 'https://efactor.tech/index.php/grid/notifications',
          'openIn': 'inAppWebView',
        }, extra: extra);
        return;
      default:
        lastError = 'Unsupported Grid host action "$hostId".';
        notifyListeners();
    }
  }

  String qrPayloadForMode(String mode, {Map<String, dynamic>? component}) {
    final share = component ??
        _map(components['grid-share-qr']) ??
        _map(content['shareQr']);
    final byMode = _map(share?['qrImageUrlsByMode']) ??
        _map(_map(components['grid-share-qr'])?['qrImageUrlsByMode']) ??
        _map(_map(content['shareQr'])?['qrImageUrlsByMode']);
    final modeUrl = byMode?[mode]?.toString().trim() ?? '';
    if (modeUrl.isNotEmpty) {
      final uri = Uri.tryParse(modeUrl);
      final dataParam = uri?.queryParameters['data']?.trim() ?? '';
      if (dataParam.isNotEmpty) return dataParam;
    }
    final payload = share?['qrPayload']?.toString().trim() ?? '';
    if (payload.isEmpty) return '';
    final uri = Uri.tryParse(payload);
    if (uri == null) return payload;
    final query = Map<String, String>.from(uri.queryParameters);
    query['mode'] = mode;
    return uri.replace(queryParameters: query).toString();
  }

  String qrImageUrlForMode(String mode, {Map<String, dynamic>? component}) {
    final share = component ??
        _map(components['grid-share-qr']) ??
        _map(content['shareQr']);
    if (share == null) return '';

    // Prefer schema-declared images only (no client-invented QR CDN host).
    final byMode = _map(share['qrImageUrlsByMode']) ??
        _map(_map(components['grid-share-qr'])?['qrImageUrlsByMode']) ??
        _map(_map(content['shareQr'])?['qrImageUrlsByMode']);
    final modeUrl = byMode?[mode]?.toString().trim() ?? '';
    if (modeUrl.isNotEmpty) return modeUrl;

    final staticUrl = _firstNonEmpty([
      share['qrImageUrl'],
      share['image'],
      share['imageUrl'],
    ]);
    if (staticUrl.isNotEmpty && mode == selectedQrMode) return staticUrl;

    final template = share['qrImageUrlTemplate']?.toString().trim() ?? '';
    final payload = qrPayloadForMode(mode, component: component);
    if (template.isNotEmpty && payload.isNotEmpty) {
      return template
          .replaceAll('{data}', Uri.encodeComponent(payload))
          .replaceAll('{size}', '200')
          .replaceAll('{mode}', Uri.encodeComponent(mode));
    }

    return staticUrl;
  }

  Color? tokenColor(String? token) {
    if (token == null || token.isEmpty) return null;
    final key = token.replaceFirst('colors.', '');
    final modeColors = _map(_map(themeConfig?['modes'])?[resolvedThemeMode]);
    if (modeColors != null) {
      final modeColor = _parseColor(modeColors[key] ?? modeColors[token]);
      if (modeColor != null) return modeColor;
    }
    if (!isDarkMode) {
      final themeColors = _map(themeConfig?['colors']);
      final themeColor = _parseColor(themeColors?[key] ?? themeColors?[token]);
      if (themeColor != null) return themeColor;
    }
    final colors = _map(designTokens['colors']);
    if (colors == null) return null;
    return _parseColor(colors[key] ?? colors[token]);
  }

  Color? parseColor(dynamic raw) => _parseColor(raw);

  String _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  Color? _parseColor(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    var hex = text.replaceFirst('#', '');
    if (hex.length == 3) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    return value == null ? null : Color(value);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }
}
