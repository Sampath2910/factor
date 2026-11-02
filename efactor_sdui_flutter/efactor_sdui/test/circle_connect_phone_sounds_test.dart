import 'package:efactor_sdui/services/grid_chat_message_notification.dart';
import 'package:efactor_sdui/services/push_notification_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Circle Connect Phone Sounds Parity Tests', () {
    test('Default channels initialize with standard IDs', () {
      expect(PushNotificationBootstrap.activeCallsChannelId,
          equals('grid_calls_v4'));
      expect(PushNotificationBootstrap.activeMessagesChannelId,
          equals('grid_messages_v4'));
      expect(GridChatMessageNotifications.activeChannelId,
          equals('grid_messages_v4'));
    });

    test(
        'refreshActiveChannels updates to versioned channels from SharedPreferences',
        () async {
      SharedPreferences.setMockInitialValues({
        'circle_connect_calls_channel_id': 'grid_calls_v5',
        'circle_connect_messages_channel_id': 'grid_messages_v5',
      });

      await PushNotificationBootstrap.refreshActiveChannels();

      expect(PushNotificationBootstrap.activeCallsChannelId,
          equals('grid_calls_v5'));
      expect(PushNotificationBootstrap.activeMessagesChannelId,
          equals('grid_messages_v5'));
      expect(GridChatMessageNotifications.activeChannelId,
          equals('grid_messages_v5'));
    });
  });
}
