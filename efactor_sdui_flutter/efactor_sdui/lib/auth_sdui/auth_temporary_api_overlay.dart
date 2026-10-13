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

  static Map<String, dynamic> apply(Map<String, dynamic> source) {
    final schema = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    if (enabled) {
      _ensureCompatibilitySessionState(schema);
    }
    return schema;
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

    final signupForm = _ensureMap(state, 'signupForm');
    signupForm.putIfAbsent('country_code', () => '+91');
    signupForm.putIfAbsent('user_type', () => 'User');
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
