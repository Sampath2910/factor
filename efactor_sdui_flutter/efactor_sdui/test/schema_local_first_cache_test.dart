import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:efactor_sdui/data/schema_repository.dart';
import 'package:efactor_sdui/services/schema_offline.dart';
import 'package:efactor_sdui/services/schema_patch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = Directory.systemTemp.createTempSync('schema_test_');
    SchemaDiskCache.testDirectory = tempDir;
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
    SchemaDiskCache.testDirectory = null;
  });

  group('LocalSchemaManifest', () {
    test('records and retrieves manifest entries', () async {
      await LocalSchemaManifest.record(
        schemaKey: 'device:EFANV1.0:EFANV1.0',
        schemaType: 'device',
        revision: 4,
        contentHash: 'abc123hash',
        schemaVersion: '4.0.0',
        fileName: 'efactor.device.test.json',
      );

      final entry = await LocalSchemaManifest.getEntry('device:EFANV1.0:EFANV1.0');
      expect(entry, isNotNull);
      expect(entry!.schemaKey, 'device:EFANV1.0:EFANV1.0');
      expect(entry.schemaType, 'device');
      expect(entry.revision, 4);
      expect(entry.contentHash, 'abc123hash');
      expect(entry.schemaVersion, '4.0.0');

      final export = await LocalSchemaManifest.exportManifestPayload();
      expect(export['schemas'], isNotNull);
      expect(
        (export['schemas'] as Map)['device:EFANV1.0:EFANV1.0']['revision'],
        4,
      );
    });
  });

  group('SchemaPatch.applyDeltaPatch', () {
    test('updates control properties and adds new controls by ID', () {
      final baseSchema = <String, dynamic>{
        'schemaVersion': '4.0.0',
        'revision': 1,
        'controls': <dynamic>[
          <String, dynamic>{
            'id': 'fan_power',
            'type': 'switch',
            'value': false,
          },
          <String, dynamic>{
            'id': 'fan_speed',
            'type': 'slider',
            'value': 3,
          },
        ],
        'theme': <String, dynamic>{
          'primary': '#FF0000',
        },
      };

      final deltaPatch = <String, dynamic>{
        'revision': 2,
        'controls': <dynamic>[
          // Update existing control
          <String, dynamic>{
            'id': 'fan_speed',
            'value': 5,
          },
          // Add new control
          <String, dynamic>{
            'id': 'fan_mode',
            'type': 'dropdown',
            'value': 'breeze',
          },
        ],
        'theme': <String, dynamic>{
          'primary': '#00FF00',
        },
      };

      final patched = SchemaPatch.applyDeltaPatch(
        baseSchema,
        deltaPatch,
        targetRevision: 2,
        targetHash: 'new_target_hash',
      );

      expect(patched['revision'], 2);
      expect(patched['contentHash'], 'new_target_hash');
      expect((patched['theme'] as Map)['primary'], '#00FF00');

      final controls = patched['controls'] as List;
      expect(controls.length, 3);

      final speed = controls.firstWhere((c) => c['id'] == 'fan_speed') as Map;
      expect(speed['value'], 5);
      expect(speed['type'], 'slider'); // Preserved from base!

      final mode = controls.firstWhere((c) => c['id'] == 'fan_mode') as Map;
      expect(mode['value'], 'breeze');
    });

    test('deletes a control when marked with _op: delete', () {
      final baseSchema = <String, dynamic>{
        'controls': <dynamic>[
          <String, dynamic>{'id': 'keep_me', 'type': 'button'},
          <String, dynamic>{'id': 'remove_me', 'type': 'button'},
        ],
      };

      final deltaPatch = <String, dynamic>{
        'controls': <dynamic>[
          <String, dynamic>{'id': 'remove_me', '_op': 'delete'},
        ],
      };

      final patched = SchemaPatch.applyDeltaPatch(baseSchema, deltaPatch);
      final controls = patched['controls'] as List;
      expect(controls.length, 1);
      expect(controls.first['id'], 'keep_me');
    });

    test('selective merge marks only changed nodes', () {
      final baseSchema = <String, dynamic>{
        'controls': <dynamic>[
          <String, dynamic>{'id': 'c1', 'value': 10},
          <String, dynamic>{'id': 'c2', 'value': 20},
        ],
      };

      final patched = <String, dynamic>{
        'controls': <dynamic>[
          <String, dynamic>{'id': 'c1', 'value': 10},
          <String, dynamic>{'id': 'c2', 'value': 99},
        ],
      };

      final result = SchemaPatch.merge(baseSchema, patched);
      expect(result.unchanged, isFalse);
      expect(result.changedNodeIds.contains('c2'), isTrue);
      expect(result.changedNodeIds.contains('c1'), isFalse);
    });
  });

  group('SchemaRepository local-first cache', () {
    test('saveToCache writes schema and readFromCache retrieves it without network', () async {
      final repo = SchemaRepository();
      const modelId = 'TEST_FAN_01';
      const nodeId = 'NODE_888';

      final schema = <String, dynamic>{
        'schemaVersion': '4.0.0',
        'meta': <String, dynamic>{
          'app': <String, dynamic>{'name': 'Test Fan'},
        },
        'theme': <String, dynamic>{
          'colors': <String, dynamic>{
            'primary': '#FF5722',
            'background': '#0B1220',
          },
          'typography': <String, dynamic>{
            'fontFamily': 'Poppins',
          },
        },
        'routes': <String, dynamic>{},
        'controls': <dynamic>[],
        'pages': <dynamic>[],
      };

      await repo.saveToCache(
        modelId: modelId,
        nodeId: nodeId,
        schema: schema,
      );

      final cached = await repo.readFromCache(
        modelId: modelId,
        nodeId: nodeId,
      );

      expect(cached, isNotNull);
      expect(cached!['_clientSchemaCacheHit'], isTrue);
      expect(cached['meta']['app']['name'], 'Test Fan');

      final manifestEntry = await LocalSchemaManifest.getEntry('device:$modelId:$nodeId');
      expect(manifestEntry, isNotNull);
      expect(manifestEntry!.schemaType, 'device');
    });
  });
}

