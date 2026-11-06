import 'dart:convert';
import 'package:efactor_sdui/services/circle_connect_device_key_store.dart';
import 'package:efactor_sdui/services/push_notification_bootstrap.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Circle Connect Device Key & Mark as Read Tests', () {
    late Map<String, String> mockSecureStore;
    late FlutterSecureStorage mockStorage;

    setUp(() {
      mockSecureStore = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(mockSecureStore);
      mockStorage = const FlutterSecureStorage();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('Device key and installation ID are stored and retrieved securely',
        () async {
      final store = CircleConnectDeviceKeyStore(storage: mockStorage);

      expect(await store.getDeviceKey(), isNull);

      await store.setDeviceKey(
        'gcdk_test_device_key_12345',
        'inst_uuid_67890',
        baseUrl: 'https://custom.server.com/index.php/grid-chat/api',
      );

      expect(await store.getDeviceKey(), equals('gcdk_test_device_key_12345'));
      expect(await store.getInstallationId(), equals('inst_uuid_67890'));
      expect(
        await store.getBaseUrl(),
        equals('https://custom.server.com/index.php/grid-chat/api'),
      );

      // Clearing key removes from secure store
      await store.clearDeviceKey();
      expect(await store.getDeviceKey(), isNull);
    });

    test(
        'markAsRead sends POST {base}/notification/action with X-Device-Key and JSON body',
        () async {
      http.Request? capturedRequest;

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/notification/action')) {
          capturedRequest = request;
          return http.Response(jsonEncode({'success': true}), 200, headers: {
            'content-type': 'application/json',
          });
        }
        return http.Response('Not Found', 404);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );

      await store.setDeviceKey('gcdk_valid_key', 'inst_1');

      final success = await store.markAsRead(
        conversationId: 'conv_42',
        messageId: 'msg_99',
        targetUrl: 'https://efactor.tech/index.php/grid-chat/api',
      );

      expect(success, isTrue);
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.method, equals('POST'));
      expect(
        capturedRequest!.url.toString(),
        equals(
            'https://efactor.tech/index.php/grid-chat/api/notification/action'),
      );
      expect(
          capturedRequest!.headers['X-Device-Key'], equals('gcdk_valid_key'));
      expect(capturedRequest!.headers.containsKey('Authorization'), isFalse);
      expect(capturedRequest!.headers['Content-Type'],
          contains('application/json'));

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['action'], equals('read'));
      expect(body['conversation_id'], equals('conv_42'));
      expect(body['message_id'], equals('msg_99'));
    });

    test('markAsRead on 401 response deletes stored device key', () async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode({'error': 'Unauthorized'}), 401);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );

      await store.setDeviceKey('gcdk_revoked_key', 'inst_1');
      expect(await store.getDeviceKey(), isNotNull);

      final success = await store.markAsRead(
        conversationId: 'conv_42',
        messageId: 'msg_99',
      );

      expect(success, isFalse);
      // Key must be cleared following 401
      expect(await store.getDeviceKey(), isNull);
    });

    test(
        'markAsRead queues action to offline queue when network fails and flush retries',
        () async {
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          throw Exception('No network');
        }
        return http.Response(jsonEncode({'success': true}), 200);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );

      await store.setDeviceKey('gcdk_offline_key', 'inst_1');

      final success = await store.markAsRead(
        conversationId: 'conv_offline',
        messageId: 'msg_offline',
      );

      expect(success, isFalse);

      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList('circle_connect_offline_read_queue');
      expect(queue, isNotNull);
      expect(queue!.length, equals(1));
      expect(queue.first, contains('conv_offline'));

      // Flush queue when network is restored
      await store.flushOfflineQueue();

      final queueAfter =
          prefs.getStringList('circle_connect_offline_read_queue');
      expect(queueAfter, isEmpty);
    });

    test(
        'revokeOnLogout sends POST {base}/notification/device_key/revoke and clears key',
        () async {
      http.Request? revokeRequest;

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/notification/device_key/revoke')) {
          revokeRequest = request;
          return http.Response(jsonEncode({'success': true}), 200);
        }
        return http.Response('Not Found', 404);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );

      await store.setDeviceKey('gcdk_to_revoke', 'inst_1');
      expect(await store.getDeviceKey(), isNotNull);

      await store.revokeOnLogout();

      expect(revokeRequest, isNotNull);
      expect(revokeRequest!.method, equals('POST'));
      expect(revokeRequest!.headers['X-Device-Key'], equals('gcdk_to_revoke'));
      expect(await store.getDeviceKey(), isNull);
    });

    test('hasDeviceKey returns accurate status and listeners are notified',
        () async {
      final store = CircleConnectDeviceKeyStore(storage: mockStorage);
      final notifications = <bool>[];
      store.addKeyStatusListener((hasKey) => notifications.add(hasKey));

      expect(await store.hasDeviceKey(), isFalse);

      await store.setDeviceKey('gcdk_key_1', 'inst_1');
      expect(await store.hasDeviceKey(), isTrue);
      expect(notifications, equals([true]));

      await store.clearDeviceKey();
      expect(await store.hasDeviceKey(), isFalse);
      expect(notifications, equals([true, false]));
    });

    test(
        '401 response deletes key only if it matches the key that request used (in-flight race condition)',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode({'error': 'Unauthorized'}), 401);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );

      // Suppose key_old is set
      await store.setDeviceKey('key_old', 'inst_1');

      // Now clearDeviceKey is called with matchingKey: 'key_other' (different key)
      await store.clearDeviceKey(matchingKey: 'key_other');
      // Must NOT be cleared because matchingKey didn't match!
      expect(await store.getDeviceKey(), equals('key_old'));

      // If key was replaced in storage by key_new while request for key_old was in flight:
      await store.setDeviceKey('key_new', 'inst_2');

      // Stale 401 response arrives for key_old:
      await store.clearDeviceKey(matchingKey: 'key_old');
      // key_new must be preserved!
      expect(await store.getDeviceKey(), equals('key_new'));

      // 401 response arrives matching current key:
      await store.clearDeviceKey(matchingKey: 'key_new');
      expect(await store.getDeviceKey(), isNull);
    });

    test('flushOfflineQueue uses the current stored key, not the queued key',
        () async {
      String? usedKey;
      final mockClient = MockClient((request) async {
        usedKey = request.headers['X-Device-Key'];
        return http.Response(jsonEncode({'success': true}), 200);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );

      // Queue an item while offline or with initial key
      await store.setDeviceKey('initial_key', 'inst_1');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('circle_connect_offline_read_queue', [
        jsonEncode({
          'conversation_id': 'conv_123',
          'message_id': 'msg_456',
          'base_url': CircleConnectDeviceKeyStore.defaultBaseUrl,
          'timestamp': '123456789',
        }),
      ]);

      // Before flushing, the key is replaced by a newer fresh key from the web app
      await store.setDeviceKey('fresh_key_after_open', 'inst_1');

      // Flush queue
      await store.flushOfflineQueue();

      // Verified: used the current stored key!
      expect(usedKey, equals('fresh_key_after_open'));
      final queueAfter =
          prefs.getStringList('circle_connect_offline_read_queue');
      expect(queueAfter, isEmpty);
    });

    test('generateUuidV4 produces valid lowercase RFC 4122 version 4 UUID', () {
      final uuid = CircleConnectDeviceKeyStore.generateUuidV4();
      expect(uuid.length, equals(36));
      expect(
          uuid,
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test(
        'sendDelivered dispatches action: delivered with conversation_id and message_id as form-url-encoded',
        () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({'success': true}), 200);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );
      await store.setDeviceKey('gcdk_delivered_key', 'inst_1');

      final success = await store.sendDelivered(
        conversationId: 'conv_7',
        messageId: 'msg_812',
      );

      expect(success, isTrue);
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.headers['X-Device-Key'],
          equals('gcdk_delivered_key'));
      expect(capturedRequest!.headers['Content-Type'],
          contains('application/x-www-form-urlencoded'));
      expect(capturedRequest!.bodyFields['action'], equals('delivered'));
      expect(capturedRequest!.bodyFields['conversation_id'], equals('conv_7'));
      expect(capturedRequest!.bodyFields['message_id'], equals('msg_812'));
    });

    test('sendReply dispatches action: reply with text and client_id',
        () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({'success': true, 'id': 999}), 201);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );
      await store.setDeviceKey('gcdk_reply_key', 'inst_1');

      final result = await store.sendReply(
        conversationId: 'conv_7',
        messageId: 'msg_812',
        text: 'On my way',
      );

      expect(result.success, isTrue);
      expect(result.statusCode, equals(201));
      expect(result.isDuplicate, isFalse);

      expect(capturedRequest, isNotNull);
      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['action'], equals('reply'));
      expect(body['conversation_id'], equals('conv_7'));
      expect(body['message_id'], equals('msg_812'));
      expect(body['text'], equals('On my way'));
      expect(body['client_id'], isNotNull);
      expect((body['client_id'] as String).length, equals(36));
    });

    test(
        'sendReply on 403 extracts server error message for blocked contact or read-only group',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'message':
                'You have blocked this contact. Unblock to send a message.'
          }),
          403,
        );
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );
      await store.setDeviceKey('gcdk_reply_key', 'inst_1');

      final result = await store.sendReply(
        conversationId: 'conv_blocked',
        messageId: 'msg_1',
        text: 'Hello',
      );

      expect(result.success, isFalse);
      expect(result.statusCode, equals(403));
      expect(result.errorMessage,
          equals('You have blocked this contact. Unblock to send a message.'));
    });

    test('muteChat dispatches action: mute with conversation_id', () async {
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'mutedUntil': '2026-11-03 01:15:00.000'}),
          200,
        );
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );
      await store.setDeviceKey('gcdk_mute_key', 'inst_1');

      final success = await store.muteChat(conversationId: 'conv_7');

      expect(success, isTrue);
      expect(capturedRequest, isNotNull);
      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['action'], equals('mute'));
      expect(body['conversation_id'], equals('conv_7'));
    });

    test(
        'flushOfflineQueue preserves reply client_id during retries for idempotency',
        () async {
      Map<String, dynamic>? lastBody;
      final mockClient = MockClient((request) async {
        lastBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({'success': true, 'duplicate': true}), 200);
      });

      final store = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );
      await store.setDeviceKey('gcdk_retry_key', 'inst_1');

      final prefs = await SharedPreferences.getInstance();
      const fixedClientId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b';
      await prefs.setStringList('circle_connect_offline_read_queue', [
        jsonEncode({
          'action': 'reply',
          'conversation_id': 'conv_retry',
          'message_id': 'msg_retry',
          'text': 'Retried message',
          'client_id': fixedClientId,
          'base_url': CircleConnectDeviceKeyStore.defaultBaseUrl,
          'timestamp': '123456789',
        }),
      ]);

      await store.flushOfflineQueue();

      expect(lastBody, isNotNull);
      expect(lastBody!['action'], equals('reply'));
      expect(lastBody!['client_id'], equals(fixedClientId));
      expect(lastBody!['text'], equals('Retried message'));

      final queueAfter =
          prefs.getStringList('circle_connect_offline_read_queue');
      expect(queueAfter, isEmpty);
    });

    test(
        'Dual storage fallback: when secure storage read fails/returns null, getDeviceKey reads from SharedPreferences',
        () async {
      final store = CircleConnectDeviceKeyStore(storage: mockStorage);

      // Save key — writes to both secure storage and SharedPreferences
      await store.setDeviceKey('gcdk_dual_storage_key_999', 'inst_dual_123');

      // Verify both have it
      expect(await store.getDeviceKey(), equals('gcdk_dual_storage_key_999'));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('efactor.circle_connect.device_key_unencrypted_cache'),
        equals('gcdk_dual_storage_key_999'),
      );

      // Simulate Android Keystore being locked/unavailable in background isolate:
      // clear the secure storage mock, leaving only SharedPreferences intact
      mockSecureStore.clear();

      // getDeviceKey must still return the key via SharedPreferences fallback!
      final recoveredKey = await store.getDeviceKey();
      expect(recoveredKey, equals('gcdk_dual_storage_key_999'));

      // sendDelivered must succeed even when Keystore is locked/empty
      http.Request? capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({'success': true}), 200);
      });

      final fallbackStore = CircleConnectDeviceKeyStore(
        storage: mockStorage,
        client: mockClient,
      );

      final delivered = await fallbackStore.sendDelivered(
        conversationId: 'conv_bg_locked',
        messageId: 'msg_bg_locked',
      );

      expect(delivered, isTrue);
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.headers['X-Device-Key'],
          equals('gcdk_dual_storage_key_999'));
      expect(capturedRequest!.bodyFields['action'], equals('delivered'));
      expect(capturedRequest!.bodyFields['conversation_id'],
          equals('conv_bg_locked'));
      expect(
          capturedRequest!.bodyFields['message_id'], equals('msg_bg_locked'));

      // clearDeviceKey removes from both secure storage and SharedPreferences
      await store.clearDeviceKey();
      expect(await store.getDeviceKey(), isNull);
      expect(
        prefs.getString('efactor.circle_connect.device_key_unencrypted_cache'),
        isNull,
      );
    });

    test(
        'Darwin notification categories for Step 2: Reply (text), Mark as read, Mute',
        () {
      final categories = kDarwinNotificationCategories;

      final messagesCat = categories.firstWhere(
        (c) => c.identifier == 'messages_category',
      );
      final actionIds = messagesCat.actions.map((a) => a.identifier).toList();
      // Step 2: Reply, Mark as read, and Mute are all enabled
      expect(actionIds, equals(['reply', 'mark_as_read', 'mute']));

      final lockedCat = categories.firstWhere(
        (c) => c.identifier == 'messages_locked_category',
      );
      expect(lockedCat.actions, isEmpty);
    });
  });
}
