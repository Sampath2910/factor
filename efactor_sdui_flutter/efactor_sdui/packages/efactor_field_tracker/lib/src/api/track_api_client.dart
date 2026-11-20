import 'dart:convert';

import 'package:http/http.dart' as http;

import '../identity/tracker_identity.dart';
import '../models/breadcrumb.dart';
import '../models/tracking_event.dart';
import '../models/tracking_policy.dart';

/// Result of an effective-policy fetch: either unchanged (HTTP 304, keep the
/// cached policy) or a fresh policy.
class EffectivePolicyResult {
  const EffectivePolicyResult.notModified()
      : notModified = true,
        policy = null;
  const EffectivePolicyResult.policy(this.policy) : notModified = false;

  final bool notModified;
  final TrackingPolicy? policy;
}

/// Thin HTTP client for the Phase 0 track endpoints. Transport only — it holds
/// no tracking state.
class TrackApiClient {
  TrackApiClient({
    required this.tokenProvider,
    this.baseUrl = defaultBaseUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const String defaultBaseUrl =
      'https://efactor.tech/index.php/api/track';

  final String baseUrl;

  /// Supplies the current Bearer access token at call time (so token refresh is
  /// transparent to this client).
  final String Function() tokenProvider;

  final http.Client _client;

  Map<String, String> _headers({bool json = true}) => <String, String>{
        if (json) 'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer ${tokenProvider()}',
      };

  /// GET /effective-policy — sends the cached `v`; a 304 means keep the cache.
  Future<EffectivePolicyResult> fetchEffectivePolicy({
    required TrackerIdentity identity,
    String? currentVersion,
  }) async {
    final query = <String, String>{
      ...identity.query,
      if (currentVersion != null && currentVersion.isNotEmpty)
        'v': currentVersion,
    };
    final uri =
        Uri.parse('$baseUrl/effective-policy').replace(queryParameters: query);

    final res = await _client
        .get(uri, headers: _headers(json: false))
        .timeout(const Duration(seconds: 15));

    if (res.statusCode == 304) {
      return const EffectivePolicyResult.notModified();
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        return EffectivePolicyResult.policy(
          TrackingPolicy.fromResponse(decoded),
        );
      }
      throw const FormatException('effective-policy: unexpected response shape');
    }
    throw http.ClientException(
      'effective-policy failed: HTTP ${res.statusCode}',
      uri,
    );
  }

  /// POST /breadcrumbs/batch — returns true on 2xx (idempotent server-side).
  Future<bool> postBreadcrumbs({
    required TrackerIdentity identity,
    required List<Breadcrumb> points,
  }) async {
    if (points.isEmpty) return true;
    final uri = Uri.parse('$baseUrl/breadcrumbs/batch');
    final body = jsonEncode(<String, dynamic>{
      ...identity.body,
      'points': points.map((p) => p.toJson()).toList(),
    });
    final res = await _client
        .post(uri, headers: _headers(), body: body)
        .timeout(const Duration(seconds: 20));
    return res.statusCode >= 200 && res.statusCode < 300;
  }

  /// POST /events — check-in / check-out.
  Future<bool> postEvent({
    required TrackerIdentity identity,
    required TrackingEvent event,
  }) async {
    final uri = Uri.parse('$baseUrl/events');
    final body = jsonEncode(<String, dynamic>{
      ...identity.body,
      ...event.toJson(),
    });
    final res = await _client
        .post(uri, headers: _headers(), body: body)
        .timeout(const Duration(seconds: 20));
    return res.statusCode >= 200 && res.statusCode < 300;
  }

  /// GET /live — last-known positions. Omit [userId] for the whole tenant;
  /// pass it for a single user. Returns the decoded JSON as-is (the backend has
  /// not yet published a typed response shape — map to models once it does).
  Future<dynamic> fetchLive({
    required TrackerIdentity identity,
    String? userId,
  }) async {
    final query = <String, String>{
      'app_id': identity.appId,
      'tenant_id': identity.tenantId,
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
    };
    final uri = Uri.parse('$baseUrl/live').replace(queryParameters: query);
    final res = await _client
        .get(uri, headers: _headers(json: false))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body);
    }
    throw http.ClientException('live failed: HTTP ${res.statusCode}', uri);
  }

  /// GET /history — route playback for [from]..[to] (ISO-8601). Omit [userId]
  /// for all tenant users. Returns the decoded JSON as-is for now.
  Future<dynamic> fetchHistory({
    required TrackerIdentity identity,
    required String from,
    required String to,
    String? userId,
  }) async {
    final query = <String, String>{
      'app_id': identity.appId,
      'tenant_id': identity.tenantId,
      'from': from,
      'to': to,
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
    };
    final uri = Uri.parse('$baseUrl/history').replace(queryParameters: query);
    final res = await _client
        .get(uri, headers: _headers(json: false))
        .timeout(const Duration(seconds: 25));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body);
    }
    throw http.ClientException('history failed: HTTP ${res.statusCode}', uri);
  }

  void close() => _client.close();
}
