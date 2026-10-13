import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/sdui/efactor_device_loader.dart';

void main() {
  testWidgets('EfactorDeviceLoader renders rotating segmented ring and center E',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: EfactorDeviceLoader(
              size: 80,
              title: 'Connecting EF-001FMN01',
              subtitle: 'Node 12345',
              statusText: 'Loading live schema...',
            ),
          ),
        ),
      ),
    );

    // Initial pump
    await tester.pump();

    // Verify text elements are rendered
    expect(find.text('Connecting EF-001FMN01'), findsOneWidget);
    expect(find.text('Node 12345'), findsOneWidget);
    expect(find.text('Loading live schema...'), findsOneWidget);

    // Advance animations
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 700));

    // Ensure CustomPaint for segmented ring is present
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('EfactorDeviceLoadingScreen renders full-screen dark loading state',
      (WidgetTester tester) async {
    bool backPressed = false;

    await tester.pumpWidget(
      EfactorDeviceLoadingScreen(
        modelId: 'EFANV1.0',
        nodeId: 'node99',
        onBack: () {
          backPressed = true;
        },
      ),
    );

    await tester.pump();

    expect(find.text('Connecting EFANV1.0'), findsOneWidget);
    expect(find.text('Node node99'), findsOneWidget);
    // Design 3 (Smart Hub) rendered for fan model
    expect(find.byType(SmartHubLoadingAnimation), findsOneWidget);
    expect(find.byType(SmartPlugLoadingAnimation), findsNothing);

    // Tap back button
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();

    expect(backPressed, isTrue);
  });

  testWidgets('EfactorDeviceLoadingScreen renders SmartPlugLoadingAnimation for socket/plug models',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const EfactorDeviceLoadingScreen(
        modelId: 'Smart Plug 16A',
        nodeId: 'plug01',
      ),
    );

    await tester.pump();

    expect(find.text('Connecting Smart Plug 16A'), findsOneWidget);
    expect(find.text('Node plug01'), findsOneWidget);
    // Design 4 (Smart Plug) rendered for socket/plug model
    expect(find.byType(SmartPlugLoadingAnimation), findsOneWidget);
    expect(find.byType(SmartHubLoadingAnimation), findsNothing);
  });

  testWidgets('MiniOrbitPageLoadingView renders in-page orbit character and headline',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MiniOrbitPageLoadingView(
              pageNo: 2,
              pageTitle: 'Timers & Schedules',
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('Preparing Page 2 Controls...'), findsOneWidget);
    expect(find.text('Timers & Schedules'), findsOneWidget);
    expect(find.byType(MiniOrbitLoadingAnimation), findsOneWidget);

    // Advance animations
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(CustomPaint), findsWidgets);
  });
}
