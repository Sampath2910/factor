import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:efactor_sdui/services/device_info_cache_manager.dart';
import 'package:efactor_sdui/services/schema_offline.dart';
import 'package:efactor_sdui/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EFCKER Recipee sno ↔ hex ↔ label matching', () {
    Map<String, dynamic> recipeControl() => <String, dynamic>{
          'id': '1:Recipee:command-2-drop-down',
          'binding': 'device.parameters.1_recipee_command_2_drop_down',
          'componentType': 'dropdown',
          'valueType': 'enum',
          'value': '',
          'options': [
            {
              'label':
                  '[RICE][BROWNRICE][FRY][MILK][SOUP][BIRIYANI][IDLY][DHAL][HARDVEG][WATER][POPCORN][CAKE][MAGGI][NOODLES][DIY]',
              'value':
                  '[000000003C6E00007D010A28009600000001036E000000][000001003C6E010F00010A28009600000001036E000000][0000020150DC000FB4010A2800F00005BE000000000000][00000301195F000F6E010A280096000000000000000000][000004001E960000B4010A2800B4000000000000000000][000005002DF00100B4010A2800F0000000000000000000][000006000F7D00055A010A280096000000000000000000][000007002D960000A0010A280096000000000000000000][0000080128C80000F0010A2800F0000000000000000000][00000900F0960000A0010A280096000000000000000000][00000B0003DC0006A5010A2800F00000000101DC000000][00000C012DDC0005B4010A2800F0000000000000000000][00000D00056A000A5A010A280096000000000000000000][00000E000ADC0008B4010A280096000000000000000000][00000F002DDC0005B401303800B4000000000000000000]',
            },
          ],
          'protocolMeta': {
            'items': [
              '[RICE][BROWNRICE][FRY][MILK][SOUP][BIRIYANI][IDLY][DHAL][HARDVEG][WATER][POPCORN][CAKE][MAGGI][NOODLES][DIY]',
            ],
            'item_values': [
              '[000000003C6E00007D010A28009600000001036E000000][000001003C6E010F00010A28009600000001036E000000][0000020150DC000FB4010A2800F00005BE000000000000][00000301195F000F6E010A280096000000000000000000][000004001E960000B4010A2800B4000000000000000000][000005002DF00100B4010A2800F0000000000000000000][000006000F7D00055A010A280096000000000000000000][000007002D960000A0010A280096000000000000000000][0000080128C80000F0010A2800F0000000000000000000][00000900F0960000A0010A280096000000000000000000][00000B0003DC0006A5010A2800F00000000101DC000000][00000C012DDC0005B4010A2800F0000000000000000000][00000D00056A000A5A010A280096000000000000000000][00000E000ADC0008B4010A280096000000000000000000][00000F002DDC0005B401303800B4000000000000000000]',
            ],
            'sno_asperui': [
              '[00][01][02][03][04][05][06][07][08][09][0B][0C][0D][0E][0F]',
            ],
          },
        };

    test('optionsFor expands recipe brackets and attaches sno aliases', () {
      final options = AppState.optionsFor(recipeControl());
      expect(options.length, 15);
      expect(options[2]['label'], 'FRY');
      expect(
        options[2]['value'],
        '0000020150DC000FB4010A2800F00005BE000000000000',
      );
      expect(options[2]['sno'], '02');
      expect(
        (options[2]['aliases'] as List).map((e) => e.toString()),
        containsAll(<String>['FRY', '02']),
      );
    });

    test('resolveEnumOption maps status sno and label onto command hex value', () {
      final control = recipeControl();
      final bySno = AppState.resolveEnumOption(control, '02');
      expect(bySno?['label'], 'FRY');
      expect(
        bySno?['value'],
        '0000020150DC000FB4010A2800F00005BE000000000000',
      );

      final byLabel = AppState.resolveEnumOption(control, 'FRY');
      expect(
        byLabel?['value'],
        '0000020150DC000FB4010A2800F00005BE000000000000',
      );

      final byHex = AppState.resolveEnumOption(
        control,
        '0000020150DC000FB4010A2800F00005BE000000000000',
      );
      expect(byHex?['label'], 'FRY');
    });

    test('setBinding coerces live sno into canonical recipe hex', () {
      final schema = <String, dynamic>{
        'controls': [recipeControl()],
        'pages': [
          {
            'id': 'page_1',
            'pageNo': '1',
            'controlIds': ['1:Recipee:command-2-drop-down'],
          },
        ],
      };
      final state = AppState(schema);
      state.setBinding(
        'device.parameters.1_recipee_command_2_drop_down',
        '02',
        dispatch: false,
      );
      expect(
        state.resolveBinding('device.parameters.1_recipee_command_2_drop_down'),
        '0000020150DC000FB4010A2800F00005BE000000000000',
      );
    });
  });

  group('EFCKER Skipmode enum trigger options', () {
    test('optionsFor exposes false/true protocol values', () {
      final control = <String, dynamic>{
        'id': '1:Skipmode:command-2-trigger',
        'binding': 'device.parameters.1_skipmode_command_2_trigger',
        'componentType': 'elevatedButton',
        'valueType': 'trigger',
        'value': 'Skipmode',
        'options': [
          {'label': 'false', 'value': '00'},
          {'label': 'true', 'value': '01'},
        ],
      };
      final options = AppState.optionsFor(control);
      expect(options.length, 2);
      expect(AppState.resolveEnumOption(control, '01')?['label'], 'true');
      expect(AppState.resolveEnumOption(control, '00')?['label'], 'false');
    });
  });

  group('EFCKER Info gateway cache slicing', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tempDir = Directory.systemTemp.createTempSync('efcker_info_cache_');
      SchemaDiskCache.testDirectory = tempDir;
      DeviceInfoCacheManager.instance.clearMemoryCache();
    });

    tearDown(() async {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
      SchemaDiskCache.testDirectory = null;
      DeviceInfoCacheManager.instance.clearMemoryCache();
    });

    test('extractCacheableInfoPayload keeps only config.info slice', () {
      final huge = <String, dynamic>{
        'status': true,
        'data': {
          'schema_json': {
            'pages': List.generate(20, (i) => {'id': 'page_$i'}),
            'node_details': [
              {
                'config': {
                  'node_id': 'NODE_COOKER',
                  'info': {
                    'SSID': 'Efactor',
                    'name': 'cooker_7E00051B',
                    'fw_version': '1.5.1',
                  },
                },
              },
            ],
          },
        },
      };
      final sliced = DeviceInfoCacheManager.extractCacheableInfoPayload(
        huge,
        responsePath: 'data.schema_json.node_details[0].config',
        infoPath: 'info',
      ) as Map;
      expect(sliced['info']['SSID'], 'Efactor');
      expect(sliced['info']['fw_version'], '1.5.1');
      expect(sliced.containsKey('pages'), isFalse);
      expect(jsonEncode(sliced).length < 2000, isTrue);
    });

    test('seedInfoPayloadFromSchema uses only schema-declared info paths', () {
      final schema = <String, dynamic>{
        'infoPage': {
          'responsePath': 'deviceConfig',
          'infoPath': 'info',
        },
        'deviceConfig': {
          'node_id': 'NODE_COOKER',
          'info': {
            'SSID': 'Efactor',
            'fw_version': '1.5.1',
            'name': 'cooker_7E00051B',
          },
        },
      };
      final seeded =
          DeviceInfoCacheManager.seedInfoPayloadFromSchema(schema) as Map;
      expect(seeded['info']['SSID'], 'Efactor');

      // Without declared paths, do not invent product-specific locations.
      expect(
        DeviceInfoCacheManager.seedInfoPayloadFromSchema(<String, dynamic>{
          'deviceConfig': {
            'info': {'SSID': 'Efactor'},
          },
        }),
        isNull,
      );
    });

    test('saveInfoData slices using declared responsePath/infoPath', () async {
      const model = 'MODEL_X';
      const node = 'NODE_Y';
      final payload = <String, dynamic>{
        'node_details': [
          {
            'config': {
              'node_id': node,
              'info': {
                'SSID': 'Efactor',
                'Access_Point': 'EWIFI',
                'fw_version': '1.5.1',
                'name': 'device',
              },
              'devices': List.generate(
                5,
                (i) => {'id': 'd$i', 'blob': 'x' * 1000},
              ),
            },
          },
        ],
      };

      await DeviceInfoCacheManager.instance.saveInfoData(
        modelId: model,
        nodeId: node,
        url: 'https://example.test/info',
        data: payload,
        responsePath: 'node_details[0].config',
        infoPath: 'info',
      );

      final cached = await DeviceInfoCacheManager.instance.getCachedInfoData(
        modelId: model,
        nodeId: node,
        url: 'https://example.test/info',
      );
      expect(cached, isNotNull);
      expect(cached['info']['SSID'], 'Efactor');
      expect(cached['info']['fw_version'], '1.5.1');
      expect(jsonEncode(cached).contains('blob'), isFalse);
    });
  });
}
