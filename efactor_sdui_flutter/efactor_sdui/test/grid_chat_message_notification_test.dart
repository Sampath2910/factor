import 'package:efactor_sdui/services/grid_chat_message_notification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GRID Chat message notifications', () {
    test('parses the NEW_MESSAGE contract and stacks the conversation URL', () {
      final message = GridChatMessage.parse(<String, dynamic>{
        'type': 'NEW_MESSAGE',
        'notification_type': 'message',
        'conversation_id': '42',
        'message_id': 'm1',
        'message_type': 'text',
        'title': 'Design',
        'body': 'Hello',
        'sender_id': '7',
        'sender_name': 'Asha',
        'is_group': '1',
        'locked': '0',
        'tag': 'conv-42',
        'url': 'https://efactor.tech/index.php/grid-chat',
      });

      expect(message, isNotNull);
      expect(message!.isGroup, isTrue);
      expect(message.locked, isFalse);
      expect(message.notificationId, 42);
      expect(message.notificationTag, 'conv-42');
      expect(
        GridChatMessageNotifications.conversationUri(
          '42',
          compose: false,
        ).toString(),
        'https://efactor.tech/index.php/grid-chat?conversation_id=42',
      );
      expect(
        GridChatMessageNotifications.conversationUri(
          '42',
          compose: true,
        ).queryParameters['compose'],
        '1',
      );
    });

    test('locked=1 hides the sender and message', () {
      final message = GridChatMessage.parse(<String, dynamic>{
        'type': 'NEW_MESSAGE',
        'conversation_id': '9',
        'message_id': 'm2',
        'title': 'Secret',
        'body': 'hidden text',
        'sender_name': 'Asha',
        'locked': 1,
      });
      expect(message!.locked, isTrue);
      expect(GridChatMessage.lockedLabel, 'GRID Chat – New message');
    });

    test('drops an expires_at that is already past and dedupes message_id', () {
      final past = GridChatMessage.parse(<String, dynamic>{
        'type': 'NEW_MESSAGE',
        'conversation_id': '9',
        'message_id': 'm3',
        'expires_at': '1000000000',
      });
      expect(past!.isExpired, isTrue);

      final futureMs = DateTime.now().toUtc().add(const Duration(minutes: 5));
      final upcoming = GridChatMessage.parse(<String, dynamic>{
        'type': 'NEW_MESSAGE',
        'conversation_id': '9',
        'message_id': 'm4',
        'expires_at': futureMs.millisecondsSinceEpoch.toString(),
      });
      expect(upcoming!.isExpired, isFalse);
      expect(
        GridChatMessage.isDuplicateMessage('m4', <String>['m1', 'm4']),
        isTrue,
      );
      expect(
        GridChatMessage.isDuplicateMessage('m5', <String>['m4']),
        isFalse,
      );
    });

    test('suppresses only the conversation that is open in the foreground', () {
      expect(
        GridChatMessage.shouldSuppress(
          activeConversationId: '42',
          conversationId: '42',
          appResumed: true,
        ),
        isTrue,
      );
      expect(
        GridChatMessage.shouldSuppress(
          activeConversationId: '42',
          conversationId: '7',
          appResumed: true,
        ),
        isFalse,
      );
      expect(
        GridChatMessage.shouldSuppress(
          activeConversationId: '42',
          conversationId: '42',
          appResumed: false,
        ),
        isFalse,
      );
    });

    test('parses msg_type contract and prioritizes it over message_type', () {
      final msgPayload = GridChatMessage.parse(<String, dynamic>{
        'type': 'NEW_MESSAGE',
        'conversation_id': '101',
        'message_id': 'img1',
        'msg_type': 'image',
        'sender_name': 'Pavan Nagapuri',
        'is_group': '0',
      });
      expect(msgPayload, isNotNull);
      expect(msgPayload!.messageType, 'image');
      expect(
        GridChatMessageNotifications.defaultBodyForMessageType(
          msgPayload.messageType,
        ),
        '📷 Photo',
      );
    });

    test(
      '1:1 chat (is_group = 0) uses strictly sender name as title and omits conversationTitle',
      () {
        final message = GridChatMessage.parse(<String, dynamic>{
          'type': 'NEW_MESSAGE',
          'conversation_id': '50',
          'message_id': 'm50',
          'msg_type': 'text',
          'title': 'Pavan Nagapuri: Pavan Nagapuri',
          'body': 'Hello there',
          'sender_id': '12',
          'sender_name': 'Pavan Nagapuri',
          'is_group': '0',
        });
        expect(message, isNotNull);
        expect(message!.isGroup, isFalse);
        expect(
          GridChatMessageNotifications.notificationTitle(message),
          'Pavan Nagapuri',
        );
        expect(
          GridChatMessageNotifications.groupConversationTitle(message),
          isNull,
        );
      },
    );

    test(
      'group chat (is_group = 1) keeps group title as notification and conversationTitle',
      () {
        final message = GridChatMessage.parse(<String, dynamic>{
          'type': 'NEW_MESSAGE',
          'conversation_id': '77',
          'message_id': 'm77',
          'msg_type': 'text',
          'title': 'Flutter Developers',
          'body': 'Standup in 5 mins',
          'sender_id': '12',
          'sender_name': 'Pavan Nagapuri',
          'is_group': '1',
        });
        expect(message, isNotNull);
        expect(message!.isGroup, isTrue);
        expect(
          GridChatMessageNotifications.notificationTitle(message),
          'Flutter Developers',
        );
        expect(
          GridChatMessageNotifications.groupConversationTitle(message),
          'Flutter Developers',
        );
      },
    );
  });
}
