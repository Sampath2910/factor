import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'push_diagnostic_sheet.dart';

/// Helper to request WhatsApp-like incoming call & floating banner permissions on Android.
class CallPermissionHelper {
  CallPermissionHelper._();

  static const MethodChannel _channel = MethodChannel('tech.efactor/circle_connect');
  static const String _prefPromptShown = 'has_seen_call_permission_prompt_v4';

  /// Checks whether "Display over other apps" (System Alert Window) is granted on Android.
  static Future<bool> canDrawOverlays() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('canDrawOverlays');
      return res ?? false;
    } catch (e) {
      debugPrint('[CallPermissionHelper] canDrawOverlays error: $e');
      return false;
    }
  }

  /// Opens the Android Notification Channel Settings directly for incoming calls.
  /// On Vivo FuntouchOS, Samsung, and Xiaomi, this screen contains the
  /// "Floating notifications / Banner" and "Lock screen" toggle.
  static Future<bool> openCallNotificationChannelSettings({
    String channelId = 'calls',
  }) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>(
        'openNotificationChannelSettings',
        {'channelId': channelId},
      );
      return res ?? false;
    } catch (e) {
      debugPrint('[CallPermissionHelper] openCallNotificationChannelSettings error: $e');
      return false;
    }
  }

  /// Opens the "Display over other apps" settings page for this app.
  static Future<bool> openOverlaySettings() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('openOverlaySettings');
      return res ?? false;
    } catch (e) {
      debugPrint('[CallPermissionHelper] openOverlaySettings error: $e');
      return false;
    }
  }

  /// On Android 14+, opens the special "Full Screen Intent" settings page.
  static Future<bool> openFullScreenIntentSettings() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('openFullScreenIntentSettings');
      return res ?? false;
    } catch (e) {
      debugPrint('[CallPermissionHelper] openFullScreenIntentSettings error: $e');
      return false;
    }
  }

  /// Checks whether app is exempt from battery optimizations (Doze mode whitelist).
  static Future<bool> isBatteryOptimizationIgnored() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final res =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? false;
    } catch (e) {
      debugPrint('[CallPermissionHelper] isIgnoringBatteryOptimizations error: $e');
      return false;
    }
  }

  /// Triggers system battery optimization exemption dialog.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final res = await _channel
          .invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return res ?? false;
    } catch (e) {
      debugPrint('[CallPermissionHelper] requestIgnoreBatteryOptimizations error: $e');
      return false;
    }
  }

  /// Opens OEM specific Autostart settings (Vivo, Xiaomi, Oppo, Samsung, Huawei).
  static Future<bool> openAutostartSettings() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('openAutostartSettings');
      return res ?? false;
    } catch (e) {
      debugPrint('[CallPermissionHelper] openAutostartSettings error: $e');
      return false;
    }
  }

  /// Gets device manufacturer lowercase.
  static Future<String> getDeviceManufacturer() async {
    if (kIsWeb || !Platform.isAndroid) return '';
    try {
      final res = await _channel.invokeMethod<String>('getDeviceManufacturer');
      return res ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Explicitly requests native activity to wake the screen and dismiss keyguard.
  static Future<void> wakeAndUnlock() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('wakeAndUnlock');
    } catch (_) {}
  }

  /// Checks if prompt is needed and displays the onboarding bottom sheet if not yet configured.
  /// Non-blocking entry point, safe to call right after login. Instead of
  /// firing OS permission dialogs or a blocking modal at startup (which stacks
  /// unfamiliar system prompts and alarms users), it surfaces a single
  /// dismissible banner. No OS dialog is triggered here; tapping "Enable" opens
  /// a self-paced checklist where each permission is requested one at a time.
  static Future<void> checkAndPromptIfNeeded(BuildContext context) async {
    if (kIsWeb || !Platform.isAndroid) return;

    final hasOverlay = await canDrawOverlays();
    final isBatteryIgnored = await isBatteryOptimizationIgnored();
    final notifGranted = (await Permission.notification.status).isGranted;
    // Everything already granted -> nothing to show.
    if (hasOverlay && isBatteryIgnored && notifGranted) return;

    final prefs = await SharedPreferences.getInstance();
    // Respect a prior dismissal / prior visit to the checklist: don't re-nag.
    if (prefs.getBool(_prefPromptShown) ?? false) return;

    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: const Color(0xFF0F172A),
        leading: const Icon(Icons.phone_in_talk, color: Color(0xFF38BDF8)),
        content: const Text(
          'Enable call alerts so incoming calls ring over your lock screen and '
          'in other apps.',
          style: TextStyle(color: Colors.white, fontSize: 13.5, height: 1.35),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              messenger.hideCurrentMaterialBanner();
              final p = await SharedPreferences.getInstance();
              await p.setBool(_prefPromptShown, true);
            },
            child: const Text('Not now',
                style: TextStyle(color: Color(0xFF64748B))),
          ),
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              if (context.mounted) showCallPermissionModal(context);
            },
            child: const Text('Enable',
                style: TextStyle(
                    color: Color(0xFF38BDF8), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Opens the self-paced permission checklist. Each permission is its own row
  /// with its own action; tapping a row triggers exactly ONE OS prompt/settings
  /// screen, and the sheet updates live (checks state on return). This replaces
  /// the old single button that fired four system screens back-to-back.
  static Future<void> showCallPermissionModal(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefPromptShown, true);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => const _CallPermissionChecklist(),
    );
  }
}

/// Self-paced, lifecycle-aware checklist for the Android call-alert permissions.
/// Shows live grant state (where the OS exposes it) and requests one permission
/// at a time, so users are never hit with a stack of system dialogs at once.
class _CallPermissionChecklist extends StatefulWidget {
  const _CallPermissionChecklist();

  @override
  State<_CallPermissionChecklist> createState() =>
      _CallPermissionChecklistState();
}

class _CallPermissionChecklistState extends State<_CallPermissionChecklist>
    with WidgetsBindingObserver {
  bool _notif = false;
  bool _overlay = false;
  bool _battery = false;
  bool _isChineseOem = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // User returns from a system settings screen -> re-read grant state so the
    // row flips to a green check without any further taps.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _init() async {
    final mfr = await CallPermissionHelper.getDeviceManufacturer();
    const oems = <String>[
      'vivo', 'xiaomi', 'oppo', 'realme', 'iqoo', 'poco', 'redmi', 'oneplus',
    ];
    if (mounted) {
      setState(() => _isChineseOem = oems.any((o) => mfr.contains(o)));
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    final notif = (await Permission.notification.status).isGranted;
    final overlay = await CallPermissionHelper.canDrawOverlays();
    final battery = await CallPermissionHelper.isBatteryOptimizationIgnored();
    if (!mounted) return;
    setState(() {
      _notif = notif;
      _overlay = overlay;
      _battery = battery;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Center(
            child: Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0284C7).withValues(alpha: 0.18),
              border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
            ),
            child: const Icon(Icons.phone_in_talk,
                color: Color(0xFF38BDF8), size: 32),
          ),
          const SizedBox(height: 16),
          const Text(
            'Enable Incoming Call Alerts',
            style: TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.3,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Turn these on one at a time so calls can ring over your lock '
            'screen and in other apps. Enable only what you want.',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13.5, height: 1.4),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          _row(
            icon: Icons.notifications_active_outlined,
            title: 'Call & Chat Notifications',
            desc: 'Lets the app notify you about calls and messages.',
            granted: _notif,
            actionLabel: 'Enable',
            onAction: () async {
              await Permission.notification.request();
              await _refresh();
            },
          ),
          _row(
            icon: Icons.chat_bubble_outline,
            title: 'Floating Heads-Up Banners',
            desc: 'Pop-up banners for calls and chats while in other apps.',
            granted: _overlay,
            actionLabel: 'Enable',
            onAction: () => CallPermissionHelper.openOverlaySettings(),
          ),
          _row(
            icon: Icons.battery_charging_full,
            title: 'Background Call Wake-up',
            desc: 'Keeps calls alive when the app is cleared from Recents.',
            granted: _battery,
            actionLabel: 'Enable',
            onAction: () async {
              await CallPermissionHelper.requestIgnoreBatteryOptimizations();
              await _refresh();
            },
          ),
          _row(
            icon: Icons.fullscreen,
            title: 'Full-Screen Lock Screen Ringing',
            desc: 'Turns the screen on so you can answer immediately.',
            granted: null, // Android exposes no status for this special access.
            actionLabel: 'Open',
            onAction: () => CallPermissionHelper.openFullScreenIntentSettings(),
          ),
          if (_isChineseOem)
            _row(
              icon: Icons.restart_alt,
              title: 'Auto-start',
              desc: 'Allows the app to start so calls arrive reliably.',
              granted: null,
              actionLabel: 'Open',
              onAction: () => CallPermissionHelper.openAutostartSettings(),
            ),
          const SizedBox(height: 12),
          const Text(
            'Android will show its own permission screen for each — that is '
            'expected.',
            style: TextStyle(color: Color(0xFF64748B), fontSize: 11.5, height: 1.3),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              TextButton.icon(
                icon: const Icon(Icons.troubleshoot,
                    size: 16, color: Color(0xFF38BDF8)),
                label: const Text('Push Diagnostics',
                    style: TextStyle(color: Color(0xFF38BDF8), fontSize: 13)),
                onPressed: () {
                  // Use the Navigator's own (stable) context so the diagnostics
                  // sheet still has a valid context after this sheet pops.
                  final nav = Navigator.of(context);
                  final navContext = nav.context;
                  nav.pop();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    PushDiagnosticSheet.show(navContext);
                  });
                },
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String desc,
    required bool? granted, // null = no OS status; always actionable.
    required String actionLabel,
    required Future<void> Function() onAction,
  }) {
    final isDone = granted == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: isDone
            ? Border.all(color: const Color(0xFF22C55E).withValues(alpha: 0.4))
            : null,
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: const Color(0xFF38BDF8), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(desc,
                    style: const TextStyle(
                        color: Color(0xFF94A3B8), fontSize: 11.5, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (isDone)
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 18),
                SizedBox(width: 4),
                Text('On',
                    style: TextStyle(
                        color: Color(0xFF22C55E),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            )
          else
            SizedBox(
              height: 32,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  elevation: 0,
                ),
                onPressed: () async {
                  await onAction();
                  await _refresh();
                },
                child: Text(actionLabel,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      ),
    );
  }
}
