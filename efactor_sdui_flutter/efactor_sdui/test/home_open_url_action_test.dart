import 'package:efactor_sdui/grid_sdui/grid_in_app_webview_page.dart';
import 'package:efactor_sdui/home_sdui/dynamic_home_sdui_page.dart';
import 'package:efactor_sdui/home_sdui/home_sdui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestNavigatorObserver extends NavigatorObserver {
  _TestNavigatorObserver(this.onPushed);
  final void Function(Route<dynamic> route) onPushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onPushed(route);
  }
}

void main() {
  group('Home SDUI open-url action', () {
    test('HomeSduiController dispatches open-url action with direct url and openIn', () async {
      String? dispatchedActionId;
      Map<String, dynamic>? dispatchedPayload;

      final state = HomeSduiState(
        schema: <String, dynamic>{
          'state': <String, dynamic>{},
          'actionRegistry': <String, dynamic>{
            'profile-rating': <String, dynamic>{
              'type': 'open-url',
              'url': 'https://efactor.tech/rating',
              'route': 'https://efactor.tech/rating',
              'title': 'Rating',
              'openIn': 'inAppWebView',
            },
          },
        },
        accessToken: 'test-token',
      );

      state.hostActionHandler = (actionId, payload) async {
        dispatchedActionId = actionId;
        dispatchedPayload = payload;
      };

      await state.dispatchAction('profile-rating');

      expect(dispatchedActionId, 'open-url');
      expect(dispatchedPayload, isNotNull);
      expect(dispatchedPayload!['url'], 'https://efactor.tech/rating');
      expect(dispatchedPayload!['title'], 'Rating');
      expect(dispatchedPayload!['openIn'], 'inAppWebView');
    });

    test('HomeSduiController extracts url from destination.url when action.url is missing', () async {
      String? dispatchedActionId;
      Map<String, dynamic>? dispatchedPayload;

      final state = HomeSduiState(
        schema: <String, dynamic>{
          'state': <String, dynamic>{},
          'actionRegistry': <String, dynamic>{
            'nested-rating': <String, dynamic>{
              'type': 'open-url',
              'destination': <String, dynamic>{
                'url': 'https://efactor.tech/feedback',
                'title': 'Feedback',
                'openIn': 'inAppWebView',
              },
            },
          },
        },
        accessToken: 'test-token',
      );

      state.hostActionHandler = (actionId, payload) async {
        dispatchedActionId = actionId;
        dispatchedPayload = payload;
      };

      await state.dispatchAction('nested-rating');

      expect(dispatchedActionId, 'open-url');
      expect(dispatchedPayload, isNotNull);
      expect(dispatchedPayload!['url'], 'https://efactor.tech/feedback');
      expect(dispatchedPayload!['title'], 'Feedback');
    });

    test('HomeSduiController extracts url from route when url is missing', () async {
      String? dispatchedActionId;
      Map<String, dynamic>? dispatchedPayload;

      final state = HomeSduiState(
        schema: <String, dynamic>{
          'state': <String, dynamic>{},
          'actionRegistry': <String, dynamic>{
            'route-rating': <String, dynamic>{
              'type': 'open-url',
              'route': 'https://efactor.tech/support',
              'openIn': 'external',
            },
          },
        },
        accessToken: 'test-token',
      );

      state.hostActionHandler = (actionId, payload) async {
        dispatchedActionId = actionId;
        dispatchedPayload = payload;
      };

      await state.dispatchAction('route-rating');

      expect(dispatchedActionId, 'open-url');
      expect(dispatchedPayload, isNotNull);
      expect(dispatchedPayload!['url'], 'https://efactor.tech/support');
      expect(dispatchedPayload!['openIn'], 'external');
    });

    test('HomeSduiController throws FormatException if url is missing', () async {
      final state = HomeSduiState(
        schema: <String, dynamic>{
          'state': <String, dynamic>{},
          'actionRegistry': <String, dynamic>{
            'invalid-rating': <String, dynamic>{
              'type': 'open-url',
            },
          },
        },
        accessToken: 'test-token',
      );

      expect(
        () => state.dispatchAction('invalid-rating'),
        throwsA(isA<FormatException>()),
      );
    });

    testWidgets('DynamicHomeSduiPage pushes GridInAppWebViewPage when openIn is inAppWebView', (tester) async {
      final pushedRoutes = <Route<dynamic>>[];
      final observer = _TestNavigatorObserver((route) => pushedRoutes.add(route));

      const homePage = DynamicHomeSduiPage(
        accessToken: 'test-token',
        userId: 123,
        enableAutoRefresh: false,
        initialSchema: <String, dynamic>{
          'routes': <String, dynamic>{},
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: const Scaffold(
            body: homePage,
          ),
        ),
      );
      await tester.pump();

      final state = tester.state<DynamicHomeSduiPageState>(find.byType(DynamicHomeSduiPage));

      // Trigger the host action directly on the state
      state.handleHostActionForTest('open-url', <String, dynamic>{
        'type': 'open-url',
        'url': 'https://efactor.tech/rating',
        'title': 'Rating',
        'openIn': 'inAppWebView',
      });

      expect(pushedRoutes.length, 2);
      final route = pushedRoutes.last as MaterialPageRoute;
      final builtWidget = route.builder(state.context);
      expect(builtWidget, isA<GridInAppWebViewPage>());
      final webView = builtWidget as GridInAppWebViewPage;
      expect(webView.uri.toString(), 'https://efactor.tech/rating');
      expect(webView.title, 'Rating');
      expect(webView.accessToken, 'test-token');
      expect(webView.userId, 123);
    });
  });
}
