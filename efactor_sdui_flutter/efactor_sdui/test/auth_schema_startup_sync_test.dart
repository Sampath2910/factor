import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:efactor_sdui/auth_sdui/auth_schema_repository.dart';
import 'package:efactor_sdui/auth_sdui/auth_schema_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, dynamic> sampleLiveSchema;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return Directory.systemTemp.path;
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      if (key == 'assets/auth_ui_schema.json') {
        final bytes = File('assets/auth_ui_schema.json').readAsBytesSync();
        return bytes.buffer.asByteData();
      }
      return null;
    });

    final raw = jsonDecode(File('assets/auth_ui_schema.json').readAsStringSync()) as Map<String, dynamic>;
    sampleLiveSchema = raw.containsKey('schema') && raw['schema'] is Map
        ? Map<String, dynamic>.from(raw['schema'] as Map)
        : raw;
  });

  test('AuthSchemaRepository.load fetches live schema first when online', () async {
    final mockClient = MockClient((request) async {
      if (request.url.path.contains('api_auth_schema.php')) {
        return http.Response(
          jsonEncode(<String, dynamic>{'schema': sampleLiveSchema}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('Not found', 404);
    });

    final repo = AuthSchemaRepository(client: mockClient);
    final schema = await repo.load();

    expect(schema['revision'], 42);
    expect(schema['_clientAuthSchemaCacheHit'], false);
    expect(schema['app']['initialPageId'], 'login');
  });

  test('AuthSchemaRepository.load falls back to bundled asset when network fails', () async {
    final mockClient = MockClient((request) async {
      throw http.ClientException('Network unreachable');
    });

    final repo = AuthSchemaRepository(client: mockClient);
    final schema = await repo.load();

    expect(schema, isNotNull);
    expect(schema['_clientAuthSchemaCacheHit'], true);
    expect(schema['revision'], 42);
  });

  test('AuthSchemaRepository.revalidate downloads full schema when delta returns full_required', () async {
    var fullSchemaRequested = false;

    final mockClient = MockClient((request) async {
      final url = request.url.toString();
      if (url.contains('action=meta')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'status': true,
            'revision': 42,
            'contentHash': '0fb8d5e7c5fde7e61b4c9908ff2f48ff4db45adf926d4c3ee0f1d704d153ecda',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (url.contains('action=delta')) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'status': true,
            'full_required': true,
            'message': 'Revision gap too large',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path.contains('api_auth_schema.php')) {
        fullSchemaRequested = true;
        return http.Response(
          jsonEncode(<String, dynamic>{'schema': sampleLiveSchema}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('Not found', 404);
    });

    // Create a mock local cache with older revision 16 based on full valid schema
    final mockCache = AuthSchemaCache();
    final cachedSchema = Map<String, dynamic>.from(jsonDecode(jsonEncode(sampleLiveSchema)) as Map);
    cachedSchema['revision'] = 16;
    cachedSchema['schemaVersion'] = 16;
    cachedSchema['contentHash'] = 'f7465d725bddd5aadb3789cd75f6874d17ae0b2d3221d3ce2b73bb32b3a943c4';
    await mockCache.write(cachedSchema);

    final repo = AuthSchemaRepository(client: mockClient, cache: mockCache);
    final result = await repo.revalidate();

    expect(fullSchemaRequested, true, reason: 'Must fetch full schema when delta returns full_required');
    expect(result.changed, true);
    expect(result.schema['revision'], 42);
    expect(result.source, 'full-delta-fallback');

    await mockCache.clear();
  });
}
