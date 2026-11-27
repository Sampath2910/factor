import 'dart:convert';
import 'dart:typed_data';

import 'package:efactor_sdui/grid_sdui/grid_in_app_webview_page.dart';
import 'package:efactor_sdui/services/push_notification_bootstrap.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Professional Space (GRID) Push Detection', () {
    test('isProfessionalSpacePush identifies PROFESSIONAL_SPACE_EVENT type', () {
      expect(
        isProfessionalSpacePush({'type': 'PROFESSIONAL_SPACE_EVENT'}),
        isTrue,
      );
      expect(
        isProfessionalSpacePush({'type': 'professional_space_event'}),
        isTrue,
      );
      expect(
        isProfessionalSpacePush({'event': 'PROFESSIONAL_SPACE_EVENT'}),
        isTrue,
      );
    });

    test('isProfessionalSpacePush identifies grid_activity channel', () {
      expect(
        isProfessionalSpacePush({'channel': 'grid_activity'}),
        isTrue,
      );
      expect(
        isProfessionalSpacePush({
          'type': 'POST_LIKE',
          'channel': 'grid_activity',
          'post_id': '582',
        }),
        isTrue,
      );
    });

    test('isProfessionalSpacePush identifies target_url containing /grid', () {
      expect(
        isProfessionalSpacePush({
          'target_url': 'https://efactor.tech/index.php/grid?post=582',
        }),
        isTrue,
      );
      expect(
        isProfessionalSpacePush({
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
        }),
        isTrue,
      );
    });

    test('isProfessionalSpacePush excludes Circle Connect chat and activity', () {
      expect(
        isProfessionalSpacePush({
          'type': 'CHAT_MESSAGE',
          'conversation_id': '42',
          'channel': 'messages',
          'target_url': 'https://efactor.tech/index.php/grid-chat?conversation=42',
        }),
        isFalse,
      );
      expect(
        isProfessionalSpacePush({
          'type': 'ACTIVITY',
          'channel': 'mentions',
          'url': 'https://efactor.tech/index.php/grid-chat?open=activity',
        }),
        isFalse,
      );
    });
  });

  group('Professional Space Notification Channel', () {
    test('kGridActivityChannel is correctly defined with High importance', () {
      expect(kGridActivityChannel.id, equals('grid_activity'));
      expect(kGridActivityChannel.name, equals('Professional Space'));
      expect(
        kGridActivityChannel.description,
        equals(
          'Notifications for posts, comments, connections, and activity in Professional Space',
        ),
      );
      expect(kGridActivityChannel.importance, equals(Importance.high));
      expect(kGridActivityChannel.playSound, isTrue);
      expect(kGridActivityChannel.enableVibration, isTrue);
    });
  });

  group('URL Safety Validation', () {
    test('isSafeEfactorUrl validates efactor.tech hosts and blocks others', () {
      expect(isSafeEfactorUrl('https://efactor.tech/index.php/grid?post=582'), isTrue);
      expect(isSafeEfactorUrl('https://efactor.tech/index.php/grid/messaging?user=7'), isTrue);
      expect(isSafeEfactorUrl('https://chat.efactor.tech/index.php/grid'), isTrue);
      expect(isSafeEfactorUrl('https://google.com'), isFalse);
      expect(isSafeEfactorUrl('https://efactor.tech.attacker.com'), isFalse);
      expect(isSafeEfactorUrl('javascript:alert(1)'), isFalse);
      expect(isSafeEfactorUrl(''), isFalse);
    });
  });

  group('Cold Start Target URL Latching', () {
    setUp(() {
      GridInAppWebViewPage.clearPendingTargetUrl();
    });

    tearDown(() {
      GridInAppWebViewPage.clearPendingTargetUrl();
    });

    test('loadTargetUrl stores pending URL and notifies listeners on cold start', () async {
      const targetUrl = 'https://efactor.tech/index.php/grid?post=582';
      expect(GridInAppWebViewPage.pendingTargetUrl, isNull);

      var notifiedCount = 0;
      void listener() {
        notifiedCount++;
      }

      GridInAppWebViewPage.pendingTargetUrlListenable.addListener(listener);

      final accepted = await GridInAppWebViewPage.loadTargetUrl(targetUrl);
      expect(accepted, isTrue);
      expect(GridInAppWebViewPage.pendingTargetUrl, equals(targetUrl));
      expect(notifiedCount, greaterThan(0));

      GridInAppWebViewPage.clearPendingTargetUrl();
      expect(GridInAppWebViewPage.pendingTargetUrl, isNull);

      GridInAppWebViewPage.pendingTargetUrlListenable.removeListener(listener);
    });

    test('loadTargetUrl blocks malicious non-efactor URLs from latching', () async {
      const maliciousUrl = 'https://malicious-site.com/steal-token';
      final accepted = await GridInAppWebViewPage.loadTargetUrl(maliciousUrl);
      expect(accepted, isFalse);
      expect(GridInAppWebViewPage.pendingTargetUrl, isNull);
    });
  });

  group('Professional Space MessagingStyle Stacking', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await ProfessionalSpaceNotifications.instance.clearAll();
    });

    tearDown(() async {
      await ProfessionalSpaceNotifications.instance.clearAll();
    });

    test('parses sender from "New message from <Name>" and resolves stable tags',
        () {
      final dmSpec = ProfessionalSpacePushSpec.parse(
        <String, dynamic>{
          'type': 'PROFESSIONAL_SPACE_EVENT',
          'title': 'New message from Pavan Kiran',
          'body': 'Hittu',
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
        },
        nowMs: 1700000000000,
      );

      expect(dmSpec.senderName, equals('Pavan Kiran'));
      expect(dmSpec.title, equals('Pavan Kiran'));
      expect(dmSpec.isGroupConversation, isFalse);
      expect(dmSpec.tag, equals('grid_user_7'));

      final explicitTagSpec = ProfessionalSpacePushSpec.parse(
        <String, dynamic>{
          'type': 'PROFESSIONAL_SPACE_EVENT',
          'tag': 'grid_custom_42',
          'actor_name': 'Alice',
          'post_id': '99',
        },
      );
      expect(explicitTagSpec.tag, equals('grid_custom_42'));
      expect(explicitTagSpec.isGroupConversation, isTrue);

      final nameFallbackTag = ProfessionalSpacePushSpec.resolveTag(
        <String, dynamic>{'title': 'New message from Pavan Kiran'},
        senderName: 'Pavan Kiran',
      );
      expect(nameFallbackTag, equals('grid_actor_pavan_kiran'));
    });

    test(
        'stacks consecutive messages from same sender using MessagingStyleInformation',
        () async {
      final plugin = FlutterLocalNotificationsPlugin();
      final captured = <({
        int id,
        String? title,
        String? body,
        NotificationDetails details,
        String? payload,
      })>[];

      final fakeAvatar = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final client = MockClient((request) async {
        expect(request.url.toString(), equals('https://efactor.tech/avatar.jpg'));
        return http.Response.bytes(fakeAvatar, 200);
      });

      await ProfessionalSpaceNotifications.instance.present(
        plugin,
        data: <String, dynamic>{
          'type': 'PROFESSIONAL_SPACE_EVENT',
          'channel': 'grid_activity',
          'title': 'New message from Pavan Kiran',
          'body': 'Hittu',
          'message_id': 'm1',
          'actor_avatar': 'https://efactor.tech/avatar.jpg',
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
        },
        nowMs: 1700000001000,
        httpClient: client,
        showOverride: (id, title, body, details, {payload}) async {
          captured.add((
            id: id,
            title: title,
            body: body,
            details: details,
            payload: payload,
          ));
        },
      );

      await ProfessionalSpaceNotifications.instance.present(
        plugin,
        data: <String, dynamic>{
          'type': 'PROFESSIONAL_SPACE_EVENT',
          'channel': 'grid_activity',
          'title': 'New message from Pavan Kiran',
          'body': 'Please check the update',
          'message_id': 'm2',
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
        },
        nowMs: 1700000002000,
        showOverride: (id, title, body, details, {payload}) async {
          captured.add((
            id: id,
            title: title,
            body: body,
            details: details,
            payload: payload,
          ));
        },
      );

      expect(captured, hasLength(2));
      expect(captured[0].id, equals(captured[1].id));

      final firstAndroid = captured[0].details.android!;
      expect(firstAndroid.largeIcon, isA<ByteArrayAndroidBitmap>());

      final secondAndroid = captured[1].details.android!;
      expect(secondAndroid.channelId, equals(kGridActivityChannel.id));
      expect(secondAndroid.tag, equals('grid_user_7'));
      expect(secondAndroid.actions, isNull);
      expect(secondAndroid.styleInformation, isA<MessagingStyleInformation>());

      final style = secondAndroid.styleInformation! as MessagingStyleInformation;
      expect(style.groupConversation, isFalse);
      expect(style.conversationTitle, isNull);
      expect(style.messages, hasLength(2));
      expect(style.messages![0].text, equals('Hittu'));
      expect(style.messages![0].person?.name, equals('Pavan Kiran'));
      expect(style.messages![1].text, equals('Please check the update'));
      expect(style.messages![1].person?.name, equals('Pavan Kiran'));

      final decodedPayload =
          jsonDecode(captured[1].payload!) as Map<String, dynamic>;
      expect(decodedPayload['tag'], equals('grid_user_7'));
    });

    test('deduplicates message_id, separates different senders, and clears stack',
        () async {
      final plugin = FlutterLocalNotificationsPlugin();
      final captured = <({int id, NotificationDetails details})>[];

      Future<void> record(
        int id,
        String? title,
        String? body,
        NotificationDetails details, {
        String? payload,
      }) async {
        captured.add((id: id, details: details));
      }

      await ProfessionalSpaceNotifications.instance.present(
        plugin,
        data: <String, dynamic>{
          'type': 'PROFESSIONAL_SPACE_EVENT',
          'title': 'New message from Pavan Kiran',
          'body': 'Hello',
          'message_id': 'dup_1',
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
        },
        nowMs: 1700000001000,
        showOverride: record,
      );

      // Duplicate message_id should not append a second line.
      await ProfessionalSpaceNotifications.instance.present(
        plugin,
        data: <String, dynamic>{
          'type': 'PROFESSIONAL_SPACE_EVENT',
          'title': 'New message from Pavan Kiran',
          'body': 'Hello',
          'message_id': 'dup_1',
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
        },
        nowMs: 1700000002000,
        showOverride: record,
      );

      // Different user must get a distinct notification id and separate stack.
      await ProfessionalSpaceNotifications.instance.present(
        plugin,
        data: <String, dynamic>{
          'type': 'PROFESSIONAL_SPACE_EVENT',
          'title': 'New message from Alice',
          'body': 'Hi from Alice',
          'message_id': 'alice_1',
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=8',
        },
        nowMs: 1700000003000,
        showOverride: record,
      );

      expect(captured, hasLength(3));
      final p1Style =
          captured[1].details.android!.styleInformation! as MessagingStyleInformation;
      expect(p1Style.messages, hasLength(1));

      expect(captured[2].id, isNot(equals(captured[0].id)));
      final aliceStyle =
          captured[2].details.android!.styleInformation! as MessagingStyleInformation;
      expect(aliceStyle.messages, hasLength(1));
      expect(aliceStyle.messages![0].text, equals('Hi from Alice'));

      // Clearing Pavan's thread stack starts fresh on the next message.
      await ProfessionalSpaceNotifications.instance.clearForData(<String, dynamic>{
        'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
      });
      await ProfessionalSpaceNotifications.instance.present(
        plugin,
        data: <String, dynamic>{
          'type': 'PROFESSIONAL_SPACE_EVENT',
          'title': 'New message from Pavan Kiran',
          'body': 'Fresh start',
          'message_id': 'new_1',
          'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
        },
        nowMs: 1700000004000,
        showOverride: record,
      );

      final freshStyle =
          captured[3].details.android!.styleInformation! as MessagingStyleInformation;
      expect(freshStyle.messages, hasLength(1));
      expect(freshStyle.messages![0].text, equals('Fresh start'));
    });

    test('caps stacked lines at maxLines and blocks unsafe avatar URLs',
        () async {
      final plugin = FlutterLocalNotificationsPlugin();
      var httpCalled = false;
      final client = MockClient((request) async {
        httpCalled = true;
        return http.Response('nope', 404);
      });
      NotificationDetails? latest;

      for (var i = 1; i <= 10; i++) {
        await ProfessionalSpaceNotifications.instance.present(
          plugin,
          data: <String, dynamic>{
            'type': 'PROFESSIONAL_SPACE_EVENT',
            'actor_name': 'Pavan Kiran',
            'body': 'Msg $i',
            'message_id': 'm_$i',
            'actor_avatar': 'https://evil.example.com/avatar.png',
            'target_url': 'https://efactor.tech/index.php/grid/messaging?user=7',
          },
          nowMs: 1700000000000 + i * 1000,
          httpClient: client,
          showOverride: (id, title, body, details, {payload}) async {
            latest = details;
          },
        );
      }

      expect(httpCalled, isFalse);
      expect(latest!.android!.largeIcon, isNull);
      final style =
          latest!.android!.styleInformation! as MessagingStyleInformation;
      expect(style.messages, hasLength(ProfessionalSpaceNotifications.maxLines));
      expect(style.messages!.first.text, equals('Msg 3'));
      expect(style.messages!.last.text, equals('Msg 10'));
    });
  });
}
