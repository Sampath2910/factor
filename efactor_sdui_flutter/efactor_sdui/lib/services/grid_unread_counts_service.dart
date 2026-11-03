import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'incoming_call_service.dart';

/// Service managing Professional Space (GRID) unread counts and bottom-bar badges.
class GridUnreadCountsService {
  GridUnreadCountsService._();
  static final GridUnreadCountsService instance = GridUnreadCountsService._();

  final ValueNotifier<int> unreadNotifications = ValueNotifier<int>(0);
  final ValueNotifier<int> unreadMessages = ValueNotifier<int>(0);
  final ValueNotifier<int> totalUnread = ValueNotifier<int>(0);

  /// Updates the unread count when a `badgeUpdate` event is received via CircleConnectPushBridge.
  void updateUnreadCount(dynamic unread) {
    final count = int.tryParse(unread?.toString() ?? '') ?? 0;
    totalUnread.value = count;
    debugPrint('[GridUnreadCounts] updated totalUnread: $count');
  }

  /// Fetches unread counts from `GET https://efactor.tech/index.php/grid/api/unread-counts`.
  /// Requires the active WebView session cookie.
  Future<Map<String, dynamic>?> fetchUnreadCounts({String? baseUrl}) async {
    try {
      final targetUrl = baseUrl ?? 'https://efactor.tech/index.php/grid';
      final cookies =
          await IncomingCallService.instance.getCookiesForUrl(targetUrl);
      final cleanBase =
          targetUrl.split('?').first.replaceAll(RegExp(r'/+$'), '');
      final origin = Uri.tryParse(cleanBase)?.origin ?? 'https://efactor.tech';
      final uri = Uri.parse('$origin/index.php/grid/api/unread-counts');

      final response = await http.get(
        uri,
        headers: <String, String>{
          'Accept': 'application/json',
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          final unreadNotifs =
              int.tryParse(data['unread_notifications']?.toString() ?? '') ?? 0;
          final unreadMsgs =
              int.tryParse(data['unread_messages']?.toString() ?? '') ?? 0;
          unreadNotifications.value = unreadNotifs;
          unreadMessages.value = unreadMsgs;
          totalUnread.value = unreadNotifs + unreadMsgs;
          debugPrint(
            '[GridUnreadCounts] fetchUnreadCounts: notifs=$unreadNotifs msgs=$unreadMsgs total=${totalUnread.value}',
          );
          return data;
        }
      } else {
        debugPrint(
          '[GridUnreadCounts] fetchUnreadCounts HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[GridUnreadCounts] fetchUnreadCounts error: $e');
    }
    return null;
  }
}
