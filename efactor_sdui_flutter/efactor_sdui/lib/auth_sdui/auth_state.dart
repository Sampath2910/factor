import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'auth_secure_storage.dart';
import '../services/app_cache_manager.dart';
import '../services/json_http.dart';
import '../services/user_location_service.dart';

class AuthState extends ChangeNotifier {
  AuthState(
    this.schema, {
    http.Client? client,
    AuthSecureStorage? secureStorage,
  }) : _client = client ?? http.Client(),
       _secureStorage = secureStorage ?? AuthSecureStorage() {
    final rawState = schema['state'];

    if (rawState is! Map) {
      throw const FormatException('auth schema state must be an object.');
    }

    _state = jsonDecode(jsonEncode(rawState)) as Map<String, dynamic>;

    var initial = schema['app']?['initialPageId']?.toString().trim();

    if (initial == null || initial.isEmpty || initial == 'welcome') {
      initial = 'login';
    }

    _pageId = initial;
  }

  final Map<String, dynamic> schema;
  final http.Client _client;
  final AuthSecureStorage _secureStorage;

  late Map<String, dynamic> _state;
  late String _pageId;

  final Map<String, String> fieldErrors = <String, String>{};

  final Map<String, bool> _passwordVisible = <String, bool>{};

  dynamic _lastResponseBody;
  int? _lastResponseStatusCode;

  final Map<String, String> _cookies = <String, String>{};

  String get cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _saveCookies(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) return;

    final parts = setCookie.split(RegExp(r',(?=\s*[A-Za-z0-9_\-]+=)'));
    for (final raw in parts) {
      final nameVal = raw.split(';').first.trim();
      final eq = nameVal.indexOf('=');
      if (eq > 0) {
        final name = nameVal.substring(0, eq).trim();
        final value = nameVal.substring(eq + 1).trim();
        if (name.isNotEmpty &&
            !name.toLowerCase().startsWith('expires') &&
            !name.toLowerCase().startsWith('max-age') &&
            !name.toLowerCase().startsWith('path') &&
            !name.toLowerCase().startsWith('domain') &&
            !name.toLowerCase().startsWith('samesite')) {
          _cookies[name] = value;
        }
      }
    }
  }

  String get pageId => _pageId;

  bool get isAuthenticated => read('auth.isAuthenticated') == true;

  bool get isLoading => read('auth.isLoading') == true;

  String get authError => read('auth.error')?.toString() ?? '';

  String get authNotice => read('auth.notice')?.toString() ?? '';

  String? get accessToken =>
      _nonEmpty(read('auth.accessToken')) ??
      _nonEmpty(read('auth.accesstoken'));

  String? get idToken =>
      _nonEmpty(read('auth.idToken')) ?? _nonEmpty(read('auth.idtoken'));

  String? get refreshToken =>
      _nonEmpty(read('auth.refreshToken')) ??
      _nonEmpty(read('auth.refreshtoken'));

  Map<String, String> get authorizationHeaders {
    final token = accessToken;

    if (!isAuthenticated || token == null) {
      return const <String, String>{};
    }

    return <String, String>{'Authorization': 'Bearer $token'};
  }

  dynamic read(String path) => _read(_state, path);

  void write(String path, dynamic value, {bool notify = true}) {
    _write(_state, path, value);
    fieldErrors.remove(path);
    if (path != 'auth.error' && authError.isNotEmpty) {
      _write(_state, 'auth.error', null);
    }
    if (notify) {
      notifyListeners();
    }
  }

  bool passwordVisible(String key) => _passwordVisible[key] == true;

  void togglePassword(String key) {
    _passwordVisible[key] = !passwordVisible(key);

    notifyListeners();
  }

  Map<String, dynamic>? page(String id) {
    final pages = schema['pages'];

    if (pages is! List) {
      return null;
    }

    for (final raw in pages) {
      if (raw is Map && raw['id']?.toString() == id) {
        return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
      }
    }

    return null;
  }

  Map<String, dynamic>? action(String actionRef) {
    final actions = schema['actions'];

    if (actions is! Map) {
      return null;
    }

    final raw = actions[actionRef];

    if (raw is! Map) {
      return null;
    }

    return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
  }

  bool isActionLoading(String actionRef) {
    final current = action(actionRef);

    final key = current?['loadingStateKey']?.toString();

    return key != null && key.isNotEmpty && read(key) == true;
  }

  /// Returns true if a JWT token has expired based on its 'exp' claim.
  static bool isJwtExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;
      final normalized = base64Url.normalize(parts[1]);
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(normalized)),
      ) as Map<String, dynamic>;
      final exp = (payload['exp'] as num?)?.toInt();
      if (exp == null) return false;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= exp;
    } catch (_) {
      return false;
    }
  }

  Future<void> restoreSession() async {
    try {
      final stored = await _secureStorage.readSession();

      final token = _nonEmpty(stored['accessToken']);

      if (token == null) {
        return;
      }

      _write(_state, 'auth.accessToken', token);
      _write(_state, 'auth.accesstoken', token);

      _write(_state, 'auth.idToken', stored['idToken']);
      _write(_state, 'auth.idtoken', stored['idToken']);

      _write(_state, 'auth.refreshToken', stored['refreshToken']);
      _write(_state, 'auth.refreshtoken', stored['refreshToken']);

      _write(_state, 'auth.username', stored['username']);

      _write(_state, 'auth.email', stored['email']);

      _write(_state, 'auth.userType', stored['userType']);
      _write(_state, 'auth.user_type', stored['userType']);

      _write(_state, 'auth.userId', stored['userId']);
      _write(_state, 'auth.user_id', stored['userId']);

      _write(_state, 'auth.isAuthenticated', true);

      notifyListeners();
    } catch (e, stackTrace) {
      debugPrint('[AuthState] restoreSession error: $e');
      debugPrintStack(stackTrace: stackTrace);
      _write(_state, 'auth.isAuthenticated', false);
    }
  }

  Future<void> clearSession({bool notify = true}) async {
    final uid = int.tryParse(read('auth.userId')?.toString() ?? '');
    final token = accessToken;
    try {
      await AppCacheManager.clearAllOnLogout(
        userId: uid,
        accessToken: token,
      );
    } catch (e) {
      debugPrint('[AuthState] AppCacheManager error: $e');
    }

    await _secureStorage.clearSession();

    final rawState = schema['state'] is Map
        ? schema['state'] as Map<String, dynamic>
        : <String, dynamic>{};
    _state = jsonDecode(jsonEncode(rawState)) as Map<String, dynamic>;

    for (final key in const <String>[
      'auth.accessToken',
      'auth.accesstoken',
      'auth.idToken',
      'auth.idtoken',
      'auth.refreshToken',
      'auth.refreshtoken',
      'auth.username',
      'auth.email',
      'auth.userType',
      'auth.user_type',
      'auth.userId',
      'auth.user_id',
    ]) {
      _write(_state, key, null);
    }

    _cookies.clear();
    fieldErrors.clear();
    _passwordVisible.clear();
    _write(_state, 'auth.isAuthenticated', false);

    if (notify) {
      notifyListeners();
    }
  }

  Future<void> invalidateSession() async {
    await clearSession();
  }

  Future<void> dispatch(String actionRef) async {
    final current = action(actionRef);

    if (current == null) {
      _setAuthError('actions.$actionRef is missing.');
      return;
    }

    _setIfPresent('auth.lastAction', actionRef);

    _setIfPresent('auth.error', null);

    _setIfPresent('auth.notice', null);

    try {
      await _executeAction(current, source: 'actions.$actionRef');
    } catch (error, stackTrace) {
      debugPrint(
        '[AUTH][ACTION][ERROR] '
        '$actionRef $error',
      );

      debugPrintStack(stackTrace: stackTrace);

      _setAuthError(_friendlyActionError(error));
    }
  }

  Future<void> _executeAction(
    Map<String, dynamic> action, {
    required String source,
  }) async {
    final type = action['type']?.toString();

    switch (type) {
      case 'navigate':
        await _navigate(action, source: source);
        return;

      case 'url':
        final raw = action['url']?.toString();

        if (raw == null || raw.isEmpty) {
          throw FormatException('$source.url is required.');
        }

        final uri = resolveUri(raw);

        final opened = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );

        if (!opened) {
          throw StateError('Could not open ${uri.toString()}');
        }

        return;

      case 'uiState':
        _executeUiState(action, source: source);
        return;

      case 'setState':
        final key = action['targetStateKey']?.toString();

        if (key == null || key.isEmpty) {
          throw FormatException(
            '$source.targetStateKey '
            'is required.',
          );
        }

        dynamic value;

        if (action.containsKey('valuePath')) {
          value = _readDynamic(
            _lastResponseBody,
            action['valuePath']?.toString() ?? '',
          );
        } else if (action.containsKey('valueStateKey')) {
          value = read(action['valueStateKey']?.toString() ?? '');
        } else if (action.containsKey('messagePath')) {
          value = _readDynamic(
            _lastResponseBody,
            action['messagePath']?.toString() ?? '',
          );
          if (value == null || value.toString().trim().isEmpty) {
            value = action.containsKey('fallbackValue')
                ? _resolve(action['fallbackValue'])
                : null;
          }
          if (value == null || value.toString().trim().isEmpty) {
            value = _responseMessage(_lastResponseBody);
          }
        } else {
          value = _resolve(action['value']);
        }

        // API `description` is authoritative for server/auth errors.
        // Do not rewrite backend wording in Flutter.

        _write(_state, key, value);
        notifyListeners();
        return;

      case 'sequence':
        final steps = action['actions'] ?? action['steps'];

        if (steps is! List) {
          throw FormatException(
            '$source.actions[] '
            'is required.',
          );
        }

        for (var i = 0; i < steps.length; i++) {
          final step = steps[i];

          if (step is String) {
            final nested = this.action(step);

            if (nested == null) {
              throw FormatException('actions.$step is missing.');
            }

            await _executeAction(nested, source: 'actions.$step');
          } else if (step is Map) {
            await _executeAction(
              Map<String, dynamic>.from(step.cast<dynamic, dynamic>()),
              source: '$source.actions[$i]',
            );
          }
        }

        return;

      case 'persistAuthSession':
        await _persistAuthSession(action, source: source);
        return;

      case 'clearAuthSession':
        await clearSession();
        return;

      case 'http':
        await _http(source, action);
        return;

      default:
        throw FormatException(
          'Unsupported auth action type '
          'at $source: $type',
        );
    }
  }

  void _executeUiState(Map<String, dynamic> action, {required String source}) {
    final operation = action['operation']?.toString();

    final key = action['targetStateKey']?.toString();

    if (operation != 'set' || key == null || key.isEmpty) {
      throw FormatException(
        '$source requires operation=set '
        'and targetStateKey.',
      );
    }

    final requires = _map(action['requires']);

    if (requires != null) {
      final stateKey = requires['stateKey']?.toString();

      final validation = _map(requires['validation']);

      if (stateKey == null ||
          stateKey.isEmpty ||
          validation == null ||
          !_matchesValidation(read(stateKey), validation)) {
        _setAuthError(
          schema['errorHandling']?['messages']?['validation']?.toString() ??
              'Please correct the highlighted fields.',
        );
        return;
      }
    }

    _write(_state, key, _resolve(action['value']));

    notifyListeners();
  }

  Future<void> _navigate(
    Map<String, dynamic> action, {
    required String source,
  }) async {
    final session = _map(action['session']);
    if (action['setAuthenticated'] == true && session != null) {
      await _persistSchemaSession(session, source: '$source.session');
      _write(_state, 'auth.isAuthenticated', true);
      notifyListeners();
      return;
    }

    final target = action['targetPageId']?.toString();

    if (target != null && target.isNotEmpty && page(target) != null) {
      _pageId = target;
      _setIfPresent('ui.activePage', target);
      fieldErrors.clear();
      notifyListeners();
      return;
    }

    final fallback = action['fallbackUrl']?.toString();

    if (fallback != null && fallback.isNotEmpty) {
      final uri = resolveUri(fallback);

      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);

      if (opened) {
        return;
      }
    }

    throw FormatException(
      '$source cannot navigate to '
      '"$target".',
    );
  }

  Future<void> _http(String source, Map<String, dynamic> action) async {
    final requiresState =
        _map(action['requires']) ?? _map(action['requiresState']);

    if (requiresState != null) {
      final stateKey = requiresState['stateKey']?.toString();
      final condition = requiresState['condition']?.toString() ?? 'equals';
      final expected = requiresState.containsKey('equals')
          ? _resolve(requiresState['equals'])
          : requiresState.containsKey('value')
          ? _resolve(requiresState['value'])
          : true;
      final actual = stateKey == null || stateKey.isEmpty
          ? null
          : read(stateKey);
      final matches = switch (condition) {
        'equals' => actual == expected,
        'notEquals' => actual != expected,
        'truthy' => actual == true,
        'notEmpty' => actual != null && actual.toString().trim().isNotEmpty,
        _ => false,
      };

      if (!matches) {
        _setAuthError(
          requiresState['message']?.toString() ??
              'This action is not available yet.',
        );
        return;
      }
    }

    final validationGroup = action['validationGroup']?.toString();

    if (validationGroup != null &&
        validationGroup.isNotEmpty &&
        !validate(validationGroup)) {
      _setAuthError(
        schema['errorHandling']?['messages']?['validation']?.toString() ??
            'Please correct the highlighted fields.',
      );
      return;
    }

    final method = action['method']?.toString().toUpperCase();

    final rawUrl = action['url']?.toString();

    final contentType = action['contentType']?.toString();

    if (method == null || rawUrl == null || contentType == null) {
      throw FormatException(
        '$source requires method, '
        'url and contentType.',
      );
    }

    final uri = resolveUri(rawUrl);

    final payload = <String, dynamic>{};

    final rawPayload = action['payload'];

    if (rawPayload is Map) {
      for (final entry in rawPayload.entries) {
        payload[entry.key.toString()] = _resolve(entry.value);
      }
    }

    final cookieStr = cookieHeader;

    final headers = <String, String>{
      'Accept': action['responseType']?.toString() == 'json'
          ? 'application/json'
          : '*/*',
      'Content-Type': contentType,
      if (cookieStr.isNotEmpty) 'Cookie': cookieStr,
    };

    final loadingKey =
        action['loadingStateKey']?.toString() ?? 'auth.isLoading';

    _write(_state, loadingKey, true);

    notifyListeners();

    try {
      final timeoutMs =
          (action['timeoutMs'] as num?)?.toInt() ??
          (schema['runtime']?['network']?['timeoutMs'] as num?)?.toInt() ??
          30000;

      late http.Response response;

      debugPrint('[AUTH][HTTP][REQ] $source $method $uri cookie=$cookieStr payload=$payload');

      if (method == 'POST') {
        if (contentType == 'application/json') {
          response = await _client
              .post(uri, headers: headers, body: jsonEncode(payload))
              .timeout(Duration(milliseconds: timeoutMs));
        } else if (contentType == 'application/x-www-form-urlencoded') {
          response = await _client
              .post(
                uri,
                headers: headers,
                body: payload.map(
                  (key, value) => MapEntry(key, value?.toString() ?? ''),
                ),
              )
              .timeout(Duration(milliseconds: timeoutMs));
        } else {
          throw FormatException(
            '$source unsupported '
            'contentType=$contentType',
          );
        }
      } else if (method == 'GET') {
        response = await _client
            .get(uri, headers: headers)
            .timeout(Duration(milliseconds: timeoutMs));
      } else {
        throw FormatException(
          '$source method "$method" '
          'is unsupported.',
        );
      }

      _saveCookies(response);

      debugPrint(
        '[AUTH][HTTP][RESP] $source status=${response.statusCode} set-cookie=${response.headers['set-cookie']} body=${response.body}',
      );

      _lastResponseBody = _decodeResponse(response, action);
      _lastResponseStatusCode = response.statusCode;

      final success = _responseSucceeded(response, action, _lastResponseBody);

      if (success) {
        if (source.toLowerCase().contains('submitsignup')) {
          final email = read('signupForm.email')?.toString() ?? '';
          final phone = read('signupForm.phone')?.toString() ?? '';
          final token = _lastResponseBody is Map
              ? (_lastResponseBody['accesstoken'] ??
                      _lastResponseBody['accessToken'] ??
                      _lastResponseBody['token'])
                  ?.toString()
              : null;
          if (email.isNotEmpty || phone.isNotEmpty) {
            unawaited(
              UserLocationService.instance.sendSignupLocation(
                email: email,
                mobileNumber: phone,
                accessToken: token,
              ),
            );
          }
        }

        if (source.toLowerCase().contains('submitlogin')) {
          final token = _lastResponseBody is Map
              ? (_lastResponseBody['accesstoken'] ??
                      _lastResponseBody['accessToken'] ??
                      _lastResponseBody['token'])
                  ?.toString()
              : null;
          final userId = _lastResponseBody is Map
              ? (_lastResponseBody['user_id'] ??
                      _lastResponseBody['userId'] ??
                      _lastResponseBody['id'])
                  ?.toString()
              : null;
          final identity = read('loginForm.identity')?.toString().trim() ?? '';
          final email = identity.contains('@') ? identity : null;
          final username = !identity.contains('@') && identity.isNotEmpty
              ? identity
              : null;
          unawaited(
            UserLocationService.instance.sendCurrentLocation(
              force: true,
              accessToken: token,
              userId: userId,
              email: email,
              username: username,
            ),
          );
        }

        final successAction = _map(action['success']);

        if (successAction != null) {
          await _executeAction(successAction, source: '$source.success');
        }
      } else {
        final failureAction = _map(action['failure']);

        if (failureAction != null) {
          final errorCodePath =
              failureAction['errorCodePath']?.toString() ??
              _map(action['responseContract'])?['errorCodePath']?.toString() ??
              'error_code';
          final errorCodeStateKey = failureAction['errorCodeStateKey']
              ?.toString();
          if (errorCodeStateKey != null && errorCodeStateKey.isNotEmpty) {
            _write(
              _state,
              errorCodeStateKey,
              _readDynamic(_lastResponseBody, errorCodePath),
            );
          }
          await _executeAction(failureAction, source: '$source.failure');
        } else {
          _setAuthError(
            _friendlyServerAuthError(
              _responseMessage(_lastResponseBody),
              source: source,
            ),
          );
        }
      }
    } finally {
      _write(_state, loadingKey, false);
      notifyListeners();
    }
  }

  dynamic _decodeResponse(http.Response response, Map<String, dynamic> action) {
    final body = response.body.trim();

    if (body.isEmpty) {
      return null;
    }

    final type = action['responseType']?.toString() ?? '';

    if (type == 'json') {
      try {
        return decodeJsonBody(
          body: body,
          contentType: response.headers['content-type'],
          source: 'auth',
        );
      } catch (_) {
        return <String, dynamic>{
          'description': 'Invalid JSON response.',
          '_raw': looksLikeHtml(body) ? '<html>' : body,
        };
      }
    }

    if (type == 'html-or-json') {
      if (looksLikeHtml(body)) return body;
      try {
        return jsonDecode(body);
      } catch (_) {
        return body;
      }
    }

    if (looksLikeHtml(body)) {
      return body;
    }
    try {
      return jsonDecode(body);
    } catch (_) {
      return body;
    }
  }

  bool _responseSucceeded(
    http.Response response,
    Map<String, dynamic> action,
    dynamic body,
  ) {
    final contract = _map(action['responseContract']);

    if (contract != null) {
      final successWhen = _map(contract['successWhen']);
      if (successWhen != null) {
        final path = successWhen['path']?.toString();
        if (path != null &&
            path.isNotEmpty &&
            successWhen.containsKey('equals')) {
          final actual = _readDynamic(body, path);
          final expected = _resolve(successWhen['equals']);
          return actual?.toString().toLowerCase() ==
              expected?.toString().toLowerCase();
        }
      }

      final statusPath = contract['statusPath']?.toString();
      final successValues = contract['successValues'];
      if (statusPath != null && successValues is List) {
        final actual = _readDynamic(body, statusPath)?.toString().toLowerCase();
        return successValues.any(
          (value) => value?.toString().toLowerCase() == actual,
        );
      }
    }

    return response.statusCode >= 200 && response.statusCode < 400;
  }

  Future<void> _persistSchemaSession(
    Map<String, dynamic> session, {
    required String source,
  }) async {
    final rawFields = session['fields'];
    if (rawFields is! Map || rawFields.isEmpty) {
      throw FormatException('$source.fields is required.');
    }

    final resolved = <String, String?>{};
    for (final entry in rawFields.entries) {
      if (entry.value is! Map) continue;
      final spec = Map<String, dynamic>.from(
        (entry.value as Map).cast<dynamic, dynamic>(),
      );
      final path = spec['path']?.toString().trim() ?? '';
      final stateKey = spec['stateKey']?.toString().trim() ?? '';
      if (path.isEmpty || stateKey.isEmpty) continue;
      final value = _nonEmpty(_readDynamic(_lastResponseBody, path));
      resolved[entry.key.toString()] = value;
      _write(_state, stateKey, value);
    }

    final accessToken = resolved['accesstoken'] ?? resolved['accessToken'];
    final userId = resolved['user_id'] ?? resolved['userId'];
    if (accessToken == null) {
      throw FormatException('$source access token is missing.');
    }
    if (userId == null) {
      throw FormatException('$source authenticated user id is missing.');
    }

    _write(_state, 'auth.accessToken', accessToken);
    _write(_state, 'auth.idToken', resolved['idtoken'] ?? resolved['idToken']);
    _write(
      _state,
      'auth.refreshToken',
      resolved['refreshtoken'] ?? resolved['refreshToken'],
    );
    _write(_state, 'auth.username', resolved['username']);
    _write(_state, 'auth.email', resolved['email']);
    _write(
      _state,
      'auth.userType',
      resolved['user_type'] ?? resolved['userType'],
    );
    _write(_state, 'auth.userId', userId);

    // App session policy: once authentication succeeds, persist the validated
    // server-issued session until an explicit logout/session invalidation.
    // The schema's Remember Me field may still control its own UI state, but it
    // must not make a successful authenticated session process-local only.
    // No credential/token values are invented here; all stored values come from
    // the validated authentication response above.
    await _secureStorage.saveSession(
      accessToken: accessToken,
      idToken: resolved['idtoken'] ?? resolved['idToken'],
      refreshToken: resolved['refreshtoken'] ?? resolved['refreshToken'],
      username: resolved['username'],
      email: resolved['email'],
      userType: resolved['user_type'] ?? resolved['userType'],
      userId: userId,
    );
  }

  Future<void> _persistAuthSession(
    Map<String, dynamic> action, {
    required String source,
  }) async {
    String path(String key, String fallback) =>
        action[key]?.toString() ?? fallback;

    final accessToken = _nonEmpty(
      _readDynamic(_lastResponseBody, path('accessTokenPath', 'accesstoken')),
    );

    if (accessToken == null) {
      throw FormatException('$source access token is missing.');
    }

    final idToken = _nonEmpty(
      _readDynamic(_lastResponseBody, path('idTokenPath', 'idtoken')),
    );

    final refreshToken = _nonEmpty(
      _readDynamic(_lastResponseBody, path('refreshTokenPath', 'refreshtoken')),
    );

    final username = _nonEmpty(
      _readDynamic(_lastResponseBody, path('usernamePath', 'username')),
    );

    final email = _nonEmpty(
      _readDynamic(_lastResponseBody, path('emailPath', 'email')),
    );

    final userType = _nonEmpty(
      _readDynamic(_lastResponseBody, path('userTypePath', 'user_type')),
    );

    final userId = _nonEmpty(
      _readDynamic(_lastResponseBody, path('userIdPath', 'user_id')),
    );

    if (userId == null) {
      throw FormatException(
        '$source authenticated user id is missing from the login response.',
      );
    }

    // App session policy: successful authentication is persisted regardless of
    // whether the optional Remember Me checkbox was selected. The user remains
    // signed in across normal app restarts until logout or a genuine server-side
    // authentication invalidation clears the session.
    await _secureStorage.saveSession(
      accessToken: accessToken,
      idToken: idToken,
      refreshToken: refreshToken,
      username: username,
      email: email,
      userType: userType,
      userId: userId,
    );

    _write(_state, 'auth.accessToken', accessToken);

    _write(_state, 'auth.idToken', idToken);

    _write(_state, 'auth.refreshToken', refreshToken);

    _write(_state, 'auth.username', username);

    _write(_state, 'auth.email', email);

    _write(_state, 'auth.userType', userType);

    _write(_state, 'auth.userId', userId);

    debugPrint('[AUTH][SESSION] authenticated userId=$userId');

    _write(_state, 'auth.isAuthenticated', true);

    notifyListeners();
  }

  bool validate(String group) {
    fieldErrors.clear();

    final rawRules = schema['validationRules']?[group];

    if (rawRules is! Map) {
      debugPrint('[AUTH][VALIDATION][MISSING_GROUP] $group');
      _setAuthError(
        schema['errorHandling']?['messages']?['validation']?.toString() ??
            'Please correct the highlighted fields.',
      );
      return false;
    }

    final form = schema['forms']?[group];

    final stateKeys = <String, String>{};

    if (form is Map && form['fields'] is List) {
      for (final raw in form['fields'] as List) {
        if (raw is! Map) {
          continue;
        }

        final name = raw['name']?.toString();

        final stateKey = raw['stateKey']?.toString();

        if (name != null && stateKey != null) {
          stateKeys[name] = stateKey;
        }
      }
    }

    for (final entry in rawRules.entries) {
      final field = entry.key.toString();

      final rules = _map(entry.value);

      if (rules == null) {
        continue;
      }

      final explicitStateKey = rules['stateKey']?.toString().trim();
      final stateKey = explicitStateKey != null && explicitStateKey.isNotEmpty
          ? explicitStateKey
          : stateKeys[field] ?? '$group.$field';

      final value = read(stateKey);

      final visibleStateKey = rules['visibilityStateKey']?.toString();

      if (visibleStateKey != null && read(visibleStateKey) != true) {
        continue;
      }

      final error = _validateValue(value, rules, stateKey: stateKey);

      if (error != null) {
        fieldErrors[stateKey] = error;
      }
    }

    notifyListeners();

    return fieldErrors.isEmpty;
  }

  bool validationGroupSatisfied(String group) {
    final rawRules = schema['validationRules']?[group];
    if (rawRules is! Map) {
      return false;
    }

    final form = schema['forms']?[group];
    final stateKeys = <String, String>{};

    if (form is Map && form['fields'] is List) {
      for (final raw in form['fields'] as List) {
        if (raw is! Map) continue;
        final name = raw['name']?.toString();
        final stateKey = raw['stateKey']?.toString();
        if (name != null && stateKey != null) {
          stateKeys[name] = stateKey;
        }
      }
    }

    for (final entry in rawRules.entries) {
      final field = entry.key.toString();
      final rules = _map(entry.value);
      if (rules == null) continue;

      final explicitStateKey = rules['stateKey']?.toString().trim();
      final stateKey = explicitStateKey != null && explicitStateKey.isNotEmpty
          ? explicitStateKey
          : stateKeys[field] ?? '$group.$field';

      final visibleStateKey = rules['visibilityStateKey']?.toString();
      if (visibleStateKey != null && read(visibleStateKey) != true) {
        continue;
      }

      if (_validateValue(read(stateKey), rules, stateKey: stateKey) != null) {
        return false;
      }
    }

    return true;
  }

  String? _validateValue(
    dynamic value,
    Map<String, dynamic> rules, {
    required String stateKey,
  }) {
    final text = value?.toString() ?? '';
    final label = _fieldLabel(stateKey);

    if (rules['required'] == true && text.trim().isEmpty && value != true) {
      final configured = rules['requiredMessage']?.toString().trim();
      if (configured != null && configured.isNotEmpty) return configured;
      return switch (stateKey) {
        'loginForm.identity' => 'Enter $label.',
        'loginForm.password' => 'Enter your password.',
        'signupForm.email' => 'Enter your email address.',
        'signupForm.phone' ||
        'forgotPasswordForm.phone' => 'Enter your mobile number.',
        'signupForm.otp' ||
        'forgotPasswordForm.otp' => 'Enter the 6-digit OTP.',
        'signupForm.password' ||
        'forgotPasswordForm.password' => 'Enter a password.',
        'signupForm.confirm_password' ||
        'forgotPasswordForm.confirm_password' => 'Confirm your password.',
        'signupForm.terms' => 'Please accept the Terms & Conditions.',
        _ => 'Enter $label.',
      };
    }

    if (rules['acceptedValue'] != null && value != rules['acceptedValue']) {
      return stateKey == 'signupForm.terms'
          ? 'Please accept the Terms & Conditions.'
          : '$label must be accepted.';
    }

    final minLength = (rules['minLength'] as num?)?.toInt();

    if (minLength != null && text.length < minLength) {
      if (stateKey.endsWith('.password')) {
        return 'Password must be at least $minLength characters.';
      }
      return '$label must be at least $minLength characters.';
    }

    final maxLength = (rules['maxLength'] as num?)?.toInt();

    if (maxLength != null && text.length > maxLength) {
      return '$label is too long.';
    }

    final exactLength = (rules['length'] as num?)?.toInt();

    if (exactLength != null && text.isNotEmpty && text.length != exactLength) {
      if (stateKey.endsWith('.phone') || stateKey == 'loginForm.identity') {
        return 'Enter a valid $exactLength-digit mobile number.';
      }
      if (stateKey.endsWith('.otp')) {
        return 'Enter the complete $exactLength-digit OTP.';
      }
      return '$label must be exactly $exactLength characters.';
    }

    if (rules['format'] == 'numeric' &&
        text.isNotEmpty &&
        !RegExp(r'^[0-9]+$').hasMatch(text)) {
      if (stateKey.endsWith('.phone') || stateKey == 'loginForm.identity') {
        return 'Mobile number must contain numbers only.';
      }
      if (stateKey.endsWith('.otp')) {
        return 'OTP must contain numbers only.';
      }
      return '$label must contain numbers only.';
    }

    if (rules['format'] == 'email' &&
        text.isNotEmpty &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)) {
      return 'Enter a valid email address.';
    }

    final matches = rules['matchesStateKey']?.toString();

    if (matches != null && text != (read(matches)?.toString() ?? '')) {
      return 'Passwords do not match.';
    }

    final mustContain = rules['mustContain'];

    if (mustContain is List && text.isNotEmpty) {
      for (final rule in mustContain) {
        final ok = switch (rule.toString()) {
          'uppercase' => RegExp(r'[A-Z]').hasMatch(text),
          'lowercase' => RegExp(r'[a-z]').hasMatch(text),
          'number' => RegExp(r'[0-9]').hasMatch(text),
          'special' => RegExp(r'[^A-Za-z0-9]').hasMatch(text),
          _ => true,
        };

        if (!ok) {
          return 'Use uppercase, lowercase, number and special character.';
        }
      }
    }

    return null;
  }

  String _fieldLabel(String stateKey) {
    final key = stateKey.split('.').last;
    return switch (key) {
      'identity' => 'email or mobile number',
      'email' => 'email address',
      'phone' => 'mobile number',
      'otp' => 'OTP',
      'password' => 'password',
      'confirm_password' => 'password confirmation',
      'terms' => 'Terms & Conditions',
      _ => key.replaceAll('_', ' '),
    };
  }

  bool _matchesValidation(dynamic value, Map<String, dynamic> validation) {
    final text = value?.toString() ?? '';

    final length = (validation['length'] as num?)?.toInt();

    if (length != null && text.length != length) {
      return false;
    }

    if (validation['format'] == 'numeric' &&
        !RegExp(r'^[0-9]+$').hasMatch(text)) {
      return false;
    }

    return true;
  }

  Uri resolveUri(String raw) {
    final parsed = Uri.tryParse(raw);

    if (parsed == null) {
      throw FormatException('Invalid URL: $raw');
    }

    if (parsed.host != 'localhost' && parsed.host != '127.0.0.1') {
      return parsed;
    }

    final sourceCandidates = <String?>[
      schema['_clientAuthSchemaSource']?.toString(),
      schema['meta']?['sourceOfTruth']?.toString(),
    ];

    for (final source in sourceCandidates) {
      if (source == null) {
        continue;
      }

      final base = Uri.tryParse(source);

      if (base != null &&
          base.hasScheme &&
          base.host.isNotEmpty &&
          base.host != 'localhost' &&
          base.host != '127.0.0.1') {
        return parsed.replace(
          scheme: base.scheme,
          host: base.host,
          port: base.hasPort ? base.port : null,
        );
      }
    }

    return parsed;
  }

  String _friendlyActionError(Object error) {
    if (error is TimeoutException || error is http.ClientException) {
      return schema['errorHandling']?['messages']?['network']?.toString() ??
          'Unable to connect. Please check your internet and try again.';
    }

    return schema['errorHandling']?['messages']?['server']?.toString() ??
        'Something went wrong. Please try again.';
  }

  String _friendlyServerAuthError(String raw, {required String source}) {
    final message = raw.trim();
    final lower = message.toLowerCase();
    final actionSource = source.toLowerCase();
    final status = _lastResponseStatusCode;

    String statusMessage(int code, String fallback) {
      final configured =
          schema['errorHandling']?['statusMessages']?[code.toString()]
              ?.toString()
              .trim();
      return configured == null || configured.isEmpty ? fallback : configured;
    }

    if (status == 429 ||
        lower.contains('too many') ||
        lower.contains('rate limit')) {
      return statusMessage(429, 'Too many attempts. Please try again shortly.');
    }

    if (lower.contains('already exist') ||
        lower.contains('already registered') ||
        lower.contains('duplicate') ||
        status == 409) {
      return statusMessage(409, 'This account is already registered.');
    }

    final isLogin = actionSource.contains('submitlogin');
    final isSignup = actionSource.contains('signup');
    final isOtp =
        actionSource.contains('otp') ||
        lower.contains('otp') ||
        lower.contains('verification code');

    if (isOtp &&
        (lower.contains('invalid') ||
            lower.contains('incorrect') ||
            lower.contains('wrong') ||
            lower.contains('expired'))) {
      if (lower.contains('expired')) {
        return 'OTP has expired. Please request a new OTP.';
      }
      return 'Incorrect OTP. Please check the 6-digit code and try again.';
    }

    if (isLogin) {
      if (lower.contains('password') &&
          (lower.contains('wrong') ||
              lower.contains('incorrect') ||
              lower.contains('invalid'))) {
        return 'Wrong password. Please try again.';
      }
      if (lower.contains('not found') ||
          lower.contains('not registered') ||
          lower.contains('does not exist') ||
          lower.contains('invalid mobile') ||
          lower.contains('invalid phone')) {
        return 'Incorrect mobile number or account not found.';
      }
      if (status == 401 ||
          status == 403 ||
          lower.contains('invalid credential') ||
          lower.contains('login failed') ||
          lower.contains('unauthor')) {
        return statusMessage(401, 'Incorrect mobile number or password.');
      }
    }

    if (isSignup && (lower.contains('email') && lower.contains('invalid'))) {
      return 'Enter a valid email address.';
    }

    if (status == 400 || status == 422) {
      return statusMessage(status!, 'Please check the entered details.');
    }

    if (status != null && status >= 500) {
      return schema['errorHandling']?['messages']?['server']?.toString() ??
          'Something went wrong. Please try again.';
    }

    if (message.isNotEmpty &&
        message.length <= 180 &&
        !lower.contains('<html') &&
        !lower.contains('exception') &&
        !lower.contains('stack trace')) {
      return message;
    }

    return schema['errorHandling']?['messages']?['server']?.toString() ??
        'Something went wrong. Please try again.';
  }

  void _setAuthError(String message) {
    _setIfPresent('auth.error', message);

    notifyListeners();
  }

  String _responseMessage(dynamic body) {
    if (body is Map) {
      for (final key in const <String>['description', 'message', 'error']) {
        final value = body[key];

        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString();
        }
      }
    }

    final statusMessage =
        schema['errorHandling']?['statusMessages']?[_lastResponseStatusCode
                ?.toString()]
            ?.toString()
            .trim();

    if (statusMessage != null && statusMessage.isNotEmpty) {
      return statusMessage;
    }

    return schema['errorHandling']?['messages']?['server']?.toString() ??
        'Something went wrong.';
  }

  dynamic _resolve(dynamic value) {
    if (value is String && value.startsWith(r'$state.')) {
      return read(value.substring(r'$state.'.length));
    }

    return value;
  }

  dynamic _readDynamic(dynamic source, String path) {
    dynamic current = source;

    if (path.trim().isEmpty) {
      return current;
    }

    for (final part in path.split('.')) {
      if (current is Map) {
        current = current[part];
      } else {
        return null;
      }
    }

    return current;
  }

  dynamic _read(Map<String, dynamic> source, String path) {
    dynamic current = source;

    for (final part in path.split('.')) {
      if (current is! Map) {
        return null;
      }

      current = current[part];
    }

    return current;
  }

  void _write(Map<String, dynamic> source, String path, dynamic value) {
    final parts = path.split('.');

    Map<String, dynamic> current = source;

    for (var i = 0; i < parts.length - 1; i++) {
      final key = parts[i];
      final next = current[key];

      if (next is Map<String, dynamic>) {
        current = next;
      } else if (next is Map) {
        final converted = Map<String, dynamic>.from(
          next.cast<dynamic, dynamic>(),
        );
        current[key] = converted;
        current = converted;
      } else {
        final created = <String, dynamic>{};
        current[key] = created;
        current = created;
      }
    }

    current[parts.last] = value;
  }

  void _setIfPresent(String path, dynamic value) {
    _write(_state, path, value);
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }

    return null;
  }

  String? _nonEmpty(dynamic value) {
    final text = value?.toString().trim();

    if (text == null || text.isEmpty) {
      return null;
    }

    return text;
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
