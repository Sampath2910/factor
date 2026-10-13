import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/sdui/efactor_device_loader.dart';

void main() {
  final testDevices = <String, Size>{
    'iPhone SE 1st gen / Mini (320x568)': const Size(320, 568),
    'iPhone 8 / SE2 (375x667)': const Size(375, 667),
    'iPhone 15 / 16 Standard (393x852)': const Size(393, 852),
    'iPhone 15 / 16 Pro Max (430x932)': const Size(430, 932),
    'Android Small / Compact (360x740)': const Size(360, 740),
    'Android Large / Ultra (412x915)': const Size(412, 915),
    'Tablet / iPad Mini (768x1024)': const Size(768, 1024),
    'Landscape Phone (844x390)': const Size(844, 390),
    'Extreme Small Screen (320x480)': const Size(320, 480),
  };

  group('Responsive Audit: EfactorDeviceLoadingScreen across all mobile sizes', () {
    for (final entry in testDevices.entries) {
      testWidgets('Renders cleanly on ${entry.key}', (WidgetTester tester) async {
        tester.view.physicalSize = Size(entry.value.width * 2, entry.value.height * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          const MaterialApp(
            home: EfactorDeviceLoadingScreen(
              modelId: 'EF-003FMN03',
              nodeId: 'node655',
              statusText: 'Connecting to server...',
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final exception = tester.takeException();
        if (exception is FlutterError) {
          debugPrint(exception.toStringDeep());
        }
        expect(exception, isNull);
        expect(find.text('Connecting EF-003FMN03'), findsOneWidget);
        expect(find.text('Node node655'), findsOneWidget);
      });
    }
  });

  group('Responsive Audit: MiniOrbitPageLoadingView across all mobile sizes', () {
    for (final entry in testDevices.entries) {
      testWidgets('Renders cleanly on ${entry.key}', (WidgetTester tester) async {
        tester.view.physicalSize = Size(entry.value.width * 2, entry.value.height * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.white,
              body: Center(
                child: SingleChildScrollView(
                  child: MiniOrbitPageLoadingView(
                    pageNo: 2,
                    pageTitle: 'Operation & Timers',
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final exception = tester.takeException();
        if (exception != null) {
          debugPrint('CAUGHT OVERFLOW: $exception');
        }
        expect(exception, isNull);
        expect(find.text('Preparing Page 2 Controls...'), findsOneWidget);
        expect(find.text('Operation & Timers'), findsOneWidget);
      });
    }
  });

  group('Responsive Audit: High Accessibility Text Scaling (1.5x and 2.0x)', () {
    for (final scale in [1.3, 1.5, 2.0]) {
      testWidgets('Handles textScaleFactor $scale on 360x740 without error',
          (WidgetTester tester) async {
        tester.view.physicalSize = const Size(360 * 2, 740 * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 740),
              textScaler: TextScaler.linear(scale),
            ),
            child: const MaterialApp(
              home: Scaffold(
                backgroundColor: Colors.white,
                body: SingleChildScrollView(
                  child: MiniOrbitPageLoadingView(
                    pageNo: 2,
                    pageTitle: 'Operation & Timers',
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(tester.takeException(), isNull);
      });
    }
  });
}
