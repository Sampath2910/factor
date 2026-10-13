import 'package:efactor_sdui/grid_sdui/grid_web_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot strips scripts and ignores the query string', () {
    final html = GridWebSnapshot.stripScripts(
      '<html><body><h1>Space</h1><script>fetch("/live")</script></body></html>',
    );
    expect(html.contains('<script'), isFalse);
    expect(html.contains('Space'), isTrue);

    final a = GridWebSnapshot.fileNameFor(
      Uri.parse('https://example.com/space?sso=1'),
    );
    final b = GridWebSnapshot.fileNameFor(
      Uri.parse('https://example.com/space?sso=2'),
    );
    expect(a, b);
  });
}
