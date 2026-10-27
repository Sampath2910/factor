import 'dart:convert';

/// Compatibility adapter for Auth SDUI state only.
///
/// The production Auth v7 schema owns UI, validation, assets, actions, and
/// endpoints. This adapter only exposes camelCase session aliases still
/// consumed by existing Flutter/Home code.
class AuthTemporaryApiOverlay {
  const AuthTemporaryApiOverlay._();

  static const bool enabled = bool.fromEnvironment(
    'AUTH_MOBILE_API_ADAPTER',
    defaultValue: true,
  );

  static const bool useLegacyEndpoints = bool.fromEnvironment(
    'AUTH_USE_LEGACY_ENDPOINTS',
    defaultValue: true,
  );

  static Map<String, dynamic> apply(Map<String, dynamic> source) {
    final schema = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    if (enabled) {
      _ensureCompatibilitySessionState(schema);
    }
    if (useLegacyEndpoints) {
      _remapLegacyAuthEndpoints(schema);
    }
    final app = schema['app'];
    if (app is Map) {
      final current = app['initialPageId']?.toString();
      if (current == null || current.isEmpty || current == 'welcome') {
        app['initialPageId'] = 'login';
      }
    }
    return schema;
  }

  static void _remapLegacyAuthEndpoints(Map<String, dynamic> schema) {
    final actions = schema['actions'];
    if (actions is! Map) return;

    // 1. sendSignupOtp: remap /sd-signup/otp -> /v8/api.php?action=user
    final sendSignupOtp = actions['sendSignupOtp'];
    if (sendSignupOtp is Map) {
      final url = sendSignupOtp['url']?.toString() ?? '';
      if (url.contains('/sd-signup/otp')) {
        sendSignupOtp['url'] = 'https://efactor.tech/v8/api.php?action=user';
      }
    }

    // 2. verifySignupOtp: remap /sd-signup/verify -> /v8/api.php?action=userverify
    final verifySignupOtp = actions['verifySignupOtp'];
    if (verifySignupOtp is Map) {
      final url = verifySignupOtp['url']?.toString() ?? '';
      if (url.contains('/sd-signup/verify')) {
        verifySignupOtp['url'] =
            'https://efactor.tech/v8/api.php?action=userverify';
      }
    }

    // 3. submitSignup: remap /sd-signup/complete -> /v8/api.php?action=userlogin
    final submitSignup = actions['submitSignup'];
    if (submitSignup is Map) {
      final url = submitSignup['url']?.toString() ?? '';
      if (url.contains('/sd-signup/complete')) {
        submitSignup['url'] =
            'https://efactor.tech/v8/api.php?action=userlogin';
        final payload = submitSignup['payload'];
        if (payload is Map) {
          payload['username'] = r'$state.signupForm.phone';
          payload['password'] = r'$state.signupForm.password';
          payload['user_type'] = r'$state.signupForm.user_type';
        }
      }
    }
  }

  static void _ensureCompatibilitySessionState(Map<String, dynamic> schema) {
    final state = _ensureMap(schema, 'state');
    final auth = _ensureMap(state, 'auth');

    auth.putIfAbsent('accessToken', () => auth['accesstoken']);
    auth.putIfAbsent('idToken', () => auth['idtoken']);
    auth.putIfAbsent('refreshToken', () => auth['refreshtoken']);
    auth.putIfAbsent('username', () => null);
    auth.putIfAbsent('email', () => null);
    auth.putIfAbsent('userType', () => auth['user_type']);
    auth.putIfAbsent('userId', () => auth['user_id']);
    auth.putIfAbsent('notice', () => null);

    final defaults = _writableMap(schema['app']?['defaults']) ??
        _writableMap(schema['config']) ??
        const <String, dynamic>{};
    final defaultCountry =
        (defaults['countryCode'] ?? defaults['country_code'] ?? '+91')
            .toString();
    final defaultUserType =
        (defaults['userType'] ?? defaults['user_type'] ?? 'User').toString();

    final signupForm = _ensureMap(state, 'signupForm');
    signupForm.putIfAbsent('country_code', () => defaultCountry);
    signupForm.putIfAbsent('user_type', () => defaultUserType);
  }

  static Map<String, dynamic> _ensureMap(
    Map<String, dynamic> parent,
    String key,
  ) {
    final existing = parent[key];
    final converted = _writableMap(existing) ?? <String, dynamic>{};
    parent[key] = converted;
    return converted;
  }

  static Map<String, dynamic>? _writableMap(dynamic value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
  }
}
