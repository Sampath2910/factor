import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:efactor_sdui/services/incoming_call_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IncomingCallData & IncomingCallService Tests', () {
    test('IncomingCallData correctly parses audio and video call JSON payloads', () {
      final audioJson = <String, dynamic>{
        'call_id': 'call_101',
        'caller_id': '707',
        'caller_name': 'Pavan',
        'call_type': 'audio',
        'room_url': 'https://efactor.tech/index.php/grid-chat?room=101',
        'timestamp': 1728456000,
      };

      final audioCall = IncomingCallData.fromJson(audioJson);
      expect(audioCall.callId, 'call_101');
      expect(audioCall.callerId, '707');
      expect(audioCall.callerName, 'Pavan');
      expect(audioCall.isVideo, isFalse);
      expect(audioCall.roomUrl, 'https://efactor.tech/index.php/grid-chat?room=101');

      final videoJson = <String, dynamic>{
        'call_id': 'call_102',
        'caller_id': '808',
        'caller_name': 'Dr. Sharma',
        'call_type': 'video',
        'room_url': 'https://efactor.tech/index.php/grid-chat?room=102',
      };

      final videoCall = IncomingCallData.fromJson(videoJson);
      expect(videoCall.callId, 'call_102');
      expect(videoCall.isVideo, isTrue);
    });

    test('IncomingCallData defaults roomUrl to standard grid-chat endpoint when omitted', () {
      final minimalJson = <String, dynamic>{
        'call_id': 'call_200',
        'caller_id': '505',
        'caller_name': 'Circle Member',
      };

      final call = IncomingCallData.fromJson(minimalJson);
      expect(call.callId, 'call_200');
      expect(call.callerId, '505');
      expect(call.roomUrl, IncomingCallData.defaultCallUrl);
      expect(call.roomUrl, 'https://efactor.tech/index.php/grid-chat');
    });

    test('cold-start answer URL targets GRID Chat and keeps the same call id', () async {
      final service = IncomingCallService.instance;
      final call = IncomingCallData.fromJson(<String, dynamic>{
        'call_id': 'call_cold_1',
        'caller_grid_id': 'grid_9',
        'call_type': 'audio',
        'caller_name': 'Asha',
        'type': 'INCOMING_CALL',
      });

      await service.recordNotificationAnswer(call);
      final pending = service.pendingAnswer;
      expect(pending, isNotNull);
      expect(pending!.callId, 'call_cold_1');

      final uri = IncomingCallService.answerGridChatUri(pending);
      expect(
        uri.toString(),
        'https://efactor.tech/index.php/grid-chat?call_action=answer&call_id=call_cold_1&call_type=audio&grid_id=grid_9',
      );

      service.logGridChatNavigation(pending.callId);
      service.logGridChatNavigation(pending.callId);
      expect(service.pendingAnswer?.callId, 'call_cold_1');

      await service.clearPendingAnswer(
        reason: 'cancelled',
        callId: 'other_call',
      );
      expect(service.pendingAnswer?.callId, 'call_cold_1');

      await service.clearPendingAnswer(
        reason: 'delivered',
        callId: 'call_cold_1',
      );
      expect(service.pendingAnswer, isNull);
    });

    test('answer URL uses audio unless the call is video', () {
      final pending = PendingCallAnswer.fromCall(
        IncomingCallData.fromJson(<String, dynamic>{
          'call_id': 'call_cold_2',
          'type': 'INCOMING_CALL',
          'caller_grid_id': 'g2',
        }),
      );
      expect(pending.normalizedCallType, 'audio');
      expect(
        IncomingCallService.answerGridChatUri(pending).queryParameters['call_type'],
        'audio',
      );

      final video = PendingCallAnswer(
        callId: 'call_cold_video',
        gridId: '',
        callType: 'video',
        callerName: 'Asha',
        callerUserId: '7',
        storedAtMs: DateTime.now().millisecondsSinceEpoch -
            const Duration(minutes: 5).inMilliseconds,
      );
      expect(video.isExpired, isTrue);
      expect(
        IncomingCallService.answerGridChatUri(video).queryParameters['grid_id'],
        isNull,
      );
    });

    test('native incoming notification is posted only when GRID Chat is not ready', () {
      expect(
        IncomingCallService.shouldPostNativeIncomingNotification(
          circleConnectReady: true,
        ),
        isFalse,
      );
      expect(
        IncomingCallService.shouldPostNativeIncomingNotification(
          circleConnectReady: false,
        ),
        isTrue,
      );
    });

    test('IncomingCallService handles incoming call payload and cancellation', () {
      final service = IncomingCallService.instance;

      service.handleIncomingPayload(<String, dynamic>{
        'type': 'INCOMING_CALL',
        'call_id': 'call_999',
        'caller_id': '707',
        'caller_name': 'Pavan',
        'call_type': 'video',
      });

      expect(service.currentCall.value, isNotNull);
      expect(service.currentCall.value?.callId, 'call_999');
      expect(service.currentCall.value?.roomUrl, 'https://efactor.tech/index.php/grid-chat');

      // Cancellation
      service.handleIncomingPayload(<String, dynamic>{
        'type': 'CALL_CANCELLED',
        'call_id': 'call_999',
      });

      expect(service.currentCall.value, isNull);
    });

    test('registerDeviceTokenWithBackend posts correct JSON payload and auth headers', () async {
      final service = IncomingCallService.instance;
      http.Request? capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode(<String, dynamic>{'status': 'success'}), 200);
      });

      final success = await service.registerDeviceTokenWithBackend(
        backendUrl: 'https://efactor.tech/index.php/api/register_device_token',
        userId: '1234',
        deviceToken: 'mock_fcm_token_abc',
        platform: 'android',
        tokenType: 'fcm',
        accessToken: 'bearer_token_xyz',
        client: mockClient,
      );

      expect(success, isTrue);
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.url.toString(), 'https://efactor.tech/index.php/api/register_device_token');
      expect(capturedRequest!.headers['Authorization'], 'Bearer bearer_token_xyz');
      expect(capturedRequest!.headers['Content-Type'], 'application/json');

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['user_id'], '1234');
      expect(body['device_token'], 'mock_fcm_token_abc');
      expect(body['platform'], 'android');
      expect(body['token_type'], 'fcm');
    });

    test('syncDeviceTokenOnLogin caches credentials and triggers backend token sync', () async {
      final service = IncomingCallService.instance;
      http.Request? capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode(<String, dynamic>{'status': 'ok'}), 200);
      });

      service.setDeviceToken('token_from_fcm');
      final result = await service.syncDeviceTokenOnLogin(
        userId: '888',
        accessToken: 'access_jwt_123',
        client: mockClient,
      );

      expect(result, isTrue);
      expect(service.activeUserId, 888);
      expect(service.activeAccessToken, 'access_jwt_123');
      expect(capturedRequest, isNotNull);

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['user_id'], '888');
      expect(body['device_token'], 'token_from_fcm');
    });

    test('unregisterDeviceTokenOnLogout sends unregister action and clears session', () async {
      final service = IncomingCallService.instance;
      http.Request? capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode(<String, dynamic>{'status': 'ok'}), 200);
      });

      service.activeUserId = 999;
      service.activeAccessToken = 'logout_jwt';

      final ok = await service.unregisterDeviceTokenOnLogout(
        client: mockClient,
      );

      expect(ok, isTrue);
      expect(service.activeUserId, isNull);
      expect(service.activeAccessToken, isNull);
      expect(capturedRequest, isNotNull);

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['action'], 'unregister_device_token');
      expect(body['user_id'], '999');
    });

    test('declineCall posts native_action decline payload to backend when action_token is present', () async {
      final service = IncomingCallService.instance;
      http.Request? capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode(<String, dynamic>{'status': 'ok'}), 200);
      });

      final call = IncomingCallData.fromJson(<String, dynamic>{
        'call_id': 'call_777',
        'caller_grid_id': 'GRID-444',
        'caller_name': 'Alice',
        'action_token': 'tok_777',
      });

      await service.declineCall(
        call,
        rejectApiUrl: 'https://efactor.tech/api/call_action',
        client: mockClient,
      );

      expect(capturedRequest, isNotNull);
      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['action'], 'decline');
      expect(body['action_token'], 'tok_777');
    });

    test('registerDeviceTokenWithBackend synchronizes FCM token with grid-chat native-token endpoint using Bearer auth', () async {
      final service = IncomingCallService.instance;
      final requests = <http.Request>[];

      final mockClient = MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode(<String, dynamic>{'status': 'ok'}), 200);
      });

      final success = await service.registerDeviceTokenWithBackend(
        userId: '54321',
        deviceToken: 'device_token_fcm_999',
        platform: 'android',
        tokenType: 'fcm',
        accessToken: 'user_active_access_token_abc',
        client: mockClient,
      );

      expect(success, isTrue);
      final nativeTokenReq = requests.firstWhere(
        (r) => r.url.path.contains('/grid-chat/api/push/native-token'),
      );
      expect(nativeTokenReq.headers['Authorization'], 'Bearer user_active_access_token_abc');
      final body = jsonDecode(nativeTokenReq.body) as Map<String, dynamic>;
      expect(body['user_id'], '54321');
      expect(body['device_token'], 'device_token_fcm_999');
      expect(body['platform'], 'android');
      expect(body['token_type'], 'fcm');
    });
  });
}

