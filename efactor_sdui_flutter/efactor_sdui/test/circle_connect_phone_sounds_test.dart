import 'package:efactor_sdui/services/grid_chat_message_notification.dart';
import 'package:efactor_sdui/services/push_notification_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Circle Connect Phone Sounds Parity Tests', () {
    test('Default channels initialize with standard grouped IDs', () {
      expect(PushNotificationBootstrap.activeCallsChannelId, equals('calls'));
      expect(PushNotificationBootstrap.activeMessagesChannelId, equals('messages'));
      expect(GridChatMessageNotifications.activeChannelId, equals('messages'));
    });

    test(
        'refreshActiveChannels ignores legacy grid_calls / grid_messages and uses calls/messages',
        () async {
      SharedPreferences.setMockInitialValues({
        'circle_connect_calls_channel_id': 'grid_calls_v5',
        'circle_connect_messages_channel_id': 'grid_messages_v5',
      });

      await PushNotificationBootstrap.refreshActiveChannels();

      expect(PushNotificationBootstrap.activeCallsChannelId, equals('calls'));
      expect(PushNotificationBootstrap.activeMessagesChannelId, equals('messages'));
      expect(GridChatMessageNotifications.activeChannelId, equals('messages'));
    });

    test('refreshActiveChannels updates to active grouped channels', () async {
      SharedPreferences.setMockInitialValues({
        'circle_connect_calls_channel_id': 'calls',
        'circle_connect_messages_channel_id': 'messages',
      });

      await PushNotificationBootstrap.refreshActiveChannels();

      expect(PushNotificationBootstrap.activeCallsChannelId, equals('calls'));
      expect(PushNotificationBootstrap.activeMessagesChannelId, equals('messages'));
      expect(GridChatMessageNotifications.activeChannelId, equals('messages'));
    });
  });
}
