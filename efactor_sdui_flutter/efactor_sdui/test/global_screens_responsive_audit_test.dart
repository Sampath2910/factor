import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/auth_sdui/auth_renderer.dart';
import 'package:efactor_sdui/auth_sdui/auth_state.dart';
import 'package:efactor_sdui/home_sdui/home_metro_grid.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_renderer.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';
import 'package:efactor_sdui/sdui/efactor_device_loader.dart';
import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/state/app_state.dart';

class DeviceArchetype {
  const DeviceArchetype({
    required this.name,
    required this.category,
    required this.size,
    required this.devicePixelRatio,
    this.bottomInset = 0.0,
    this.textScale = 1.0,
  });

  final String name;
  final String category;
  final Size size;
  final double devicePixelRatio;
  final double bottomInset;
  final double textScale;
}

final globalDeviceArchetypes = <DeviceArchetype>[
  // Category 1: Ultra-Compact & Budget Entry (320dp - 359dp)
  const DeviceArchetype(
    name: 'iPhone SE 1 / Android Go',
    category: 'Category 1: Ultra-Compact',
    size: Size(320, 568),
    devicePixelRatio: 2.0,
  ),
  // Category 2: Modern Compact Flagships (Samsung Galaxy S25 / S24 / Pixel 4a)
  const DeviceArchetype(
    name: 'Samsung Galaxy S25 (360x780)',
    category: 'Category 2: Modern Compact Flagships',
    size: Size(360, 780),
    devicePixelRatio: 3.0,
    textScale: 1.15,
  ),
  // Category 3: Mainstream Standard Viewports (Realme Narzo 30 / iPhone 16) with 3-Button Nav Bar
  const DeviceArchetype(
    name: 'Realme Narzo 30 (392x850 + 3-Button Nav)',
    category: 'Category 3: Mainstream Standard Viewports',
    size: Size(392, 850),
    devicePixelRatio: 2.75,
    bottomInset: 48.0,
    textScale: 1.15,
  ),
  // Category 4: Large / Plus / Pro Max Devices (iPhone 16 Pro Max / S25 Ultra)
  const DeviceArchetype(
    name: 'iPhone 16 Pro Max (430x932)',
    category: 'Category 4: Large / Plus / Pro Max',
    size: Size(430, 932),
    devicePixelRatio: 3.0,
  ),
  // Category 5: Foldables & Compact Tablets (600dp - 768dp)
  const DeviceArchetype(
    name: 'Android Tablet / Z Fold Inner (600x960)',
    category: 'Category 5: Foldables & Compact Tablets',
    size: Size(600, 960),
    devicePixelRatio: 2.0,
  ),
  // Category 6: Accessibility Stress Axis (1.30x Font Zoom + 3-Button Nav Bar)
  const DeviceArchetype(
    name: 'Accessibility Stress Phone (360x740, 1.30x Zoom, 48dp Nav)',
    category: 'Category 6: Accessibility Stress Axis',
    size: Size(360, 740),
    devicePixelRatio: 2.5,
    bottomInset: 48.0,
    textScale: 1.30,
  ),
];

Map<String, dynamic> _loadJson(String path) {
  final file = File(path);
  if (!file.existsSync()) return <String, dynamic>{};
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is Map<String, dynamic>) {
    if (decoded.containsKey('schema') && decoded['schema'] is Map) {
      return Map<String, dynamic>.from(decoded['schema'] as Map);
    }
    return decoded;
  }
  return <String, dynamic>{};
}

Widget _wrapWithDevice(
  Widget child,
  DeviceArchetype device,
  WidgetTester tester,
) {
  tester.view.physicalSize = Size(
    device.size.width * device.devicePixelRatio,
    device.size.height * device.devicePixelRatio,
  );
  tester.view.devicePixelRatio = device.devicePixelRatio;
  if (device.bottomInset > 0) {
    tester.view.padding = FakeViewPadding(
      bottom: device.bottomInset * device.devicePixelRatio,
    );
  }

  return MediaQuery(
    data: MediaQueryData(
      size: device.size,
      padding: EdgeInsets.only(bottom: device.bottomInset),
      textScaler: TextScaler.linear(device.textScale),
    ),
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          bottom: true,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─────────────────────────────────────────────────────────────
  // 1. AUTH SCREENS AUDIT (Welcome, Login, Signup, ForgotPassword)
  // ─────────────────────────────────────────────────────────────
  group('Global Screen Audit: Authentication Screens across 6 Archetypes', () {
    final authSchema = _loadJson('assets/auth_ui_schema.json');
    final authPages = <String>['welcome', 'login', 'signup', 'forgotPassword'];

    for (final pageId in authPages) {
      for (final device in globalDeviceArchetypes) {
        testWidgets('Auth screen "$pageId" on ${device.name}', (WidgetTester tester) async {
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetPadding();
          });

          final pageSchema = Map<String, dynamic>.from(authSchema);
          final app = Map<String, dynamic>.from(pageSchema['app'] as Map? ?? {});
          app['initialPageId'] = pageId;
          pageSchema['app'] = app;

          final authState = AuthState(pageSchema);
          final renderer = AuthRenderer(authState);

          await tester.pumpWidget(
            _wrapWithDevice(
              Builder(builder: (context) => renderer.build(context)),
              device,
              tester,
            ),
          );

          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(tester.takeException(), isNull,
              reason: 'Auth page $pageId must render without errors on ${device.name}');
        });
      }
    }
  });

  // ─────────────────────────────────────────────────────────────
  // 2. HOME & PROFILE SCREENS AUDIT
  // ─────────────────────────────────────────────────────────────
  group('Global Screen Audit: Home & Profile Screens across 6 Archetypes', () {
    final homeJson = _loadJson('assets/home_ui_schema.json');

    for (final device in globalDeviceArchetypes) {
      testWidgets('Home Profile Page on ${device.name}', (WidgetTester tester) async {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetPadding();
        });

        final state = HomeSduiState(
          schema: homeJson,
          accessToken: 'test_token',
          userId: 655,
          email: 'user@efactor.app',
          username: 'efactor_user',
        );

        final renderer = HomeSduiRenderer(state);

        await tester.pumpWidget(
          _wrapWithDevice(
            Builder(
              builder: (context) => renderer.buildComponent(context, 'profile-page'),
            ),
            device,
            tester,
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(tester.takeException(), isNull,
            reason: 'Profile page must render cleanly on ${device.name}');
      });

      testWidgets('Home Metro Grid responsive coordinates on ${device.name}', (WidgetTester tester) async {
        final items = const <HomeMetroItem>[
          HomeMetroItem(id: 'device1', columnSpan: 3, rowSpan: 2, columnStart: 1, rowStart: 1),
          HomeMetroItem(id: 'device2', columnSpan: 3, rowSpan: 2, columnStart: 4, rowStart: 1),
          HomeMetroItem(id: 'device3', columnSpan: 6, rowSpan: 2, columnStart: 1, rowStart: 3),
        ];

        final placed = placeHomeMetroGrid(
          columns: 6,
          clampColumnSpan: true,
          items: items,
        );

        expect(placed.length, 3);
        // Verify no placement exceeds the 6-column grid boundary
        for (final p in placed) {
          expect(p.column + p.columnSpan - 1, lessThanOrEqualTo(6));
        }
      });
    }
  });

  // ─────────────────────────────────────────────────────────────
  // 3. PRODUCTION DEVICE MODELS AUDIT (EF-001FMN01, EFANV1.0, nireeModal1)
  // ─────────────────────────────────────────────────────────────
  group('Global Screen Audit: Live Device Schemas across 6 Archetypes', () {
    final auditFile = File('tool/live_schema_audit_result.json');
    if (!auditFile.existsSync()) return;

    final auditJson = jsonDecode(auditFile.readAsStringSync()) as Map<String, dynamic>;

    final modelKeys = [
      'Device Schema (EF-001FMN01)',
      'Device Schema (EFANV1.0)',
      'Device Schema (nireeModal1)',
    ];

    for (final modelKey in modelKeys) {
      final modelData = auditJson[modelKey] as Map<String, dynamic>?;
      if (modelData == null || modelData['extracted'] == null) continue;

      final schema = modelData['extracted'] as Map<String, dynamic>;
      final pagesRaw = schema['pages'];
      if (pagesRaw is! List || pagesRaw.isEmpty) continue;

      final pages = pagesRaw.cast<Map<String, dynamic>>();

      for (var pageIdx = 0; pageIdx < pages.length; pageIdx++) {
        final page = pages[pageIdx];
        final pageTitle = page['title'] ?? 'Page ${pageIdx + 1}';

        for (final device in globalDeviceArchetypes) {
          testWidgets('$modelKey - $pageTitle on ${device.name}', (WidgetTester tester) async {
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetPadding();
            });

            final state = AppState(schema);
            final renderer = SduiRenderer(state);

            await tester.pumpWidget(
              _wrapWithDevice(
                SingleChildScrollView(
                  child: Builder(
                    builder: (context) => renderer.build(context, page),
                  ),
                ),
                device,
                tester,
              ),
            );

            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));

            expect(tester.takeException(), isNull,
                reason: '$modelKey $pageTitle must render cleanly on ${device.name}');

            state.dispose();
          });
        }
      }
    }
  });

  // ─────────────────────────────────────────────────────────────
  // 4. TRANSITION & LOADING VIEWS AUDIT
  // ─────────────────────────────────────────────────────────────
  group('Global Screen Audit: State Overlays & Loading Views across 6 Archetypes', () {
    for (final device in globalDeviceArchetypes) {
      testWidgets('EfactorDeviceLoadingScreen on ${device.name}', (WidgetTester tester) async {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetPadding();
        });

        await tester.pumpWidget(
          _wrapWithDevice(
            const EfactorDeviceLoadingScreen(
              modelId: 'EF-001FMN01',
              nodeId: 'node-living-room',
              statusText: 'Connecting to Cloud Device...',
            ),
            device,
            tester,
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull,
            reason: 'Device loading screen must render cleanly on ${device.name}');
      });

      testWidgets('MiniOrbitPageLoadingView on ${device.name}', (WidgetTester tester) async {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetPadding();
        });

        await tester.pumpWidget(
          _wrapWithDevice(
            const SingleChildScrollView(
              child: MiniOrbitPageLoadingView(
                pageNo: 2,
                pageTitle: 'Tuning & Settings',
              ),
            ),
            device,
            tester,
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull,
            reason: 'MiniOrbitPageLoadingView must render cleanly on ${device.name}');
      });
    }
  });
}
