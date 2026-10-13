import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../services/json_http.dart';

/// Sends scanner information to the Efactor PHP scan API.
///
/// POST endpoint:
/// http://efactor.tech/v8/api_scan.php
///
/// Request body (4 fields only):
/// {
///   "model_no":  "STUDIO_9_7",
///   "node_id":   "kiran",
///   "device_id": "GW001",
///   "qr_value":  "QR123456789"
/// }
class ScanRepository {
  ScanRepository({http.Client? client, String? urlTemplate})
    : _client = client ?? http.Client(),
      _scanEndpoint = urlTemplate ?? defaultScanEndpoint;

  static const String defaultScanEndpoint = String.fromEnvironment(
    'SCAN_API_URL',
    defaultValue: 'https://efactor.tech/v8/api_scan.php',
  );

  static const Duration _timeout = Duration(seconds: 20);

  final http.Client _client;
  final String _scanEndpoint;

  /// Resolves the scan endpoint from the live Device schema first.
  ///
  /// [endpointOverride] is supplied by AppState from the current schema
  /// (apiContracts/meta/_clientConnection). The configured repository endpoint
  /// is used only as a compatibility fallback when the live schema does not
  /// publish a scan endpoint.
  Uri buildUri({
    required String modelId,
    required String nodeId,
    String? endpointOverride,
  }) {
    final schemaEndpoint = endpointOverride?.trim() ?? '';
    final endpoint = schemaEndpoint.isNotEmpty
        ? schemaEndpoint
        : _scanEndpoint.trim();
    final uri = Uri.parse(endpoint);

    if (!uri.hasScheme ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw FormatException('Invalid scanner API URL: $endpoint');
    }

    return uri;
  }

  Map<String, dynamic> buildScanPayload({
    required String modelId,
    required String nodeId,
    required String value,
    Map<String, dynamic>? extra,
  }) {
    final fields = Map<String, dynamic>.from(extra ?? const {});

    // model_no: from extra (set by scanner_action) or fallback to modelId
    final modelNo = _required(
      _firstNonEmpty(<dynamic>[fields['model_no'], fields['modelNo'], modelId]),
      'model_no',
    );

    // node_id: from extra or fallback to nodeId (NODE_ID from connection screen)
    final resolvedNodeId = _required(
      _firstNonEmpty(<dynamic>[fields['node_id'], fields['nodeId'], nodeId]),
      'node_id',
    );

    // device_id: from extra or fallback to nodeId
    final deviceId = _required(
      _firstNonEmpty(<dynamic>[
        fields['device_id'],
        fields['deviceId'],
        nodeId,
      ]),
      'device_id',
    );

    // qr_value: the scanned value
    final qrValue = _required(
      _firstNonEmpty(<dynamic>[fields['qr_value'], fields['qrValue'], value]),
      'qr_value',
    );

    return <String, dynamic>{
      'model_no': modelNo,
      'node_id': resolvedNodeId,
      'device_id': deviceId,
      'qr_value': qrValue,
    };
  }

  /// Keeps the previous public signature so AppState does not need to change.
  /// Only the new six-field PHP payload is sent.
  Future<ScanPostResult> postScan({
    required String modelId,
    required String nodeId,
    required String scanId,
    required String value,
    required String format,
    required DateTime scannedAt,
    String feature = 'qrBarcodeScan',
    Map<String, dynamic>? extra,
    String? endpointOverride,
  }) async {
    final model = _required(modelId, 'MODEL_ID');
    final node = _required(nodeId, 'NODE_ID');
    final normalizedQrValue = _required(value, 'qr_value');

    final uri = buildUri(
      modelId: model,
      nodeId: node,
      endpointOverride: endpointOverride,
    );

    final payload = buildScanPayload(
      modelId: model,
      nodeId: node,
      value: normalizedQrValue,
      extra: extra,
    );

    debugPrint('[ScanRepository] POST $uri');
    debugPrint(
      '[ScanRepository] PAYLOAD '
      'model_no=${payload['model_no']} '
      'node_id=${payload['node_id']} '
      'device_id=${payload['device_id']} '
      'qr_present=${(payload['qr_value']?.toString() ?? '').isNotEmpty}',
    );

    final response = await _send(
      () => _client.post(
        uri,
        headers: const <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(payload),
      ),
      uri: uri,
      operation: 'send scan',
    );

    final body = _decodeBody(response);

    debugPrint('[ScanRepository] HTTP_STATUS=${response.statusCode}');

    if (!_isSuccess(response.statusCode)) {
      throw _httpException(
        response: response,
        body: body,
        uri: uri,
        operation: 'store scan',
      );
    }

    return ScanPostResult(
      statusCode: response.statusCode,
      message: _messageFromResponse(body, fallback: 'Scan sent successfully.'),
      data: _dataFromResponse(body),
      resourceUri: uri,
    );
  }

  /// The new PHP contract supplied for this change only defines POST.
  /// Keep this method for compatibility with existing AppState code.
  Future<ScanRecord?> getLatestScan({
    required String modelId,
    required String nodeId,
    String? endpointOverride,
  }) async {
    debugPrint(
      '[ScanRepository] GET skipped: '
      'the new api_scan.php contract is POST-only.',
    );
    return null;
  }

  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    required Uri uri,
    required String operation,
  }) async {
    try {
      return await request().timeout(_timeout);
    } catch (error, stackTrace) {
      debugPrint('[ScanRepository] Failed to $operation: $error');
      debugPrintStack(stackTrace: stackTrace);

      throw ScanRepositoryException(
        message: 'Unable to $operation.',
        uri: uri,
        cause: error,
      );
    }
  }

  bool _isSuccess(int statusCode) {
    return statusCode >= 200 && statusCode < 300;
  }

  ScanRepositoryException _httpException({
    required http.Response response,
    required dynamic body,
    required Uri uri,
    required String operation,
  }) {
    return ScanRepositoryException(
      message: _messageFromResponse(
        body,
        fallback: 'Unable to $operation. HTTP ${response.statusCode}.',
      ),
      statusCode: response.statusCode,
      responseBody: body,
      uri: uri,
    );
  }

  dynamic _decodeBody(http.Response response) {
    if (response.bodyBytes.isEmpty) return null;

    final raw = utf8.decode(response.bodyBytes).trim();
    if (raw.isEmpty) return null;

    if (looksLikeHtml(raw)) {
      throw FormatException(
        'Scan API returned HTML instead of JSON.',
      );
    }
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  String _messageFromResponse(dynamic body, {required String fallback}) {
    if (body is Map) {
      for (final key in const <String>[
        'message',
        'error',
        'detail',
        'status',
      ]) {
        final value = body[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString().trim();
        }
      }
    }

    if (body is String && body.trim().isNotEmpty) {
      return body.trim();
    }

    return fallback;
  }

  Map<String, dynamic>? _dataFromResponse(dynamic body) {
    if (body is! Map) return null;

    final root = Map<String, dynamic>.from(body);
    final data = root['data'];

    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }

    return root;
  }

  String _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final normalized = value?.toString().trim();
      if (normalized != null && normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  String _required(String value, String fieldName) {
    final normalized = value.trim();

    if (normalized.isEmpty) {
      throw FormatException('$fieldName is required.');
    }

    return normalized;
  }

  void dispose() {
    _client.close();
  }
}

@immutable
class ScanPostResult {
  const ScanPostResult({
    required this.statusCode,
    required this.message,
    required this.resourceUri,
    this.data,
  });

  final int statusCode;
  final String message;
  final Uri resourceUri;
  final Map<String, dynamic>? data;
}

/// Kept for compatibility with AppState.fetchLatestScanResult().
@immutable
class ScanRecord {
  const ScanRecord({
    required this.scanId,
    required this.value,
    required this.format,
    required this.scannedAt,
    this.modelId,
    this.nodeId,
    this.deviceId,
    this.feature,
  });

  factory ScanRecord.fromJson(Map<String, dynamic> json) {
    return ScanRecord(
      scanId: (json['scanId'] ?? json['id'] ?? '').toString(),
      modelId: (json['model_no'] ?? json['modelId'])?.toString(),
      nodeId: (json['node_id'] ?? json['nodeId'])?.toString(),
      deviceId: (json['device_id'] ?? json['deviceId'])?.toString(),
      value: (json['qr_value'] ?? json['value'] ?? '').toString(),
      format: (json['format'] ?? 'qr').toString(),
      scannedAt: (json['scannedAt'] ?? '').toString(),
      feature: json['feature']?.toString(),
    );
  }

  final String scanId;
  final String? modelId;
  final String? nodeId;
  final String? deviceId;
  final String value;
  final String format;
  final String scannedAt;
  final String? feature;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'scanId': scanId,
      if (modelId != null) 'model_no': modelId,
      if (nodeId != null) 'node_id': nodeId,
      if (deviceId != null) 'device_id': deviceId,
      'value': value,
      'format': format,
      'scannedAt': scannedAt,
      if (feature != null) 'feature': feature,
    };
  }
}

class ScanRepositoryException implements Exception {
  const ScanRepositoryException({
    required this.message,
    this.statusCode,
    this.responseBody,
    this.uri,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final dynamic responseBody;
  final Uri? uri;
  final Object? cause;

  @override
  String toString() {
    return 'ScanRepositoryException: $message'
        '${statusCode == null ? '' : ' | HTTP $statusCode'}'
        '${uri == null ? '' : ' | $uri'}';
  }
}
