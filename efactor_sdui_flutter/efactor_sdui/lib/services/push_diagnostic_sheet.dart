import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'call_permission_helper.dart';
import 'incoming_call_service.dart';
import 'push_notification_bootstrap.dart';

/// Interactive diagnostic sheet for troubleshooting FCM push notifications,
/// backend device token synchronization, lock-screen wake-ups, and cross-device calling.
class PushDiagnosticSheet extends StatefulWidget {
  const PushDiagnosticSheet({
    super.key,
    this.userId,
    this.accessToken,
  });

  final String? userId;
  final String? accessToken;

  static Future<void> show(
    BuildContext context, {
    String? userId,
    String? accessToken,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.90,
        minChildSize: 0.50,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => PushDiagnosticSheet(
          userId: userId,
          accessToken: accessToken,
        ),
      ),
    );
  }

  @override
  State<PushDiagnosticSheet> createState() => _PushDiagnosticSheetState();
}

class _PushDiagnosticSheetState extends State<PushDiagnosticSheet> {
  String? _fcmToken;
  bool _loadingToken = true;
  String? _tokenError;

  // Permissions state
  bool _notifGranted = false;
  bool _overlayGranted = false;
  bool _batteryIgnored = false;

  // Backend Sync State
  bool _syncingBackend = false;
  String? _syncStatus;
  int? _syncHttpCode;
  String? _syncBody;
  int? _syncLatencyMs;

  // Self Test Countdown
  Timer? _countdownTimer;
  int _countdownSeconds = 0;

  // Cross-device test input
  final TextEditingController _targetTokenController = TextEditingController();
  final TextEditingController _serverKeyController = TextEditingController();
  bool _sendingCrossPush = false;
  String? _crossPushResult;

  @override
  void initState() {
    super.initState();
    _loadDiagnostics();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _targetTokenController.dispose();
    _serverKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadDiagnostics() async {
    setState(() => _loadingToken = true);

    try {
      if (!kIsWeb) {
        final notif = await Permission.notification.status;
        _notifGranted = notif.isGranted;
        _overlayGranted = await CallPermissionHelper.canDrawOverlays();
        _batteryIgnored =
            await CallPermissionHelper.isBatteryOptimizationIgnored();

        var token = IncomingCallService.instance.deviceToken;
        if (token == null || token.isEmpty) {
          token = await FirebaseMessaging.instance.getToken();
          if (token != null) {
            IncomingCallService.instance.setDeviceToken(token);
          }
        }
        _fcmToken = token;
      }
    } catch (e) {
      _tokenError = e.toString();
    } finally {
      if (mounted) {
        setState(() => _loadingToken = false);
      }
    }
  }

  Future<void> _testBackendSync() async {
    final token = _fcmToken ?? IncomingCallService.instance.deviceToken;
    final uid = widget.userId ??
        IncomingCallService.instance.activeUserId?.toString() ??
        '177';
    final access = widget.accessToken ??
        IncomingCallService.instance.activeAccessToken ??
        '';

    if (token == null || token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot sync: FCM token is missing!')),
      );
      return;
    }

    setState(() {
      _syncingBackend = true;
      _syncStatus = 'Sending registration request to https://efactor.tech...';
      _syncHttpCode = null;
      _syncBody = null;
      _syncLatencyMs = null;
    });

    final stopwatch = Stopwatch()..start();
    try {
      final cookies = await IncomingCallService.instance
          .getCookiesForUrl('https://efactor.tech/index.php/grid-chat');

      final cleanToken = access.startsWith('Bearer ')
          ? access.substring(7).trim()
          : access.trim();

      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (cookies.isNotEmpty) 'Cookie': cookies,
        if (cleanToken.isNotEmpty) ...{
          'Authorization': 'Bearer $cleanToken',
          'access_token': cleanToken,
          'accesstoken': cleanToken,
          'token': cleanToken,
        },
      };

      final payload = jsonEncode(<String, dynamic>{
        'device_token': token,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'token_type': 'fcm',
        'user_id': uid,
        if (cleanToken.isNotEmpty) 'access_token': cleanToken,
      });

      final targetUri = Uri.parse(
        'https://efactor.tech/index.php/api/register_device_token',
      );

      final response = await http
          .post(targetUri, headers: headers, body: payload)
          .timeout(const Duration(seconds: 12));

      stopwatch.stop();

      setState(() {
        _syncHttpCode = response.statusCode;
        _syncBody = response.body;
        _syncLatencyMs = stopwatch.elapsedMilliseconds;

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final lower = response.body.toLowerCase();
          if (lower.contains('success') || lower.contains('true')) {
            _syncStatus =
                'SUCCESS (200 OK): Token is saved in server database for user $uid.';
          } else {
            _syncStatus =
                'WARNING (${response.statusCode}): Received response, but status was not explicit success.';
          }
        } else if (response.statusCode == 401) {
          _syncStatus =
              'FAILED (401 Unauthorized): Server rejected token registration! Session Bearer token or CSRF cookie is missing/expired.';
        } else {
          _syncStatus =
              'ERROR (${response.statusCode}): Server returned error ${response.statusCode}.';
        }
      });
    } catch (e) {
      stopwatch.stop();
      setState(() {
        _syncStatus = 'NETWORK ERROR: $e';
        _syncLatencyMs = stopwatch.elapsedMilliseconds;
      });
    } finally {
      if (mounted) {
        setState(() => _syncingBackend = false);
      }
    }
  }

  void _startSelfCallTest() {
    if (_countdownSeconds > 0) return;

    setState(() => _countdownSeconds = 5);

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_countdownSeconds <= 1) {
        timer.cancel();
        setState(() => _countdownSeconds = 0);

        final testCall = IncomingCallData(
          callId: 'diag_${DateTime.now().millisecondsSinceEpoch}',
          callerId: '99',
          callerName: 'Efactor Diag Lab',
          callerAvatar: null,
          callType: 'video',
          roomUrl: 'https://efactor.tech/index.php/grid-chat',
        );

        final plugin = FlutterLocalNotificationsPlugin();
        await showIncomingCallNotificationOnPlugin(plugin, testCall);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Color(0xFF059669),
              content: Text('Test call notification dispatched to system tray!'),
            ),
          );
        }
      } else {
        setState(() => _countdownSeconds--);
      }
    });
  }

  Future<void> _sendCrossDevicePush() async {
    final targetToken = _targetTokenController.text.trim();
    final serverKey = _serverKeyController.text.trim();

    if (targetToken.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter recipient FCM token!')),
      );
      return;
    }

    if (serverKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter Firebase Server Key (or use terminal cURL)'),
        ),
      );
      return;
    }

    setState(() {
      _sendingCrossPush = true;
      _crossPushResult = null;
    });

    try {
      final fcmPayload = {
        'to': targetToken,
        'priority': 'high',
        'data': {
          'type': 'INCOMING_CALL',
          'call_id': 'cross_test_${DateTime.now().millisecondsSinceEpoch}',
          'caller_name': 'Remote Diag Phone',
          'call_type': 'video',
          'caller_user_id': widget.userId ?? '177',
          'room_url': 'https://efactor.tech/index.php/grid-chat',
        },
      };

      final resp = await http.post(
        Uri.parse('https://fcm.googleapis.com/fcm/send'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'key=$serverKey',
        },
        body: jsonEncode(fcmPayload),
      );

      setState(() {
        _crossPushResult =
            'HTTP ${resp.statusCode}: ${resp.body}';
      });
    } catch (e) {
      setState(() {
        _crossPushResult = 'Error: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _sendingCrossPush = false);
      }
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF0284C7),
        content: Text('$label copied to clipboard!'),
      ),
    );
  }

  String _buildCurlCommand() {
    final token = _fcmToken ?? '<RECIPIENT_FCM_TOKEN>';
    return '''curl -X POST "https://fcm.googleapis.com/fcm/send" \\
  -H "Authorization: key=YOUR_FIREBASE_SERVER_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{
    "to": "$token",
    "priority": "high",
    "data": {
      "type": "INCOMING_CALL",
      "call_id": "test_${DateTime.now().millisecondsSinceEpoch}",
      "caller_name": "Terminal Test Call",
      "call_type": "video",
      "caller_user_id": "177",
      "room_url": "https://efactor.tech/index.php/grid-chat"
    }
  }' ''';
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0F172A);
    const cardBg = Color(0xFF1E293B);
    const borderCol = Color(0xFF334155);
    const primary = Color(0xFF38BDF8);

    return Container(
      decoration: const BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.phonelink_ring, color: primary, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Push & Call Cross-Device Inspector',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Diagnose why calls fail between two mobiles',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white70),
                  onPressed: _loadDiagnostics,
                  tooltip: 'Refresh Diagnostics',
                ),
              ],
            ),
          ),
          const Divider(color: borderCol, height: 1),

          // Scrollable body
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // SECTION 1: Device Identity & FCM Token
                _buildCard(
                  cardBg: cardBg,
                  borderCol: borderCol,
                  title: 'Device Identity & FCM Token',
                  icon: Icons.fingerprint,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildKeyValue(
                        'Active User ID',
                        widget.userId ??
                            IncomingCallService.instance.activeUserId
                                ?.toString() ??
                            'Not detected',
                      ),
                      const SizedBox(height: 8),
                      _buildKeyValue(
                        'Session Bearer Token',
                        widget.accessToken != null &&
                                widget.accessToken!.isNotEmpty
                            ? 'Present (${widget.accessToken!.length} chars)'
                            : (IncomingCallService.instance.activeAccessToken !=
                                        null
                                    ? 'Present in Service'
                                    : 'MISSING (Will cause 401 error!)'),
                        isWarn: widget.accessToken == null &&
                            IncomingCallService.instance.activeAccessToken ==
                                null,
                      ),
                      const SizedBox(height: 8),
                      if (_loadingToken)
                        const Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Acquiring FCM token...',
                                style: TextStyle(color: Colors.white70)),
                          ],
                        )
                      else if (_fcmToken != null) ...[
                        const Text(
                          'FCM Device Token (Unique to this phone):',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black38,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: borderCol),
                          ),
                          child: SelectableText(
                            _fcmToken!,
                            style: const TextStyle(
                              color: Color(0xFF34D399),
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primary,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('Copy Token'),
                              onPressed: () => _copyToClipboard(
                                _fcmToken!,
                                'FCM Device Token',
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                side: const BorderSide(color: borderCol),
                              ),
                              icon: const Icon(Icons.code, size: 16),
                              label: const Text('Copy cURL Command'),
                              onPressed: () => _copyToClipboard(
                                _buildCurlCommand(),
                                'Terminal cURL Command',
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        Text(
                          'FCM Token Missing: ${_tokenError ?? "Firebase did not return token"}',
                          style: const TextStyle(color: Color(0xFFF87171)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // SECTION 2: Backend Sync Verifier
                _buildCard(
                  cardBg: cardBg,
                  borderCol: borderCol,
                  title: 'Step 1: Test Server Token Registration',
                  icon: Icons.cloud_sync,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tests if https://efactor.tech accepts and stores this device token in its database.',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          icon: _syncingBackend
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.send),
                          label: Text(_syncingBackend
                              ? 'Checking Server Response...'
                              : 'Verify Backend Registration Now'),
                          onPressed: _syncingBackend ? null : _testBackendSync,
                        ),
                      ),
                      if (_syncStatus != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _syncHttpCode == 200
                                ? const Color(0xFF064E3B)
                                : const Color(0xFF450A0A),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _syncHttpCode == 200
                                  ? const Color(0xFF059669)
                                  : const Color(0xFFDC2626),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _syncHttpCode == 200
                                        ? Icons.check_circle
                                        : Icons.error,
                                    color: _syncHttpCode == 200
                                        ? const Color(0xFF34D399)
                                        : const Color(0xFFF87171),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Status: ${_syncHttpCode ?? "Err"} (${_syncLatencyMs ?? 0}ms)',
                                    style: TextStyle(
                                      color: _syncHttpCode == 200
                                          ? const Color(0xFF34D399)
                                          : const Color(0xFFF87171),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _syncStatus!,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              if (_syncBody != null && _syncBody!.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.black45,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    _syncBody!,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // SECTION 3: Self Wake-up & Lock Screen Test
                _buildCard(
                  cardBg: cardBg,
                  borderCol: borderCol,
                  title: 'Step 2: Self Test (Lock Screen Wake-Up)',
                  icon: Icons.screen_lock_portrait,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tests if incoming call notifications can ring continuously and wake up your phone when locked.',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _countdownSeconds > 0
                                ? const Color(0xFFD97706)
                                : const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          icon: Icon(_countdownSeconds > 0
                              ? Icons.timer
                              : Icons.ring_volume),
                          label: Text(
                            _countdownSeconds > 0
                                ? 'Ringing in $_countdownSeconds seconds! LOCK PHONE NOW!'
                                : 'Test Incoming Call (5s Delay)',
                          ),
                          onPressed: _startSelfCallTest,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // SECTION 4: Cross-Device Ping / Dispatch
                _buildCard(
                  cardBg: cardBg,
                  borderCol: borderCol,
                  title: 'Step 3: Direct Cross-Device Ping to Mobile B',
                  icon: Icons.send_to_mobile,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Paste the FCM token from Mobile B here to test if Mobile B can receive a call push directly from Google:',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _targetTokenController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                        decoration: InputDecoration(
                          hintText: 'Paste Mobile B Token (starts with eNx... or dXy...)',
                          hintStyle: const TextStyle(color: Colors.white30),
                          filled: true,
                          fillColor: Colors.black26,
                          isDense: true,
                          border: OutlineInputBorder(
                            borderSide: const BorderSide(color: borderCol),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.paste, color: primary, size: 18),
                            onPressed: () async {
                              final data = await Clipboard.getData('text/plain');
                              if (data?.text != null) {
                                _targetTokenController.text = data!.text!.trim();
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _serverKeyController,
                        obscureText: true,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        decoration: InputDecoration(
                          hintText: 'Firebase Server Key (from Firebase Console)',
                          hintStyle: const TextStyle(color: Colors.white30),
                          filled: true,
                          fillColor: Colors.black26,
                          isDense: true,
                          border: OutlineInputBorder(
                            borderSide: const BorderSide(color: borderCol),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: primary,
                            side: const BorderSide(color: primary),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: _sendingCrossPush
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.send, size: 16),
                          label: const Text('Send Call Push to Mobile B'),
                          onPressed:
                              _sendingCrossPush ? null : _sendCrossDevicePush,
                        ),
                      ),
                      if (_crossPushResult != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black38,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _crossPushResult!,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // SECTION 5: Permissions Checklist
                _buildCard(
                  cardBg: cardBg,
                  borderCol: borderCol,
                  title: 'Device Permissions Checklist',
                  icon: Icons.checklist,
                  child: Column(
                    children: [
                      _buildChecklistRow(
                        title: 'Notification Permission',
                        granted: _notifGranted,
                        onFix: () async {
                          await Permission.notification.request();
                          await _loadDiagnostics();
                        },
                      ),
                      const Divider(color: borderCol, height: 16),
                      _buildChecklistRow(
                        title: 'Display over other apps (Floating Alert)',
                        granted: _overlayGranted,
                        onFix: () async {
                          await CallPermissionHelper.openOverlaySettings();
                          await Future<void>.delayed(
                            const Duration(seconds: 1),
                          );
                          await _loadDiagnostics();
                        },
                      ),
                      const Divider(color: borderCol, height: 16),
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Call Channel Settings (grid_calls_v4)',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        subtitle: const Text(
                          'Ensure sound & lock screen banner are turned on',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        trailing: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: primary,
                            side: const BorderSide(color: borderCol),
                          ),
                          onPressed: () => CallPermissionHelper
                              .openCallNotificationChannelSettings(),
                          child: const Text('Configure'),
                        ),
                      ),
                      const Divider(color: borderCol, height: 16),
                      _buildChecklistRow(
                        title: 'Battery Whitelist (Doze Exemption)',
                        granted: _batteryIgnored,
                        onFix: () async {
                          await CallPermissionHelper.requestIgnoreBatteryOptimizations();
                          await Future<void>.delayed(
                            const Duration(seconds: 1),
                          );
                          await _loadDiagnostics();
                        },
                      ),
                      const Divider(color: borderCol, height: 16),
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'OEM Autostart / Background Run',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        subtitle: const Text(
                          'Vivo, Xiaomi, Oppo background wake after swipe',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        trailing: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: primary,
                            side: const BorderSide(color: borderCol),
                          ),
                          onPressed: () =>
                              CallPermissionHelper.openAutostartSettings(),
                          child: const Text('Open'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({
    required Color cardBg,
    required Color borderCol,
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderCol),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF38BDF8), size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _buildKeyValue(String key, String value, {bool isWarn = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(key, style: const TextStyle(color: Colors.white60, fontSize: 12)),
        Text(
          value,
          style: TextStyle(
            color: isWarn ? const Color(0xFFF87171) : Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildChecklistRow({
    required String title,
    required bool granted,
    required VoidCallback onFix,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              Icon(
                granted ? Icons.check_circle : Icons.cancel,
                color: granted ? const Color(0xFF34D399) : const Color(0xFFF87171),
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        if (!granted)
          TextButton(
            onPressed: onFix,
            child: const Text('Fix / Enable', style: TextStyle(color: Color(0xFF38BDF8))),
          )
        else
          const Text(
            'Granted',
            style: TextStyle(color: Color(0xFF34D399), fontSize: 12),
          ),
      ],
    );
  }
}
