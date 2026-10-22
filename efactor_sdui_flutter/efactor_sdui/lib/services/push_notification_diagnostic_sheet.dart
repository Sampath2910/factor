import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'incoming_call_service.dart';
import 'push_notification_bootstrap.dart';

/// In-app interactive diagnostic sheet for testing and verifying:
/// 1. Firebase FCM Token acquisition and status.
/// 2. Live device token registration to backend (`/api/register_device_token` & `/grid-chat/api/push/native-token`).
/// 3. Local simulated incoming call with 5-second countdown to test lock-screen ringing & full-screen intent.
/// 4. Android system notification permissions.
/// 5. Generation of ready-to-test FCM HTTP v1 curl commands.
class PushNotificationDiagnosticSheet extends StatefulWidget {
  const PushNotificationDiagnosticSheet({
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
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => PushNotificationDiagnosticSheet(
          userId: userId,
          accessToken: accessToken,
        ),
      ),
    );
  }

  @override
  State<PushNotificationDiagnosticSheet> createState() =>
      _PushNotificationDiagnosticSheetState();
}

class _PushNotificationDiagnosticSheetState
    extends State<PushNotificationDiagnosticSheet> {
  String _fcmToken = '';
  String _tokenStatus = 'Checking...';
  String _permissionStatus = 'Checking...';
  bool _firebaseInitialized = false;

  bool _isRegistering = false;
  String? _registerResult;
  int? _registerStatusCode;
  String? _gridChatResult;
  int? _gridChatStatusCode;

  int _countdownSeconds = 0;
  Timer? _countdownTimer;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadDiagnostics();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDiagnostics() async {
    try {
      _firebaseInitialized = Firebase.apps.isNotEmpty;
    } catch (_) {
      _firebaseInitialized = false;
    }

    // Permission status
    if (!kIsWeb && Platform.isAndroid) {
      final status = await Permission.notification.status;
      _permissionStatus = status.isGranted
          ? 'Granted (Notifications Active)'
          : status.isDenied
              ? 'Denied (Please Allow)'
              : status.isPermanentlyDenied
                  ? 'Permanently Denied (Enable in App Settings)'
                  : status.toString();
    } else {
      _permissionStatus = 'Platform Not Android';
    }

    // FCM token
    final cachedToken = IncomingCallService.instance.deviceToken ?? '';
    if (cachedToken.isNotEmpty) {
      _fcmToken = cachedToken;
      _tokenStatus = 'Acquired (${cachedToken.length} chars)';
    } else if (!kIsWeb) {
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null && token.isNotEmpty) {
          _fcmToken = token;
          IncomingCallService.instance.setDeviceToken(token);
          _tokenStatus = 'Acquired via Firebase (${token.length} chars)';
        } else {
          _tokenStatus = 'No token returned by Firebase';
        }
      } catch (e) {
        _tokenStatus = 'Error fetching token: $e';
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> _testBackendRegistration() async {
    setState(() {
      _isRegistering = true;
      _registerResult = null;
      _registerStatusCode = null;
      _gridChatResult = null;
      _gridChatStatusCode = null;
    });

    final effectiveUserId = widget.userId ??
        IncomingCallService.instance.activeUserId?.toString() ??
        '763';
    final rawToken = widget.accessToken ??
        IncomingCallService.instance.activeAccessToken ??
        '';
    final cleanToken = rawToken.startsWith('Bearer ')
        ? rawToken.substring(7).trim()
        : rawToken.trim();

    if (_fcmToken.isEmpty) {
      setState(() {
        _isRegistering = false;
        _registerResult = 'Cannot register: FCM Token is empty.';
      });
      return;
    }

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (cleanToken.isNotEmpty) ...{
        'Authorization': 'Bearer $cleanToken',
        'access_token': cleanToken,
        'accesstoken': cleanToken,
        'token': cleanToken,
      },
    };

    final payload = jsonEncode(<String, dynamic>{
      'device_token': _fcmToken,
      'platform': 'android',
      'token_type': 'fcm',
      'user_id': effectiveUserId,
      if (cleanToken.isNotEmpty) ...{
        'access_token': cleanToken,
        'accesstoken': cleanToken,
        'token': cleanToken,
      },
    });

    // 1. Test Core Backend Register Endpoint
    try {
      final uri = Uri.parse(
        'https://efactor.tech/index.php/api/register_device_token',
      );
      final resp = await http
          .post(uri, headers: headers, body: payload)
          .timeout(const Duration(seconds: 12));

      _registerStatusCode = resp.statusCode;
      _registerResult = resp.body;
    } catch (e) {
      _registerStatusCode = 0;
      _registerResult = 'Network/Timeout Error: $e';
    }

    // 2. Test Circle Connect Native Token Endpoint
    try {
      final uri = Uri.parse(
        'https://efactor.tech/index.php/grid-chat/api/push/native-token',
      );
      final resp = await http
          .post(uri, headers: headers, body: payload)
          .timeout(const Duration(seconds: 12));

      _gridChatStatusCode = resp.statusCode;
      _gridChatResult = resp.body;
    } catch (e) {
      _gridChatStatusCode = 0;
      _gridChatResult = 'Network/Timeout Error: $e';
    }

    if (mounted) {
      setState(() {
        _isRegistering = false;
      });
    }
  }

  void _startIncomingCallSimulation() {
    _countdownTimer?.cancel();
    setState(() {
      _countdownSeconds = 5;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_countdownSeconds <= 1) {
        timer.cancel();
        setState(() {
          _countdownSeconds = 0;
        });
        _triggerLocalCallNotification();
      } else {
        setState(() {
          _countdownSeconds--;
        });
      }
    });
  }

  Future<void> _triggerLocalCallNotification() async {
    final call = IncomingCallData(
      callId: 'diag_${DateTime.now().millisecondsSinceEpoch}',
      callerId: 'diag_tester',
      callerName: 'Efactor Test Caller',
      callType: 'audio',
      roomUrl: 'https://efactor.tech/index.php/grid-chat',
      body: 'Incoming audio call (Diagnostic Simulation)',
    );

    await PushNotificationBootstrap.instance.showIncomingCallNotification(call);
  }

  Future<void> _triggerLocalChatMessage() async {
    final data = <String, dynamic>{
      'type': 'NEW_MESSAGE',
      'conversation_id': 'diag_chat',
      'sender_name': 'Circle Connect Bot',
      'body': 'This is a test chat push notification from the Diagnostic Panel.',
      'url': 'https://efactor.tech/index.php/grid-chat',
    };

    final plugin = PushNotificationBootstrap.instance;
    await plugin.showMissedCallNotification(
      IncomingCallData(
        callId: 'diag_msg',
        callerId: 'bot',
        callerName: 'Circle Connect',
        roomUrl: '',
        body: 'New message received',
      ),
    );
  }

  Future<void> _stopAllRinging() async {
    await PushNotificationBootstrap.instance.handleCallHandled('diag_');
    IncomingCallService.instance.dismissCall();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All local ringing alerts dismissed.')),
    );
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard!')),
    );
  }

  String _generateCurlCommand() {
    final token = _fcmToken.isNotEmpty ? _fcmToken : '<FCM_DEVICE_TOKEN>';
    return '''# Send this command from your terminal to trigger a real call alert on this device:
curl -X POST https://fcm.googleapis.com/v1/projects/grid-factor/messages:send \\
  -H "Authorization: Bearer \$(gcloud auth print-access-token)" \\
  -H "Content-Type: application/json" \\
  -d '{
    "message": {
      "token": "$token",
      "data": {
        "type": "INCOMING_CALL",
        "call_id": "test_call_${DateTime.now().millisecondsSinceEpoch}",
        "caller_name": "Terminal Test Caller",
        "caller_user_id": "763",
        "call_type": "audio",
        "room_url": "https://efactor.tech/index.php/grid-chat",
        "body": "Incoming test call"
      },
      "android": {
        "priority": "HIGH"
      }
    }
  }' ''';
  }

  @override
  Widget build(BuildContext context) {
    final effectiveUserId = widget.userId ??
        IncomingCallService.instance.activeUserId?.toString() ??
        'Not Set';
    final rawToken = widget.accessToken ??
        IncomingCallService.instance.activeAccessToken ??
        '';
    final tokenPreview = rawToken.length > 20
        ? '${rawToken.substring(0, 10)}...${rawToken.substring(rawToken.length - 10)}'
        : (rawToken.isNotEmpty ? rawToken : 'None');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: ListView(
        controller: _scrollController,
        children: <Widget>[
          // Header
          Center(
            child: Container(
              width: 48,
              height: 5,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Row(
            children: <Widget>[
              const Icon(Icons.notifications_active, color: Color(0xFF38BDF8), size: 28),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Push & Call Diagnostic Panel',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white70),
                onPressed: _loadDiagnostics,
                tooltip: 'Refresh Status',
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Test live backend token registration, lock-screen call ringing, and push contracts directly on this device.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const Divider(color: Colors.white12, height: 24),

          // 1. Device Token Section
          _buildCard(
            title: '1. Device FCM Push Token',
            icon: Icons.key,
            iconColor: const Color(0xFFF59E0B),
            children: <Widget>[
              _buildRow('Firebase Initialized:', _firebaseInitialized ? 'YES ✅' : 'NO ❌'),
              _buildRow('Token Status:', _tokenStatus),
              if (_fcmToken.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: SelectableText(
                    _fcmToken,
                    style: const TextStyle(
                      color: Color(0xFF38BDF8),
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E293B),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => _copyToClipboard(_fcmToken, 'FCM Token'),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Token String'),
                    ),
                  ],
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // 2. Active Session Credentials
          _buildCard(
            title: '2. Active User Session',
            icon: Icons.account_circle,
            iconColor: const Color(0xFF10B981),
            children: <Widget>[
              _buildRow('User ID:', effectiveUserId),
              _buildRow('Access Token:', tokenPreview),
              const SizedBox(height: 4),
              const Text(
                'Note: Backend matches access_token string directly in MySQL `users.access_token`.',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // 3. Test Live Backend Registration
          _buildCard(
            title: '3. Live Backend Token Registration Test',
            icon: Icons.cloud_upload,
            iconColor: const Color(0xFF38BDF8),
            children: <Widget>[
              const Text(
                'Sends live POST requests to both endpoints to verify if the server returns HTTP 200 and saves the token:',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: _isRegistering ? null : _testBackendRegistration,
                icon: _isRegistering
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(
                  _isRegistering ? 'Registering with Server...' : 'Test Token Registration Now',
                ),
              ),
              if (_registerStatusCode != null) ...<Widget>[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _registerStatusCode == 200
                        ? const Color(0xFF064E3B)
                        : const Color(0xFF7F1D1D),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _registerStatusCode == 200
                          ? const Color(0xFF10B981)
                          : const Color(0xFFEF4444),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Core API Status: HTTP $_registerStatusCode ${_registerStatusCode == 200 ? "SUCCESS ✅" : "FAILED (401/Unauthorized) ❌"}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Response: ${_registerResult ?? ""}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (_gridChatStatusCode != null) ...<Widget>[
                        const Divider(color: Colors.white24, height: 16),
                        Text(
                          'Grid Chat API Status: HTTP $_gridChatStatusCode ${_gridChatStatusCode == 200 ? "SUCCESS ✅" : "RESPONSE"}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Grid Chat Response: ${_gridChatResult ?? ""}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // 4. Test Lock-Screen Incoming Call (Local Simulation)
          _buildCard(
            title: '4. Test Incoming Call UI & Ringing (Local)',
            icon: Icons.phone_in_talk,
            iconColor: const Color(0xFFEC4899),
            children: <Widget>[
              const Text(
                'Tap the button below, then immediately PRESS THE PHONE POWER BUTTON TO LOCK SCREEN or go to Home screen. After 5 seconds, the phone should ring and display the full-screen call banner!',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              if (_countdownSeconds > 0) ...<Widget>[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF831843),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFEC4899)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'LOCK PHONE NOW! Ringing in $_countdownSeconds...',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...<Widget>[
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFBE185D),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onPressed: _startIncomingCallSimulation,
                      icon: const Icon(Icons.timer),
                      label: const Text('Start 5s Countdown & Test Call'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                      ),
                      onPressed: _stopAllRinging,
                      icon: const Icon(Icons.call_end, size: 16),
                      label: const Text('Stop Ringing'),
                    ),
                  ],
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // 5. Device Permissions Check
          _buildCard(
            title: '5. Android OS Permissions Audit',
            icon: Icons.security,
            iconColor: const Color(0xFF8B5CF6),
            children: <Widget>[
              _buildRow('POST_NOTIFICATIONS:', _permissionStatus),
              const SizedBox(height: 6),
              const Text(
                'Android 14+ / 16 (Vivo V2518) Notice:\n'
                '• Full Screen Intent must be enabled under:\n'
                '  Settings -> Apps -> Special App Access -> Full Screen Intents -> Efactor IoE 2.0 -> Allow\n'
                '• Battery Optimization should be set to "Unrestricted" so Vivo OS does not kill background wakeups.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4C1D95),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => openAppSettings(),
                icon: const Icon(Icons.settings, size: 16),
                label: const Text('Open App Settings in Android'),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // 6. Direct Terminal Push Command
          _buildCard(
            title: '6. Direct FCM HTTP v1 Test Curl',
            icon: Icons.terminal,
            iconColor: const Color(0xFF06B6D4),
            children: <Widget>[
              const Text(
                'Copy this curl command and give it to your Backend / DevOps team to send an instant push directly to your phone:',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _copyToClipboard(
                  _generateCurlCommand(),
                  'FCM Curl Command',
                ),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Terminal Curl Command'),
              ),
            ],
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildCard({
    required String title,
    required IconData icon,
    required Color iconColor,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white10, height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _buildRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
