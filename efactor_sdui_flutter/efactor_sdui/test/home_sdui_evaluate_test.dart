import 'package:flutter_test/flutter_test.dart';

import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';

void main() {
  test('compact state-equals visibleWhen matches the web Home schema', () {
    final state = HomeSduiState(
      schema: <String, dynamic>{
        'state': <String, dynamic>{
          'preferences': <String, dynamic>{
            'showWelcome': true,
            'showAlerts': false,
          },
        },
        'components': <String, dynamic>{},
        'routes': <String, dynamic>{},
        'pages': <String, dynamic>{},
        'navigation': <String, dynamic>{'items': <dynamic>[]},
      },
      accessToken: 'token',
    );

    expect(
      state.evaluate(<String, dynamic>{
        r'$state': 'preferences.showWelcome',
        'equals': true,
      }),
      isTrue,
    );
    expect(
      state.evaluate(<String, dynamic>{
        r'$state': 'preferences.showAlerts',
        'equals': true,
      }),
      isFalse,
    );
  });

  test('home page children gated by false preferences stay hidden', () {
    final state = HomeSduiState(
      schema: <String, dynamic>{
        'state': <String, dynamic>{
          'preferences': <String, dynamic>{
            'showWelcome': false,
            'showAlerts': false,
          },
        },
        'components': <String, dynamic>{
          'home-page': <String, dynamic>{
            'id': 'home-page',
            'type': 'scrollPage',
            'children': <String>['welcome-banner', 'alerts-summary'],
          },
          'welcome-banner': <String, dynamic>{
            'id': 'welcome-banner',
            'type': 'banner',
            'visibleWhen': <String, dynamic>{
              r'$state': 'preferences.showWelcome',
              'equals': true,
            },
          },
          'alerts-summary': <String, dynamic>{
            'id': 'alerts-summary',
            'type': 'summaryBanner',
            'visibleWhen': <String, dynamic>{
              r'$state': 'preferences.showAlerts',
              'equals': true,
            },
          },
        },
        'routes': <String, dynamic>{},
        'pages': <String, dynamic>{},
        'navigation': <String, dynamic>{'items': <dynamic>[]},
      },
      accessToken: 'token',
    );

    expect(state.readState('preferences.showWelcome'), isFalse);
    expect(state.readState('preferences.showAlerts'), isFalse);
    expect(
      state.evaluate(<String, dynamic>{
        r'$state': 'preferences.showWelcome',
        'equals': true,
      }),
      isFalse,
    );
  });

  test('does not invent profile chrome when the live page only has a header', () {
    final state = HomeSduiState(
      schema: <String, dynamic>{
        'state': <String, dynamic>{},
        'navigation': <String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{
              'slot': 'profile',
              'iconToken': 'profile',
              'routeId': 'profile',
            },
          ],
        },
        'routes': <String, dynamic>{
          'profile': <String, dynamic>{'pageId': 'profile'},
        },
        'pages': <String, dynamic>{
          'profile': <String, dynamic>{
            'id': 'profile',
            'routeId': 'profile',
            'rootComponentId': 'profile-page',
          },
        },
        'components': <String, dynamic>{
          'profile-page': <String, dynamic>{
            'id': 'profile-page',
            'type': 'scrollPage',
            'children': <String>['profile-page-header'],
          },
          'profile-page-header': <String, dynamic>{
            'id': 'profile-page-header',
            'type': 'pageHeader',
            'title': 'Profile',
          },
        },
      },
      accessToken: 'token',
      userId: 655,
      email: 'user@example.com',
      username: 'user',
    );

    final page = state.component('profile-page');
    final children = page?['children'] as List<dynamic>;
    expect(children, <String>['profile-page-header']);
    expect(state.component('host-profile-header'), isNull);
    expect(state.component('host-profile-menu'), isNull);
    expect(state.component('host-profile-logout'), isNull);
  });

  Map<String, dynamic> _shellSchema() {
    return <String, dynamic>{
      'state': <String, dynamic>{
        'navigation': <String, dynamic>{'activeRouteId': 'home'},
      },
      'appShell': <String, dynamic>{
        'persistent': true,
        'persistAcrossRoutes': true,
        'replaceOnNestedSchema': false,
        'bottomNavigationComponentId': 'main-bottom-navigation',
        'visibleOnRouteIds': <String>['home', 'devices', 'grid', 'profile'],
        'hideOnRouteIds': <String>['login'],
      },
      'navigation': <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'id': 'nav-home',
            'label': 'Home',
            'routeId': 'home',
            'actionId': 'navigate-home',
          },
          <String, dynamic>{
            'id': 'nav-devices',
            'label': 'IoT',
            'routeId': 'devices',
            'actionId': 'navigate-devices',
          },
          <String, dynamic>{
            'id': 'nav-grid',
            'label': 'Grid',
            'routeId': 'grid',
            'actionId': 'navigate-grid',
          },
          <String, dynamic>{
            'id': 'nav-profile',
            'label': 'Profile',
            'routeId': 'profile',
            'actionId': 'navigate-profile',
          },
        ],
      },
      'actionRegistry': <String, dynamic>{
        'navigate-home': <String, dynamic>{
          'type': 'navigate',
          'destination': <String, dynamic>{'routeId': 'home'},
        },
        'navigate-devices': <String, dynamic>{
          'type': 'host-action',
          'actionId': 'open-iot',
        },
        'navigate-grid': <String, dynamic>{
          'type': 'navigate',
          'destination': <String, dynamic>{'routeId': 'grid'},
        },
        'navigate-profile': <String, dynamic>{
          'type': 'navigate',
          'destination': <String, dynamic>{'routeId': 'profile'},
        },
        'open-grid-module': <String, dynamic>{
          'type': 'navigate',
          'destination': <String, dynamic>{'routeId': 'grid-details'},
        },
      },
      'routes': <String, dynamic>{
        'home': <String, dynamic>{'pageId': 'home'},
        'devices': <String, dynamic>{'pageId': 'devices'},
        'grid': <String, dynamic>{'pageId': 'grid'},
        'profile': <String, dynamic>{'pageId': 'profile'},
        'grid-details': <String, dynamic>{'pageId': 'grid-details'},
      },
      'pages': <String, dynamic>{
        'home': <String, dynamic>{
          'rootComponentId': 'home-page',
          'usesAppShell': true,
          'keepBottomNavigation': true,
        },
        'devices': <String, dynamic>{
          'rootComponentId': 'devices-page',
          'usesAppShell': true,
          'keepBottomNavigation': true,
        },
        'grid': <String, dynamic>{
          'rootComponentId': 'grid-page',
          'dataSourceId': 'grid',
          'usesAppShell': true,
          'keepBottomNavigation': true,
        },
        'profile': <String, dynamic>{
          'rootComponentId': 'profile-page',
          'usesAppShell': true,
          'keepBottomNavigation': true,
        },
        'grid-details': <String, dynamic>{
          'rootComponentId': 'grid-details-page',
          'usesAppShell': true,
          'keepBottomNavigation': true,
        },
      },
      'components': <String, dynamic>{
        'home-page': <String, dynamic>{'id': 'home-page', 'type': 'scrollPage'},
        'devices-page': <String, dynamic>{
          'id': 'devices-page',
          'type': 'scrollPage',
        },
        'grid-page': <String, dynamic>{
          'id': 'grid-page',
          'type': 'scrollPage',
          'style': 'gridNetwork',
          'dataSourceId': 'grid',
          'children': <dynamic>[],
        },
        'profile-page': <String, dynamic>{
          'id': 'profile-page',
          'type': 'scrollPage',
        },
        'grid-details-page': <String, dynamic>{
          'id': 'grid-details-page',
          'type': 'scrollPage',
        },
      },
    };
  }

  test('Home shell keeps Grid in-route instead of replacing the host', () async {
    var hostOpenedGrid = false;
    final state = HomeSduiState(
      schema: _shellSchema(),
      accessToken: 'token',
    );
    state.hostActionHandler = (actionId, action) async {
      if (actionId == 'open-grid') hostOpenedGrid = true;
    };

    await state.navigate('grid');

    expect(hostOpenedGrid, isFalse);
    expect(state.activeRouteId, 'grid');
    expect(state.replaceOnNestedSchema, isFalse);
    expect(state.shouldEmbedLiveGrid(), isTrue);
    expect(state.shouldShowBottomNavigation(), isTrue);
    expect(state.shouldEmbedLiveIot(), isFalse);
  });

  test('IoT tab is a nested host route that keeps the Home bottom bar', () {
    final state = HomeSduiState(
      schema: _shellSchema(),
      accessToken: 'token',
    );

    expect(state.routeIdForHostAction('open-iot'), 'devices');
    expect(state.shouldEmbedLiveIot('devices'), isTrue);
    expect(state.shouldShowBottomNavigation('devices'), isTrue);
    expect(state.shouldEmbedLiveGrid('grid-details'), isTrue);
    expect(
      state.navigationItemMatchesRoute(
        <String, dynamic>{'routeId': 'grid'},
        'grid-details',
      ),
      isTrue,
    );
  });
}
