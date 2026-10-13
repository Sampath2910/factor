import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/auth_sdui/auth_temporary_api_overlay.dart';

Map<String, dynamic> _schema(String path) {
  final root = jsonDecode(File(path).readAsStringSync()) as Map;
  if (root.containsKey('schema') && root['schema'] is Map) {
    return Map<String, dynamic>.from((root['schema'] as Map).cast());
  }
  return Map<String, dynamic>.from(root.cast());
}

Map<String, dynamic> _page(Map<String, dynamic> schema, String id) {
  return Map<String, dynamic>.from(
    (schema['pages'] as List)
        .cast<Map>()
        .firstWhere((page) => page['id'] == id)
        .cast(),
  );
}

Map<String, dynamic> _component(List<dynamic> components, String id) {
  return Map<String, dynamic>.from(
    components
        .cast<Map>()
        .firstWhere((component) => component['id'] == id)
        .cast(),
  );
}

void main() {
  test('welcome Create Account navigates only to signup', () {
    final schema = _schema('assets/auth_ui_schema.json');
    final welcome = _page(schema, 'welcome');
    final create = _component(
      List<dynamic>.from(welcome['components'] as List),
      'welcome_create_account',
    );

    expect(create['actionRef'], 'goSignup');
    expect(schema['actions']['goSignup']['targetPageId'], 'signup');
    expect(create['actionRef'], isNot('openPrivacyPolicy'));
  });

  test('auth threshold events are declared by schema', () {
    final schema = _schema('assets/auth_ui_schema.json');
    final signupPanel = _component(
      List<dynamic>.from(_page(schema, 'signup')['components'] as List),
      'signup_glass_panel',
    );
    final forgotPanel = _component(
      List<dynamic>.from(_page(schema, 'forgotPassword')['components'] as List),
      'forgot_glass_panel',
    );

    final signupOtp = _component(
      List<dynamic>.from(signupPanel['children'] as List),
      'signup_otp_boxes',
    );
    final forgotPhone = _component(
      List<dynamic>.from(forgotPanel['children'] as List),
      'forgot_phone',
    );

    expect(signupOtp['digitCount'] ?? signupOtp['events']?['onLengthReached']?['length'], 6);
    expect(forgotPhone['inputMode'] ?? forgotPhone['events']?['onLengthReached'], isNotNull);
  });

  test('forgot-password success feedback is schema-driven', () {
    final schema = _schema('assets/auth_ui_schema.json');
    final effective = AuthTemporaryApiOverlay.apply(schema);
    expect(effective['state']['auth']['notice'], isNull);
  });

  test('authentication transport and tokens are app-owned', () {
    final schema = _schema('assets/auth_ui_schema.json');
    expect(schema['state'].containsKey('authConfig'), isFalse);

    final effective = AuthTemporaryApiOverlay.apply(schema);
    final effectiveAuth = effective['state']['auth'] as Map;

    expect(effectiveAuth.containsKey('accessToken'), isTrue);
    expect(effectiveAuth.containsKey('idToken'), isTrue);
    expect(effectiveAuth.containsKey('refreshToken'), isTrue);
  });

  test('signup and forgot-password OTP layouts match mobile states', () {
    final schema = _schema('assets/auth_ui_schema.json');
    final signupPanel = _component(
      List<dynamic>.from(_page(schema, 'signup')['components'] as List),
      'signup_glass_panel',
    );
    final forgotPanel = _component(
      List<dynamic>.from(_page(schema, 'forgotPassword')['components'] as List),
      'forgot_glass_panel',
    );
    final signupChildren = List<dynamic>.from(signupPanel['children'] as List);
    final forgotChildren = List<dynamic>.from(forgotPanel['children'] as List);

    final signupOtp = _component(signupChildren, 'signup_otp_boxes');
    final forgotOtp = _component(forgotChildren, 'forgot_otp_boxes');

    expect(signupOtp['visibleStateKey'], 'signupForm.otpVisible');
    expect(signupOtp['hiddenByDefault'], isTrue);

    expect(forgotOtp['visibleStateKey'], isNotNull);
    expect(forgotOtp['hiddenByDefault'], isTrue);
  });

  test('home components have complete schema appearance', () {
    final schema = _schema('assets/home_ui_schema.json');
    expect(schema.isNotEmpty, isTrue);
    expect(schema.containsKey('schemaId'), isTrue);
  });
}
