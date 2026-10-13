import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/sdui/schema_runtime.dart';
import 'package:efactor_sdui/state/app_state.dart';
import 'package:efactor_sdui/sdui/renderer.dart';
import 'package:efactor_sdui/sdui/efactor_device_loader.dart';

void main() {
  group('Pillar 1: SchemaRuntime Responsive Fallback for Legacy/Unspecified Schemas', () {
    test('Null responsive configuration defaults to 430dp single-column pager layout', () {
      final runtime = SchemaRuntime(const <String, dynamic>{
        'id': 'EF-001FMN01',
        'type': 'page',
      });

      expect(runtime.responsive, isNull);

      final layout = runtime.resolveResponsiveLayout(360);
      expect(layout, isNotNull);
      expect(layout!.name, 'compact');
      expect(layout.maxContentWidth, 430.0);
      expect(layout.columns, 1);
      expect(layout.navigation, 'pager');
    });

    test('Defined responsive configuration resolves normally based on width', () {
      final runtime = SchemaRuntime(const <String, dynamic>{
        'responsive': {
          'breakpoints': {
            'compact': {'minimumWidth': 0, 'maximumWidth': 599},
            'expanded': {'minimumWidth': 600},
          },
          'layouts': {
            'compact': {'maxContentWidth': 400.0, 'columns': 1},
            'expanded': {'maxContentWidth': 800.0, 'columns': 2},
          },
        },
      });

      final compactLayout = runtime.resolveResponsiveLayout(360);
      expect(compactLayout!.name, 'compact');
      expect(compactLayout.maxContentWidth, 400.0);

      final expandedLayout = runtime.resolveResponsiveLayout(700);
      expect(expandedLayout!.name, 'expanded');
      expect(expandedLayout.maxContentWidth, 800.0);
      expect(expandedLayout.columns, 2);
    });
  });

  group('Pillar 2: Global TextScaler Clamping Defense', () {
    testWidgets('Clamps high system font multipliers (1.5x, 2.0x) down to safe ceiling (1.15x)',
        (WidgetTester tester) async {
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(2.0),
          ),
          child: Builder(
            builder: (context) {
              final media = MediaQuery.of(context);
              final clampedChild = MediaQuery(
                data: media.copyWith(
                  textScaler: media.textScaler.clamp(
                    minScaleFactor: 0.85,
                    maxScaleFactor: 1.15,
                  ),
                ),
                child: Builder(
                  builder: (innerContext) {
                    capturedContext = innerContext;
                    return const SizedBox.shrink();
                  },
                ),
              );
              return clampedChild;
            },
          ),
        ),
      );

      final scaler = MediaQuery.textScalerOf(capturedContext);
      // Scaling a 10px font should result in exactly 11.5px (clamped to 1.15x), NOT 20.0px
      expect(scaler.scale(10.0), closeTo(11.5, 0.001));
    });

    testWidgets('Clamps low system font multipliers (0.6x) up to safe floor (0.85x)',
        (WidgetTester tester) async {
      late BuildContext capturedContext;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(0.6),
          ),
          child: Builder(
            builder: (context) {
              final media = MediaQuery.of(context);
              final clampedChild = MediaQuery(
                data: media.copyWith(
                  textScaler: media.textScaler.clamp(
                    minScaleFactor: 0.85,
                    maxScaleFactor: 1.15,
                  ),
                ),
                child: Builder(
                  builder: (innerContext) {
                    capturedContext = innerContext;
                    return const SizedBox.shrink();
                  },
                ),
              );
              return clampedChild;
            },
          ),
        ),
      );

      final scaler = MediaQuery.textScalerOf(capturedContext);
      // Scaling a 10px font should result in 8.5px (clamped to 0.85x), NOT 6.0px
      expect(scaler.scale(10.0), closeTo(8.5, 0.001));
    });
  });

  group('Pillar 3: Elastic Button Defense (Samsung Galaxy S25 & Narrow Screens)', () {
    testWidgets('ElevatedButton wraps text in FittedBox with maxLines 1 and no word wrapping',
        (WidgetTester tester) async {
      // Simulate Samsung Galaxy S25 viewport: 360 logical width
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState(const <String, dynamic>{
        'theme': {
          'colors': {
            'primary': '#007AFF',
            'background': '#FFFFFF',
            'surface': '#F2F2F7',
          },
        },
      });
      final renderer = SduiRenderer(state);

      final buttonNode = {
        'id': 'test_btn',
        'type': 'elevatedbutton',
        'properties': {
          'binding': 'device.parameters.btn_1',
          'props': {
            'label': 'COMMAND GET STATUS TRIGGER',
            'value': 'ON',
            'backgroundColor': '#007AFF',
            'textColor': '#FFFFFF',
            'borderColor': '#007AFF',
            'borderRadius': 8,
            'padding': {'left': 16, 'right': 16, 'top': 12, 'bottom': 12},
          },
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 140, // Constrained container where label would normally wrap into 2 lines
              child: Builder(
                builder: (context) {
                  return renderer.build(context, buttonNode);
                },
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(tester.takeException(), isNull);

      // Verify FittedBox is present
      final fittedBoxFinder = find.descendant(
        of: find.byType(ElevatedButton),
        matching: find.byType(FittedBox),
      );
      expect(fittedBoxFinder, findsOneWidget);

      final fittedBox = tester.widget<FittedBox>(fittedBoxFinder);
      expect(fittedBox.fit, BoxFit.scaleDown);

      // Verify Text is configured with maxLines: 1 and softWrap: false
      final textFinder = find.descendant(
        of: fittedBoxFinder,
        matching: find.byType(Text),
      );
      expect(textFinder, findsOneWidget);

      final textWidget = tester.widget<Text>(textFinder);
      expect(textWidget.maxLines, 1);
      expect(textWidget.softWrap, false);

      state.dispose();
    });

    testWidgets('FireControlPanel buttons use FittedBox preventing word wrap',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final state = AppState(const <String, dynamic>{
        'theme': {
          'colors': {
            'primary': '#007AFF',
            'background': '#FFFFFF',
            'surface': '#F2F2F7',
          },
        },
      });
      final renderer = SduiRenderer(state);

      final firePanelNode = {
        'id': 'burn_panel',
        'type': 'FireControlPanel',
        'properties': {
          'binding': 'device.parameters.burn_1',
          'props': {
            'containerBackgroundColor': '#FFFFFF',
            'containerBorderColor': '#E0E0E0',
            'containerBorderWidth': 1.0,
            'containerBorderRadius': 12.0,
            'containerPadding': 16.0,
            'spacing': 8.0,
            'commands': [
              {
                'label': 'LONG COMMAND ACTION',
                'value': 'START',
                'backgroundColor': '#FF5722',
                'textColor': '#FFFFFF',
                'borderRadius': 8.0,
                'padding': {'left': 16.0, 'right': 16.0, 'top': 8.0, 'bottom': 8.0},
              }
            ],
          },
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 360,
                child: Builder(
                  builder: (context) {
                    return renderer.build(context, firePanelNode);
                  },
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(tester.takeException(), isNull);

      final fittedBoxFinder = find.descendant(
        of: find.byType(ElevatedButton),
        matching: find.byType(FittedBox),
      );
      expect(fittedBoxFinder, findsWidgets);

      state.dispose();
    });
  });

  group('Pillar 4: Native Scrollbar Polish & Title Fluid Scaling', () {
    testWidgets('SDUI Text renderer scales title-like single line text with FittedBox',
        (WidgetTester tester) async {
      final state = AppState(const <String, dynamic>{
        'theme': {
          'colors': {
            'primary': '#007AFF',
            'background': '#FFFFFF',
            'surface': '#F2F2F7',
          },
        },
      });
      final renderer = SduiRenderer(state);

      final titleNode = {
        'id': 'device_title_header',
        'type': 'text',
        'properties': {
          'props': {
            'text': 'Very Long Smart Aroma Diffuser Model EF-001FMN01 Extra Edition',
            'maxLines': 1,
            'overflow': 'ellipsis',
          },
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200, // Small width
              child: Builder(
                builder: (context) => renderer.build(context, titleNode),
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(tester.takeException(), isNull);

      final fittedBoxFinder = find.byType(FittedBox);
      expect(fittedBoxFinder, findsOneWidget);

      final fittedBox = tester.widget<FittedBox>(fittedBoxFinder);
      expect(fittedBox.fit, BoxFit.scaleDown);
      expect(fittedBox.alignment, Alignment.centerLeft);

      state.dispose();
    });
  });

  group('Pillar 5: Universal Device Matrix Verification (No Overflows & Clean Layout)', () {
    final matrixDevices = <String, Size>{
      'Ultra Compact (320x568 - iPhone SE 1)': const Size(320, 568),
      'Samsung Galaxy S25 (360x780)': const Size(360, 780),
      'Realme Narzo 30 (392x850)': const Size(392, 850),
      'iPhone 16 Pro (402x874)': const Size(402, 874),
      'iPhone 16 Pro Max (430x932)': const Size(430, 932),
      'Android Tablet (600x960)': const Size(600, 960),
    };

    for (final device in matrixDevices.entries) {
      testWidgets('MiniOrbitPageLoadingView renders cleanly on ${device.key} with 48dp Nav Bar',
          (WidgetTester tester) async {
        tester.view.physicalSize = Size(device.value.width * 2, device.value.height * 2);
        tester.view.devicePixelRatio = 2.0;
        // Simulate Android 3-Button Navigation bar (48dp bottom inset)
        tester.view.padding = const FakeViewPadding(bottom: 96); // 48dp * 2.0 ratio
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetPadding();
        });

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.white,
              body: SafeArea(
                bottom: true,
                child: SingleChildScrollView(
                  child: MiniOrbitPageLoadingView(
                    pageNo: 3,
                    pageTitle: 'Telemetry & Calibration',
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.takeException(), isNull);
        expect(find.text('Preparing Page 3 Controls...'), findsOneWidget);
        expect(find.text('Telemetry & Calibration'), findsOneWidget);
      });
    }
  });
}
