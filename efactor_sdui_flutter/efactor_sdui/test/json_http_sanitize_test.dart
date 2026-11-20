import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:efactor_sdui/services/json_http.dart';
import 'package:efactor_sdui/utils/deep_copy_json.dart';

void main() {
  group('extractJsonPayload', () {
    test('returns a clean object unchanged', () {
      const body = '{"ok":true,"n":1}';
      expect(extractJsonPayload(body), body);
      expect(jsonDecode(extractJsonPayload(body)), {'ok': true, 'n': 1});
    });

    test('returns a clean array unchanged', () {
      const body = '[{"a":1},{"b":2}]';
      expect(extractJsonPayload(body), body);
    });

    test('trims surrounding whitespace', () {
      expect(extractJsonPayload('  {"a":1}\n'), '{"a":1}');
    });

    test('strips a leading PHP warning before the object', () {
      const body =
          'PHP Warning: mail(): SMTP server failed in /x.php on line 5\n'
          '{"status":"sent"}';
      expect(jsonDecode(extractJsonPayload(body)), {'status': 'sent'});
    });

    test('strips a trailing notice after the object', () {
      const body = '{"status":"ok"}\n<br/>Notice: undefined index';
      expect(jsonDecode(extractJsonPayload(body)), {'status': 'ok'});
    });

    test('known limit: a bracket inside leading noise mis-slices but fails safe',
        () {
      // Noise contains "array[]" before the real object; the slice starts at
      // that stray '[', so the result is not valid JSON. decodeJsonBody turns
      // that into its error path — it never yields wrong data.
      const body = 'Warning: array[] dump {"status":"ok"}';
      final sliced = extractJsonPayload(body);
      expect(() => jsonDecode(sliced), throwsFormatException);
    });
  });

  group('deepCopyJson', () {
    test('produces an equal but independent deep copy', () {
      final src = {
        'a': 1,
        'b': [
          {'c': 2},
          3,
        ],
        'd': {'e': null},
      };
      final copy = deepCopyJson(src) as Map<String, dynamic>;
      expect(copy, src);
      expect(identical(copy, src), isFalse);
      expect(identical(copy['b'], src['b']), isFalse);
      // Mutating the copy must not touch the source.
      (copy['b'] as List)[1] = 99;
      expect((src['b'] as List)[1], 3);
    });

    test('coerces map keys to String like the old jsonEncode round-trip', () {
      final copy = deepCopyJson({1: 'x'}) as Map<String, dynamic>;
      expect(copy, {'1': 'x'});
    });
  });
}
