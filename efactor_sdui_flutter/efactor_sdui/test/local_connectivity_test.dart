import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_provisioning/efactor_provisioning.dart';
import 'package:efactor_sdui/services/efactor_cloud_service.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/iot_sdui/iot_sdui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Local Connectivity & Hybrid Online/Offline', () {
    final cloudService = EfactorCloudService.instance;

    setUp(() {
      cloudService.clearLocalDevices();
    });

    tearDown(() {
      cloudService.clearLocalDevices();
    });

    test('AppState resolves local connectivity bindings accurately', () {
      final appState = AppState(<String, dynamic>{
        '_clientConnection': {
          'modelId': 'MOD_001',
          'nodeId': 'NODE_TEST_123',
        },
        'extensions': {
          'universalUi': {
            'data': {
              'state': {'online': false},
            },
          },
        },
      });

      // Initially offline because cloud is offline and not discovered on LAN
      expect(appState.resolveBinding('state.online'), isFalse);
      expect(appState.resolveBinding('state.onlineLabel'), 'Offline');
      expect(appState.resolveBinding('state.isLocal'), isFalse);
      expect(appState.resolveBinding('state.connectivityType'), 'offline');
      expect(appState.resolveBinding('state.connectivityLabel'), 'Offline');
      expect(appState.resolveBinding('state.localDeviceIp'), isNull);

      // Simulate mDNS discovery of this node
      cloudService.setLocalDevice(
        EfLocalDevice(
          nodeId: 'NODE_TEST_123',
          ip: '192.168.1.150',
          port: 80,
        ),
      );

      // Now AppState should resolve to Online via Local LAN
      expect(appState.resolveBinding('state.online'), isTrue);
      expect(appState.resolveBinding('state.onlineLabel'), 'Online');
      expect(appState.resolveBinding('state.isLocal'), isTrue);
      expect(appState.resolveBinding('state.connectivityType'), 'local');
      expect(appState.resolveBinding('state.connectivityLabel'), 'Local (LAN)');
      expect(appState.resolveBinding('state.localDeviceIp'), '192.168.1.150');
      expect(appState.resolveBinding('state.localDevicePort'), 80);

      appState.dispose();
    });

    test('AppState ticks binding channels when local devices change', () {
      final appState = AppState(<String, dynamic>{
        '_clientConnection': {
          'modelId': 'MOD_001',
          'nodeId': 'NODE_TICK_123',
        },
      });

      var ticked = false;
      final listenable = appState.listenableForBinding('state.online');
      void listener() {
        ticked = true;
      }

      listenable.addListener(listener);

      // Trigger local discovery change
      cloudService.setLocalDevice(
        EfLocalDevice(
          nodeId: 'NODE_TICK_123',
          ip: '192.168.1.200',
          port: 80,
        ),
      );

      expect(ticked, isTrue);
      listenable.removeListener(listener);
      appState.dispose();
    });

    test('checkLocalConnectivity returns false when node is unknown or unreachable', () async {
      final appState = AppState(<String, dynamic>{
        '_clientConnection': {
          'modelId': 'MOD_001',
          'nodeId': 'NODE_NON_EXISTENT',
        },
      });

      final reachable = await appState.checkLocalConnectivity(
        timeout: const Duration(milliseconds: 200),
      );
      expect(reachable, isFalse);
      appState.dispose();
    });

    test('IotSduiState reflects local discovery in device online status', () {
      final iotState = IotSduiState(
        schema: <String, dynamic>{
          'screens': [
            {
              'id': 'home',
              'components': [
                {
                  'type': 'deviceGrid',
                  'dataSource': {'type': 'static'},
                }
              ]
            }
          ]
        },
        accessToken: 'token_123',
      );

      // Check isNodeLocal behavior
      expect(cloudService.isNodeLocal('NODE_LAN_XYZ'), isFalse);

      cloudService.setLocalDevice(
        EfLocalDevice(
          nodeId: 'NODE_LAN_XYZ',
          ip: '192.168.1.188',
          port: 80,
        ),
      );

      expect(cloudService.isNodeLocal('NODE_LAN_XYZ'), isTrue);

      iotState.dispose();
    });
  });
}
