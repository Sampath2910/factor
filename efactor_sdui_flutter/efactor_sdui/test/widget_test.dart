import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/state/app_state.dart';

void main() {
  final schema = <String, dynamic>{
    'state': {
      'activePageIndex': 0,
      'device': {
        'parameters': {'1_': false}
      }
    },
    'pages': [
      {'id': 'page_1', 'pageNo': '1', 'title': 'home.test', 'subtitle': 'Page 1.Operation'}
    ],
    'controls': <dynamic>[],
  };

  test('binding resolves and updates device parameter', () {
    final state = AppState(schema);
    expect(state.resolveBinding('device.parameters.1_'), false);
    state.setBinding('device.parameters.1_', true);
    expect(state.resolveBinding('device.parameters.1_'), true);
    expect(state.resolveBinding('state.activePageName'), 'home.test');
  });

  test('pager expressions clamp correctly', () {
    final state = AppState(schema);
    state.runExpression('activePageIndex=min(activePageIndex+1,pages.length-1)');
    expect(state.activePageIndex, 0); // only one page, stays clamped
    state.runExpression('activePageIndex=max(activePageIndex-1,0)');
    expect(state.activePageIndex, 0);
  });
}
