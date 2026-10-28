import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:efactor_sdui/grid_sdui/grid_schema_repository.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_renderer.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_state.dart';
import 'package:efactor_sdui/sdui/schema_pull_to_refresh.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final assetFile = File('assets/branding/grid.json');
    if (assetFile.existsSync()) {
      final jsonContent = assetFile.readAsStringSync();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (ByteData? message) async {
        final key = utf8.decode(message!.buffer.asUint8List());
        if (key == 'assets/branding/grid.json') {
          return ByteData.view(Uint8List.fromList(utf8.encode(jsonContent)).buffer);
        }
        return null;
      });
    }
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  group('Grid Schema Envelope and Dynamic Content Merging', () {
    test('merges root content and dynamic components into template schema', () async {
      await GridSchemaRepository.clearUserCache(userId: 12345);

      final envelope = {
        'success': true,
        'user_id': 12345,
        'pageId': 'grid',
        'routeId': 'grid',
        'schema_version': '3.0.0',
        'updated_at': '2026-10-28T12:00:00Z',
        'content': {
          'header': {
            'title': 'Dynamic Grid Title',
            'subtitle': 'Updated subtitle from server',
          },
          'stats': [
            {'id': 'professionals', 'label': 'Professionals', 'value': 999},
            {'id': 'opportunities', 'label': 'Opportunities', 'value': 42},
          ],
        },
        'components': {
          'grid-feature-professional-space': {
            'id': 'grid-feature-professional-space',
            'type': 'featureCard',
            'title': 'Live Space Title',
            'url': 'https://efactor.tech/live-space?grid_sso=live_token_abc',
          },
        },
        'schema': {
          'pageId': 'grid',
          'rootComponentId': 'grid-page',
          'page': {
            'id': 'grid',
            'rootComponentId': 'grid-page',
          },
          'components': {
            'grid-page': {
              'id': 'grid-page',
              'type': 'scrollPage',
              'layout': {'padding': {'top': 0, 'bottom': 0, 'left': 0, 'right': 0}, 'gap': 10},
              'children': ['grid-feature-professional-space'],
            },
            'grid-feature-professional-space': {
              'id': 'grid-feature-professional-space',
              'type': 'featureCard',
              'title': 'Template Space Title',
              'url': 'https://efactor.tech/template',
            },
          },
          'content': {
            'header': {
              'title': 'Template Header',
            },
          },
        },
      };

      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(envelope),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final repo = GridSchemaRepository(
        accessToken: 'token_123',
        userId: 12345,
        client: client,
      );

      final schema = await repo.load(forceRefresh: true);

      // Verify root metadata
      expect(schema['user_id'], 12345);
      expect(schema['updated_at'], '2026-10-28T12:00:00Z');

      // Verify merged content
      final content = schema['content'] as Map<String, dynamic>;
      final header = content['header'] as Map<String, dynamic>;
      expect(header['title'], 'Dynamic Grid Title');
      expect(header['subtitle'], 'Updated subtitle from server');

      // Verify merged components
      final comps = schema['components'] as Map<String, dynamic>;
      final profCard = comps['grid-feature-professional-space'] as Map<String, dynamic>;
      expect(profCard['title'], 'Live Space Title');
      expect(profCard['url'], contains('live_token_abc'));

      // Verify GridSduiState synthesis and live stats
      final state = GridSduiState(schema);
      expect(state.content['header']['title'], 'Dynamic Grid Title');
      final statsRow = state.component('grid-stats-row');
      expect(statsRow, isNotNull);
      final items = statsRow!['items'] as List;
      expect(items.first['value'], 999);
    });

    test('offline fallback marks schema with _clientGridSchemaOfflineFallback flag', () async {
      await GridSchemaRepository.clearUserCache(userId: 12346);

      final failingClient = MockClient((request) async {
        throw const SocketException('Connection refused');
      });

      final repo = GridSchemaRepository(
        accessToken: 'token_offline',
        userId: 12346,
        client: failingClient,
      );

      final schema = await repo.load(forceRefresh: true);
      expect(schema['_clientGridSchemaOfflineFallback'], isTrue);
    });

    test('revalidate detects changes when schema is modified on server', () async {
      await GridSchemaRepository.clearUserCache(userId: 77777);

      final baseSchema = {
        'pageId': 'grid',
        'rootComponentId': 'grid-page',
        'page': {'id': 'grid', 'rootComponentId': 'grid-page'},
        'components': {
          'grid-page': {
            'id': 'grid-page',
            'type': 'scrollPage',
            'layout': {'padding': {'top': 0, 'bottom': 0, 'left': 0, 'right': 0}, 'gap': 10},
            'children': [],
          },
        },
      };

      final updatedSchema = Map<String, dynamic>.from(baseSchema);
      updatedSchema['schema_version'] = '3.0.1';

      int count = 0;
      final client = MockClient((request) async {
        count++;
        return http.Response(
          jsonEncode({'schema': count == 1 ? baseSchema : updatedSchema}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final repo = GridSchemaRepository(
        accessToken: 'test_token',
        userId: 77777,
        client: client,
      );

      // Initial load
      final first = await repo.load(forceRefresh: true);
      expect(first, isNotNull);

      // Revalidate should detect change
      final result = await repo.revalidate(forceFull: true);
      expect(result.changed, isTrue);
      expect(result.schema['schema_version'], '3.0.1');
    });
  });

  group('Grid SDUI Pull-To-Refresh and UI Rendering', () {
    testWidgets('Pull-to-refresh triggers on Grid scrollPage with SchemaPullToRefresh', (WidgetTester tester) async {
      var refreshed = false;
      final schema = {
        'pageId': 'grid',
        'rootComponentId': 'grid-page',
        'page': {
          'id': 'grid',
          'rootComponentId': 'grid-page',
        },
        'components': {
          'grid-page': {
            'id': 'grid-page',
            'type': 'scrollPage',
            'layout': {
              'padding': {'top': 10.0, 'bottom': 10.0, 'left': 10.0, 'right': 10.0},
              'gap': 10.0,
            },
            'children': ['grid-quote'],
          },
          'grid-quote': {
            'id': 'grid-quote',
            'type': 'quoteBlock',
            'title': 'Initial Quote Text',
            'appearance': {
              'backgroundColor': '#ffffff',
              'textColor': '#000000',
              'borderRadius': 12.0,
            },
          },
        },
        'content': {},
      };

      final state = GridSduiState(schema);
      final renderer = GridSduiRenderer(state);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SchemaPullToRefresh(
              onRefresh: () async {
                refreshed = true;
              },
              child: Builder(
                builder: (context) => renderer.buildRoot(context),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Initial Quote Text'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(refreshed, isTrue);
    });
  });
}
