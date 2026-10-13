import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

Future<void> main() async {
  final client = http.Client();
  final report = <String, dynamic>{};

  print('=== STARTING LIVE SCHEMA FETCH & RESPONSIVENESS AUDIT ===\n');

  // 1. Auth Schema
  await auditEndpoint(
    client: client,
    name: 'Auth Schema',
    url: 'https://efactor.tech/v8/api_auth_schema.php',
    report: report,
    extractSchema: (data) => data['schema'] ?? data['data']?['schema'] ?? data,
  );

  // 2. Home Schema
  await auditEndpoint(
    client: client,
    name: 'Home Schema (user_id=655)',
    url: 'https://efactor.tech/v8/api_creation.php?action=get_schema&user_id=655',
    report: report,
    extractSchema: (data) => data['schema'] ?? data,
  );

  // 3. Grid Schema
  await auditEndpoint(
    client: client,
    name: 'Grid Schema (user_id=655)',
    url: 'https://efactor.tech/v8/grid_api_creation.php?action=get_grid&user_id=655',
    report: report,
    extractSchema: (data) => data['schema'] ?? data['content'] ?? data,
  );

  // 4. Device Schemas (multiple live models)
  final models = ['EFANV1.0', 'EF-001FMN01', 'EF Touch Switch_C6- 10SW', 'nireeModal1'];
  for (final model in models) {
    await auditEndpoint(
      client: client,
      name: 'Device Schema ($model)',
      url: 'https://efactor.tech/v8/api_schema.php?model_no=${Uri.encodeComponent(model)}',
      report: report,
      extractSchema: (data) {
        final schemaJson = data['data']?['schema_json'] ?? data['schema_json'] ?? data['schema'];
        if (schemaJson is String) {
          try {
            return jsonDecode(schemaJson);
          } catch (_) {}
        }
        return schemaJson ?? data;
      },
    );
  }

  // 5. Check if we can get a login token to test IoT schema
  print('\n--- Testing Authentication for IoT Schema ---');
  String? token;
  try {
    // Check if there is an auth endpoint in the fetched Auth Schema
    final authSchema = report['Auth Schema']?['extracted'];
    String loginUrl = 'https://efactor.tech/v8/api_auth.php?action=login';
    if (authSchema is Map && authSchema['actions'] is Map) {
      final loginAction = (authSchema['actions'] as Map)['submitLogin'];
      if (loginAction is Map && loginAction['url'] != null) {
        loginUrl = loginAction['url'].toString();
      }
    }
    print('Auth submitLogin URL: $loginUrl');
  } catch (e) {
    print('Error finding login action: $e');
  }

  // Save report to disk for inspection
  final outputFile = File('tool/live_schema_audit_result.json');
  outputFile.writeAsStringSync(jsonEncode(report));
  print('\nAudit raw data written to ${outputFile.path}');

  client.close();
}

Future<void> auditEndpoint({
  required http.Client client,
  required String name,
  required String url,
  required Map<String, dynamic> report,
  required dynamic Function(Map<String, dynamic>) extractSchema,
  Map<String, String>? headers,
}) async {
  print('Fetching $name from: $url');
  try {
    final response = await client.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 15));
    print('  Status: ${response.statusCode} (${response.bodyBytes.length} bytes)');

    if (response.statusCode != 200) {
      report[name] = {
        'status': response.statusCode,
        'error': response.body,
      };
      return;
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      report[name] = {
        'status': response.statusCode,
        'error': 'Response was not a JSON object',
      };
      return;
    }

    final schema = extractSchema(decoded);
    final schemaMap = schema is Map<String, dynamic> ? schema : <String, dynamic>{};

    final audit = analyzeSchemaDynamicsAndResponsiveness(name, schemaMap);
    report[name] = {
      'status': response.statusCode,
      'schemaSummary': audit,
      'extracted': schemaMap,
    };

    print('  Analyzed $name successfully:');
    print('    - Dynamic features: ${audit['dynamicFeatures']}');
    print('    - Responsive features: ${audit['responsiveFeatures']}');
    print('    - Breakpoints declared: ${audit['breakpoints']}');
    print('    - Page/Screen count: ${audit['pageCount']}');
    print('    - Actions declared: ${audit['actionCount']}');
    print('    - Bindings/State keys: ${audit['stateKeyCount']}');
  } catch (e, stack) {
    print('  FAILED $name: $e');
    report[name] = {
      'error': e.toString(),
      'stack': stack.toString(),
    };
  }
}

Map<String, dynamic> analyzeSchemaDynamicsAndResponsiveness(String name, Map<String, dynamic> schema) {
  final dynamicFeatures = <String>[];
  final responsiveFeatures = <String>[];
  final breakpoints = <String>[];
  var pageCount = 0;
  var actionCount = 0;
  var stateKeyCount = 0;

  // Check Schema metadata & versioning
  if (schema.containsKey('schemaVersion') || schema.containsKey('version')) {
    dynamicFeatures.add('versioned-schema (${schema['schemaVersion'] ?? schema['version']})');
  }
  if (schema.containsKey('contentHash') || schema.containsKey('schema_hash')) {
    dynamicFeatures.add('hash-fingerprinted');
  }

  // Check dynamic pages/screens
  final pages = schema['pages'] ?? schema['screens'] ?? schema['tabs'] ?? schema['views'];
  if (pages is Map) {
    pageCount = pages.length;
    dynamicFeatures.add('multi-page dynamic map (${pages.length} pages)');
  } else if (pages is List) {
    pageCount = pages.length;
    dynamicFeatures.add('multi-page dynamic list (${pages.length} pages)');
  }

  // Check dynamic actions & events
  final actions = schema['actions'] ?? schema['events'] ?? schema['handlers'];
  if (actions is Map) {
    actionCount = actions.length;
    dynamicFeatures.add('dynamic action registry (${actions.length} actions)');
  } else if (actions is List) {
    actionCount = actions.length;
    dynamicFeatures.add('dynamic action list (${actions.length} actions)');
  }

  // Check dynamic state / bindings
  final state = schema['state'] ?? schema['initialState'] ?? schema['dataBinding'];
  if (state is Map) {
    stateKeyCount = state.length;
    dynamicFeatures.add('dynamic reactive state store (${state.length} keys)');
  }

  // Check dynamic validation rules
  if (schema.containsKey('validationRules') || schema.containsKey('validation')) {
    dynamicFeatures.add('schema-driven validation rules');
  }

  // Check dynamic design tokens / theme
  final theme = schema['theme'] ?? schema['designSystem'] ?? schema['styles'];
  if (theme is Map) {
    dynamicFeatures.add('centralized dynamic theme/token system');
  }

  // Check RESPONSIVENESS
  // 1. Explicit responsive block
  if (schema.containsKey('responsive')) {
    responsiveFeatures.add('top-level "responsive" declaration');
    final resp = schema['responsive'];
    if (resp is Map) {
      if (resp['breakpoints'] != null) {
        responsiveFeatures.add('responsive.breakpoints declared');
        breakpoints.add(resp['breakpoints'].toString());
      }
      if (resp['dimensionPolicy'] != null) {
        responsiveFeatures.add('dimensionPolicy: ${resp['dimensionPolicy']}');
      }
      if (resp['unit'] != null) {
        responsiveFeatures.add('unit: ${resp['unit']}');
      }
    }
  }

  // 2. Design system breakpoints
  if (theme is Map) {
    if (theme.containsKey('breakpoints')) {
      responsiveFeatures.add('designSystem.breakpoints declared');
      breakpoints.add(theme['breakpoints'].toString());
    }
    if (theme.containsKey('layoutGrid') || theme.containsKey('grid')) {
      responsiveFeatures.add('dynamic grid layout system');
    }
  }

  // 3. Recursive inspection for responsive properties across components
  var flexCount = 0;
  var breakpointStyleCount = 0;
  var clampCount = 0;
  var percentageWidthCount = 0;
  var fixedDimensionCount = 0;

  void inspectNode(dynamic node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString();
        final value = entry.value;

        if (key == 'breakpoints' || key == 'breakpointStyles') {
          breakpointStyleCount++;
        }
        if (key == 'flex' || key == 'expanded') {
          flexCount++;
        }
        if (key == 'width' || key == 'height') {
          final str = value.toString().trim();
          if (str.endsWith('%') || str == 'match_parent' || str == 'wrap_content' || str == 'auto') {
            percentageWidthCount++;
          } else if (num.tryParse(str) != null) {
            fixedDimensionCount++;
          }
        }
        if (value is String && (value.contains('clamp') || value.contains('min(') || value.contains('max('))) {
          clampCount++;
        }
        inspectNode(value);
      }
    } else if (node is List) {
      for (final item in node) {
        inspectNode(item);
      }
    }
  }

  inspectNode(schema);

  if (flexCount > 0) responsiveFeatures.add('flex/expanded layout count: $flexCount');
  if (breakpointStyleCount > 0) responsiveFeatures.add('component breakpoint overrides: $breakpointStyleCount');
  if (percentageWidthCount > 0) responsiveFeatures.add('fluid/percentage dimensions: $percentageWidthCount');
  if (clampCount > 0) responsiveFeatures.add('clamped expressions: $clampCount');
  if (fixedDimensionCount > 0) responsiveFeatures.add('fixed numeric dimensions: $fixedDimensionCount');

  return {
    'dynamicFeatures': dynamicFeatures,
    'responsiveFeatures': responsiveFeatures,
    'breakpoints': breakpoints,
    'pageCount': pageCount,
    'actionCount': actionCount,
    'stateKeyCount': stateKeyCount,
    'counts': {
      'flex': flexCount,
      'breakpointStyles': breakpointStyleCount,
      'percentageWidth': percentageWidthCount,
      'clamp': clampCount,
      'fixedDimension': fixedDimensionCount,
    }
  };
}
