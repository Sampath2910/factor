import 'dart:async';

import 'package:flutter/material.dart';

import 'incoming_call_service.dart';

/// App-owned foreground message banner.
///
/// Circle Connect's native host (not the GRID Chat web page, which has
/// `messageNotificationsManaged = true`) must keep a foreground message
/// heads-up visible long enough to tap. A system heads-up is OEM-controlled
/// and on some devices self-dismisses in under a second, so while the app is
/// visible we show this overlay instead and skip the duplicate system
/// heads-up. Guaranteed minimum dwell, pause-while-touched, tap-to-open, and a
/// single-slot queue so a second message never shortens the current one.
class MessageBanner {
  MessageBanner._();
  static final MessageBanner instance = MessageBanner._();

  /// Recommended dwell (spec: >=1500ms, 2500ms recommended).
  static const Duration _dwell = Duration(milliseconds: 2500);

  OverlayEntry? _entry;
  Timer? _dismissTimer;
  _BannerData? _queued;

  /// Shows [title]/[body] as a tappable banner. Returns false when no overlay
  /// is available (caller should fall back to the system heads-up).
  bool show({
    required String title,
    required String body,
    required VoidCallback onTap,
  }) {
    final overlay =
        IncomingCallService.instance.navigatorKey.currentState?.overlay;
    if (overlay == null) return false;

    final data = _BannerData(title: title, body: body, onTap: onTap);
    // A banner is already visible: queue this one (replacing any older queued
    // entry) and let the current banner finish its minimum dwell first.
    if (_entry != null) {
      _queued = data;
      return true;
    }
    _present(overlay, data);
    return true;
  }

  void _present(OverlayState overlay, _BannerData data) {
    final entry = OverlayEntry(
      builder: (context) => _BannerWidget(
        data: data,
        onTap: () {
          data.onTap();
          _dismiss();
        },
        onPauseDismiss: () => _dismissTimer?.cancel(),
        onResumeDismiss: _startDismissTimer,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _startDismissTimer();
  }

  void _startDismissTimer() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(_dwell, _dismiss);
  }

  void _dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _entry?.remove();
    _entry = null;
    final next = _queued;
    if (next == null) return;
    _queued = null;
    final overlay =
        IncomingCallService.instance.navigatorKey.currentState?.overlay;
    if (overlay != null) _present(overlay, next);
  }
}

class _BannerData {
  _BannerData({required this.title, required this.body, required this.onTap});
  final String title;
  final String body;
  final VoidCallback onTap;
}

class _BannerWidget extends StatelessWidget {
  const _BannerWidget({
    required this.data,
    required this.onTap,
    required this.onPauseDismiss,
    required this.onResumeDismiss,
  });

  final _BannerData data;
  final VoidCallback onTap;
  final VoidCallback onPauseDismiss;
  final VoidCallback onResumeDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Listener(
            // Pause auto-dismiss while the user is touching the banner.
            onPointerDown: (_) => onPauseDismiss(),
            onPointerUp: (_) => onResumeDismiss(),
            onPointerCancel: (_) => onResumeDismiss(),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(14),
              color: theme.colorScheme.surface,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(Icons.chat_bubble,
                          color: Color(0xFF0284C7), size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              data.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (data.body.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                data.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
