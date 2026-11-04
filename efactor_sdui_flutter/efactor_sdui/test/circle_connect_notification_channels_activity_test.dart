import 'package:efactor_sdui/services/push_notification_bootstrap.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Circle Connect Notification Channels & Groups', () {
    test('Channel groups have correct IDs and names', () {
      expect(kGroupGridChatMessages.id, equals('grid_chat_messages'));
      expect(kGroupGridChatMessages.name, equals('GRID Chat messages'));

      expect(kGroupGridChatActivity.id, equals('grid_chat_activity'));
      expect(kGroupGridChatActivity.name, equals('GRID Chat activity'));
    });

    test('All 13 channels are registered in kCircleConnectChannels', () {
      expect(kCircleConnectChannels.length, equals(13));

      final expectedChannels = <String, Map<String, dynamic>>{
        'messages': {
          'name': 'Messages',
          'groupId': 'grid_chat_messages',
          'importance': Importance.max,
        },
        'group_messages': {
          'name': 'Group messages',
          'groupId': 'grid_chat_messages',
          'importance': Importance.max,
        },
        'calls': {
          'name': 'Calls',
          'groupId': 'grid_chat_messages',
          'importance': Importance.max,
        },
        'missed_calls': {
          'name': 'Missed calls',
          'groupId': 'grid_chat_messages',
          'importance': Importance.high,
        },
        'mentions': {
          'name': 'Mentions',
          'groupId': 'grid_chat_activity',
          'importance': Importance.high,
        },
        'comments': {
          'name': 'Comments',
          'groupId': 'grid_chat_activity',
          'importance': Importance.defaultImportance,
        },
        'likes': {
          'name': 'Likes & reactions',
          'groupId': 'grid_chat_activity',
          'importance': Importance.defaultImportance,
        },
        'live': {
          'name': 'Live videos',
          'groupId': 'grid_chat_activity',
          'importance': Importance.defaultImportance,
        },
        'channels': {
          'name': 'Channel posts & followers',
          'groupId': 'grid_chat_activity',
          'importance': Importance.defaultImportance,
        },
        'groups': {
          'name': 'Groups (added / admin)',
          'groupId': 'grid_chat_activity',
          'importance': Importance.defaultImportance,
        },
        'location': {
          'name': 'Live location',
          'groupId': 'grid_chat_activity',
          'importance': Importance.defaultImportance,
        },
        'polls': {
          'name': 'Polls',
          'groupId': 'grid_chat_activity',
          'importance': Importance.defaultImportance,
        },
        'contacts': {
          'name': 'Contacts joined',
          'groupId': 'grid_chat_activity',
          'importance': Importance.defaultImportance,
        },
      };

      for (final entry in expectedChannels.entries) {
        final id = entry.key;
        final expected = entry.value;
        final channel = kCircleConnectChannels[id];
        expect(channel, isNotNull, reason: 'Channel $id must exist');
        expect(channel!.name, equals(expected['name']));
        expect(channel.groupId, equals(expected['groupId']));
        expect(channel.importance, equals(expected['importance']));
        expect(channel.playSound, isTrue);
      }
    });

    test('resolveCircleConnectChannelId maps keys properly', () {
      expect(
        resolveCircleConnectChannelId('messages'),
        equals(PushNotificationBootstrap.activeMessagesChannelId),
      );
      expect(
        resolveCircleConnectChannelId('calls'),
        equals(PushNotificationBootstrap.activeCallsChannelId),
      );
      expect(
        resolveCircleConnectChannelId('group_messages'),
        equals('group_messages'),
      );
      expect(
        resolveCircleConnectChannelId('missed_calls'),
        equals('missed_calls'),
      );
      expect(
        resolveCircleConnectChannelId('mentions'),
        equals('mentions'),
      );
      expect(
        resolveCircleConnectChannelId('comments'),
        equals('comments'),
      );
      expect(
        resolveCircleConnectChannelId('likes'),
        equals('likes'),
      );
      expect(
        resolveCircleConnectChannelId('live'),
        equals('live'),
      );
      expect(
        resolveCircleConnectChannelId('channels'),
        equals('channels'),
      );
      expect(
        resolveCircleConnectChannelId('groups'),
        equals('groups'),
      );
      expect(
        resolveCircleConnectChannelId('location'),
        equals('location'),
      );
      expect(
        resolveCircleConnectChannelId('polls'),
        equals('polls'),
      );
      expect(
        resolveCircleConnectChannelId('contacts'),
        equals('contacts'),
      );

      // Fallback on null, empty, or unknown
      expect(resolveCircleConnectChannelId(null), equals('mentions'));
      expect(resolveCircleConnectChannelId(''), equals('mentions'));
      expect(
        resolveCircleConnectChannelId('unknown_custom', fallback: 'custom_fb'),
        equals('custom_fb'),
      );
    });
  });

  group('Circle Connect URL Safety Validation', () {
    test('isSafeEfactorUrl validates efactor.tech domains safely', () {
      expect(
        isSafeEfactorUrl('https://efactor.tech/index.php/grid-chat?open=activity'),
        isTrue,
      );
      expect(
        isSafeEfactorUrl('https://efactor.tech/index.php/grid-chat/settings'),
        isTrue,
      );
      expect(
        isSafeEfactorUrl('https://api.efactor.tech/v1/resource'),
        isTrue,
      );
      expect(
        isSafeEfactorUrl('https://evil-efactor.tech'),
        isFalse,
      );
      expect(
        isSafeEfactorUrl('https://google.com'),
        isFalse,
      );
      expect(
        isSafeEfactorUrl(''),
        isFalse,
      );
      expect(
        isSafeEfactorUrl('not_a_valid_url'),
        isFalse,
      );
    });
  });
}

