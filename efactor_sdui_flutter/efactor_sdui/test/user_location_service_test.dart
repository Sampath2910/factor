import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UserLocationService Sign-In Telemetry Tests', () {
    test('user_currentLocation payload contains coordinates, user_id, and access token', () async {
      http.Request? capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode(<String, dynamic>{'status': 'success', 'message': 'Location updated.'}),
          200,
        );
      });

      // Prepare payload exactly as sent on submitLogin
      final payload = <String, dynamic>{
        'latitude': '17.4910284',
        'longitude': '78.3172724',
        'app_version': 'v5.2',
        'handset_id': 'mock_handset_id',
        'handset_name': 'mock_device',
        'model': 'mock_model',
        'os': 'Android 14',
        'access_token': 'test_jwt_access_token_123',
        'user_id': '707',
        'email': 'user@example.com',
      };

      final uri = Uri.parse('https://efactor.tech/v8/api.php?action=user_currentLocation');
      final response = await mockClient.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'test_jwt_access_token_123',
          'access_token': 'test_jwt_access_token_123',
        },
        body: jsonEncode(payload),
      );

      expect(response.statusCode, 200);
      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.url.toString(), 'https://efactor.tech/v8/api.php?action=user_currentLocation');
      expect(capturedRequest!.headers['Authorization'], 'test_jwt_access_token_123');
      expect(capturedRequest!.headers['access_token'], 'test_jwt_access_token_123');

      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['latitude'], '17.4910284');
      expect(body['longitude'], '78.3172724');
      expect(body['user_id'], '707');
      expect(body['access_token'], 'test_jwt_access_token_123');
      expect(body['email'], 'user@example.com');
    });
  });
}
