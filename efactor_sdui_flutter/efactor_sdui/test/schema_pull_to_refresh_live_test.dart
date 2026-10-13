import 'package:efactor_sdui/sdui/schema_pull_to_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SchemaPullToRefresh invokes onRefresh when pulled', (
    tester,
  ) async {
    var liveFetchCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchemaPullToRefresh(
            fillViewport: true,
            onRefresh: () async {
              liveFetchCount++;
            },
            child: const Center(child: Text('schema-body')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.text('schema-body'),
      const Offset(0, 300),
      1000,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(liveFetchCount, greaterThanOrEqualTo(1));
  });

  test('runLiveRefresh always awaits the live fetch callback', () async {
    var ran = false;
    await SchemaPullToRefresh.runLiveRefresh(() async {
      ran = true;
    });
    expect(ran, isTrue);
  });

  testWidgets('pull refresh completes even when live fetch is a no-op', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchemaPullToRefresh(
            fillViewport: true,
            onRefresh: () async {},
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const <Widget>[
                SizedBox(height: 800, child: Text('tall-content')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('tall-content')),
    );
    await gesture.moveBy(const Offset(0, 250));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('tall-content'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
