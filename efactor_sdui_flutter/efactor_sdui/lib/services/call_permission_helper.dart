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
    String channelId = 'grid_calls_v4',
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
  static Future<void> checkAndPromptIfNeeded(BuildContext context) async {
    if (kIsWeb || !Platform.isAndroid) return;

    // Check basic notification permission
    final notifStatus = await Permission.notification.status;
    if (!notifStatus.isGranted) {
      await Permission.notification.request();
    }

    final prefs = await SharedPreferences.getInstance();
    final alreadyPrompted = prefs.getBool(_prefPromptShown) ?? false;
    final hasOverlay = await canDrawOverlays();
    final isBatteryIgnored = await isBatteryOptimizationIgnored();

    // If both overlay and battery whitelist are granted, nothing needed!
    if (hasOverlay && isBatteryIgnored) return;

    // If user already dismissed it previously, don't nag every single second
    if (alreadyPrompted) return;

    if (!context.mounted) return;
    await showCallPermissionModal(context);
  }

  /// Displays the rich, WhatsApp-style permission bottom sheet.
  static Future<void> showCallPermissionModal(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefPromptShown, true);

    if (!context.mounted) return;

    final manufacturer = await getDeviceManufacturer();
    final isChineseOem = manufacturer.contains('vivo') ||
        manufacturer.contains('xiaomi') ||
        manufacturer.contains('oppo') ||
        manufacturer.contains('realme') ||
        manufacturer.contains('iqoo') ||
        manufacturer.contains('poco') ||
        manufacturer.contains('redmi') ||
        manufacturer.contains('oneplus');

    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: const BoxDecoration(
            color: Color(0xFF0F172A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Top drag indicator
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

              // Glowing Call Icon
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0284C7).withValues(alpha: 0.18),
                  border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
                ),
                child: const Icon(
                  Icons.phone_in_talk,
                  color: Color(0xFF38BDF8),
                  size: 34,
                ),
              ),
              const SizedBox(height: 18),

              // Title
              const Text(
                'Enable Incoming Call Alerts',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.3,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),

              // Subtitle
              const Text(
                'To ring and display Answer/Decline buttons over your lock screen and while using other apps, please enable Floating Call Alerts.',
                style: TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 14,
                  height: 1.45,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),

              // Feature cards
              _buildFeatureRow(
                icon: Icons.fullscreen,
                title: 'Full-Screen Lock Screen Ringing',
                desc: 'Turns your screen on and lets you answer calls immediately.',
              ),
              const SizedBox(height: 12),
              _buildFeatureRow(
                icon: Icons.chat_bubble_outline,
                title: 'Floating Heads-Up Banners',
                desc: 'Pop-up banners for calls and chat messages while in other apps.',
              ),
              const SizedBox(height: 12),
              _buildFeatureRow(
                icon: Icons.battery_charging_full,
                title: 'Background Call Wake-up',
                desc: 'Prevents phone power manager from killing calls when cleared from Recents.',
              ),
              const SizedBox(height: 24),

              // Action Buttons
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    // 1. Request Battery Optimization Exemption (Crucial for closed app wake)
                    final isBatIgnored = await isBatteryOptimizationIgnored();
                    if (!isBatIgnored) {
                      await requestIgnoreBatteryOptimizations();
                      await Future<void>.delayed(const Duration(milliseconds: 500));
                    }

                    // 2. Open notification channel settings (contains floating banner toggle)
                    await openCallNotificationChannelSettings();

                    // 3. Open overlay settings if needed
                    final hasOverlay = await canDrawOverlays();
                    if (!hasOverlay) {
                      await Future<void>.delayed(const Duration(milliseconds: 600));
                      await openOverlaySettings();
                    }

                    // 4. On Vivo / Xiaomi / Oppo, prompt autostart if needed
                    if (isChineseOem) {
                      await Future<void>.delayed(const Duration(milliseconds: 600));
                      await openAutostartSettings();
                    }
                  },
                  child: const Text(
                    'Enable Call Alerts & Background Wake',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.troubleshoot, size: 16, color: Color(0xFF38BDF8)),
                    label: const Text(
                      'Push Diagnostics',
                      style: TextStyle(color: Color(0xFF38BDF8), fontSize: 13),
                    ),
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      PushDiagnosticSheet.show(context);
                    },
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text(
                      'Later',
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget _buildFeatureRow({
    required IconData icon,
    required String title,
    required String desc,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: const Color(0xFF38BDF8), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
