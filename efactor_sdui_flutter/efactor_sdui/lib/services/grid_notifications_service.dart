import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'call_lifecycle_tracker.dart';
import 'grid_unread_counts_service.dart';
import 'incoming_call_service.dart';
import 'ongoing_call_service.dart';

class _FeedFetchResult {
  const _FeedFetchResult({
    required this.items,
    required this.ok,
    this.unreadOverride,
    this.activeCall,
  });

  final List<Map<String, dynamic>> items;
  final bool ok;
  final int? unreadOverride;
  final Map<String, dynamic>? activeCall;
}

/// Service managing GRID & Circle Connect notifications (the bell icon & Updates feed).
/// Interacts with live backend endpoints:
/// - GET /index.php/grid/api/notifications?limit=30
/// - POST /index.php/grid/api/notifications/mark-read
/// - GET /index.php/grid-chat/api/notifications?limit=30
/// - POST /index.php/grid-chat/api/notifications/mark-read
/// - GET /index.php/grid-chat/api/call/active
class GridNotificationsService {
  GridNotificationsService._();
  static final GridNotificationsService instance = GridNotificationsService._();

  final ValueNotifier<List<Map<String, dynamic>>> notifications =
      ValueNotifier<List<Map<String, dynamic>>>(const <Map<String, dynamic>>[]);
  final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(false);
  final ValueNotifier<Map<String, dynamic>?> activeGroupCall =
      ValueNotifier<Map<String, dynamic>?>(null);

  /// Helper to convert relative time from an ISO timestamp string or DateTime.
  /// E.g. "2026-11-24T09:12:33+00:00" -> "2h", "yesterday", etc.
  static String formatRelativeTime(dynamic timestamp) {
    if (timestamp == null) return '';
    DateTime? dt;
    if (timestamp is DateTime) {
      dt = timestamp;
    } else {
      dt = DateTime.tryParse(timestamp.toString().trim());
    }
    if (dt == null) return timestamp.toString().trim();

    final now = DateTime.now();
    final diff = now.difference(dt.toLocal());

    if (diff.isNegative || diff.inSeconds < 45) {
      return 'just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h';
    } else if (diff.inDays == 1) {
      return 'yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d';
    } else if (diff.inDays < 30) {
      final weeks = (diff.inDays / 7).floor();
      return '${weeks}w';
    } else {
      const months = <String>[
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ];
      return '${dt.day} ${months[dt.month - 1]}';
    }
  }

  /// Helper to derive initials from actor_name.
  static String getInitials(String? name) {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return 'U';
    final parts =
        trimmed.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) {
      final single = parts[0];
      return single.substring(0, single.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  static String _originForBaseUrl(String? baseUrl) {
    const defaultTarget = 'https://efactor.tech/index.php/grid';
    final target = baseUrl ?? defaultTarget;
    final cleanBase = target.split('?').first.replaceAll(RegExp(r'/+$'), '');
    return Uri.tryParse(cleanBase)?.origin ?? 'https://efactor.tech';
  }

  Future<String> _resolveSessionCookies(
    String primaryUrl, {
    String? fallbackUrl,
  }) async {
    var cookies = await IncomingCallService.instance.getCookiesForUrl(primaryUrl);
    if (cookies.isEmpty && fallbackUrl != null) {
      cookies = await IncomingCallService.instance.getCookiesForUrl(fallbackUrl);
    }
    return cookies;
  }

  static bool _isRowUnread(Map<String, dynamic> item) {
    final isRead = item['is_read'];
    return isRead == 0 || isRead == false || isRead == '0';
  }

  static bool _isCircleRow(Map<String, dynamic> item) {
    final source = item['_notificationSpace']?.toString().trim().toLowerCase();
    if (source == 'circle' || source == 'chat') return true;
    if (source == 'professional') return false;
    final rawType = (item['type'] ?? '').toString().toLowerCase();
    final link = (item['link'] ?? '').toString().toLowerCase();
    return rawType.contains('circle') ||
        rawType.contains('chat') ||
        link.contains('grid-chat') ||
        link.contains('/chat');
  }

  static int _timestampMillis(Map<String, dynamic> item) {
    final raw = item['created_at']?.toString().trim() ?? '';
    if (raw.isEmpty) return 0;
    return DateTime.tryParse(raw)?.millisecondsSinceEpoch ?? 0;
  }

  Future<_FeedFetchResult> _fetchFeed({
    required Uri uri,
    required String space,
    required String primaryCookieUrl,
    String? fallbackCookieUrl,
    http.Client? client,
  }) async {
    try {
      final cookies = await _resolveSessionCookies(
        primaryCookieUrl,
        fallbackUrl: fallbackCookieUrl,
      );
      final httpClient = client ?? http.Client();
      final response = await httpClient.get(
        uri,
        headers: <String, String>{
          'Accept': 'application/json',
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic> && decoded['success'] == true) {
          final listRaw = decoded['data'];
          final parsed = (listRaw is List)
              ? listRaw
                  .whereType<Map>()
                  .map((m) {
                    final row = Map<String, dynamic>.from(
                      m.cast<dynamic, dynamic>(),
                    );
                    row['_notificationSpace'] = space;
                    return row;
                  })
                  .toList()
              : <Map<String, dynamic>>[];

          final rawUnread = decoded['unread'];
          final unreadOverride =
              rawUnread is num ? rawUnread.toInt() : int.tryParse('$rawUnread');
          final rawActiveCall = decoded['active_call'];
          final activeCall = (rawActiveCall is Map)
              ? Map<String, dynamic>.from(rawActiveCall.cast<dynamic, dynamic>())
              : null;

          return _FeedFetchResult(
            items: parsed,
            ok: true,
            unreadOverride: unreadOverride,
            activeCall: activeCall,
          );
        }
      } else {
        debugPrint(
          '[GridNotifications] fetch($space) HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[GridNotifications] fetch($space) error: $e');
    }
    return const _FeedFetchResult(items: <Map<String, dynamic>>[], ok: false);
  }

  /// Fetches Circle Connect notifications from
  /// `GET /index.php/grid-chat/api/notifications?limit=$limit`.
  Future<List<Map<String, dynamic>>> fetchCircleNotifications({
    int limit = 30,
    int? beforeId,
    String? category,
    String? baseUrl,
    http.Client? client,
  }) async {
    final origin = _originForBaseUrl(baseUrl);
    final query = <String, String>{'limit': '$limit'};
    if (beforeId != null) query['before_id'] = '$beforeId';
    final cleanCategory = category?.trim();
    if (cleanCategory != null && cleanCategory.isNotEmpty) {
      query['category'] = cleanCategory;
    }
    final uri = Uri.parse('$origin/index.php/grid-chat/api/notifications')
        .replace(queryParameters: query);

    final result = await _fetchFeed(
      uri: uri,
      space: 'circle',
      primaryCookieUrl: '$origin/index.php/grid-chat',
      fallbackCookieUrl: '$origin/index.php/grid',
      client: client,
    );
    if (result.activeCall != null) {
      unawaited(_handleActiveGroupCall(result.activeCall!));
    }
    return result.items;
  }

  /// Fetches bell notifications from both Professional Space
  /// (`GET /index.php/grid/api/notifications?limit=$limit`) and Circle Connect
  /// (`GET /index.php/grid-chat/api/notifications?limit=$limit`).
  Future<List<Map<String, dynamic>>> fetchNotifications({
    int limit = 30,
    String? baseUrl,
    http.Client? client,
    bool includeCircle = true,
  }) async {
    try {
      isLoading.value = true;
      final origin = _originForBaseUrl(baseUrl);
      final profUri =
          Uri.parse('$origin/index.php/grid/api/notifications?limit=$limit');
      final circleUri = Uri.parse(
        '$origin/index.php/grid-chat/api/notifications?limit=$limit',
      );

      final profFuture = _fetchFeed(
        uri: profUri,
        space: 'professional',
        primaryCookieUrl: '$origin/index.php/grid',
        client: client,
      );
      final circleFuture = includeCircle
          ? _fetchFeed(
              uri: circleUri,
              space: 'circle',
              primaryCookieUrl: '$origin/index.php/grid-chat',
              fallbackCookieUrl: '$origin/index.php/grid',
              client: client,
            )
          : Future<_FeedFetchResult>.value(
              const _FeedFetchResult(
                items: <Map<String, dynamic>>[],
                ok: true,
              ),
            );

      final results = await Future.wait<_FeedFetchResult>(<Future<_FeedFetchResult>>[
        profFuture,
        circleFuture,
      ]);
      final profResult = results[0];
      final circleResult = results[1];

      if (!profResult.ok && !circleResult.ok) {
        return notifications.value;
      }

      if (circleResult.activeCall != null) {
        unawaited(_handleActiveGroupCall(circleResult.activeCall!));
      }

      final previousItems = notifications.value;
      final profItems = profResult.ok
          ? profResult.items
          : previousItems.where((item) => !_isCircleRow(item)).toList();
      final circleItems = circleResult.ok
          ? circleResult.items
          : (includeCircle
              ? previousItems.where(_isCircleRow).toList()
              : const <Map<String, dynamic>>[]);

      final merged = <Map<String, dynamic>>[
        ...profItems,
        ...circleItems,
      ];
      merged.sort(
        (a, b) => _timestampMillis(b).compareTo(_timestampMillis(a)),
      );

      notifications.value = merged;

      final profUnread = profItems.where(_isRowUnread).length;
      final circleUnread = circleResult.ok
          ? (circleResult.unreadOverride ??
              circleItems.where(_isRowUnread).length)
          : circleItems.where(_isRowUnread).length;
      final totalUnread = profUnread + circleUnread;
      unreadCount.value = totalUnread;
      GridUnreadCountsService.instance.unreadNotifications.value = totalUnread;
      return merged;
    } catch (e) {
      debugPrint('[GridNotifications] fetchNotifications error: $e');
    } finally {
      isLoading.value = false;
    }
    return notifications.value;
  }

  /// Checks `GET /index.php/grid-chat/api/call/active` once on app open/resume
  /// to surface any in-progress group call.
  Future<Map<String, dynamic>?> fetchActiveCall({
    String? baseUrl,
    http.Client? client,
  }) async {
    try {
      final origin = _originForBaseUrl(baseUrl);
      final cookies = await _resolveSessionCookies(
        '$origin/index.php/grid-chat',
        fallbackUrl: '$origin/index.php/grid',
      );
      final uri = Uri.parse('$origin/index.php/grid-chat/api/call/active');
      final httpClient = client ?? http.Client();
      final response = await httpClient.get(
        uri,
        headers: <String, String>{
          'Accept': 'application/json',
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic> && decoded['success'] == true) {
          final rawCall = decoded['active_call'] ??
              (decoded['data'] is Map ? decoded['data'] : null);
          if (rawCall is Map) {
            final callMap =
                Map<String, dynamic>.from(rawCall.cast<dynamic, dynamic>());
            activeGroupCall.value = callMap;
            await _handleActiveGroupCall(callMap);
            return callMap;
          }
          activeGroupCall.value = null;
        }
      }
    } catch (e) {
      debugPrint('[GridNotifications] fetchActiveCall error: $e');
    }
    return null;
  }

  Future<void> _handleActiveGroupCall(Map<String, dynamic> rawCall) async {
    if (OngoingCallService.instance.isCallActive ||
        await CallLifecycleTracker.isOngoingCallActive()) {
      return;
    }
    final call = IncomingCallData.fromJson(rawCall);
    if (call.callId.isEmpty) return;
    if (CallLifecycleTracker.isCallFinishedSync(call.callId)) return;
    await IncomingCallService.instance.showCallScreen(call);
  }

  /// Fetches unread count from `GET /grid/api/notifications/unread-count`.
  Future<int?> fetchUnreadCount({
    String? baseUrl,
    http.Client? client,
  }) async {
    try {
      final origin = _originForBaseUrl(baseUrl);
      final cookies = await _resolveSessionCookies('$origin/index.php/grid');
      final uri =
          Uri.parse('$origin/index.php/grid/api/notifications/unread-count');

      final httpClient = client ?? http.Client();
      final response = await httpClient.get(
        uri,
        headers: <String, String>{
          'Accept': 'application/json',
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          final countRaw = data['data']?['count'];
          final count = int.tryParse(countRaw?.toString() ?? '') ?? 0;
          unreadCount.value = count;
          GridUnreadCountsService.instance.unreadNotifications.value = count;
          return count;
        }
      }
    } catch (e) {
      debugPrint('[GridNotifications] fetchUnreadCount error: $e');
    }
    return null;
  }

  /// Marks notification(s) as read via either:
  /// - `POST /index.php/grid-chat/api/notifications/mark-read` (when [space] is `'circle'`/`'chat'`)
  /// - `POST /index.php/grid/api/notifications/mark-read` (when [space] is `'professional'`)
  /// Body: `{"id": id}`, `{"ids": ids}`, or `{"all": true}`.
  Future<bool> markRead({
    int? id,
    List<int>? ids,
    bool all = false,
    String? space,
    String? baseUrl,
    http.Client? client,
  }) async {
    try {
      final origin = _originForBaseUrl(baseUrl);
      final normalizedSpace = space?.trim().toLowerCase();
      bool isCircleTarget;
      if (normalizedSpace == 'circle' || normalizedSpace == 'chat') {
        isCircleTarget = true;
      } else if (normalizedSpace == 'professional') {
        isCircleTarget = false;
      } else if (id != null) {
        final matched = notifications.value.where((item) => item['id'] == id);
        isCircleTarget = matched.isNotEmpty && _isCircleRow(matched.first);
      } else {
        isCircleTarget = false;
      }

      final cookies = isCircleTarget
          ? await _resolveSessionCookies(
              '$origin/index.php/grid-chat',
              fallbackUrl: '$origin/index.php/grid',
            )
          : await _resolveSessionCookies('$origin/index.php/grid');
      final uri = isCircleTarget
          ? Uri.parse('$origin/index.php/grid-chat/api/notifications/mark-read')
          : Uri.parse('$origin/index.php/grid/api/notifications/mark-read');

      final body = all
          ? jsonEncode(<String, dynamic>{'all': true})
          : (ids != null && ids.isNotEmpty)
              ? jsonEncode(<String, dynamic>{'ids': ids})
              : jsonEncode(<String, dynamic>{'id': id});

      final targetIds = <int>{
        if (id != null) id,
        if (ids != null) ...ids,
      };

      // Optimistically update local state
      final current =
          List<Map<String, dynamic>>.from(notifications.value);
      var markedCount = 0;
      for (var i = 0; i < current.length; i++) {
        final item = Map<String, dynamic>.from(current[i]);
        final rowIsCircle = _isCircleRow(item);
        if (normalizedSpace != null && rowIsCircle != isCircleTarget) {
          continue;
        }
        final itemId = item['id'] is int
            ? item['id'] as int
            : int.tryParse(item['id']?.toString() ?? '');
        if (all || (itemId != null && targetIds.contains(itemId))) {
          if (_isRowUnread(item)) {
            item['is_read'] = 1;
            item['unread'] = false;
            current[i] = item;
            markedCount++;
          }
        }
      }
      if (markedCount > 0) {
        notifications.value = current;
        if (all && normalizedSpace == null) {
          unreadCount.value = 0;
          GridUnreadCountsService.instance.unreadNotifications.value = 0;
        } else {
          final newCount = (unreadCount.value - markedCount).clamp(0, 9999);
          unreadCount.value = newCount;
          GridUnreadCountsService.instance.unreadNotifications.value = newCount;
        }
      }

      final httpClient = client ?? http.Client();
      final response = await httpClient.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
        body: body,
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['success'] == true;
      }
    } catch (e) {
      debugPrint('[GridNotifications] markRead error: $e');
    }
    return false;
  }
}
