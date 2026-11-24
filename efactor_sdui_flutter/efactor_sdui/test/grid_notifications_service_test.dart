import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:efactor_sdui/grid_sdui/grid_sdui_state.dart';
import 'package:efactor_sdui/services/grid_notifications_service.dart';
import 'package:efactor_sdui/services/grid_unread_counts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GridNotificationsService.instance.notifications.value = const [];
    GridNotificationsService.instance.unreadCount.value = 0;
    GridUnreadCountsService.instance.unreadNotifications.value = 0;
  });

  tearDown(() {
    GridNotificationsService.instance.notifications.value = const [];
    GridNotificationsService.instance.unreadCount.value = 0;
    GridUnreadCountsService.instance.unreadNotifications.value = 0;
  });

  group('GridNotificationsService unit tests', () {
    test('formatRelativeTime formats correctly', () {
      final now = DateTime.now();
      expect(
        GridNotificationsService.formatRelativeTime(
          now.subtract(const Duration(seconds: 10)).toIso8601String(),
        ),
        'just now',
      );
      expect(
        GridNotificationsService.formatRelativeTime(
          now.subtract(const Duration(minutes: 5)).toIso8601String(),
        ),
        '5m',
      );
      expect(
        GridNotificationsService.formatRelativeTime(
          now.subtract(const Duration(hours: 2)).toIso8601String(),
        ),
        '2h',
      );
      expect(
        GridNotificationsService.formatRelativeTime(
          now.subtract(const Duration(days: 1)).toIso8601String(),
        ),
        'yesterday',
      );
      expect(
        GridNotificationsService.formatRelativeTime(
          now.subtract(const Duration(days: 3)).toIso8601String(),
        ),
        '3d',
      );
    });

    test('getInitials extracts initials accurately', () {
      expect(GridNotificationsService.getInitials('Aarav Shah'), 'AS');
      expect(GridNotificationsService.getInitials('Aarav'), 'AA');
      expect(GridNotificationsService.getInitials(''), 'U');
      expect(GridNotificationsService.getInitials(null), 'U');
    });

    test('fetchNotifications parses backend payload and updates counts',
        () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, contains('/grid/api/notifications'));
        return http.Response(
          jsonEncode({
            'success': true,
            'data': [
              {
                'id': 101,
                'type': 'new_message',
                'title': 'Aarav sent you a message',
                'body': 'Hey, are you free to talk?',
                'link': '/grid?view=messages&peer=45',
                'is_read': 0,
                'created_at': DateTime.now()
                    .subtract(const Duration(hours: 2))
                    .toIso8601String(),
                'actor_name': 'Aarav Shah',
                'actor_avatar':
                    'https://efactor.tech/uploads/grid/avatars/45.jpg',
              },
              {
                'id': 102,
                'type': 'connection_request',
                'title': 'Priya sent a connection request',
                'body': 'Let\'s connect on GRID',
                'link': '/grid/network',
                'is_read': 1,
                'created_at': DateTime.now()
                    .subtract(const Duration(days: 1))
                    .toIso8601String(),
                'actor_name': 'Priya Nair',
                'actor_avatar': null,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final result = await GridNotificationsService.instance
          .fetchNotifications(client: mockClient);

      expect(result.length, 2);
      expect(GridNotificationsService.instance.unreadCount.value, 1);
      expect(
        GridUnreadCountsService.instance.unreadNotifications.value,
        1,
      );
    });

    test('markRead marks an unread notification as read', () async {
      GridNotificationsService.instance.notifications.value = [
        {
          'id': 123,
          'title': 'Test message',
          'is_read': 0,
        },
      ];
      GridNotificationsService.instance.unreadCount.value = 1;

      final mockClient = MockClient((request) async {
        expect(request.url.path, contains('/grid/api/notifications/mark-read'));
        final body = jsonDecode(request.body);
        expect(body['id'], 123);
        return http.Response(jsonEncode({'success': true}), 200);
      });

      final success = await GridNotificationsService.instance
          .markRead(id: 123, client: mockClient);

      expect(success, isTrue);
      expect(
        GridNotificationsService.instance.notifications.value[0]['is_read'],
        1,
      );
      expect(GridNotificationsService.instance.unreadCount.value, 0);
    });
  });

  group('GRID State Updates notifications mapping', () {
    final baseSchema = <String, dynamic>{
      'components': <String, dynamic>{
        'grid-explore-section': <String, dynamic>{
          'id': 'grid-explore-section',
          'type': 'section',
          'title': 'Updates',
          'filters': [
            {'id': 'professional', 'label': 'Professional', 'selected': true},
            {'id': 'circle', 'label': 'Chat', 'selected': false},
          ],
          'trailing': {
            'label': 'View All',
            'actionId': 'grid-see-all-exploring',
          },
          'footer': {
            'label': 'View All Updates',
            'actionId': 'grid-see-all-exploring',
          },
          'children': ['grid-explore-row'],
        },
        'grid-explore-row': <String, dynamic>{
          'id': 'grid-explore-row',
          'type': 'responsiveGrid',
          'children': <String>[],
        },
      },
      'actions': <String, dynamic>{
        'grid-see-all-exploring': <String, dynamic>{
          'type': 'open-url',
          'url': 'https://efactor.tech/index.php/grid/network',
        },
      },
    };

    test('applyNotifications synthesizes cards and updates section badge', () {
      final state = GridSduiState(Map<String, dynamic>.from(baseSchema));

      final testRows = <Map<String, dynamic>>[
        {
          'id': 456,
          'type': 'new_message',
          'title': 'Aarav sent you a message',
          'body': 'Hey, are you free to talk?',
          'link': '/grid?view=messages&peer=45',
          'is_read': 0,
          'created_at': DateTime.now()
              .subtract(const Duration(hours: 2))
              .toIso8601String(),
          'actor_name': 'Aarav Shah',
          'actor_avatar': 'https://efactor.tech/uploads/grid/avatars/45.jpg',
        },
        {
          'id': 457,
          'type': 'circle_message',
          'title': 'Tech Circle update',
          'body': 'New meetup announcement',
          'link': '/grid-chat/connect?room=10',
          'is_read': 1,
          'created_at': DateTime.now()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'actor_name': 'Tech Circle',
          'actor_avatar': null,
        },
      ];

      state.applyNotifications(testRows, unreadCount: 1);

      // Verify row children
      final row = state.component('grid-explore-row');
      expect((row?['children'] as List).contains('grid-notif-456'), isTrue);
      expect((row?['children'] as List).contains('grid-notif-457'), isTrue);

      // Verify Professional card
      final card1 = state.component('grid-notif-456');
      expect(card1?['title'], 'Aarav sent you a message');
      expect(card1?['subtitle'], 'Hey, are you free to talk?');
      expect(card1?['time'], '2h');
      expect(card1?['unread'], isTrue);
      expect(card1?['space'], 'professional');
      expect(card1?['imageUrl'],
          'https://efactor.tech/uploads/grid/avatars/45.jpg');
      expect(card1?['url'],
          'https://efactor.tech/index.php/grid?view=messages&peer=45');

      // Verify Circle card
      final card2 = state.component('grid-notif-457');
      expect(card2?['title'], 'Tech Circle update');
      expect(card2?['unread'], isFalse);
      expect(card2?['space'], 'circle');
      expect(card2?['badge'], 'Chat');
      expect(card2?['label'], 'TC');

      // Verify Section badge
      final section = state.component('grid-explore-section');
      expect(section?['badge'], '1 new');
      expect(section?['headerBadge']?['label'], '1 new');
    });

    test('View All action redirects to grid notifications page', () async {
      final state = GridSduiState(Map<String, dynamic>.from(baseSchema));
      Uri? openedUri;
      state.inAppWebViewOpener = (uri,
          {title,
          clearCache,
          displayMode,
          hideAppBar,
          javaScriptEnabled,
          sharedCookies,
          showAppBar,
          showToolbar}) async {
        openedUri = uri;
        return true;
      };

      await state.dispatch('grid-see-all-exploring');

      expect(openedUri, isNotNull);
      expect(
        openedUri.toString(),
        'https://efactor.tech/index.php/grid/notifications',
      );
    });

    test('Tapping notification row marks item read and opens link', () async {
      final state = GridSduiState(Map<String, dynamic>.from(baseSchema));
      state.applyNotifications([
        {
          'id': 888,
          'type': 'new_message',
          'title': 'Test message',
          'body': 'Hello',
          'link': '/grid?view=messages&peer=99',
          'is_read': 0,
        },
      ]);

      Uri? openedUri;
      state.inAppWebViewOpener = (uri,
          {title,
          clearCache,
          displayMode,
          hideAppBar,
          javaScriptEnabled,
          sharedCookies,
          showAppBar,
          showToolbar}) async {
        openedUri = uri;
        return true;
      };

      final card = state.component('grid-notif-888');
      expect(card?['unread'], isTrue);

      await state.dispatch(
        'grid-open-notification-item',
        extra: <String, dynamic>{
          'url': card?['url'],
          'notificationId': 888,
        },
      );

      expect(openedUri, isNotNull);
      expect(
        openedUri.toString(),
        'https://efactor.tech/index.php/grid?view=messages&peer=99',
      );

      // Verify card was updated locally to read
      final updatedCard = state.component('grid-notif-888');
      expect(updatedCard?['unread'], isFalse);
    });
  });
}
