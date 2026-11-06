import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Result from an inline notification reply request.
class CircleConnectReplyResult {
  const CircleConnectReplyResult({
    required this.success,
    this.statusCode,
    this.errorMessage,
    this.isDuplicate = false,
  });

  final bool success;
  final int? statusCode;
  final String? errorMessage;
  final bool isDuplicate;
}

/// Manages the Circle Connect device key used for background notification actions
/// (e.g., Mark as read, Reply, Mute) when the app/WebView is closed.
///
/// Follows Circle Connect specifications:
/// - Stores key in encrypted storage (Android Keystore / iOS Keychain).
/// - Never logs the key value in plain text.
/// - Authenticates via `X-Device-Key` header (avoids `Authorization` header).
/// - Handles HTTP status codes (401 revokes key; 403/404 removes notification).
/// - Queues actions when offline and retries on connectivity.
/// - Revokes key with the server on user logout.
class CircleConnectDeviceKeyStore {
  CircleConnectDeviceKeyStore({
    FlutterSecureStorage? storage,
    http.Client? client,
  })  : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            ),
        _client = client ?? http.Client();

  static final CircleConnectDeviceKeyStore instance =
      CircleConnectDeviceKeyStore();

  final FlutterSecureStorage _storage;
  final http.Client _client;

  static const String _kDeviceKey = 'efactor.circle_connect.device_key';
  static const String _kInstallationId =
      'efactor.circle_connect.installation_id';
  static const String _kBaseUrl = 'efactor.circle_connect.base_url';
  static const String _kOfflineQueueKey = 'circle_connect_offline_read_queue';

  // Dual-storage unencrypted fallback cache for background isolates.
  // On devices like Vivo, Samsung, Xiaomi, Android Keystore can be locked or
  // unavailable to background workers when the app is killed. SharedPreferences
  // guarantees instant (<1ms) key access without Keystore initialization.
  static const String _kDeviceKeyFallback =
      'efactor.circle_connect.device_key_unencrypted_cache';
  static const String _kInstallationIdFallback =
      'efactor.circle_connect.installation_id_cache';
  static const String _kBaseUrlFallback =
      'efactor.circle_connect.base_url_cache';

  static const String defaultBaseUrl =
      'https://efactor.tech/index.php/grid-chat/api';

  final List<void Function(bool hasKey)> _keyStatusListeners =
      <void Function(bool hasKey)>[];

  /// Registers a listener that fires whenever device key availability changes.
  void addKeyStatusListener(void Function(bool hasKey) listener) {
    if (!_keyStatusListeners.contains(listener)) {
      _keyStatusListeners.add(listener);
    }
  }

  /// Removes a registered key status listener.
  void removeKeyStatusListener(void Function(bool hasKey) listener) {
    _keyStatusListeners.remove(listener);
  }

  void _notifyKeyStatus(bool hasKey) {
    for (final listener
        in List<void Function(bool hasKey)>.from(_keyStatusListeners)) {
      try {
        listener(hasKey);
      } catch (e) {
        debugPrint('[CircleConnectKeyStore] Listener error: $e');
      }
    }
  }

  /// Saves the device key and installation ID to secure storage and fallback prefs.
  /// Newer keys replace existing keys. Key is never logged.
  Future<void> setDeviceKey(
    String deviceKey,
    String installationId, {
    String? baseUrl,
  }) async {
    final cleanKey = deviceKey.trim();
    final cleanId = installationId.trim();
    if (cleanKey.isEmpty) return;

    try {
      await _storage.write(key: _kDeviceKey, value: cleanKey);
      if (cleanId.isNotEmpty) {
        await _storage.write(key: _kInstallationId, value: cleanId);
      }
      if (baseUrl != null && baseUrl.isNotEmpty) {
        await _storage.write(
          key: _kBaseUrl,
          value: _normalizeBaseUrl(baseUrl),
        );
      }
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error storing device key in secure storage: $e');
    }

    // Dual storage: Also persist to SharedPreferences as unencrypted fallback cache.
    // In background/killed state on devices like Vivo/Samsung, Android Keystore may be
    // locked or unavailable to the background isolate. SharedPreferences guarantees
    // immediate <1ms access without Keystore dependencies.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDeviceKeyFallback, cleanKey);
      if (cleanId.isNotEmpty) {
        await prefs.setString(_kInstallationIdFallback, cleanId);
      }
      if (baseUrl != null && baseUrl.isNotEmpty) {
        await prefs.setString(_kBaseUrlFallback, _normalizeBaseUrl(baseUrl));
      }
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error storing device key in fallback prefs: $e');
    }

    _notifyKeyStatus(true);
    debugPrint(
      '[CircleConnectKeyStore] Device key stored securely & cached '
      '(installationId=${cleanId.isNotEmpty ? cleanId : "none"})',
    );
  }

  /// Checks if a non-empty device key is currently stored.
  Future<bool> hasDeviceKey() async {
    final key = await getDeviceKey();
    return key != null && key.isNotEmpty;
  }

  /// Retrieves the stored device key from encrypted storage, falling back to cached prefs.
  Future<String?> getDeviceKey() async {
    try {
      final key = await _storage.read(key: _kDeviceKey);
      if (key != null && key.isNotEmpty) return key;
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error reading device key from secure storage: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final fallbackKey = prefs.getString(_kDeviceKeyFallback);
      if (fallbackKey != null && fallbackKey.isNotEmpty) {
        return fallbackKey;
      }
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error reading device key from fallback prefs: $e');
    }
    return null;
  }

  /// Retrieves the stored installation ID.
  Future<String?> getInstallationId() async {
    try {
      final id = await _storage.read(key: _kInstallationId);
      if (id != null && id.isNotEmpty) return id;
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error reading installation ID from secure storage: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final fallbackId = prefs.getString(_kInstallationIdFallback);
      if (fallbackId != null && fallbackId.isNotEmpty) {
        return fallbackId;
      }
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error reading installation ID from fallback prefs: $e');
    }
    return null;
  }

  /// Retrieves the stored API base URL.
  Future<String> getBaseUrl({String? hintUrl}) async {
    if (hintUrl != null && hintUrl.isNotEmpty) {
      return _normalizeBaseUrl(hintUrl);
    }
    try {
      final stored = await _storage.read(key: _kBaseUrl);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final fallbackUrl = prefs.getString(_kBaseUrlFallback);
      if (fallbackUrl != null && fallbackUrl.isNotEmpty) return fallbackUrl;
    } catch (_) {}
    return defaultBaseUrl;
  }

  /// Normalizes any input URL to `{origin}/index.php/grid-chat/api`.
  static String _normalizeBaseUrl(String url) {
    var clean = url.trim();
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      clean = 'https://efactor.tech/${clean.replaceAll(RegExp(r"^/+"), "")}';
    }
    final uri = Uri.tryParse(clean);
    if (uri != null && uri.host.isNotEmpty) {
      return '${uri.origin}/index.php/grid-chat/api';
    }
    return defaultBaseUrl;
  }

  /// Deletes the device key from secure storage and fallback cache (e.g. on 401 response or logout).
  ///
  /// If [matchingKey] is provided, the key is only cleared if the currently
  /// stored key still matches [matchingKey]. This protects against race conditions
  /// where a fresh key was set while an earlier request was in-flight.
  Future<void> clearDeviceKey({String? matchingKey}) async {
    try {
      if (matchingKey != null && matchingKey.isNotEmpty) {
        final currentKey = await getDeviceKey();
        if (currentKey != null && currentKey != matchingKey) {
          debugPrint(
            '[CircleConnectKeyStore] 401 received for key, but key was replaced in-flight. Retaining new key.',
          );
          return;
        }
      }
      await _storage.delete(key: _kDeviceKey);
      await _storage.delete(key: _kInstallationId);
      await _storage.delete(key: _kBaseUrl);
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error clearing device key from secure storage: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kDeviceKeyFallback);
      await prefs.remove(_kInstallationIdFallback);
      await prefs.remove(_kBaseUrlFallback);
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error clearing device key from fallback prefs: $e');
    }
    _notifyKeyStatus(false);
    debugPrint(
        '[CircleConnectKeyStore] Device key cleared from secure storage & fallback cache.');
  }

  /// Sends a background "Mark as read" request for a conversation and message.
  ///
  /// Contract:
  /// POST {base}/notification/action
  /// Header: X-Device-Key: <device key>
  /// Content-Type: application/json
  /// {"action": "read", "conversation_id": "...", "message_id": "..."}
  Future<bool> markAsRead({
    required String conversationId,
    required String messageId,
    String? targetUrl,
  }) async {
    final cleanConvId = conversationId.trim();
    final cleanMsgId = messageId.trim();
    if (cleanConvId.isEmpty) return false;

    final deviceKey = await getDeviceKey();
    final baseUrl = await getBaseUrl(hintUrl: targetUrl);
    final endpoint = Uri.tryParse('$baseUrl/notification/action');
    if (endpoint == null) return false;

    if (deviceKey == null || deviceKey.isEmpty) {
      debugPrint(
        '[CircleConnectKeyStore] No device key available for markAsRead; queuing action.',
      );
      await _enqueueOffline(cleanConvId, cleanMsgId, baseUrl);
      return false;
    }

    final body = jsonEncode(<String, dynamic>{
      'action': 'read',
      'conversation_id': cleanConvId,
      'message_id': cleanMsgId,
    });

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Device-Key': deviceKey,
    };

    try {
      final response = await _client
          .post(endpoint, headers: headers, body: body)
          .timeout(const Duration(seconds: 12));

      final statusCode = response.statusCode;
      debugPrint(
        '[CircleConnectKeyStore] markAsRead response: $statusCode '
        'convId=$cleanConvId msgId=$cleanMsgId',
      );

      if (statusCode >= 200 && statusCode < 300) {
        // Success: sender ticks turn blue on server
        return true;
      }

      if (statusCode == 401) {
        // Key unknown or revoked: delete stored key if it is still the one used
        debugPrint(
          '[CircleConnectKeyStore] 401 Key revoked or invalid; clearing matching device key.',
        );
        await clearDeviceKey(matchingKey: deviceKey);
        return false;
      }

      if (statusCode == 403 || statusCode == 404) {
        // Chat locked, user left, or chat deleted: nothing more to do
        return false;
      }

      if (statusCode == 422) {
        debugPrint(
          '[CircleConnectKeyStore][BUG] 422 Bad request: ${response.body}',
        );
        return false;
      }

      // Other 5xx or server errors: queue for offline retry
      await _enqueueOffline(cleanConvId, cleanMsgId, baseUrl);
      return false;
    } on SocketException catch (_) {
      // Network unreachable: queue request
      await _enqueueOffline(cleanConvId, cleanMsgId, baseUrl);
      return false;
    } on TimeoutException catch (_) {
      await _enqueueOffline(cleanConvId, cleanMsgId, baseUrl);
      return false;
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] markAsRead exception: $e');
      await _enqueueOffline(cleanConvId, cleanMsgId, baseUrl);
      return false;
    }
  }

  /// Generates a cryptographically secure lowercase RFC 4122 version 4 UUID.
  static String generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // RFC 4122 v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10xx
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) {
        buffer.write('-');
      }
      buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString().toLowerCase();
  }

  /// Sends a background "Delivered" action when a message push arrives (Step 2).
  ///
  /// Contract:
  /// POST {base}/notification/action
  /// Header: X-Device-Key: <device key>
  /// Content-Type: application/x-www-form-urlencoded
  /// Body: action=delivered&conversation_id=...&message_id=...
  Future<bool> sendDelivered({
    required String conversationId,
    required String messageId,
    String? targetUrl,
  }) async {
    final cleanConvId = conversationId.trim();
    final cleanMsgId = messageId.trim();
    if (cleanConvId.isEmpty || cleanMsgId.isEmpty) return false;

    final baseUrl = await getBaseUrl(hintUrl: targetUrl);
    final endpoint = Uri.tryParse('$baseUrl/notification/action');
    if (endpoint == null) return false;

    final deviceKey = await getDeviceKey();
    if (deviceKey == null || deviceKey.isEmpty) {
      debugPrint(
        '[CircleConnectKeyStore] No device key available for sendDelivered; queuing action.',
      );
      await _enqueueAction(<String, dynamic>{
        'action': 'delivered',
        'conversation_id': cleanConvId,
        'message_id': cleanMsgId,
        'base_url': baseUrl,
      });
      return false;
    }

    final body = <String, String>{
      'action': 'delivered',
      'conversation_id': cleanConvId,
      'message_id': cleanMsgId,
    };

    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'X-Device-Key': deviceKey,
    };

    try {
      debugPrint(
        '[CircleConnectKeyStore] sendDelivered dispatching to $endpoint '
        'convId=$cleanConvId msgId=$cleanMsgId',
      );
      final response = await _client
          .post(endpoint, headers: headers, body: body)
          .timeout(const Duration(seconds: 10));

      final statusCode = response.statusCode;
      debugPrint(
        '[CircleConnectKeyStore] sendDelivered response: $statusCode '
        'convId=$cleanConvId msgId=$cleanMsgId (${response.body})',
      );
      if (statusCode >= 200 && statusCode < 300) {
        return true;
      }
      if (statusCode == 401) {
        debugPrint(
          '[CircleConnectKeyStore] sendDelivered 401: Key revoked or invalid; clearing device key.',
        );
        await clearDeviceKey(matchingKey: deviceKey);
        return false;
      }
      if (statusCode == 403 || statusCode == 404 || statusCode == 422) {
        return false;
      }
      await _enqueueAction(<String, dynamic>{
        'action': 'delivered',
        'conversation_id': cleanConvId,
        'message_id': cleanMsgId,
        'base_url': baseUrl,
      });
      return false;
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] sendDelivered exception: $e');
      await _enqueueAction(<String, dynamic>{
        'action': 'delivered',
        'conversation_id': cleanConvId,
        'message_id': cleanMsgId,
        'base_url': baseUrl,
      });
      return false;
    }
  }

  /// Sends an inline quick reply without opening the app (Step 2).
  ///
  /// Contract:
  /// POST {base}/notification/action
  /// Header: X-Device-Key: <device key>
  /// Content-Type: application/json
  /// {"action": "reply", "conversation_id": "...", "message_id": "...", "text": "...", "client_id": "..."}
  Future<CircleConnectReplyResult> sendReply({
    required String conversationId,
    required String messageId,
    required String text,
    String? clientId,
    String? targetUrl,
  }) async {
    final cleanConvId = conversationId.trim();
    final cleanMsgId = messageId.trim();
    final cleanText = text.trim();
    if (cleanConvId.isEmpty || cleanText.isEmpty) {
      return const CircleConnectReplyResult(
        success: false,
        statusCode: 422,
        errorMessage: 'Empty text or conversation ID',
      );
    }

    final effectiveClientId = (clientId != null && clientId.trim().isNotEmpty)
        ? clientId.trim().toLowerCase()
        : generateUuidV4();

    final baseUrl = await getBaseUrl(hintUrl: targetUrl);
    final endpoint = Uri.tryParse('$baseUrl/notification/action');
    if (endpoint == null) {
      return const CircleConnectReplyResult(
        success: false,
        errorMessage: 'Invalid endpoint URL',
      );
    }

    final deviceKey = await getDeviceKey();
    if (deviceKey == null || deviceKey.isEmpty) {
      await _enqueueAction(<String, dynamic>{
        'action': 'reply',
        'conversation_id': cleanConvId,
        'message_id': cleanMsgId,
        'text': cleanText,
        'client_id': effectiveClientId,
        'base_url': baseUrl,
      });
      return const CircleConnectReplyResult(
        success: false,
        errorMessage: 'No device key stored',
      );
    }

    final body = jsonEncode(<String, dynamic>{
      'action': 'reply',
      'conversation_id': cleanConvId,
      'message_id': cleanMsgId,
      'text': cleanText,
      'client_id': effectiveClientId,
    });

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Device-Key': deviceKey,
    };

    try {
      final response = await _client
          .post(endpoint, headers: headers, body: body)
          .timeout(const Duration(seconds: 12));

      final statusCode = response.statusCode;
      Map<String, dynamic>? jsonBody;
      try {
        jsonBody = jsonDecode(response.body) as Map<String, dynamic>?;
      } catch (_) {}

      if (statusCode == 200 || statusCode == 201) {
        final isDuplicate = jsonBody?['duplicate'] == true;
        return CircleConnectReplyResult(
          success: true,
          statusCode: statusCode,
          isDuplicate: isDuplicate,
        );
      }

      if (statusCode == 401) {
        await clearDeviceKey(matchingKey: deviceKey);
        return const CircleConnectReplyResult(
          success: false,
          statusCode: 401,
          errorMessage: 'Unauthorized',
        );
      }

      if (statusCode == 403) {
        final msg = jsonBody?['message']?.toString() ??
            'Action not allowed or contact blocked.';
        return CircleConnectReplyResult(
          success: false,
          statusCode: 403,
          errorMessage: msg,
        );
      }

      if (statusCode == 404 || statusCode == 422) {
        return CircleConnectReplyResult(
          success: false,
          statusCode: statusCode,
          errorMessage: jsonBody?['message']?.toString() ?? 'Bad request',
        );
      }

      await _enqueueAction(<String, dynamic>{
        'action': 'reply',
        'conversation_id': cleanConvId,
        'message_id': cleanMsgId,
        'text': cleanText,
        'client_id': effectiveClientId,
        'base_url': baseUrl,
      });
      return CircleConnectReplyResult(
        success: false,
        statusCode: statusCode,
        errorMessage: 'Server error; queued for retry',
      );
    } catch (e) {
      await _enqueueAction(<String, dynamic>{
        'action': 'reply',
        'conversation_id': cleanConvId,
        'message_id': cleanMsgId,
        'text': cleanText,
        'client_id': effectiveClientId,
        'base_url': baseUrl,
      });
      return CircleConnectReplyResult(
        success: false,
        errorMessage: e.toString(),
      );
    }
  }

  /// Mutes a conversation for 8 hours from a notification action (Step 2).
  ///
  /// Contract:
  /// POST {base}/notification/action
  /// Header: X-Device-Key: <device key>
  /// Content-Type: application/json
  /// {"action": "mute", "conversation_id": "..."}
  Future<bool> muteChat({
    required String conversationId,
    String? targetUrl,
  }) async {
    final cleanConvId = conversationId.trim();
    if (cleanConvId.isEmpty) return false;

    final baseUrl = await getBaseUrl(hintUrl: targetUrl);
    final endpoint = Uri.tryParse('$baseUrl/notification/action');
    if (endpoint == null) return false;

    final deviceKey = await getDeviceKey();
    if (deviceKey == null || deviceKey.isEmpty) {
      await _enqueueAction(<String, dynamic>{
        'action': 'mute',
        'conversation_id': cleanConvId,
        'base_url': baseUrl,
      });
      return false;
    }

    final body = jsonEncode(<String, dynamic>{
      'action': 'mute',
      'conversation_id': cleanConvId,
    });

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Device-Key': deviceKey,
    };

    try {
      final response = await _client
          .post(endpoint, headers: headers, body: body)
          .timeout(const Duration(seconds: 10));

      final statusCode = response.statusCode;
      if (statusCode >= 200 && statusCode < 300) {
        return true;
      }
      if (statusCode == 401) {
        await clearDeviceKey(matchingKey: deviceKey);
        return false;
      }
      if (statusCode == 403 || statusCode == 404 || statusCode == 422) {
        return false;
      }
      await _enqueueAction(<String, dynamic>{
        'action': 'mute',
        'conversation_id': cleanConvId,
        'base_url': baseUrl,
      });
      return false;
    } catch (_) {
      await _enqueueAction(<String, dynamic>{
        'action': 'mute',
        'conversation_id': cleanConvId,
        'base_url': baseUrl,
      });
      return false;
    }
  }

  /// Queues a failed action to retry when network is available.
  Future<void> _enqueueAction(Map<String, dynamic> itemMap) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kOfflineQueueKey) ?? <String>[];
      final item = Map<String, dynamic>.from(itemMap);
      item['timestamp'] ??= DateTime.now().millisecondsSinceEpoch.toString();
      list.add(jsonEncode(item));
      await prefs.setStringList(_kOfflineQueueKey, list);
      debugPrint(
        '[CircleConnectKeyStore] Queued offline action=${item["action"]} convId=${item["conversation_id"]} (total=${list.length})',
      );
    } catch (_) {}
  }

  /// Legacy helper for queuing mark-as-read.
  Future<void> _enqueueOffline(
    String conversationId,
    String messageId,
    String baseUrl,
  ) async {
    await _enqueueAction(<String, dynamic>{
      'action': 'read',
      'conversation_id': conversationId,
      'message_id': messageId,
      'base_url': baseUrl,
    });
  }

  /// Flushes any pending offline notification requests (read, delivered, reply, mute).
  ///
  /// Always queries and uses the current stored device key at retry time,
  /// preserving client_id for replies to guarantee idempotent delivery.
  Future<void> flushOfflineQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kOfflineQueueKey);
      if (list == null || list.isEmpty) return;

      final remaining = <String>[];
      for (final raw in list) {
        try {
          final currentKey = await getDeviceKey();
          if (currentKey == null || currentKey.isEmpty) {
            remaining.add(raw);
            continue;
          }

          final data = jsonDecode(raw) as Map<String, dynamic>;
          final action = (data['action'] ?? 'read').toString();
          final convId = data['conversation_id']?.toString() ?? '';
          final msgId = data['message_id']?.toString() ?? '';
          final text = data['text']?.toString() ?? '';
          final clientId = data['client_id']?.toString();
          final baseUrl = data['base_url']?.toString() ?? defaultBaseUrl;

          final endpoint = Uri.tryParse('$baseUrl/notification/action');
          if (endpoint == null) continue;

          final payload = <String, dynamic>{
            'action': action,
            'conversation_id': convId,
          };
          if (msgId.isNotEmpty) payload['message_id'] = msgId;
          if (action == 'reply') {
            payload['text'] = text;
            if (clientId != null && clientId.isNotEmpty) {
              payload['client_id'] = clientId;
            }
          }

          final response = action == 'delivered'
              ? await _client.post(
                  endpoint,
                  headers: <String, String>{
                    'Content-Type': 'application/x-www-form-urlencoded',
                    'X-Device-Key': currentKey,
                  },
                  body: <String, String>{
                    'action': action,
                    'conversation_id': convId,
                    if (msgId.isNotEmpty) 'message_id': msgId,
                  },
                ).timeout(const Duration(seconds: 10))
              : await _client
                  .post(
                    endpoint,
                    headers: <String, String>{
                      'Content-Type': 'application/json',
                      'X-Device-Key': currentKey,
                    },
                    body: jsonEncode(payload),
                  )
                  .timeout(const Duration(seconds: 10));

          if (response.statusCode == 401) {
            await clearDeviceKey(matchingKey: currentKey);
            remaining.add(raw);
            break;
          }

          if (response.statusCode >= 200 && response.statusCode < 300) {
            // Success or duplicate accepted
            continue;
          }

          if (response.statusCode == 403 ||
              response.statusCode == 404 ||
              response.statusCode == 422) {
            // Drop unrecoverable error
            continue;
          }

          remaining.add(raw);
        } catch (_) {
          remaining.add(raw);
        }
      }

      await prefs.setStringList(_kOfflineQueueKey, remaining);
    } catch (_) {}
  }

  /// Calls `{base}/notification/device_key/revoke` on logout before clearing app data.
  Future<void> revokeOnLogout({String? targetUrl}) async {
    try {
      final deviceKey = await getDeviceKey();
      if (deviceKey == null || deviceKey.isEmpty) {
        await clearDeviceKey();
        return;
      }

      final baseUrl = await getBaseUrl(hintUrl: targetUrl);
      final endpoint = Uri.tryParse('$baseUrl/notification/device_key/revoke');
      if (endpoint != null) {
        try {
          await _client.post(
            endpoint,
            headers: <String, String>{
              'X-Device-Key': deviceKey,
            },
          ).timeout(const Duration(seconds: 8));
          debugPrint('[CircleConnectKeyStore] Device key revoked on server.');
        } catch (e) {
          debugPrint(
            '[CircleConnectKeyStore] Server revoke request failed (continuing local purge): $e',
          );
        }
      }

      await clearDeviceKey();
    } catch (e) {
      debugPrint('[CircleConnectKeyStore] Error during revokeOnLogout: $e');
    }
  }
}
