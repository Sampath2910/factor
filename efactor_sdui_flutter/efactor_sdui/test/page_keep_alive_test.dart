import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Page slider keep alive preserves page state when scrolled',
      (tester) async {
    int buildCountPage1 = 0;
    int buildCountPage2 = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView(
            children: [
              _TestKeepAlive(
                builder: () {
                  buildCountPage1++;
                  return const Text('Page 1 Content');
                },
              ),
              _TestKeepAlive(
                builder: () {
                  buildCountPage2++;
                  return const Text('Page 2 Content');
                },
              ),
            ],
          ),
        ),
      ),
    );

    // Initial build: Page 1 is built
    expect(find.text('Page 1 Content'), findsOneWidget);
    expect(buildCountPage1, 1);

    // Swipe to Page 2
    await tester.drag(find.byType(PageView), const Offset(-800, 0));
    await tester.pumpAndSettle();

    expect(find.text('Page 2 Content'), findsOneWidget);
    expect(buildCountPage2, 1);

    // Swipe back to Page 1
    await tester.drag(find.byType(PageView), const Offset(800, 0));
    await tester.pumpAndSettle();

    expect(find.text('Page 1 Content'), findsOneWidget);
    // Because keep alive is active, Page 1 was NOT rebuilt from scratch!
    expect(buildCountPage1, 1);
  });
}

class _TestKeepAlive extends StatefulWidget {
  const _TestKeepAlive({required this.builder});
  final Widget Function() builder;

  @override
  State<_TestKeepAlive> createState() => _TestKeepAliveState();
}

class _TestKeepAliveState extends State<_TestKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.builder();
  }
}
