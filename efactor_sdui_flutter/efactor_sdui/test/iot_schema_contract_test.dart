import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled IoT schema preserves the server contract', () {
    final raw = File('assets/iot_ui_schema.json').readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final schema = json.containsKey('schema') && json['schema'] is Map
        ? Map<String, dynamic>.from(json['schema'] as Map)
        : json;

    expect(schema['kind'], 'efactor.iot.sdui.dashboard');
    expect(schema['schemaVersion'], '2.2.1');
    expect(schema.containsKey('layout'), isTrue);
    expect(schema.containsKey('auth'), isTrue);
  });
}
