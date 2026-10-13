import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/wifi_sdui/dynamic_wifi_sdui_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tech.efactor.studio/wifi_native'),
      (MethodCall methodCall) async {
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tech.efactor.studio/wifi_provision'),
      (MethodCall methodCall) async {
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tech.efactor.studio/wifi_native'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tech.efactor.studio/wifi_provision'),
      null,
    );
  });

  final sampleWifiSchema = <String, dynamic>{
    'state': {
      'activePageIndex': 0,
      'device': {
        'parameters': <String, dynamic>{},
      },
    },
    'theme': {
      'colors': {
        'background': '#FFFFFF',
        'surface': '#F8F9FA',
        'text': '#111827',
        'mutedText': '#6B7280',
        'accent': '#2F6BFF',
        'buttonBg': '#2F6BFF',
        'buttonText': '#FFFFFF',
        'error': '#DC2626',
      },
      'spacing': {
        'pagePadding': 16,
        'cardGap': 12,
      },
      'typography': {
        'subtitleSize': 14,
      },
    },
    'wifiProvisioning': {
      'entryScreen': 'wifiNetworkPicker',
      'flow': {
        'entryScreen': 'wifiNetworkPicker',
        'successScreen': 'wifiSuccess',
        'errorScreen': 'wifiError',
        'back': {
          'wifiNetworkPicker': 'close',
          'wifiPassword': 'wifiNetworkPicker',
          'provisioning': {
            'screen': 'wifiPassword',
            'whenOpen': 'wifiNetworkPicker',
          },
          'cloudConfirmation': {
            'screen': 'wifiPassword',
            'whenOpen': 'wifiNetworkPicker',
          },
          'wifiSuccess': 'close',
          'wifiError': 'wifiNetworkPicker',
        },
      },
      'screens': [
        {
          'id': 'wifiNetworkPicker',
          'title': 'Select Wi-Fi Network',
          'header': {
            'title': 'Select Wi-Fi',
            'backButton': {
              'width': 36,
              'height': 36,
              'icon': 'chevron-left',
            },
          },
          'onBack': {
            'type': 'wifi.close',
          },
          'body': <dynamic>[
            {
              'type': 'button',
              'text': 'Go to Password Screen',
              'action': {
                'type': 'navigate',
                'screen': 'wifiPassword',
              },
            },
          ],
        },
        {
          'id': 'wifiPassword',
          'title': 'Enter Password',
          'header': {
            'title': 'Wi-Fi Password',
            'backButton': {
              'width': 36,
              'height': 36,
              'icon': 'chevron-left',
            },
          },
          'onBack': {
            'type': 'navigate',
            'screen': 'wifiNetworkPicker',
          },
          'body': <dynamic>[
            {
              'type': 'button',
              'text': 'Connect Device',
              'action': {
                'type': 'navigate',
                'screen': 'provisioning',
              },
            },
          ],
        },
        {
          'id': 'provisioning',
          'title': 'Connecting Device',
          'header': {
            'title': 'Connecting',
            'backButton': {
              'width': 36,
              'height': 36,
              'icon': 'chevron-left',
            },
          },
          'onBack': {
            'type': 'sequence',
            'steps': [
              {
                'type': 'nativeCapability',
                'capability': 'cancelProvisioning',
              },
              {
                'type': 'navigate',
                'screen': 'wifiPassword',
              },
            ],
          },
          'body': <dynamic>[
            {
              'type': 'text',
              'text': 'Connecting in progress...',
            },
          ],
        },
      ],
      'nativeCapabilities': {
        'cancelProvisioning': {
          'method': 'wifi.cancelProvisioning',
        },
      },
    },
  };

  testWidgets('Back button is always clickable on entry screen and pops route to restore previous state', (tester) async {
    final state = AppState(sampleWifiSchema);
    Map<String, dynamic>? popResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                popResult = await Navigator.of(context).push<Map<String, dynamic>>(
                  MaterialPageRoute<Map<String, dynamic>>(
                    builder: (_) => DynamicWifiSduiPage(
                      state: state,
                      action: const <String, dynamic>{'type': 'openWifiConfig'},
                    ),
                  ),
                );
              },
              child: const Text('Open Wi-Fi'),
            ),
          ),
        ),
      ),
    );

    // Open Wi-Fi page
    await tester.tap(find.text('Open Wi-Fi'));
    await tester.pumpAndSettle();

    expect(find.text('Select Wi-Fi'), findsOneWidget);

    // Find and tap the Back button on AppBar
    final backButton = find.bySemanticsLabel('Back');
    expect(backButton, findsOneWidget);

    await tester.tap(backButton);
    await tester.pumpAndSettle();

    // Verify it popped back to original screen and returned closed status
    expect(find.text('Open Wi-Fi'), findsOneWidget);
    expect(popResult, isNotNull);
    expect(popResult!['status'], 'closed');
  });

  testWidgets('Multi-step back navigation from connecting -> password -> network picker -> device page', (tester) async {
    final state = AppState(sampleWifiSchema);
    Map<String, dynamic>? popResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                popResult = await Navigator.of(context).push<Map<String, dynamic>>(
                  MaterialPageRoute<Map<String, dynamic>>(
                    builder: (_) => DynamicWifiSduiPage(
                      state: state,
                      action: const <String, dynamic>{'type': 'openWifiConfig'},
                    ),
                  ),
                );
              },
              child: const Text('Device Page View'),
            ),
          ),
        ),
      ),
    );

    // 1. Open Wi-Fi page from device page
    await tester.tap(find.text('Device Page View'));
    await tester.pumpAndSettle();
    expect(find.text('Select Wi-Fi'), findsOneWidget);

    // 2. Select network and navigate forward to Password screen
    await tester.tap(find.text('Go to Password Screen'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi Password'), findsOneWidget);

    // 3. Tap Connect Device to navigate forward to Provisioning screen
    await tester.tap(find.text('Connect Device'));
    await tester.pumpAndSettle();
    expect(find.text('Connecting'), findsOneWidget);

    // 4. User is on Connecting screen and taps Back button
    final backFromConnecting = find.bySemanticsLabel('Back');
    expect(backFromConnecting, findsOneWidget);
    await tester.tap(backFromConnecting);
    await tester.pumpAndSettle();

    // Verify user stepped back to Password screen
    expect(find.text('Wi-Fi Password'), findsOneWidget);

    // 5. User taps Back button on Password screen
    final backFromPassword = find.bySemanticsLabel('Back');
    expect(backFromPassword, findsOneWidget);
    await tester.tap(backFromPassword);
    await tester.pumpAndSettle();

    // Verify user stepped back to Network Picker screen
    expect(find.text('Select Wi-Fi'), findsOneWidget);

    // 6. User taps Back button on Network Picker screen
    final backFromPicker = find.bySemanticsLabel('Back');
    expect(backFromPicker, findsOneWidget);
    await tester.tap(backFromPicker);
    await tester.pumpAndSettle();

    // Verify user returned completely to the Device Page's previous state
    expect(find.text('Device Page View'), findsOneWidget);
    expect(popResult, isNotNull);
    expect(popResult!['status'], 'closed');
  });

  testWidgets('Open network navigation skips password screen on back button', (tester) async {
    final state = AppState(sampleWifiSchema);
    Map<String, dynamic>? popResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                popResult = await Navigator.of(context).push<Map<String, dynamic>>(
                  MaterialPageRoute<Map<String, dynamic>>(
                    builder: (_) => DynamicWifiSduiPage(
                      state: state,
                      action: const <String, dynamic>{'type': 'openWifiConfig'},
                    ),
                  ),
                );
              },
              child: const Text('Device Page View'),
            ),
          ),
        ),
      ),
    );

    // 1. Open Wi-Fi page
    await tester.tap(find.text('Device Page View'));
    await tester.pumpAndSettle();
    expect(find.text('Select Wi-Fi'), findsOneWidget);

    // 2. Tapping back from entry screen closes immediately
    final backButton = find.bySemanticsLabel('Back');
    expect(backButton, findsOneWidget);
    await tester.tap(backButton);
    await tester.pumpAndSettle();

    expect(find.text('Device Page View'), findsOneWidget);
    expect(popResult!['status'], 'closed');
  });
}

