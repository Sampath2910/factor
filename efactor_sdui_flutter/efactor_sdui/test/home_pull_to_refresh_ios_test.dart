import 'package:efactor_sdui/home_sdui/home_sdui_renderer.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';
import 'package:efactor_sdui/sdui/schema_pull_to_refresh.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Home Page iOS Pull-To-Refresh Tests', () {
    testWidgets('Pull-to-refresh triggers on iOS with scrollPage', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        var refreshed = false;

        final schema = <String, dynamic>{
          'designTokens': <String, dynamic>{
            'colors': <String, dynamic>{
              'surface': '#151b2e',
              'textPrimary': '#ffffff',
              'textSecondary': '#94a3b8',
              'welcomeText': '#ffffff',
            },
            'radius': <String, dynamic>{'card': 16.0},
            'spacing': <String, dynamic>{'sm': 8.0, 'xs': 4.0},
            'typography': <String, dynamic>{
              'cardTitle': <String, dynamic>{'fontSize': 12.0},
              'cardSubtitle': <String, dynamic>{'fontSize': 9.0},
            },
          },
          'components': <String, dynamic>{
            'home-page': <String, dynamic>{
              'id': 'home-page',
              'type': 'scrollPage',
              'layout': <String, dynamic>{
                'padding': {'left': 10, 'right': 10, 'top': 8, 'bottom': 120},
                'gap': 4,
              },
              'children': ['home-header', 'banner-1'],
            },
            'home-header': <String, dynamic>{
              'id': 'home-header',
              'type': 'homeHeader',
              'title': 'Test Home',
            },
            'banner-1': <String, dynamic>{
              'id': 'banner-1',
              'type': 'banner',
              'title': 'Banner 1',
            },
          },
        };

        final state = HomeSduiState(schema: schema, accessToken: 'test-token');
        final renderer = HomeSduiRenderer(state);

        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: Scaffold(
              body: SchemaPullToRefresh(
                fillViewport: false,
                onRefresh: () async {
                  refreshed = true;
                },
                child: Builder(
                  builder: (context) => renderer.buildComponent(context, 'home-page'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Drag down on the home-page ListView
        await tester.drag(find.byType(ListView), const Offset(0, 250));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(refreshed, isTrue, reason: 'Pull-to-refresh must trigger on iOS for scrollPage');
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Pull-to-refresh triggers on iOS with non-scrollable root via fillViewport', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        var refreshed = false;

        final schema = <String, dynamic>{
          'designTokens': <String, dynamic>{
            'colors': <String, dynamic>{
              'surface': '#151b2e',
              'textPrimary': '#ffffff',
            },
          },
          'components': <String, dynamic>{
            'banner-root': <String, dynamic>{
              'id': 'banner-root',
              'type': 'banner',
              'title': 'Static Hero Banner',
            },
          },
        };

        final state = HomeSduiState(schema: schema, accessToken: 'test-token');
        final renderer = HomeSduiRenderer(state);

        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: Scaffold(
              body: SchemaPullToRefresh(
                fillViewport: true, // Non-scrollable root gets fillViewport: true
                onRefresh: () async {
                  refreshed = true;
                },
                child: Builder(
                  builder: (context) => renderer.buildComponent(context, 'banner-root'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Drag down on the banner
        await tester.drag(find.byType(ListView), const Offset(0, 250));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(refreshed, isTrue, reason: 'Pull-to-refresh must trigger on iOS for non-scrollable root via fillViewport');
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('SchemaPullToRefresh renders Cupertino indicator on iOS platform', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: Scaffold(
              body: SchemaPullToRefresh(
                fillViewport: false,
                onRefresh: () async {
                  await Future<void>.delayed(const Duration(seconds: 2));
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  children: const [
                    SizedBox(height: 100, child: Text('List Item 1')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Start drag to bring up indicator
        final gesture = await tester.startGesture(tester.getCenter(find.text('List Item 1')));
        await gesture.moveBy(const Offset(0, 200));
        await tester.pump();

        // On iOS with RefreshIndicator.adaptive, CupertinoActivityIndicator is rendered during refresh
        expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
