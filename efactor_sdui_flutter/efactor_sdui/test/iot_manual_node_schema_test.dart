import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> loadIotSchema() {
    final raw = File('assets/iot_schema_test.json').readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final schema = json['schema'];
    expect(schema, isA<Map>());
    return Map<String, dynamic>.from(schema as Map);
  }

  test('IoT overlay declares the manual node ID prompt used by web', () {
    final schema = loadIotSchema();
    final overlay = Map<String, dynamic>.from(
      (schema['overlays'] as Map)['qrScannerModal'] as Map,
    );
    final header = Map<String, dynamic>.from(overlay['header'] as Map);
    final rightAction = Map<String, dynamic>.from(header['rightAction'] as Map);
    final onTap = Map<String, dynamic>.from(rightAction['onTap'] as Map);
    final prompt = Map<String, dynamic>.from(overlay['manualEntry'] as Map);

    expect(onTap['action'], 'openPrompt');
    expect(onTap['promptId'], 'manualNodeId');
    expect(rightAction['id'], prompt['id']);
    expect(prompt['enabled'], isTrue);
    expect(prompt['type'], 'prompt');
    expect((prompt['input'] as Map)['name'], 'node_id');
    expect((prompt['input'] as Map)['required'], isTrue);

    final connect = (prompt['actions'] as List).cast<dynamic>().firstWhere((
      raw,
    ) {
      final action = Map<String, dynamic>.from(raw as Map);
      final tap = Map<String, dynamic>.from(action['onTap'] as Map);
      return tap['action'] == 'submitNodeId';
    });
    final connectTap = Map<String, dynamic>.from(
      (connect as Map)['onTap'] as Map,
    );
    expect(connectTap['sameAsScan'], isTrue);
    expect(connectTap['flow'], <String>['checkDevice', 'addWifiNode']);
  });

  test('manual node ID copy is owned by schema, not Flutter', () {
    final schema = loadIotSchema();
    final overlay = Map<String, dynamic>.from(
      (schema['overlays'] as Map)['qrScannerModal'] as Map,
    );
    final prompt = Map<String, dynamic>.from(overlay['manualEntry'] as Map);
    final rightAction = Map<String, dynamic>.from(
      (overlay['header'] as Map)['rightAction'] as Map,
    );

    expect(rightAction['label'], isNotEmpty);
    expect(prompt['title'], isNotEmpty);
    expect(prompt['subtitle'], isNotEmpty);
    expect((prompt['input'] as Map)['placeholder'], isNotEmpty);
  });
}
