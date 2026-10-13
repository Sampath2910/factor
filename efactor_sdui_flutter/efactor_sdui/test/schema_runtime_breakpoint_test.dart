import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/sdui/schema_runtime.dart';

void main() {
  Map<String, dynamic> schema() => <String, dynamic>{
        'responsive': <String, dynamic>{
          'defaultBreakpoint': 'compact',
          'breakpoints': <String, dynamic>{
            'narrow': <String, dynamic>{
              'minimumWidth': 0,
              'maximumWidth': 359,
            },
            'compact': <String, dynamic>{
              'minimumWidth': 360,
              'maximumWidth': 599,
            },
            'medium': <String, dynamic>{
              'minimumWidth': 600,
              'maximumWidth': 1023,
            },
            'expanded': <String, dynamic>{
              'minimumWidth': 1024,
            },
          },
        },
      };

  test('small phones select the schema narrow breakpoint', () {
    final runtime = SchemaRuntime(schema());
    expect(runtime.resolveBreakpointName(320), 'narrow');
    expect(runtime.resolveBreakpointName(359), 'narrow');
  });

  test('standard phones select compact', () {
    final runtime = SchemaRuntime(schema());
    expect(runtime.resolveBreakpointName(360), 'compact');
    expect(runtime.resolveBreakpointName(414), 'compact');
  });

  test('phones below every minimumWidth still get the smallest layout', () {
    final runtime = SchemaRuntime(<String, dynamic>{
      'responsive': <String, dynamic>{
        'breakpoints': <String, dynamic>{
          'compact': <String, dynamic>{
            'minimumWidth': 360,
            'maximumWidth': 599,
          },
          'medium': <String, dynamic>{
            'minimumWidth': 600,
          },
        },
      },
    });
    expect(runtime.resolveBreakpointName(320), 'compact');
  });
}
