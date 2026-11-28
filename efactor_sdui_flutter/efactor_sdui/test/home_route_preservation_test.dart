import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';

// Guards the fix for Circle Connect being ejected to Home on a live schema
// refresh: a rebuilt HomeSduiState must be able to restore the route the user
// was on instead of snapping back to the schema's initialRouteId.
void main() {
  HomeSduiState buildState() => HomeSduiState(
        schema: <String, dynamic>{
          'state': <String, dynamic>{},
          'components': <String, dynamic>{},
          'routes': <String, dynamic>{
            'home': <String, dynamic>{'title': 'Home'},
            'circle': <String, dynamic>{'title': 'Circle Connect'},
          },
          'pages': <String, dynamic>{},
          'navigation': <String, dynamic>{'initialRouteId': 'home'},
        },
        accessToken: 'token',
      );

  test('fresh state defaults to the schema initialRouteId', () {
    expect(buildState().activeRouteId, 'home');
  });

  test('restoreActiveRoute keeps the user on their current section', () {
    final state = buildState();
    state.restoreActiveRoute('circle');
    expect(state.activeRouteId, 'circle');
    expect(state.readState('navigation.activeRouteId'), 'circle');
  });

  test('restoreActiveRoute is a no-op for a route removed from the schema', () {
    final state = buildState();
    state.restoreActiveRoute('deleted-route');
    expect(state.activeRouteId, 'home'); // falls back to default
  });
}
