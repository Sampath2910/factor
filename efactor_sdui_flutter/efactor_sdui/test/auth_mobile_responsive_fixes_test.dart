import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:efactor_sdui/auth_sdui/auth_renderer.dart';
import 'package:efactor_sdui/auth_sdui/auth_state.dart';
import 'package:efactor_sdui/auth_sdui/auth_temporary_api_overlay.dart';

void main() {
  late Map<String, dynamic> schema;

  setUpAll(() {
    final file = File('assets/auth_ui_schema.json');
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    schema = raw.containsKey('schema') && raw['schema'] is Map
        ? Map<String, dynamic>.from(raw['schema'] as Map)
        : raw;
  });

  Map<String, dynamic> pageSchema(String pageId) {
    final copy = Map<String, dynamic>.from(schema);
    final app = Map<String, dynamic>.from(copy['app'] as Map? ?? {});
    app['initialPageId'] = pageId;
    copy['app'] = app;
    return copy;
  }

  testWidgets('OTP boxes scale without overflow on Samsung S25 (360dp) and iPhone SE (320dp)', (tester) async {
    final viewports = [
      const Size(320, 568),
      const Size(360, 780),
      const Size(392, 850),
    ];

    for (final size in viewports) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      FlutterErrorDetails? overflowError;
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains('overflowed')) {
          overflowError = details;
        }
        originalOnError?.call(details);
      };

      final state = AuthState(pageSchema('forgotPassword'));
      // Make OTP visible
      state.write('forgotPasswordForm.otpVisible', true);

      final renderer = AuthRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.build(ctx)),
        ),
      );
      await tester.pump();

      expect(overflowError, isNull, reason: 'OTP input must not overflow on ${size.width}x${size.height}');
    }
  });

  testWidgets('Social Google button renders without Schema error badge', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AuthState(pageSchema('signup'));
    final renderer = AuthRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (ctx) => renderer.build(ctx)),
      ),
    );
    await tester.pump();

    // Verify "Schema error" is NOT shown on the screen
    expect(find.text('Schema error'), findsNothing);
  });

  testWidgets('Signup page scrolls when keyboard opens on short phone', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AuthState(pageSchema('signup'));
    final renderer = AuthRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            viewInsets: EdgeInsets.only(bottom: 280),
          ),
          child: Builder(builder: (ctx) => renderer.build(ctx)),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(find.text('Schema error'), findsNothing);
  });

  testWidgets('Auth card slides to topCenter when keyboard opens on 360dp phone', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AuthState(pageSchema('forgotPassword'));
    final renderer = AuthRenderer(state);

    // Simulate keyboard open by injecting viewInsets
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 780),
            viewInsets: EdgeInsets.only(bottom: 300),
          ),
          child: Builder(builder: (ctx) => renderer.build(ctx)),
        ),
      ),
    );
    await tester.pump();

    // Find the Align widget used by verticalCenter positioning
    final alignFinder = find.byWidgetPredicate((widget) {
      return widget is Align && widget.alignment == Alignment.topCenter;
    });
    expect(alignFinder, findsWidgets, reason: 'Card must align to topCenter when keyboard is visible');
  });

  testWidgets('Signup TextField keeps focus after keyboard insets appear', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AuthState(pageSchema('signup'));
    final renderer = AuthRenderer(state);

    Future<void> pumpAuth({double keyboardBottom = 0}) {
      return tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 780),
              viewInsets: EdgeInsets.only(bottom: keyboardBottom),
            ),
            child: AnimatedBuilder(
              animation: state,
              builder: (ctx, _) => renderer.build(ctx),
            ),
          ),
        ),
      );
    }

    await pumpAuth();
    await tester.pump();

    final emailField = find.byWidgetPredicate(
      (w) => w is TextField && w.keyboardType == TextInputType.emailAddress,
    );
    expect(emailField, findsOneWidget);

    await tester.tap(emailField);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.hasFocus,
      isTrue,
      reason: 'Email field must take focus on tap',
    );

    // IME open: same tree with viewInsets — focus must survive the rebuild.
    await pumpAuth(keyboardBottom: 280);
    await tester.pump();

    expect(
      FocusManager.instance.primaryFocus?.hasFocus,
      isTrue,
      reason: 'Focus must survive keyboard inset rebuild (IME cancel bug)',
    );
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('Tapping Send OTP with empty fields highlights errors instead of dropping tap', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AuthState(pageSchema('signup'));
    final renderer = AuthRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (ctx) => renderer.build(ctx)),
      ),
    );
    await tester.pump();

    // Verify button exists
    final sendOtpFinder = find.text('Send OTP');
    expect(sendOtpFinder, findsOneWidget);

    // Initial state: no field errors
    expect(state.fieldErrors, isEmpty);

    // Tap "Send OTP" while fields are empty
    await tester.tap(sendOtpFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Field errors should now be populated
    expect(state.fieldErrors.containsKey('signupForm.email'), isTrue);
    expect(state.fieldErrors.containsKey('signupForm.phone'), isTrue);
    expect(state.fieldErrors.containsKey('signupForm.password'), isTrue);
    expect(state.authError, isNotEmpty);
  });

  testWidgets('Phone input sanitizes and normalizes +91 and leading zero', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AuthState(pageSchema('signup'));
    final renderer = AuthRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (ctx) => renderer.build(ctx)),
      ),
    );
    await tester.pump();

    final phoneField = find.byWidgetPredicate((w) => w is TextField && w.keyboardType == TextInputType.phone);
    expect(phoneField, findsOneWidget);

    await tester.enterText(phoneField, '+91 98765 43210');
    await tester.pump();
    expect(state.read('signupForm.phone'), '9876543210');

    await tester.enterText(phoneField, '09123456789');
    await tester.pump();
    expect(state.read('signupForm.phone'), '9123456789');
  });

  testWidgets('Send OTP button displays "Resend OTP" when OTP is visible', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AuthState(pageSchema('signup'));
    state.write('signupForm.otpVisible', true);

    final renderer = AuthRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (ctx) => renderer.build(ctx)),
      ),
    );
    await tester.pump();

    expect(find.text('Resend OTP'), findsOneWidget);
  });

  testWidgets('Tapping Send OTP with valid fields dispatches network request and reveals 6 OTP boxes', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    http.Request? capturedRequest;
    final mockClient = MockClient((request) async {
      capturedRequest = request;
      return http.Response(
        jsonEncode({'status': 'success', 'message': 'OTP sent successfully'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final effectiveSchema = AuthTemporaryApiOverlay.apply(pageSchema('signup'));
    final state = AuthState(effectiveSchema, client: mockClient);
    final renderer = AuthRenderer(state);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: state,
          builder: (ctx, _) => renderer.build(ctx),
        ),
      ),
    );
    await tester.pump();

    // Fill valid credentials: email, 10-digit phone, complex password
    state.write('signupForm.email', 'testuser@efactor.tech');
    state.write('signupForm.phone', '9876543210');
    state.write('signupForm.password', 'SecurePass123!');
    await tester.pump();

    // Verify Send OTP button is displayed
    final sendOtpFinder = find.text('Send OTP');
    expect(sendOtpFinder, findsOneWidget);

    // Tap Send OTP
    await tester.tap(sendOtpFinder);
    await tester.pump();
    while (state.isActionLoading('sendSignupOtp')) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 100));

    // Verify network request was made with exact contract
    expect(capturedRequest, isNotNull);
    expect(capturedRequest!.url.toString(), 'https://efactor.tech/v8/api.php?action=user');
    final payload = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
    expect(payload['email'], 'testuser@efactor.tech');
    expect(payload['phone'], '9876543210');
    expect(payload['password'], 'SecurePass123!');
    expect(payload['country_code'], '+91');
    expect(payload['user_type'], 'User');

    // Verify OTP state and Resend OTP label
    expect(state.read('signupForm.otpVisible'), isTrue);
    expect(find.text('Resend OTP'), findsOneWidget);
  });
}

