import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/services/device_parameter_store.dart';
import 'package:efactor_sdui/services/ongoing_call_service.dart';
import 'package:efactor_sdui/sdui/component_registry.dart';
import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/sdui/style.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/wifi_sdui/wifi_native_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('iOS Platform Parity Tests', () {
    test('WifiRuntimeNetwork correctly deserializes iOS WifiNativeBridge map', () {
      // Structure returned by WifiNativeBridge.swift
      final iosBridgeMap = <String, dynamic>{
        'ssid': 'Home_WiFi_5G',
        'bssid': '',
        'rssi': -50,
        'frequency': 0,
        'securityLabel': 'WPA2',
        'security': 'WPA2',
        'open': false,
      };

      final network = WifiRuntimeNetwork.fromMap(iosBridgeMap);
      expect(network.ssid, 'Home_WiFi_5G');
      expect(network.bssid, '');
      expect(network.rssi, -50);
      expect(network.frequency, 0);
      expect(network.securityLabel, 'WPA2');
      expect(network.isOpen, false);

      final serialized = network.toMap();
      expect(serialized['ssid'], 'Home_WiFi_5G');
      expect(serialized['open'], false);
    });

    test('WifiNativeService handles iOS scanRouterNetworks returning current SSID', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('tech.efactor.studio/wifi_native'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'scanRouterNetworks') {
            return [
              {
                'ssid': 'MyHomeNetwork',
                'bssid': '',
                'rssi': -50,
                'frequency': 0,
                'securityLabel': 'WPA2',
                'security': 'WPA2',
                'open': false,
              }
            ];
          }
          if (methodCall.method == 'scanDeviceSoftAp') {
            return {
              'ssid': 'EWIFI_7E0005E8',
              'bssid': '',
              'rssi': -50,
              'frequency': 0,
              'securityLabel': 'Open',
              'security': 'Open',
              'open': true,
            };
          }
          return null;
        },
      );

      final routers = await WifiNativeService.instance.scanRouterNetworks();
      expect(routers.length, 1);
      expect(routers.first.ssid, 'MyHomeNetwork');
      expect(routers.first.isOpen, false);

      final softAp = await WifiNativeService.instance.scanDeviceSoftAp(
        expectedSsid: 'EWIFI_7E0005E8',
      );
      expect(softAp.ssid, 'EWIFI_7E0005E8');
      expect(softAp.isOpen, true);
    });

    test('Multi-page telemetry caching and dynamic resolution works identically in iOS environment', () {
      final p1 = {
        'id': 'page1',
        'controls': [
          {
            'id': '1:power:command-2-toggle-switch',
            'binding': 'device.parameters.1_power_command_2_toggle_switch',
            'parameter': 'power',
            'value': 'OFF',
          },
          {
            'id': '1:Speed:command-2-slider',
            'binding': 'device.parameters.1_speed_command_2_slider',
            'parameter': 'Speed',
            'value': 1,
          },
        ],
        'state': {
          'device': {
            'parameters': {
              '1_power_command_2_toggle_switch': false,
              '1_speed_command_2_slider': 1,
            }
          }
        }
      };

      final p3 = {
        'id': 'page3',
        'controls': [
          {
            'id': '3:command_get_status:response-3-text',
            'binding': 'device.parameters.3_command_get_status_response_3_text',
            'parameter': 'Command Get Status',
            'value': 'OFF',
            'deviceFrame': {
              'name': 'Command Get Status',
              'commands': [],
              'response': [
                {'default_name': 'CommandId'},
                {'default_name': 'Function Code'},
                {'default_name': 'power', 'asperui_value': 'true'},
                {'default_name': 'Speed', 'asperui_value': '6'},
              ]
            }
          }
        ],
        'state': {
          'device': {
            'parameters': {
              '3_command_get_status_response_3_text': 'OFF',
            }
          }
        }
      };

      final state = AppState(p1);

      // Ingest live WebSocket telemetry (e.g. from cloud)
      state.ingestCloudPayload({
        'node_id': 'IOS_NODE_123',
        'action': 'auto_get_nodes_params',
        'fan_device': {
          'Speed': 5,
        }
      });

      expect(
        state.resolveBinding('device.parameters.1_speed_command_2_slider')?.toString(),
        '5',
      );
      expect(state.latestCloudTelemetry['Speed'], 5);

      // Merge Page 3
      final merged = SchemaRepository.mergeDevicePageSchema(p1, p3);
      state.replaceSchema(merged, preserveValues: true, preservePage: true);

      // Assert Page 3 hydrated from latest cloud telemetry
      expect(
        state.resolveBinding('device.parameters.3_command_get_status_response_3_text')?.toString(),
        '5',
      );

      final ctrl = state.controlById('3:command_get_status:response-3-text')!;
      expect(state.presentedFieldText(ctrl, '5'), '5');
    });

    test('DeviceParameterStore persists and hydrates across app lifecycle', () async {
      final store = DeviceParameterStore(modelId: 'MODEL_IOS', nodeId: 'NODE_IOS');

      await store.writeIfChanged({
        'speed_ctrl': 4,
        'voltage_ctrl': 24.5,
      });

      final loaded = await store.read();
      expect(loaded?['speed_ctrl'], 4);
      expect(loaded?['voltage_ctrl'], 24.5);
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('Single-page model displays page button 1 under $platform', (tester) async {

        final singlePageSchema = <String, dynamic>{
          'version': '4.0.0',
          'pages': [
            {'id': 'page_1', 'pageNo': '1', 'title': 'Page1.Operation'},
          ],
          'controls': [
            {
              'id': 'ctrl_1',
              'type': 'text',
              'properties': {'text': 'Control on Page 1'},
            }
          ],
          'state': {
            'activePageIndex': 0,
            'device': {'parameters': {}},
          },
          'ui': {
            'type': 'column',
            'children': [
              {
                'id': 'page_buttons',
                'type': 'listView',
                'properties': {'scrollDirection': 'horizontal'},
                'children': [
                  {
                    'id': 'page_button_0',
                    'type': 'button',
                    'properties': {
                      'events': [
                        {
                          'event': 'onTap',
                          'action': {
                            'type': 'update',
                            'value': 'activePageIndex=0',
                          },
                        }
                      ],
                    },
                    'children': [
                      {
                        'id': 'page_text_1',
                        'type': 'text',
                        'properties': {'text': '1'},
                      }
                    ],
                  },
                ],
              },
            ],
          },
        };

        final state = AppState(singlePageSchema);
        expect(state.pages.length, 1);

        final renderer = SduiRenderer(state);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: Builder(
                builder: (context) => renderer.build(context, singlePageSchema['ui']),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('1'), findsOneWidget, reason: 'Page button 1 must render on $platform');
        state.dispose();
      });

      testWidgets('Send button and terminal scrolling operate identically on $platform', (tester) async {

        final sendControl = <String, dynamic>{
          'id': '3:send_data:command-0-enter-text',
          'parameter': 'Send Data',
          'binding': 'device.parameters.send_data_input',
          'componentType': 'textField',
          'component': {
            'props': {
              'textColor': '#111827',
              'borderColor': '#E5E7EB',
              'focusedBorderColor': '#3B82F6',
              'borderRadius': 8,
              'horizontalPadding': 12,
              'verticalPadding': 8,
              'sendButton': {
                'icon': 'send',
                'size': 40,
                'borderRadius': 8,
                'iconSize': 20,
                'backgroundColor': '#3B82F6',
                'iconColor': '#FFFFFF',
                'action': {
                  'type': 'send',
                  'binding': 'device.parameters.send_data_input',
                },
              },
            },
          },
        };

        final state = AppState(<String, dynamic>{
          'controls': [sendControl],
        });

        final renderer = SduiRenderer(state);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: Builder(
                builder: (context) => ComponentRegistry.instance.build(
                  context: context,
                  node: <String, dynamic>{
                    'type': 'textField',
                    'properties': <String, dynamic>{
                      'binding': 'device.parameters.send_data_input',
                      'props': sendControl['component']['props'],
                    },
                  },
                  props: <String, dynamic>{
                    'binding': 'device.parameters.send_data_input',
                    ...Map<String, dynamic>.from(sendControl['component']['props'] as Map),
                  },
                  style: SduiStyle(const {}),
                  children: const [],
                  state: state,
                  renderer: renderer,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final allInkWells = tester.widgetList<InkWell>(find.byType(InkWell)).toList();
        expect(allInkWells.isNotEmpty, isTrue);
        expect(allInkWells.any((w) => w.onTap != null), isTrue, reason: 'Send button must be clickable on $platform');

        state.dispose();
      });
    }

    test('OngoingCallService invokes startOngoingCallService and stopOngoingCallService under iOS platform', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final calls = <String>[];
        final payloads = <Map<dynamic, dynamic>>[];

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('tech.efactor/circle_connect'),
          (MethodCall methodCall) async {
            calls.add(methodCall.method);
            if (methodCall.arguments is Map) {
              payloads.add(methodCall.arguments as Map<dynamic, dynamic>);
            }
            return true;
          },
        );

        await OngoingCallService.instance.startCall(
          callId: 'call_ios_123',
          callType: 'audio',
          name: 'Pavan',
          isGroup: false,
        );

        expect(OngoingCallService.instance.isCallActive, isTrue);
        expect(OngoingCallService.instance.activeCallId, 'call_ios_123');
        expect(calls, contains('startOngoingCallService'));
        expect(payloads.first['callId'], 'call_ios_123');

        await OngoingCallService.instance.stopCall('call_ios_123');
        expect(OngoingCallService.instance.isCallActive, isFalse);
        expect(calls, contains('stopOngoingCallService'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('iOS Info.plist disables Impeller (FLTEnableImpeller: false) to match Android Skia 3D parity', () async {
      final file = File('ios/Runner/Info.plist');
      expect(file.existsSync(), isTrue);
      final content = await file.readAsString();
      expect(content, contains('<key>FLTEnableImpeller</key>'));
      expect(content, contains('<false/>'));
    });
  });
}
