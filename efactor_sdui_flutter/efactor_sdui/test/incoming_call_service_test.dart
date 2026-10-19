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

    test('declineCall posts call_rejected payload to backend', () async {
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
      });

      await service.declineCall(
        call,
        rejectApiUrl: 'https://efactor.tech/api/call_action',
        client: mockClient,
      );

      expect(capturedRequest, isNotNull);
      final body = Uri.splitQueryString(capturedRequest!.body);
      expect(body['call_id'], 'call_777');
      expect(body['caller_grid_id'], 'GRID-444');
    });
  });
}
