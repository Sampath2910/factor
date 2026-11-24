import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'grid_unread_counts_service.dart';
import 'incoming_call_service.dart';

/// Service managing GRID notifications (the bell icon feed).
/// Interacts with live GRID backend endpoints:
/// - GET /grid/api/notifications?limit=30
/// - GET /grid/api/notifications/unread-count
/// - POST /grid/api/notifications/mark-read
class GridNotificationsService {
  GridNotificationsService._();
  static final GridNotificationsService instance = GridNotificationsService._();

  final ValueNotifier<List<Map<String, dynamic>>> notifications =
      ValueNotifier<List<Map<String, dynamic>>>(const <Map<String, dynamic>>[]);
  final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(false);

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

  /// Fetches bell notifications from `GET /grid/api/notifications?limit=$limit`.
  Future<List<Map<String, dynamic>>> fetchNotifications({
    int limit = 30,
    String? baseUrl,
    http.Client? client,
  }) async {
    try {
      isLoading.value = true;
      const defaultTarget = 'https://efactor.tech/index.php/grid';
      final target = baseUrl ?? defaultTarget;
      final cookies =
          await IncomingCallService.instance.getCookiesForUrl(target);
      final cleanBase =
          target.split('?').first.replaceAll(RegExp(r'/+$'), '');
      final origin =
          Uri.tryParse(cleanBase)?.origin ?? 'https://efactor.tech';
      final uri =
          Uri.parse('$origin/index.php/grid/api/notifications?limit=$limit');

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
          final listRaw = data['data'];
          if (listRaw is List) {
            final parsed = listRaw
                .whereType<Map>()
                .map((m) =>
                    Map<String, dynamic>.from(m.cast<dynamic, dynamic>()))
                .toList();
            notifications.value = parsed;

            // Compute unread count from the returned list
            final count = parsed.where((item) {
              final isRead = item['is_read'];
              return isRead == 0 || isRead == false || isRead == '0';
            }).length;
            unreadCount.value = count;
            GridUnreadCountsService.instance.unreadNotifications.value = count;
            return parsed;
          }
        }
      } else {
        debugPrint(
          '[GridNotifications] fetchNotifications HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[GridNotifications] fetchNotifications error: $e');
    } finally {
      isLoading.value = false;
    }
    return notifications.value;
  }

  /// Fetches unread count from `GET /grid/api/notifications/unread-count`.
  Future<int?> fetchUnreadCount({
    String? baseUrl,
    http.Client? client,
  }) async {
    try {
      const defaultTarget = 'https://efactor.tech/index.php/grid';
      final target = baseUrl ?? defaultTarget;
      final cookies =
          await IncomingCallService.instance.getCookiesForUrl(target);
      final cleanBase =
          target.split('?').first.replaceAll(RegExp(r'/+$'), '');
      final origin =
          Uri.tryParse(cleanBase)?.origin ?? 'https://efactor.tech';
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

  /// Marks a notification as read via `POST /grid/api/notifications/mark-read`.
  /// Body: `{"id": id}` or `{"all": true}`.
  Future<bool> markRead({
    int? id,
    bool all = false,
    String? baseUrl,
    http.Client? client,
  }) async {
    try {
      const defaultTarget = 'https://efactor.tech/index.php/grid';
      final target = baseUrl ?? defaultTarget;
      final cookies =
          await IncomingCallService.instance.getCookiesForUrl(target);
      final cleanBase =
          target.split('?').first.replaceAll(RegExp(r'/+$'), '');
      final origin =
          Uri.tryParse(cleanBase)?.origin ?? 'https://efactor.tech';
      final uri =
          Uri.parse('$origin/index.php/grid/api/notifications/mark-read');

      final body =
          all ? jsonEncode({'all': true}) : jsonEncode({'id': id});

      // Optimistically update local state
      final current =
          List<Map<String, dynamic>>.from(notifications.value);
      var marked = false;
      for (var i = 0; i < current.length; i++) {
        final item = Map<String, dynamic>.from(current[i]);
        if (all || (id != null && item['id'] == id)) {
          final wasUnread = item['is_read'] == 0 ||
              item['is_read'] == false ||
              item['is_read'] == '0';
          if (wasUnread) {
            item['is_read'] = 1;
            item['unread'] = false;
            current[i] = item;
            marked = true;
          }
        }
      }
      if (marked) {
        notifications.value = current;
        if (all) {
          unreadCount.value = 0;
          GridUnreadCountsService.instance.unreadNotifications.value = 0;
        } else {
          final newCount = (unreadCount.value - 1).clamp(0, 9999);
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
