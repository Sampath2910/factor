import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
            onPressed: () async {
              messenger.hideCurrentMaterialBanner();
              final p = await SharedPreferences.getInstance();
              await p.setBool(_prefPromptShown, true);
              // Directly run the full guided permission flow (no intermediate
              // checklist screen): native dialogs first, then each settings page
              // one at a time.
              await runCallPermissionFlow(messenger);
            },
            child: const Text('Enable',
                style: TextStyle(
                    color: Color(0xFF38BDF8), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Runs the full guided call-alert permission flow in one tap (Approach A):
  /// the two native dialogs first (notifications, then background wake), then
  /// each remaining special-access Settings page one at a time, auto-advancing
  /// as the user returns from each. No intermediate checklist screen.
  /// Android-only; Android forces a Settings toggle for overlay / full-screen /
  /// autostart, so those pages are unavoidable, but they open sequentially.
  static Future<void> runCallPermissionFlow(
      ScaffoldMessengerState messenger) async {
    if (kIsWeb || !Platform.isAndroid) return;
    await _CallPermissionFlow(messenger).start();
  }
}

/// One special-access step that can only be granted on a Settings page (overlay,
/// full-screen intent, OEM autostart). [isGranted] is null when Android exposes
/// no status for it (we then simply advance once the user returns).
class _SettingsStep {
  const _SettingsStep(this.label, this.isGranted, this.open);
  final String label;
  final Future<bool> Function()? isGranted;
  final Future<void> Function() open;
}

/// Headless, lifecycle-driven sequencer. Fires the native permission dialogs,
/// then walks the user through the Settings-page permissions one at a time,
/// advancing on each app resume, with lightweight "N of M" SnackBars. No visible
/// checklist sheet — the banner's single "Enable" tap drives the whole thing.
class _CallPermissionFlow with WidgetsBindingObserver {
  _CallPermissionFlow(this._messenger);

  final ScaffoldMessengerState _messenger;
  final List<_SettingsStep> _queue = <_SettingsStep>[];
  int _total = 0;
  bool _active = false;
  bool _awaitingReturn = false;

  Future<void> start() async {
    // Phase 1 — native dialogs, in sequence (no Settings pages).
    if (!(await Permission.notification.status).isGranted) {
      await Permission.notification.request();
    }
    if (!await CallPermissionHelper.isBatteryOptimizationIgnored()) {
      await CallPermissionHelper.requestIgnoreBatteryOptimizations();
    }

    // Phase 2 — queue the not-yet-granted special-access steps.
    final mfr = await CallPermissionHelper.getDeviceManufacturer();
    const oems = <String>[
      'vivo', 'xiaomi', 'oppo', 'realme', 'iqoo', 'poco', 'redmi', 'oneplus',
    ];
    final isOem = oems.any((o) => mfr.contains(o));

    if (!await CallPermissionHelper.canDrawOverlays()) {
      _queue.add(const _SettingsStep(
        'Floating Banners',
        CallPermissionHelper.canDrawOverlays,
        CallPermissionHelper.openOverlaySettings,
      ));
    }
    // Full-screen intent: no status API -> best-effort, always included.
    _queue.add(const _SettingsStep(
      'Full-Screen Ringing',
      null,
      CallPermissionHelper.openFullScreenIntentSettings,
    ));
    if (isOem) {
      _queue.add(const _SettingsStep(
        'Auto-start',
        null,
        CallPermissionHelper.openAutostartSettings,
      ));
    }

    _total = _queue.length;
    if (_queue.isEmpty) {
      _toast('Call alerts enabled');
      return;
    }

    WidgetsBinding.instance.addObserver(this);
    _active = true;
    await _openNext();
  }

  Future<void> _openNext() async {
    if (_queue.isEmpty) {
      _finish();
      return;
    }
    final step = _queue.first;
    final index = _total - _queue.length + 1;
    _toast('$index of $_total  •  enable ${step.label}');
    _awaitingReturn = true;
    await step.open();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_active || !_awaitingReturn) {
      return;
    }
    _awaitingReturn = false;
    unawaited(_advance());
  }

  Future<void> _advance() async {
    // Drop the step we just showed, then skip any that are now granted.
    if (_queue.isNotEmpty) _queue.removeAt(0);
    while (_queue.isNotEmpty) {
      final check = _queue.first.isGranted;
      if (check == null) break;
      if (await check()) {
        _queue.removeAt(0);
      } else {
        break;
      }
    }
    if (_queue.isEmpty) {
      _finish();
      return;
    }
    await _openNext();
  }

  void _finish() {
    if (!_active) return;
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    _toast('Call alerts setup complete');
  }

  void _toast(String msg) {
    _messenger.clearSnackBars();
    _messenger.showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
