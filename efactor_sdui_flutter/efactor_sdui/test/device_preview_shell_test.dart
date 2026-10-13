import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/utils/device_preview_shell.dart';

void main() {
  testWidgets('DevicePreviewShell renders native child and can switch presets', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DevicePreviewShell(
          child: Scaffold(
            body: Center(
              child: Text('Live App Content'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Live App Content'), findsOneWidget);
    expect(find.text('Native Device'), findsOneWidget);

    // Tap quick switch pill to open drawer
    await tester.tap(find.text('Native Device'));
    await tester.pumpAndSettle();

    expect(find.text('📱 Universal Device Switcher'), findsOneWidget);
    expect(find.text('S25 (360p)'), findsOneWidget);
    expect(find.text('Narzo 30 (392p)'), findsOneWidget);

    // Switch to Samsung Galaxy S25
    await tester.tap(find.text('S25 (360p)'));
    await tester.pumpAndSettle();

    // Verify S25 simulated frame and nav bar are active
    expect(find.textContaining('S25 (360p)'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget); // 3-Button simulated nav bar
    expect(find.text('Live App Content'), findsOneWidget);
  });
}
