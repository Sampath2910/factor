import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/efactor_cloud_service.dart';
import '../services/json_http.dart';
import '../services/schema_patch.dart';

class HomeSduiState extends ChangeNotifier {
  HomeSduiState({
    required this.schema,
    required String? accessToken,
    String? refreshToken,
    int? userId,
    String? email,
    String? username,
    List<String>? roles,
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _secureState = <String, dynamic>{
          'session': <String, dynamic>{
            'accessToken': accessToken,
            'iotAccessToken': accessToken,
            'refreshToken': refreshToken,
          },
        } {
    _state = _deepMap(schema['state']);

    if (userId != null) {
      writeState('session.userId', userId, notify: false);
    }
    final trimmedEmail = email?.trim() ?? '';
    final trimmedUsername = username?.trim() ?? '';
    if (trimmedEmail.isNotEmpty) {
      writeState('session.user.email', trimmedEmail, notify: false);
    }
    if (trimmedUsername.isNotEmpty) {
      writeState('session.user.username', trimmedUsername, notify: false);
    }
    final displayName = trimmedUsername.isNotEmpty
        ? trimmedUsername
        : trimmedEmail;
    if (displayName.isNotEmpty) {
      writeState('session.user.displayName', displayName, notify: false);
    }
    if (roles != null) {
      writeState('session.roles', roles, notify: false);
    }

    void copyIfEmpty(String path, dynamic raw) {
      final text = raw?.toString().trim() ?? '';
      if (text.isEmpty) return;
      final existing = readState(path)?.toString().trim() ?? '';
      if (existing.isEmpty) writeState(path, text, notify: false);
    }

    final profileData = _map(schema['profile']?['data']) ??
        _map(schema['profilePage']) ??
        _map(schema['meta']?['layoutSnapshot']?['profilePage']);
    if (profileData != null) {
      copyIfEmpty('session.user.displayName', profileData['name']);
      copyIfEmpty('session.user.email', profileData['email']);
      copyIfEmpty('session.user.phone', profileData['phone']);
      copyIfEmpty('session.user.memberId', profileData['memberId']);
    }

    final initialsSource =
        (readState('session.user.displayName') ??
                readState('session.user.email') ??
                '')
            .toString()
            .trim();
    if (initialsSource.isNotEmpty) {
      copyIfEmpty('session.user.initials', initialsSource[0].toUpperCase());
    }

    if (accessToken != null && accessToken.trim().isNotEmpty) {
      writeState('session.authenticated', true, notify: false);
    }

    _activeRouteId = readState('navigation.activeRouteId')?.toString() ??
        schema['navigation']?['initialRouteId']?.toString() ??
        schema['meta']?['defaultRouteId']?.toString() ??
        '';

    _parameters = <String, dynamic>{};

    EfactorCloudService.instance.liveNodes.addListener(_onLiveNodesChanged);
    if (EfactorCloudService.instance.liveNodes.value.isNotEmpty) {
      applyLiveNodes(EfactorCloudService.instance.liveNodes.value);
    }
  }

  void _onLiveNodesChanged() {
    if (_disposed) return;
    applyLiveNodes(EfactorCloudService.instance.liveNodes.value);
  }

  Map<String, dynamic> schema;
  final http.Client _client;
  late Map<String, dynamic> _state;
  final Map<String, dynamic> _secureState;
  final Map<String, dynamic> _data = <String, dynamic>{};
  final Map<String, String> _dataErrors = <String, String>{};

  String? dataError(String sourceId) => _dataErrors[sourceId];

  bool _disposed = false;
  bool _notifyScheduled = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (_disposed) return;
      super.notifyListeners();
    });
  }

  late String _activeRouteId;
  Map<String, dynamic> _parameters = <String, dynamic>{};

  Future<void> Function(String actionId, Map<String, dynamic> action)?
      hostActionHandler;

  String get activeRouteId => _activeRouteId;
  Map<String, dynamic> get parameters => Map.unmodifiable(_parameters);

  Future<SchemaPatchResult> replaceSchema(Map<String, dynamic> incoming) async {
    final previousSources = SchemaPatch.nodeFingerprint(
      schema['dataSources'],
    );
    final patch = SchemaPatch.merge(schema, incoming);
    if (patch.unchanged) return patch;

    schema = patch.schema;
    _syncServerControlledThemeState(incoming);

    // A live schema refresh may remove or rename the route that was active in
    // the previous schema. Re-resolve from the incoming schema instead of
    // leaving Home on an invalid route. This is capability based and does not
    // depend on any account or route name.
    if (route(_activeRouteId) == null) {
      final incomingState = _map(incoming['state']);
      final incomingNavigationState = _map(incomingState?['navigation']);
      final incomingNavigation = _map(incoming['navigation']);

      final candidates = <dynamic>[
        incomingNavigationState?['activeRouteId'],
        incomingNavigation?['initialRouteId'],
        _map(incoming['meta'])?['defaultRouteId'],
      ];

      String? nextRouteId;
      for (final raw in candidates) {
        final candidate = raw?.toString().trim();
        if (candidate != null &&
            candidate.isNotEmpty &&
            route(candidate) != null) {
          nextRouteId = candidate;
          break;
        }
      }

      if (nextRouteId == null) {
        final routes = _map(incoming['routes']);
        if (routes != null && routes.isNotEmpty) {
          nextRouteId = routes.keys.first;
        }
      }

      if (nextRouteId != null && nextRouteId.isNotEmpty) {
        _activeRouteId = nextRouteId;
        _parameters = <String, dynamic>{};
        writeState(
          'navigation.activeRouteId',
          _activeRouteId,
          notify: false,
        );
      }
    }

    notifyListeners();
    final nextSources = SchemaPatch.nodeFingerprint(
      schema['dataSources'],
    );
    if (patch.structural || previousSources != nextSources) {
      await loadRouteData();
    }
    return patch;
  }

  void _syncServerControlledThemeState(Map<String, dynamic> incoming) {
    final themes = _map(incoming['themes']);
    final incomingState = _map(incoming['state']);
    final incomingGlobal = _map(incomingState?['global']);

    final serverControlled = themes?['serverControlled'] == true ||
        incomingGlobal?['themeServerControlled'] == true;
    if (!serverControlled) return;

    final preset = incomingGlobal?['themePreset']?.toString().trim() ??
        themes?['activePreset']?.toString().trim();
    final mode = incomingGlobal?['themeMode']?.toString().trim() ??
        themes?['activeMode']?.toString().trim();

    if (preset != null && preset.isNotEmpty) {
      writeState('global.themePreset', preset, notify: false);
    }
    if (mode != null && mode.isNotEmpty) {
      writeState('global.themeMode', mode, notify: false);
    }
    writeState('global.themeServerControlled', true, notify: false);
  }

  dynamic readState(String path) => _readPath(_state, path);
  dynamic readSecureState(String path) => _readPath(_secureState, path);
  dynamic readData(String path) => _readPath(_data, path);

  void writeState(String path, dynamic value, {bool notify = true}) {
    _writePath(_state, path, value);
    if (notify) notifyListeners();
  }

  void writeSecureState(String path, dynamic value, {bool notify = true}) {
    _writePath(_secureState, path, value);
    if (notify) notifyListeners();
  }

  Map<String, dynamic>? component(String id) {
    final raw = schema['components']?[id];
    if (raw is Map) {
      return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
    }
    return null;
  }

  Map<String, dynamic>? route(String id) {
    final raw = schema['routes']?[id];
    if (raw is Map) {
      return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
    }
    return null;
  }

  Map<String, dynamic>? pageForRoute(String routeId) {
    final routeDef = route(routeId);
    final pageId = routeDef?['pageId']?.toString();
    final raw = pageId == null ? null : schema['pages']?[pageId];
    if (raw is Map) {
      return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
    }
    return null;
  }

  Map<String, dynamic>? get appShell {
    final raw = schema['appShell'];
    if (raw is Map) {
      return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
    }
    return null;
  }

  /// When true, nested IoT/Grid documents replace the Home shell (legacy push).
  /// The live Home schema sets this to false so the bottom bar stays visible.
  bool get replaceOnNestedSchema => appShell?['replaceOnNestedSchema'] == true;

  String? routeIdForHostAction(String hostActionId) {
    final items = schema['navigation']?['items'];
    final actions = schema['actionRegistry'];
    if (items is! List || actions is! Map) return null;

    for (final raw in items) {
      if (raw is! Map) continue;
      final actionId = raw['actionId']?.toString();
      if (actionId == null || actionId.isEmpty) continue;
      final action = actions[actionId];
      if (action is Map &&
          action['type']?.toString() == 'host-action' &&
          action['actionId']?.toString() == hostActionId) {
        return raw['routeId']?.toString();
      }
    }
    return null;
  }

  bool isLiveIotHostRoute([String? routeId]) {
    final id = routeId ?? _activeRouteId;
    final mapped = routeIdForHostAction('open-iot');
    return mapped != null && mapped == id;
  }

  bool isLiveGridHostRoute([String? routeId]) {
    final id = routeId ?? _activeRouteId;
    if (id.isEmpty) return false;

    final page = pageForRoute(id);
    if (page?['dataSourceId']?.toString() == 'grid') return true;

    final rootId = page?['rootComponentId']?.toString();
    if (rootId != null) {
      final root = component(rootId);
      if (root?['dataSourceId']?.toString() == 'grid') return true;
      if (root?['style']?.toString() == 'gridNetwork') return true;
    }

    if (routeIdForHostAction('open-grid') == id) return true;

    final actions = schema['actionRegistry'];
    if (actions is! Map) return false;
    for (final entry in actions.entries) {
      final action = entry.value;
      if (action is! Map) continue;
      final dest = action['destination'];
      if (dest is! Map || dest['routeId']?.toString() != id) continue;

      final type = action['type']?.toString();
      final hostId = action['actionId']?.toString();
      final name = entry.key.toString();
      if (type == 'host-action' &&
          (hostId == 'open-grid' || hostId == 'open-grid-module')) {
        return true;
      }
      if (type == 'navigate' &&
          (name == 'open-grid-module' || name == 'open-grid')) {
        return true;
      }
    }
    return false;
  }

  bool shouldEmbedLiveIot([String? routeId]) =>
      !replaceOnNestedSchema && isLiveIotHostRoute(routeId);

  bool shouldEmbedLiveGrid([String? routeId]) =>
      !replaceOnNestedSchema && isLiveGridHostRoute(routeId);

  bool shouldShowBottomNavigation([String? routeId]) {
    final id = routeId ?? _activeRouteId;
    final shell = appShell;
    final page = pageForRoute(id);
    final hideOn = shell?['hideOnRouteIds'];
    if (hideOn is List && hideOn.map((e) => e.toString()).contains(id)) {
      return false;
    }
    if (page?['hideBottomNavigation'] == true) return false;
    if (page?['bottomNavigationVisible'] == false) return false;

    final bottomId =
        page?['bottomNavigationComponentId']?.toString() ??
        shell?['bottomNavigationComponentId']?.toString();
    if (bottomId == null || bottomId.isEmpty) return false;

    if (page?['keepBottomNavigation'] == true ||
        page?['usesAppShell'] == true ||
        page?['bottomNavigationVisible'] == true ||
        shell?['persistAcrossRoutes'] == true ||
        shell?['persistsAcrossRoutes'] == true ||
        shell?['persistent'] == true) {
      return true;
    }

    final visibleOn = shell?['visibleOnRouteIds'];
    if (visibleOn is List && visibleOn.isNotEmpty) {
      return visibleOn.map((e) => e.toString()).contains(id);
    }
    return true;
  }

  bool navigationItemMatchesRoute(Map item, [String? routeId]) {
    final id = routeId ?? _activeRouteId;
    final itemRoute = item['routeId']?.toString();
    if (itemRoute == null || itemRoute.isEmpty) return false;
    if (itemRoute == id) return true;
    return isLiveGridHostRoute(id) && isLiveGridHostRoute(itemRoute);
  }

  dynamic resolve(
    dynamic value, {
    Map<String, dynamic>? item,
    Map<String, dynamic>? event,
    Map<String, dynamic>? parameters,
    dynamic response,
  }) {
    if (value is List) {
      return value
          .map(
            (e) => resolve(
              e,
              item: item,
              event: event,
              parameters: parameters,
              response: response,
            ),
          )
          .toList();
    }

    if (value is! Map) {
      return value;
    }

    final map = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());

    if (map.containsKey(r'$state')) {
      return _withFallback(
        readState(map[r'$state'].toString()),
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$secureState')) {
      return _withFallback(
        readSecureState(map[r'$secureState'].toString()),
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$bind')) {
      return _withFallback(
        readData(map[r'$bind'].toString()),
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$item')) {
      return _withFallback(
        _readPath(item ?? const <String, dynamic>{}, map[r'$item'].toString()),
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$event')) {
      return _withFallback(
        _readPath(
          event ?? const <String, dynamic>{},
          map[r'$event'].toString(),
        ),
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$parameter')) {
      return _withFallback(
        _readPath(parameters ?? _parameters, map[r'$parameter'].toString()),
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$toggleState')) {
      final rawPath = map[r'$toggleState']?.toString() ?? '';
      final path = _interpolateTemplate(rawPath, event: event, item: item);
      final current = readState(path);
      final toggled = current == true ? false : true;
      return _withFallback(
        toggled,
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$response')) {
      return _withFallback(
        _readPath(
          response is Map
              ? Map<String, dynamic>.from(response.cast<dynamic, dynamic>())
              : const <String, dynamic>{},
          map[r'$response'].toString(),
        ),
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$reference')) {
      return _withFallback(
        _readPath(schema, map[r'$reference'].toString()),
        map,
        item: item,
        event: event,
        parameters: parameters,
        response: response,
      );
    }

    if (map.containsKey(r'$format')) {
      var formatted = map[r'$format']?.toString() ?? '';
      final bindings = map[r'$bindings'];

      if (bindings is Map) {
        for (final entry in bindings.entries) {
          final key = entry.key.toString();
          final binding = entry.value;

          var resolved = resolve(
            binding,
            item: item,
            event: event,
            parameters: parameters,
            response: response,
          );

          if (binding is Map) {
            resolved = _applyValueTransform(
              resolved,
              binding['transform']?.toString(),
            );
          }

          formatted = formatted.replaceAll(
            '{$key}',
            resolved?.toString() ?? '',
          );
        }
      }

      return formatted;
    }

    if (map.containsKey(r'$i18n')) {
      return i18n(map[r'$i18n'].toString());
    }

    return <String, dynamic>{
      for (final entry in map.entries)
        entry.key: resolve(
          entry.value,
          item: item,
          event: event,
          parameters: parameters,
          response: response,
        ),
    };
  }

  dynamic _withFallback(
    dynamic resolved,
    Map<String, dynamic> binding, {
    Map<String, dynamic>? item,
    Map<String, dynamic>? event,
    Map<String, dynamic>? parameters,
    dynamic response,
  }) {
    if (resolved != null) return resolved;
    if (!binding.containsKey('fallback')) return null;
    return resolve(
      binding['fallback'],
      item: item,
      event: event,
      parameters: parameters,
      response: response,
    );
  }

  dynamic _applyValueTransform(dynamic value, String? transform) {
    if (value == null || transform == null || transform.isEmpty) {
      return value;
    }

    final text = value.toString();

    switch (transform) {
      case 'capitalizeFirst':
        if (text.isEmpty) return text;
        return text[0].toUpperCase() + text.substring(1);
      case 'uppercase':
        return text.toUpperCase();
      case 'lowercase':
        return text.toLowerCase();
      case 'trim':
        return text.trim();
      default:
        return value;
    }
  }

  String i18n(String key) {
    final locale = readState('global.locale')?.toString() ??
        schema['localization']?['defaultLocale']?.toString() ??
        'en';

    final resources = schema['localization']?['resources'];
    if (resources is! Map) return key;

    final exact = resources[locale];
    if (exact is Map && exact[key] != null) {
      return exact[key].toString();
    }

    final fallbackLocale =
        schema['localization']?['fallbackLocale']?.toString() ?? 'en';
    final fallback = resources[fallbackLocale];
    if (fallback is Map && fallback[key] != null) {
      return fallback[key].toString();
    }

    return key;
  }

  bool evaluate(
    dynamic expression, {
    Map<String, dynamic>? item,
    Map<String, dynamic>? event,
    Map<String, dynamic>? parameters,
  }) {
    if (expression == null) return true;
    if (expression is bool) return expression;
    if (expression is! Map) return false;

    final map = Map<String, dynamic>.from(expression.cast<dynamic, dynamic>());

    // Live Home schema uses compact visibility, e.g.
    // { "$state": "preferences.showWelcome", "equals": true }.
    // The previous length==1 gate treated that as false, so welcome/alerts
    // never rendered even though they are home-page children on web.
    const bindingKeys = <String>{
      r'$state',
      r'$bind',
      r'$secureState',
      r'$item',
      r'$event',
      r'$parameter',
    };
    String? bindingKey;
    for (final key in map.keys) {
      if (bindingKeys.contains(key.toString())) {
        bindingKey = key.toString();
        break;
      }
    }
    if (bindingKey != null) {
      final left = resolve(
        <String, dynamic>{bindingKey: map[bindingKey]},
        item: item,
        event: event,
        parameters: parameters,
      );
      if (map.containsKey('equals')) {
        return _valuesEqual(
          left,
          resolve(
            map['equals'],
            item: item,
            event: event,
            parameters: parameters,
          ),
        );
      }
      if (map.containsKey('notEquals')) {
        return !_valuesEqual(
          left,
          resolve(
            map['notEquals'],
            item: item,
            event: event,
            parameters: parameters,
          ),
        );
      }
      if (map.length == 1) return _isTruthy(left);
    }

    if (map.length != 1) {
      return false;
    }

    final op = map.keys.first.toString();
    final rawArgs = map.values.first;
    final args = rawArgs is List ? rawArgs : <dynamic>[rawArgs];

    dynamic arg(int index) {
      if (index >= args.length) return null;
      return resolve(
        args[index],
        item: item,
        event: event,
        parameters: parameters,
      );
    }

    num? n(dynamic v) {
      if (v is num) return v;
      return num.tryParse(v?.toString() ?? '');
    }

    switch (op) {
      case 'equals':
        return arg(0) == arg(1);
      case 'notEquals':
        return arg(0) != arg(1);
      case 'greaterThan':
        return (n(arg(0)) ?? double.nan) > (n(arg(1)) ?? double.nan);
      case 'greaterThanOrEqual':
        return (n(arg(0)) ?? double.nan) >= (n(arg(1)) ?? double.nan);
      case 'lessThan':
        return (n(arg(0)) ?? double.nan) < (n(arg(1)) ?? double.nan);
      case 'lessThanOrEqual':
        return (n(arg(0)) ?? double.nan) <= (n(arg(1)) ?? double.nan);
      case 'and':
        return args.every(
          (e) => evaluate(e, item: item, event: event, parameters: parameters),
        );
      case 'or':
        return args.any(
          (e) => evaluate(e, item: item, event: event, parameters: parameters),
        );
      case 'not':
        return !evaluate(
          args.isEmpty ? null : args.first,
          item: item,
          event: event,
          parameters: parameters,
        );
      case 'includes':
        final source = arg(0);
        final needle = arg(1);
        return source is Iterable && source.contains(needle);
      case 'exists':
        return arg(0) != null;
      case 'isEmpty':
        final value = arg(0);
        return value == null ||
            value == '' ||
            (value is Iterable && value.isEmpty) ||
            (value is Map && value.isEmpty);
      case 'matches':
        final value = arg(0)?.toString() ?? '';
        final pattern = arg(1)?.toString() ?? '';
        return RegExp(pattern).hasMatch(value);
      case r'$state':
      case r'$bind':
      case r'$secureState':
        return _isTruthy(arg(0));
      default:
        return false;
    }
  }

  bool _isTruthy(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (text.isEmpty || text == 'false' || text == '0') return false;
      return true;
    }
    if (value is Iterable) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }

  bool _valuesEqual(dynamic left, dynamic right) {
    if (identical(left, right) || left == right) return true;
    if (left is bool) return left == _isTruthy(right);
    if (right is bool) return right == _isTruthy(left);
    if (left is num && right is num) return left == right;
    return left?.toString() == right?.toString();
  }

  Future<void> navigate(
    String routeId, {
    Map<String, dynamic>? parameters,
  }) async {
    if (replaceOnNestedSchema && isLiveGridHostRoute(routeId)) {
      final handler = hostActionHandler;
      if (handler != null) {
        await handler('open-grid', <String, dynamic>{'routeId': routeId});
        return;
      }
    }

    final target = route(routeId);
    if (target == null) {
      await dispatchAction(
        schema['navigation']?['unknownRouteActionId']?.toString() ?? '',
      );
      return;
    }

    final routePermissions = (target['requiredPermissions'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    if (!_hasPermissions(routePermissions)) {
      final denied =
          schema['api']?['standardErrors']?['403']?['actionId']?.toString();
      if (denied != null && denied.isNotEmpty) {
        await dispatchAction(denied);
      }
      return;
    }

    final requiresAuth = target['requiresAuthentication'] == true;
    if (requiresAuth && readState('session.authenticated') != true) {
      final login = schema['routes']
          ?.entries
          .where((e) => e.value is Map && (e.value as Map)['public'] == true)
          .map((e) => e.key.toString())
          .cast<String?>()
          .firstWhere((e) => e != null, orElse: () => null);
      if (login != null) {
        _activeRouteId = login;
      }
    } else {
      final current = _activeRouteId;
      final history = readState('navigation.history');
      if (history is List && current.isNotEmpty && current != routeId) {
        history.add(current);
        final max =
            (schema['navigation']?['maximumHistoryEntries'] as num?)?.toInt() ??
                20;
        while (history.length > max) {
          history.removeAt(0);
        }
      }

      _activeRouteId = routeId;
      _parameters = parameters ?? <String, dynamic>{};
    }

    writeState('navigation.activeRouteId', _activeRouteId, notify: false);
    notifyListeners();
    await loadRouteData();
  }

  Future<bool> back() async {
    final history = readState('navigation.history');
    if (history is List && history.isNotEmpty) {
      final routeId = history.removeLast().toString();
      _activeRouteId = routeId;
      _parameters = <String, dynamic>{};
      writeState('navigation.activeRouteId', routeId, notify: false);
      notifyListeners();
      await loadRouteData();
      return true;
    }
    return false;
  }

  Future<void> loadRouteData() async {
    final page = pageForRoute(_activeRouteId);
    if (page == null) return;

    final pageId = page['id']?.toString();
    final sources = <String>{};

    final remoteStatus = schema['rendererFeatureStatus']
            ?['exampleRemoteDataSources']
        ?.toString();
    final remoteSourcesPublished = remoteStatus != 'not-published';

    // The supplied v3 contract uses dashboard data on home and device data on
    // devices/device-details. This discovery is based on actual bindings used
    // by the page component tree rather than route-name checks.
    final rootId = page['rootComponentId']?.toString();
    if (rootId != null) {
      _collectDataSourcePrefixes(rootId, sources, <String>{});
    }

    for (final sourceId in sources) {
      if (schema['dataSources']?[sourceId] == null) continue;

      if (!remoteSourcesPublished) {
        logDebug(
          '[HOME_SDUI][DATA] "$sourceId" skipped because '
          'rendererFeatureStatus.exampleRemoteDataSources=$remoteStatus.',
        );
        continue;
      }

      try {
        await refreshDataSource(sourceId);
      } catch (error) {
        logDebug('[HOME_SDUI][DATA_ERROR] $sourceId: $error');
      }
    }

    if (pageId != null) {
      notifyListeners();
    }
  }

  void _collectDataSourcePrefixes(
    String componentId,
    Set<String> output,
    Set<String> visited,
  ) {
    if (!visited.add(componentId)) return;
    final c = component(componentId);
    if (c == null) return;

    void walk(dynamic value) {
      if (value is Map) {
        if (value[r'$bind'] != null) {
          final path = value[r'$bind'].toString();
          final prefix = path.split('.').first;
          if (prefix.isNotEmpty) output.add(prefix);
        }
        for (final child in value.values) {
          walk(child);
        }
      } else if (value is List) {
        for (final child in value) {
          walk(child);
        }
      }
    }

    walk(c);

    final children = c['children'];
    if (children is List) {
      for (final child in children) {
        if (child is String) {
          _collectDataSourcePrefixes(child, output, visited);
        }
      }
    }
  }

  Future<void> refreshDataSource(String id) async {
    final raw = schema['dataSources']?[id];
    if (raw is! Map) return;

    final ds = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
    if (ds['type']?.toString() != 'rest') {
      throw FormatException('Unsupported data source type: ${ds['type']}');
    }

    if (!_hasPermissions(
      (ds['requires'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
    )) {
      throw StateError('Permission denied for data source "$id".');
    }

    final endpoint = _interpolatePath(
      ds['endpoint']?.toString() ?? '',
      _resolveMap(ds['pathParameters']),
    );

    var uri = _apiUri(endpoint);

    final queryParameters = _resolveMap(ds['queryParameters']);
    if (queryParameters.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{
          ...uri.queryParameters,
          for (final entry in queryParameters.entries)
            if (entry.value != null && entry.value.toString().trim().isNotEmpty)
              entry.key: entry.value.toString(),
        },
      );
    }

    final method = ds['method']?.toString().toUpperCase() ?? 'GET';
    final timeoutMs = (ds['timeoutMs'] as num?)?.toInt() ?? 15000;

    final resolvedUserId = readState('session.userId')?.toString().trim() ?? '';
    final cacheKey = resolvedUserId.isNotEmpty
        ? 'home_sdui.cache.$resolvedUserId.$id'
        : 'home_sdui.cache.$id';
    final prefs = await SharedPreferences.getInstance();

    try {
      late http.Response response;
      if (method == 'GET') {
        final requestHeaders = _headers();
        final declaredHeaders = _resolveMap(ds['headers']);
        for (final entry in declaredHeaders.entries) {
          final value = entry.value?.toString().trim() ?? '';
          if (value.isNotEmpty) requestHeaders[entry.key] = value;
        }
        response = await _client
            .get(uri, headers: requestHeaders)
            .timeout(Duration(milliseconds: timeoutMs));
      } else {
        throw FormatException(
          'Data source "$id" uses unsupported method "$method".',
        );
      }

      if (response.statusCode == 401) {
        await _handleStandardError('401');
        return;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw http.ClientException(
          'HTTP ${response.statusCode} for data source "$id".',
          uri,
        );
      }

      final decoded = decodeJsonBody(
        body: response.body,
        contentType: response.headers['content-type'],
        source: 'home-datasource:$id',
      );
      if (decoded is! Map) {
        throw FormatException('Data source "$id" response must be an object.');
      }

      final mapped = <String, dynamic>{};
      final responseMapping = _map(ds['responseMapping']);
      if (responseMapping != null) {
        for (final entry in responseMapping.entries) {
          mapped[entry.key] = _jsonPath(decoded, entry.value.toString());
        }
      }

      // Honor schema fallback mappings without hardcoding a response shape.
      // Example: items + fallbackItems, summary + fallbackSummary.
      for (final key in mapped.keys.toList(growable: false)) {
        if (!key.startsWith('fallback') || key.length <= 8) continue;
        final target = key.substring(8, 9).toLowerCase() + key.substring(9);
        final current = mapped[target];
        final fallback = mapped[key];
        final emptyCurrent = current == null ||
            (current is List && current.isEmpty) ||
            (current is Map && current.isEmpty);
        if (emptyCurrent && fallback != null) mapped[target] = fallback;
      }

      _data[id] = mapped;
      _dataErrors.remove(id);

      await prefs.setString(
        cacheKey,
        jsonEncode(<String, dynamic>{
          'savedAt': DateTime.now().toUtc().toIso8601String(),
          'data': mapped,
        }),
      );
      notifyListeners();
    } catch (error) {
      final policy = _map(ds['errorPolicy']);
      if (policy?['useCachedData'] == true) {
        final cached = prefs.getString(cacheKey);
        if (cached != null) {
          final decoded = jsonDecode(cached);
          if (decoded is Map && decoded['data'] is Map) {
            _data[id] = Map<String, dynamic>.from(
              (decoded['data'] as Map).cast<dynamic, dynamic>(),
            );
            _dataErrors.remove(id);
            notifyListeners();
            return;
          }
        }
      }

      _dataErrors[id] = 'Data source "$id" failed: $error';
      notifyListeners();
      rethrow;
    }
  }

  /// Clears persisted datasource cache (e.g. dashboard, profile) for this user on logout.
  static Future<void> clearUserCache({required int? userId}) async {
    final uid = userId?.toString().trim();
    if (uid == null || uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final prefix = 'home_sdui.cache.$uid.';
      for (final key in keys) {
        if (key.startsWith(prefix)) {
          await prefs.remove(key);
        }
      }
      logDebug('[HomeSduiState] Cleared datasource cache for user=$uid');
    } catch (error) {
      logDebug('[HomeSduiState] Failed to clear user cache: $error');
    }
  }

  Future<void> dispatchAction(
    String actionId, {
    Map<String, dynamic>? event,
    Map<String, dynamic>? item,
  }) async {
    if (actionId.trim().isEmpty) return;

    if (actionId == 'logout' ||
        actionId == 'host-logout' ||
        actionId == 'session-expired') {
      final handler = hostActionHandler;
      if (handler != null) {
        await handler('logout', <String, dynamic>{'actionId': actionId});
        return;
      }
    }

    final configuredLogoutActionId =
        schema['auth']?['logout']?['actionId']?.toString().trim();

    if (configuredLogoutActionId != null &&
        configuredLogoutActionId.isNotEmpty &&
        actionId == configuredLogoutActionId) {
      final handler = hostActionHandler;
      if (handler == null) {
        throw StateError(
          'Home schema requested logout, but the authenticated host logout '
          'handler is not configured.',
        );
      }

      final rawLogout = schema['actionRegistry']?[actionId];
      final logoutAction = rawLogout is Map
          ? Map<String, dynamic>.from(rawLogout.cast<dynamic, dynamic>())
          : <String, dynamic>{'actionId': actionId};

      logDebug(
        '[HOME_SDUI][LOGOUT] Delegating schema logout action '
        '"$actionId" to authenticated Flutter host.',
      );

      await handler('logout', logoutAction);
      return;
    }

    if (replaceOnNestedSchema &&
        (actionId == 'open-grid-module' || actionId == 'open-grid')) {
      final handler = hostActionHandler;
      if (handler == null) {
        throw StateError(
          'Home schema requested Grid but the authenticated host '
          'did not provide onOpenGrid.',
        );
      }
      await handler('open-grid', <String, dynamic>{'actionId': actionId});
      return;
    }

    final raw = schema['actionRegistry']?[actionId];
    if (raw is! Map) {
      throw FormatException('Unknown action "$actionId".');
    }

    final action = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());

    if (!_hasPermissions(
      (action['requires'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
    )) {
      await _showActionError(action, fallback: 'Access denied.');
      return;
    }

    if (!await _ensureNativePermissions(action)) {
      return;
    }

    await _executeAction(action, actionId: actionId, event: event, item: item);
  }

  Future<void> _executeAction(
    Map<String, dynamic> action, {
    required String actionId,
    Map<String, dynamic>? event,
    Map<String, dynamic>? item,
    dynamic response,
  }) async {
    switch (action['type']?.toString()) {
      case 'navigate':
        final destination = _map(action['destination']);
        final routeId = destination?['routeId']?.toString();
        if (routeId == null) {
          throw FormatException('$actionId destination.routeId is missing.');
        }

        final parameters = _resolveMap(
          destination?['parameters'],
          event: event,
          item: item,
          response: response,
        );

        await navigate(routeId, parameters: parameters);
        return;

      case 'sequence':
        final actions = action['actions'];
        if (actions is! List) {
          throw FormatException('$actionId actions[] is required.');
        }

        for (var i = 0; i < actions.length; i++) {
          final step = actions[i];
          if (step is Map) {
            await _executeAction(
              Map<String, dynamic>.from(step.cast<dynamic, dynamic>()),
              actionId: '$actionId[$i]',
              event: event,
              item: item,
              response: response,
            );
          }
        }
        return;

      case 'set-state':
        final path = action['path']?.toString();
        if (path == null) {
          throw FormatException('$actionId.path is required.');
        }
        writeState(
          _interpolateTemplate(path, event: event, item: item),
          resolve(
            action['value'],
            event: event,
            item: item,
            parameters: _parameters,
            response: response,
          ),
        );
        return;

      case 'set-secure-state':
        final path = action['path']?.toString();
        if (path == null) {
          throw FormatException('$actionId.path is required.');
        }
        writeSecureState(
          _interpolateTemplate(path, event: event, item: item),
          resolve(
            action['value'],
            event: event,
            item: item,
            parameters: _parameters,
            response: response,
          ),
        );
        return;

      case 'refresh-data-source':
        final id = action['dataSourceId']?.toString();
        if (id == null) {
          throw FormatException('$actionId.dataSourceId is required.');
        }
        await refreshDataSource(id);
        return;

      case 'request':
        await _executeRequest(
          action,
          actionId: actionId,
          event: event,
          item: item,
        );
        return;

      case 'show-bottom-sheet':
      case 'show-dialog':
      case 'show-snackbar':
        // These presentation actions are executed by the UI host through
        // presentationHandler, configured by DynamicHomeSduiPage.
        final handler = presentationHandler;
        if (handler != null) {
          await handler(action, event: event, item: item);
        }
        return;

      case 'host-action':
        final hostActionId = action['actionId']?.toString();
        if (hostActionId == null || hostActionId.isEmpty) {
          throw FormatException('$actionId.actionId is required.');
        }
        final handler = hostActionHandler;
        if (handler == null) {
          throw StateError(
            'No host action handler is registered for "$hostActionId".',
          );
        }

        // Resolve schema-declared host parameters against the tapped item/event
        // before crossing into the Flutter host. This keeps node/model identity
        // server-driven and avoids teaching main.dart about component internals.
        final resolvedParameters = _resolveMap(
          action['parameters'],
          event: event,
          item: item,
          response: response,
        );
        await handler(hostActionId, <String, dynamic>{
          ...action,
          if (resolvedParameters.isNotEmpty) 'parameters': resolvedParameters,
        });
        return;

      case 'external-navigate':
        final url = resolve(
          action['url'],
          event: event,
          item: item,
          parameters: _parameters,
          response: response,
        )?.toString();

        if (url == null || url.trim().isEmpty) {
          throw FormatException('$actionId.url is required.');
        }

        final handler = hostActionHandler;
        if (handler == null) {
          throw StateError(
            'No host action handler is registered for external navigation.',
          );
        }

        await handler('external-navigate', <String, dynamic>{
          ...action,
          'url': url,
        });
        return;

      default:
        throw FormatException(
          'Unsupported action type ${action['type']} at $actionId.',
        );
    }
  }

  Future<void> _executeRequest(
    Map<String, dynamic> action, {
    required String actionId,
    Map<String, dynamic>? event,
    Map<String, dynamic>? item,
  }) async {
    final request = _map(action['request']);
    if (request == null) {
      throw FormatException('$actionId.request is required.');
    }

    final method = request['method']?.toString().toUpperCase() ?? 'GET';
    final pathParameters = _resolveMap(
      request['pathParameters'],
      event: event,
      item: item,
    );

    final endpoint = _interpolatePath(
      request['endpoint']?.toString() ?? '',
      pathParameters,
    );

    final uri = _apiUri(endpoint);
    final headers = _headers();

    final requestHeaders = _map(request['headers']);
    if (requestHeaders != null) {
      for (final entry in requestHeaders.entries) {
        final resolved = resolve(
          entry.value,
          event: event,
          item: item,
          parameters: _parameters,
        );
        if (resolved != null) {
          headers[entry.key] = resolved.toString();
        }
      }
    }

    final body = resolve(
      request['body'],
      event: event,
      item: item,
      parameters: _parameters,
    );

    late http.Response response;
    if (method == 'GET') {
      response = await _client.get(uri, headers: headers);
    } else if (method == 'POST') {
      response = await _client.post(
        uri,
        headers: headers,
        body: jsonEncode(body ?? const <String, dynamic>{}),
      );
    } else {
      throw FormatException('$actionId uses unsupported method "$method".');
    }

    if (response.statusCode == 401) {
      await _handleStandardError('401');
      return;
    }
    if (response.statusCode == 403) {
      await _handleStandardError('403');
      return;
    }
    if (response.statusCode == 404) {
      await _handleStandardError('404');
      return;
    }
    if (response.statusCode == 429) {
      await _handleStandardError('429');
      return;
    }
    if (response.statusCode >= 500) {
      await _handleStandardError('500');
      return;
    }

    dynamic decoded;
    if (response.body.trim().isNotEmpty) {
      try {
        decoded = decodeJsonBody(
          body: response.body,
          contentType: response.headers['content-type'],
          source: 'home-action:$actionId',
        );
      } on FormatException {
        if (looksLikeHtml(response.body)) {
          throw FormatException(
            'API returned HTML instead of JSON for "$actionId".',
          );
        }
        decoded = response.body;
      }
    }

    final onSuccess = _map(action['onSuccess']);
    if (onSuccess != null &&
        response.statusCode >= 200 &&
        response.statusCode < 300) {
      await _executeAction(
        onSuccess,
        actionId: '$actionId.onSuccess',
        event: event,
        item: item,
        response: decoded,
      );
    }

    notifyListeners();
  }

  Future<void> _handleStandardError(String statusCode) async {
    final actionId =
        schema['api']?['standardErrors']?[statusCode]?['actionId']?.toString();
    if (actionId != null) {
      await dispatchAction(actionId);
    }
  }

  bool _hasPermissions(List<String> required) {
    if (required.isEmpty) return true;
    final roles = readState('session.roles');

    // If no roles data has been loaded yet (e.g. the backend hasn't returned
    // role information with this session), allow the action rather than
    // silently blocking it. Server-side enforcement is the authoritative gate.
    if (roles is! List || roles.isEmpty) return true;

    final roleMap = schema['permissions']?['roles'];
    // If the schema does not define a role→permission map, allow the action.
    if (roleMap is! Map) return true;

    final granted = <String>{};
    for (final role in roles) {
      final permissions = roleMap[role.toString()];
      if (permissions is List) {
        granted.addAll(permissions.map((e) => e.toString()));
      }
    }

    return granted.contains('*') || required.every(granted.contains);
  }

  Future<bool> _ensureNativePermissions(Map<String, dynamic> action) async {
    final required = action['requiredNativePermissions'];
    if (required is! List || required.isEmpty) return true;

    for (final raw in required) {
      final name = raw.toString();
      final permissions = _nativePermissionsFor(name);

      if (permissions.isEmpty) continue;

      var granted = true;
      for (final permission in permissions) {
        final result = await permission.request();
        if (!result.isGranted) {
          granted = false;
        }
      }

      if (!granted) {
        final deniedActionId = schema['permissions']?['native']?[name]
                ?['deniedActionId']
            ?.toString();
        if (deniedActionId != null) {
          await dispatchAction(deniedActionId);
        }
        return false;
      }
    }

    return true;
  }

  List<Permission> _nativePermissionsFor(String name) {
    switch (name) {
      case 'camera':
        return <Permission>[Permission.camera];
      case 'location':
        return <Permission>[Permission.locationWhenInUse];
      case 'notifications':
        return <Permission>[Permission.notification];
      case 'bluetooth':
        // Android 12+ splits Bluetooth into scan/connect permissions.
        // iOS exposes one Bluetooth permission through permission_handler.
        // The schema still declares only the platform-independent capability
        // name "bluetooth"; Flutter maps that capability to the native API.
        if (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS) {
          return <Permission>[Permission.bluetooth];
        }
        return <Permission>[
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
        ];
      default:
        return const <Permission>[];
    }
  }

  Future<void> _showActionError(
    Map<String, dynamic> action, {
    required String fallback,
  }) async {
    final presentation = _map(action['errorPresentation']);
    if (presentation != null && presentationHandler != null) {
      await presentationHandler!(presentation);
      return;
    }
    logDebug('[HOME_SDUI] $fallback');
  }

  Uri _apiUri(String endpoint) {
    final env = resolve(
      schema['api']?['currentEnvironmentBinding'],
    )?.toString();

    final environments = schema['api']?['environments'];
    final environment = environments is Map ? environments[env] : null;
    final baseUrl =
        environment is Map ? environment['baseUrl']?.toString() : null;

    if (baseUrl == null || baseUrl.trim().isEmpty) {
      throw StateError('API baseUrl is missing for environment "$env".');
    }

    final base = Uri.parse(baseUrl);
    final uri =
        endpoint.startsWith('http://') || endpoint.startsWith('https://')
            ? Uri.parse(endpoint)
            : base.resolve(endpoint);

    if (schema['security']?['requireHttps'] == true &&
        uri.scheme.toLowerCase() != 'https') {
      throw StateError('Schema requires HTTPS but resolved URI is $uri.');
    }

    return uri;
  }

  Map<String, String> _headers() {
    final headers = <String, String>{};
    final defaults = schema['api']?['defaultHeaders'];
    if (defaults is Map) {
      for (final entry in defaults.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }

    final auth = _map(schema['api']?['authentication']);
    if (auth?['type'] == 'bearer') {
      final token = resolve(auth?['tokenBinding'])?.toString().trim();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }

    return headers;
  }

  Map<String, dynamic> _resolveMap(
    dynamic raw, {
    Map<String, dynamic>? event,
    Map<String, dynamic>? item,
    dynamic response,
  }) {
    if (raw is! Map) return <String, dynamic>{};
    final out = <String, dynamic>{};
    for (final entry in raw.entries) {
      out[entry.key.toString()] = resolve(
        entry.value,
        event: event,
        item: item,
        parameters: _parameters,
        response: response,
      );
    }
    return out;
  }

  String _interpolatePath(String template, Map<String, dynamic> values) {
    var out = template;
    for (final entry in values.entries) {
      out = out.replaceAll(
        '{${entry.key}}',
        Uri.encodeComponent(entry.value?.toString() ?? ''),
      );
    }
    return out;
  }

  String _interpolateTemplate(
    String template, {
    Map<String, dynamic>? event,
    Map<String, dynamic>? item,
  }) {
    var out = template;
    final merged = <String, dynamic>{...?event, ...?item};
    for (final entry in merged.entries) {
      out = out.replaceAll('{${entry.key}}', entry.value?.toString() ?? '');
    }
    return out;
  }

  dynamic _jsonPath(dynamic source, String path) {
    var normalized = path.trim();
    if (normalized.startsWith(r'$.')) {
      normalized = normalized.substring(2);
    } else if (normalized == r'$') {
      return source;
    }

    dynamic current = source;
    for (final part in normalized.split('.')) {
      if (current is Map) {
        current = current[part];
      } else {
        return null;
      }
    }
    return current;
  }

  Map<String, dynamic> _deepMap(dynamic source) {
    if (source is! Map) return <String, dynamic>{};
    return jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  }

  dynamic _readPath(Map<String, dynamic> root, String path) {
    dynamic current = root;
    if (path.isEmpty) return current;
    for (final part in path.split('.')) {
      if (current is! Map) return null;
      current = current[part];
    }
    return current;
  }

  void _writePath(Map<String, dynamic> root, String path, dynamic value) {
    final parts = path.split('.');
    Map<String, dynamic> current = root;

    for (var i = 0; i < parts.length - 1; i++) {
      final part = parts[i];
      final next = current[part];
      if (next is Map<String, dynamic>) {
        current = next;
      } else if (next is Map) {
        final converted = Map<String, dynamic>.from(
          next.cast<dynamic, dynamic>(),
        );
        current[part] = converted;
        current = converted;
      } else {
        final created = <String, dynamic>{};
        current[part] = created;
        current = created;
      }
    }

    current[parts.last] = value;
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  static bool? _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'online' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'offline' || text == 'off') {
      return false;
    }
    return null;
  }

  void applyLiveNodes(Map<String, dynamic> liveNodes) {
    if (_disposed || liveNodes.isEmpty || _data.isEmpty) return;

    var modified = false;

    void updateDeviceMap(Map<String, dynamic> device) {
      final nodeId = (device['node_id'] ??
              device['nodeId'] ??
              device['id'] ??
              device['deviceId'])
          ?.toString()
          .trim();
      if (nodeId == null || nodeId.isEmpty) return;

      Map<String, dynamic>? nodeData;
      if (liveNodes.containsKey(nodeId)) {
        final raw = liveNodes[nodeId];
        if (raw is Map) nodeData = Map<String, dynamic>.from(raw);
      } else {
        for (final entry in liveNodes.values) {
          if (entry is! Map) continue;
          final entryId = (entry['node_id'] ?? entry['nodeId'] ?? entry['id'])?.toString().trim();
          if (entryId == nodeId) {
            nodeData = Map<String, dynamic>.from(entry);
            break;
          }
          final childDevices = entry['devices'];
          if (childDevices is List) {
            for (final d in childDevices) {
              if (d is Map &&
                  (d['id']?.toString().trim() == nodeId ||
                      d['node_id']?.toString().trim() == nodeId)) {
                nodeData = Map<String, dynamic>.from(entry);
                break;
              }
            }
          }
          if (nodeData != null) break;
        }
      }

      if (nodeData != null) {
        final status = nodeData['status'];
        bool? connected;
        if (status is Map) {
          final conn = status['connectivity'];
          if (conn is Map) {
            connected = _asBool(conn['connected']);
          } else {
            connected = _asBool(status['connected']);
          }
        }
        connected ??= _asBool(nodeData['online']) ?? _asBool(nodeData['connected']);

        if (connected != null) {
          if (device['online'] != connected ||
              device['status'] != (connected ? 'Online' : 'Offline')) {
            device['online'] = connected;
            device['status'] = connected ? 'Online' : 'Offline';
            modified = true;
          }
        }

        dynamic powerVal = nodeData['power'];
        if (status is Map && status.containsKey('power')) {
          powerVal = status['power'];
        }
        final power = _asBool(powerVal);
        if (power != null && device['power'] != power) {
          device['power'] = power;
          modified = true;
        }
      }
    }

    void scanValue(dynamic value) {
      if (value is Map) {
        if (value.containsKey('node_id') ||
            value.containsKey('nodeId') ||
            (value.containsKey('id') &&
                (value.containsKey('online') ||
                    value.containsKey('status') ||
                    value.containsKey('power')))) {
          updateDeviceMap(Map<String, dynamic>.from(value));
        }
        for (final v in value.values) {
          scanValue(v);
        }
      } else if (value is List) {
        for (final item in value) {
          scanValue(item);
        }
      }
    }

    scanValue(_data);

    if (modified) {
      notifyListeners();
    }
  }

  Future<void> Function(
    Map<String, dynamic> action, {
    Map<String, dynamic>? event,
    Map<String, dynamic>? item,
  })? presentationHandler;

  @override
  void dispose() {
    EfactorCloudService.instance.liveNodes.removeListener(_onLiveNodesChanged);
    _disposed = true;
    _client.close();
    super.dispose();
  }
}
