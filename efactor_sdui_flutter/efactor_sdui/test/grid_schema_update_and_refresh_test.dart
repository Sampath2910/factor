import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:efactor_sdui/grid_sdui/dynamic_grid_sdui_page.dart';
import 'package:efactor_sdui/grid_sdui/grid_schema_repository.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_renderer.dart';
import 'package:efactor_sdui/grid_sdui/grid_sdui_state.dart';
import 'package:efactor_sdui/home_sdui/dynamic_home_sdui_page.dart';
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
        if (key == 'AssetManifest.bin') {
          return const StandardMessageCodec()
              .encodeMessage(<Object?, Object?>{});
        }
        if (key == 'AssetManifest.json') {
          return ByteData.view(Uint8List.fromList(utf8.encode('{}')).buffer);
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

  group('Network-first Fetch, schema_rev, Live Brightness & Host Integration',
      () {
    Map<String, dynamic> liveGridPayload({
      String schemaRev = 'grid-logo-globe-3',
      String avatarLabel = 'A',
      String qrData = 'https://efactor.tech/grid/profile/u1',
      String updatesSubtitle = '1 update',
    }) {
      return <String, dynamic>{
        'schema_rev': schemaRev,
        'schema': <String, dynamic>{
          'schema_rev': schemaRev,
          'pageId': 'grid',
          'rootComponentId': 'grid-page',
          'page': <String, dynamic>{
            'id': 'grid',
            'rootComponentId': 'grid-page',
          },
          'theme': <String, dynamic>{
            'defaultMode': 'system',
            'systemFollows': 'device',
            'modes': <String, dynamic>{
              'light': <String, dynamic>{
                'pageBackground': '#eef4fb',
                'surface': '#ffffff',
                'onSurface': '#0b1b33',
                'textPrimary': '#0b1b33',
                'textSecondary': '#64748b',
                'textMuted': '#94a3b8',
                'border': '#cbd5e1',
                'accent': '#7c3aed',
                'onAccent': '#ffffff',
              },
              'dark': <String, dynamic>{
                'pageBackground': '#050b16',
                'surface': '#1a1f2e',
                'onSurface': '#f8fafc',
                'textPrimary': '#f8fafc',
                'textSecondary': '#94a3b8',
                'textMuted': '#64748b',
                'border': '#2a3344',
                'accent': '#8b5cf6',
                'onAccent': '#ffffff',
              },
            },
          },
          'designTokens': <String, dynamic>{
            'colors': <String, dynamic>{
              'pageBackground': '#eef4fb',
              'surface': '#ffffff',
              'onSurface': '#0b1b33',
              'textPrimary': '#0b1b33',
              'textSecondary': '#64748b',
              'accent': '#7c3aed',
              'onAccent': '#ffffff',
            },
            'typography': <String, dynamic>{
              'fontFamily': 'Plus Jakarta Sans',
              'pageTitle': <String, dynamic>{'size': 18.0, 'weight': 800},
              'pageSubtitle': <String, dynamic>{'size': 11.0, 'weight': 500},
            },
          },
          'components': <String, dynamic>{
            'grid-page': <String, dynamic>{
              'id': 'grid-page',
              'type': 'scrollPage',
              'layout': <String, dynamic>{
                'padding': <String, dynamic>{
                  'top': 12.0,
                  'bottom': 24.0,
                  'left': 16.0,
                  'right': 16.0,
                },
                'gap': 12.0,
              },
              'children': <String>[
                'grid-page-header',
                'grid-share-qr',
                'grid-explore-professional-message',
              ],
              'appearance': <String, dynamic>{'backgroundColor': '#eef4fb'},
              'appearanceDark': <String, dynamic>{'backgroundColor': '#050b16'},
            },
            'grid-page-header': <String, dynamic>{
              'id': 'grid-page-header',
              'type': 'pageHeader',
              'logoUrl': 'https://efactor.tech/assets/images/GRID_Logo.png',
              'logoUrlDark':
                  'https://efactor.tech/assets/images/dark_grid.png',
              'title': 'GRID Network',
              'subtitle': updatesSubtitle,
              'orbitGlobeImageUrl':
                  'https://efactor.tech/assets/images/grid-orbit-globe.png',
              'orbitGlobeClip': false,
              'layout': <String, dynamic>{
                'heroGlobeWidth': 160.0,
                'heroGlobeHeight': 160.0,
                'responsive': <String, dynamic>{
                  'compact': <String, dynamic>{
                    'logoHeight': 48.0,
                    'heroGlobeWidth': 160.0,
                    'heroGlobeHeight': 160.0,
                  },
                },
              },
              'appearance': <String, dynamic>{
                'logoHeight': 48.0,
                'logoMaxWidth': 168.0,
                'orbitGlobeSize': 160.0,
                'titleColor': '#0b1b33',
              },
              'appearanceDark': <String, dynamic>{
                'logoUrlDark':
                    'https://efactor.tech/assets/images/dark_grid.png',
                'logoHeight': 48.0,
                'titleColor': '#f8fafc',
              },
              'actions': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'grid-header-avatar',
                  'kind': 'avatar',
                  'label': avatarLabel,
                  'size': 48.0,
                },
              ],
            },
            'grid-share-qr': <String, dynamic>{
              'id': 'grid-share-qr',
              'type': 'shareQrCard',
              'title': 'Share QR',
              'data': qrData,
              'layout': <String, dynamic>{'gap': 10.0},
              'appearance': <String, dynamic>{
                'backgroundColor': '#ffffff',
                'qrBackgroundColor': '#ffffff',
                'titleFontSize': 16.0,
                'subtitleFontSize': 12.0,
                'borderRadius': 16.0,
                'padding': 16.0,
              },
              'appearanceDark': <String, dynamic>{
                'backgroundColor': '#1a1f2e',
                'qrBackgroundColor': '#ffffff',
              },
            },
            'grid-explore-professional-message': <String, dynamic>{
              'id': 'grid-explore-professional-message',
              'type': 'featureCard',
              'title': 'Updates',
              'subtitle': updatesSubtitle,
              'layout': <String, dynamic>{'minHeight': 72.0},
              'appearance': <String, dynamic>{
                'backgroundColor': '#ffffff',
                'titleColor': '#0b1b33',
                'subtitleColor': '#64748b',
                'borderRadius': 16.0,
                'iconSize': 42.0,
                'titleFontSize': 15.0,
                'subtitleFontSize': 12.0,
                'padding': 14.0,
              },
              'appearanceDark': <String, dynamic>{
                'backgroundColor': '#1a1f2e',
                'titleColor': '#f8fafc',
                'subtitleColor': '#94a3b8',
              },
            },
          },
          'content': <String, dynamic>{
            'avatarLabel': avatarLabel,
            'qrData': qrData,
          },
        },
      };
    }

    test(
        'GridSchemaRepository sends Cache-Control: no-cache, must-revalidate, always fetches live data first, and detects schema_rev changes',
        () async {
      var callCount = 0;
      String? capturedCacheControl;

      final client = MockClient((request) async {
        callCount++;
        capturedCacheControl =
            request.headers['Cache-Control'] ?? request.headers['cache-control'];
        final body = callCount == 1
            ? liveGridPayload(
                schemaRev: 'grid-logo-globe-2',
                avatarLabel: 'A1',
                qrData: 'https://efactor.tech/grid/profile/1',
                updatesSubtitle: '1 update',
              )
            : liveGridPayload(
                schemaRev: 'grid-logo-globe-3',
                avatarLabel: 'A2',
                qrData: 'https://efactor.tech/grid/profile/2',
                updatesSubtitle: '5 updates',
              );
        return http.Response(jsonEncode(body), 200);
      });

      await GridSchemaRepository.clearUserCache(userId: 91919);
      final repo = GridSchemaRepository(
        accessToken: 'tok-rev',
        userId: 91919,
        client: client,
      );

      final first = await repo.load();
      expect(callCount, 1);
      expect(capturedCacheControl, contains('no-cache'));
      expect(capturedCacheControl, contains('must-revalidate'));
      expect(GridSchemaRepository.extractSchemaRev(first), 'grid-logo-globe-2');
      expect((first['content'] as Map)['avatarLabel'], 'A1');

      // Second load (without forceRefresh) still hits network first and picks up updated schema_rev + dynamic data
      final second = await repo.load();
      expect(callCount, 2);
      expect(GridSchemaRepository.extractSchemaRev(second), 'grid-logo-globe-3');
      expect((second['content'] as Map)['avatarLabel'], 'A2');
      expect(
        ((second['components'] as Map)['grid-explore-professional-message']
            as Map)['subtitle'],
        '5 updates',
      );
    });

    testWidgets(
        'DynamicGridSduiPage reacts to live OS brightness switch with zero extra API calls and applies includeTopSafeArea edge-to-edge background',
        (tester) async {
      var fetchCount = 0;
      final client = MockClient((request) async {
        fetchCount++;
        return http.Response(
          jsonEncode(liveGridPayload(schemaRev: 'grid-logo-globe-3')),
          200,
        );
      });

      await tester.runAsync(() async {
        await GridSchemaRepository.clearUserCache(userId: 92929);
      });
      final repo = GridSchemaRepository(
        accessToken: 'tok-live-ui',
        userId: 92929,
        client: client,
      );

      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.platformDispatcher.clearPlatformBrightnessTestValue();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 44),
              ),
              child: DynamicGridSduiPage(
                accessToken: 'tok-live-ui',
                userId: 92929,
                repository: repo,
                embedInHostShell: true,
                includeTopSafeArea: true,
                enableAutoRefresh: false,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump();

      expect(fetchCount, 1);

      // Initially light mode -> GRID_Logo.png + light #eef4fb backdrop + dark status icons
      var images = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .toList();
      expect(
        images.any((i) =>
            i.imageUrl == 'https://efactor.tech/assets/images/GRID_Logo.png'),
        isTrue,
      );
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((b) => b.color == const Color(0xFFEEF4FB)),
        isTrue,
      );
      final lightOverlay = tester
          .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .last;
      expect(lightOverlay.value.statusBarIconBrightness, Brightness.dark);

      // Verify SafeArea(top: true) is INSIDE dark/light backdrop ColoredBox for edge-to-edge host embedding
      final gridSafeArea = tester
          .widgetList<SafeArea>(find.byType(SafeArea))
          .firstWhere((s) => s.top == true && s.bottom == false);
      expect(gridSafeArea, isNotNull);

      // Flip device brightness to DARK while Grid is open -> NO new HTTP request!
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await tester.pump();

      expect(fetchCount, 1);

      images = tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .toList();
      expect(
        images.any((i) =>
            i.imageUrl == 'https://efactor.tech/assets/images/dark_grid.png'),
        isTrue,
      );
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((b) => b.color == const Color(0xFF050B16)),
        isTrue,
      );
      final darkOverlay = tester
          .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .last;
      expect(darkOverlay.value.statusBarIconBrightness, Brightness.light);

      // Flip back to LIGHT -> immediate switch back, still 1 HTTP call
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pump();
      await tester.pump();

      expect(fetchCount, 1);
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((b) => b.color == const Color(0xFFEEF4FB)),
        isTrue,
      );
    });

    testWidgets(
        'DynamicHomeSduiPage passes includeTopSafeArea: true to embedded DynamicGridSduiPage without outer top SafeArea',
        (tester) async {
      final homeSchema = <String, dynamic>{
        'designTokens': <String, dynamic>{
          'colors': <String, dynamic>{
            'pageBackground': '#ffffff',
            'surface': '#ffffff',
            'textPrimary': '#0f172a',
          },
        },
        'state': <String, dynamic>{
          'navigation': <String, dynamic>{
            'activeRouteId': 'grid_tab',
            'history': <dynamic>[],
          },
        },
        'routes': <String, dynamic>{
          'grid_tab': <String, dynamic>{
            'id': 'grid_tab',
            'pageId': 'grid_page',
          },
        },
        'pages': <String, dynamic>{
          'grid_page': <String, dynamic>{
            'id': 'grid_page',
            'dataSourceId': 'grid',
            'rootComponentId': 'grid-host-root',
          },
        },
        'components': <String, dynamic>{
          'grid-host-root': <String, dynamic>{
            'id': 'grid-host-root',
            'type': 'container',
          },
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 860),
              padding: EdgeInsets.only(top: 44),
            ),
            child: DynamicHomeSduiPage(
              accessToken: 'home-grid-token',
              userId: 655,
              enableAutoRefresh: false,
              initialSchema: homeSchema,
            ),
          ),
        ),
      );
      await tester.pump();

      final embeddedGridFinder = find.byType(DynamicGridSduiPage);
      expect(embeddedGridFinder, findsOneWidget);
      final embeddedGrid = tester.widget<DynamicGridSduiPage>(embeddedGridFinder);
      expect(embeddedGrid.embedInHostShell, isTrue);
      expect(embeddedGrid.includeTopSafeArea, isTrue);

      // Verify no SafeArea wraps outside the IndexedStack / DynamicGridSduiPage inside Home's Scaffold body
      final indexedStackFinder = find.ancestor(
        of: embeddedGridFinder,
        matching: find.byType(IndexedStack),
      );
      expect(indexedStackFinder, findsOneWidget);
      final outerSafeAreaFinder = find.ancestor(
        of: indexedStackFinder,
        matching: find.byType(SafeArea),
      );
      expect(outerSafeAreaFinder, findsNothing);
    });
  });
}
