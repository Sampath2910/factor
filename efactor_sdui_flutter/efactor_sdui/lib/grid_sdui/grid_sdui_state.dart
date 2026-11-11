import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class GridSduiState extends ChangeNotifier {
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

  /// Account/schema configured mode: `light`, `dark`, or `system`.
  String get configuredThemeMode {
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
    final share = _map(content['shareQr']) ?? _map(components['grid-share-qr']);
    return share?['selectedMode']?.toString().trim() ?? 'professional';
  }

  String selectedFilter(String sectionId) {
    final key = '_clientSelectedFilter_$sectionId';
    final fromState = schema[key]?.toString().trim();
    if (fromState != null && fromState.isNotEmpty) return fromState;
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
      case 'open-grid-exploring-all':
        lastError =
            'Grid host action "$hostId" has no destination in the schema yet.';
        notifyListeners();
        return;
      default:
        lastError = 'Unsupported Grid host action "$hostId".';
        notifyListeners();
    }
  }

  String qrPayloadForMode(String mode) {
    final share = _map(content['shareQr']) ?? _map(components['grid-share-qr']);
    final payload = share?['qrPayload']?.toString().trim() ?? '';
    if (payload.isEmpty) return '';
    final uri = Uri.tryParse(payload);
    if (uri == null) return payload;
    final query = Map<String, String>.from(uri.queryParameters);
    query['mode'] = mode;
    return uri.replace(queryParameters: query).toString();
  }

  String qrImageUrlForMode(String mode) {
    final share =
        _map(content['shareQr']) ?? _map(components['grid-share-qr']);
    if (share == null) return '';

    // Prefer schema-declared images only (no client-invented QR CDN host).
    final byMode = _map(share['qrImageUrlsByMode']);
    final modeUrl = byMode?[mode]?.toString().trim() ?? '';
    if (modeUrl.isNotEmpty) return modeUrl;

    final staticUrl = _firstNonEmpty(<dynamic>[
      share['qrImageUrl'],
      share['image'],
      share['imageUrl'],
    ]);
    if (staticUrl.isNotEmpty) return staticUrl;

    final template = share['qrImageUrlTemplate']?.toString().trim() ?? '';
    final payload = qrPayloadForMode(mode);
    if (template.isNotEmpty && payload.isNotEmpty) {
      return template
          .replaceAll('{data}', Uri.encodeComponent(payload))
          .replaceAll('{payload}', Uri.encodeComponent(payload))
          .replaceAll('{mode}', Uri.encodeComponent(mode));
    }

    return '';
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
