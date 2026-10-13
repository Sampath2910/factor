import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'device_command_transport.dart';

/// HTTP REST implementation of [DeviceCommandTransport].
///
/// Posts the command payload to the Efactor parameters endpoint and maps the
/// HTTP response to a [DeviceCommandResult].
///
/// Auth: the Efactor API uses `Authorization: Bearer <accessToken>` headers.
/// The token is provided by [DeviceCommandRequest.accessToken]; if absent the
/// request is sent without an auth header so the server can return a clean 401.
class EfactorHttpTransport implements DeviceCommandTransport {
  EfactorHttpTransport({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _defaultTimeout = Duration(seconds: 30);

  static bool _isTrustedEfactorHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'efactor.tech' || normalized.endsWith('.efactor.tech');
  }

  @override
  Future<DeviceCommandResult> send(DeviceCommandRequest request) async {
    final endpoint = request.endpointUrl?.trim() ?? '';
    final uri = Uri.tryParse(endpoint);
    if (endpoint.isEmpty || uri == null || !uri.hasScheme) {
      return DeviceCommandResult(
        status: DeviceCommandStatus.invalidCommand,
        message:
            '[Device Command] Invalid endpoint URL: "${request.endpointUrl ?? ""}". '
            'Schema apiContracts.parameters.url may be missing or malformed.',
      );
    }

    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };

    final token = request.accessToken?.trim();
    if (token != null && token.isNotEmpty && _isTrustedEfactorHost(uri.host)) {
      headers['Authorization'] = 'Bearer $token';
    }

    final payload = request.toPayload();

    try {
      final response = await _client
          .post(uri, headers: headers, body: jsonEncode(payload))
          .timeout(_defaultTimeout);

      final code = response.statusCode;
      final body = response.body;

      if (code == 401 || code == 403) {
        return DeviceCommandResult(
          status: DeviceCommandStatus.authFailure,
          httpStatusCode: code,
          message:
              '[Device Command] Authentication failed (HTTP $code).\n'
              'Control: ${request.controlId ?? "unknown"}\n'
              'Parameter: ${request.parameter}\n'
              'Binding: ${request.binding ?? "N/A"}\n'
              'The authenticated session may have expired or the token is missing.',
          responseBody: body,
        );
      }

      if (code < 200 || code >= 300) {
        return DeviceCommandResult(
          status: DeviceCommandStatus.rejected,
          httpStatusCode: code,
          message:
              '[Device Command] Server rejected command (HTTP $code).\n'
              'Control: ${request.controlId ?? "unknown"}\n'
              'Parameter: ${request.parameter}\n'
              'Binding: ${request.binding ?? "N/A"}\n'
              'Model: ${request.modelId}  Node: ${request.nodeId}\n'
              'Response: $body',
          responseBody: body,
        );
      }

      // HTTP 2xx — server accepted the request.
      // The REST endpoint queues the command; it does NOT wait for a device ACK.
      return DeviceCommandResult(
        status: DeviceCommandStatus.accepted,
        httpStatusCode: code,
        message:
            'Command accepted by server (HTTP $code). '
            'Device delivery is not confirmed via REST.',
        responseBody: body,
      );
    } on TimeoutException {
      return const DeviceCommandResult(
        status: DeviceCommandStatus.timeout,
        message:
            '[Device Command] Request timed out. '
            'The server did not respond within 30 s. '
            'Check network connectivity and server status.',
      );
    } on SocketException catch (e) {
      return DeviceCommandResult(
        status: DeviceCommandStatus.offline,
        message:
            '[Device Command] Network error: ${e.message}.\n'
            'The device cannot be reached. Check Wi-Fi / internet connectivity.',
      );
    } catch (e) {
      return DeviceCommandResult(
        status: DeviceCommandStatus.rejected,
        message:
            '[Device Command] Unexpected error: $e\n'
            'Control: ${request.controlId ?? "unknown"}\n'
            'Parameter: ${request.parameter}',
      );
    }
  }
}
