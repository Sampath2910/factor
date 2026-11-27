import 'package:efactor_sdui/services/incoming_call_service.dart';
import 'package:efactor_sdui/services/message_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Mount a MaterialApp wired to the shared navigatorKey so MessageBanner can
  // find the root overlay (as it does at runtime).
  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: IncomingCallService.instance.navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
  }

  testWidgets('shows a tappable banner and auto-dismisses after min dwell',
      (tester) async {
    await pumpHost(tester);

    var tapped = false;
    final shown = MessageBanner.instance.show(
      title: 'Alice',
      body: 'Hey there',
      onTap: () => tapped = true,
    );
    expect(shown, isTrue);
    await tester.pump();
    expect(find.text('Alice'), findsOneWidget);

    // Still visible before the dwell elapses.
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.text('Alice'), findsOneWidget);

    await tester.tap(find.text('Alice'));
    expect(tapped, isTrue);
    await tester.pump();
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('auto-dismisses after the full dwell with no interaction',
      (tester) async {
    await pumpHost(tester);
    MessageBanner.instance.show(title: 'Bob', body: 'Hi', onTap: () {});
    await tester.pump();
    expect(find.text('Bob'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2600));
    expect(find.text('Bob'), findsNothing);
  });

  testWidgets('queues a second message instead of replacing the first',
      (tester) async {
    await pumpHost(tester);

    MessageBanner.instance.show(title: 'First', body: 'a', onTap: () {});
    MessageBanner.instance.show(title: 'Second', body: 'b', onTap: () {});
    await tester.pump();

    // First keeps its slot; second is queued.
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsNothing);

    // After the first finishes its dwell, the queued one appears.
    await tester.pump(const Duration(milliseconds: 2600));
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2600));
    expect(find.text('Second'), findsNothing);
  });

  testWidgets('returns false when no overlay is mounted', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final shown =
        MessageBanner.instance.show(title: 'X', body: 'y', onTap: () {});
    expect(shown, isFalse);
  });

  testWidgets('Reply opens inline input and stops auto-dismiss', (tester) async {
    await pumpHost(tester);
    MessageBanner.instance.show(
      title: 'Alice',
      body: 'Hi',
      onTap: () {},
      onReply: (_) async {},
      onMarkRead: () async {},
      onMute: () async {},
    );
    await tester.pump();

    expect(find.text('Reply'), findsOneWidget);
    await tester.tap(find.text('Reply'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);

    // Past the full dwell, still visible because the reply box is open.
    await tester.pump(const Duration(milliseconds: 3000));
    expect(find.byType(TextField), findsOneWidget);

    // Cleanup: close reply, let the resumed dwell dismiss it.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2600));
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('Send forwards the typed text and dismisses', (tester) async {
    await pumpHost(tester);
    String? sent;
    MessageBanner.instance.show(
      title: 'Alice',
      body: 'Hi',
      onTap: () {},
      onReply: (text) async => sent = text,
    );
    await tester.pump();

    await tester.tap(find.text('Reply'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'on my way');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    await tester.pump();

    expect(sent, 'on my way');
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('Mark as read and Mute invoke their action and dismiss',
      (tester) async {
    await pumpHost(tester);
    var marked = false;
    MessageBanner.instance.show(
      title: 'Alice',
      body: 'Hi',
      onTap: () {},
      onMarkRead: () async => marked = true,
      onMute: () async {},
    );
    await tester.pump();

    await tester.tap(find.text('Mark as read'));
    await tester.pump();
    await tester.pump();

    expect(marked, isTrue);
    expect(find.text('Alice'), findsNothing);
  });
}
