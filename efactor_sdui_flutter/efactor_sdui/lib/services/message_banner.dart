import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme_controller.dart';
import 'incoming_call_service.dart';

/// App-owned foreground message banner.
///
/// Circle Connect's native host (not the GRID Chat web page, which has
/// `messageNotificationsManaged = true`) must keep a foreground message
/// heads-up visible long enough to act on. A system heads-up is OEM-controlled
/// and on some devices self-dismisses in under a second, so while the app is
/// visible we show this overlay instead and skip the duplicate system
/// heads-up.
///
/// Mirrors the Android heads-up card (theme-adaptive) with inline Reply,
/// Mark as read and Mute. Guaranteed minimum dwell, pause-while-touched,
/// hard-stop auto-dismiss while the inline reply is open, tap-to-open, and a
/// single-slot queue so a second message never shortens the current one.
///
/// Actions are wired by the caller to the existing Circle Connect services
/// (device-key reply / mark-read / mute) — this widget owns no networking.
class MessageBanner {
  MessageBanner._();
  static final MessageBanner instance = MessageBanner._();

  /// Recommended dwell (spec: >=1500ms, 2500ms recommended).
  static const Duration _dwell = Duration(milliseconds: 2500);

  OverlayEntry? _entry;
  Timer? _dismissTimer;
  _BannerData? _queued;

  /// Shows [title]/[body] as a tappable banner. [onTap] opens the full chat;
  /// [onReply]/[onMarkRead]/[onMute], when provided, render the action row and
  /// run in the background without navigating the WebView. Returns false when
  /// no overlay is available (caller should fall back to the system heads-up).
  bool show({
    required String title,
    required String body,
    required VoidCallback onTap,
    Future<void> Function(String text)? onReply,
    Future<void> Function()? onMarkRead,
    Future<void> Function()? onMute,
    bool? isDark,
  }) {
    final overlay =
        IncomingCallService.instance.navigatorKey.currentState?.overlay;
    if (overlay == null) return false;

    final data = _BannerData(
      title: title,
      body: body,
      onTap: onTap,
      onReply: onReply,
      onMarkRead: onMarkRead,
      onMute: onMute,
      isDark: isDark ?? ThemeController.instance.isDark(),
    );
    // A banner is already visible: queue this one (replacing any older queued
    // entry) and let the current banner finish first.
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
        onDismiss: _dismiss,
        // Reply open / finger down: stop auto-dismiss so it can't vanish
        // mid-interaction. Reply close / finger up: restart the dwell.
        onHoldStart: _cancelDismissTimer,
        onHoldEnd: _startDismissTimer,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _startDismissTimer();
  }

  void _cancelDismissTimer() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
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
  _BannerData({
    required this.title,
    required this.body,
    required this.onTap,
    required this.isDark,
    this.onReply,
    this.onMarkRead,
    this.onMute,
  });

  final String title;
  final String body;
  final bool isDark;
  final VoidCallback onTap;
  final Future<void> Function(String text)? onReply;
  final Future<void> Function()? onMarkRead;
  final Future<void> Function()? onMute;

  bool get hasActions =>
      onReply != null || onMarkRead != null || onMute != null;
}

class _BannerWidget extends StatefulWidget {
  const _BannerWidget({
    required this.data,
    required this.onDismiss,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final _BannerData data;
  final VoidCallback onDismiss;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  State<_BannerWidget> createState() => _BannerWidgetState();
}

class _BannerWidgetState extends State<_BannerWidget> {
  bool _isReplying = false;
  bool _isSending = false;
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();

  @override
  void dispose() {
    _replyController.dispose();
    _replyFocusNode.dispose();
    super.dispose();
  }

  void _openReply() {
    widget.onHoldStart(); // hard-stop auto-dismiss while typing
    setState(() => _isReplying = true);
    _replyFocusNode.requestFocus();
  }

  void _closeReply() {
    setState(() => _isReplying = false);
    widget.onHoldEnd(); // resume the dwell timer
  }

  Future<void> _handleSend() async {
    final text = _replyController.text.trim();
    final onReply = widget.data.onReply;
    if (text.isEmpty || _isSending || onReply == null) return;
    setState(() => _isSending = true);
    try {
      await onReply(text);
    } catch (e) {
      debugPrint('[MessageBanner] reply failed: $e');
    } finally {
      widget.onDismiss();
    }
  }

  Future<void> _runAndDismiss(Future<void> Function()? action) async {
    if (action != null) {
      try {
        await action();
      } catch (e) {
        debugPrint('[MessageBanner] action failed: $e');
      }
    }
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final cardBg = d.isDark ? const Color(0xFF1E2630) : const Color(0xFFFFFFFF);
    final borderColor =
        d.isDark ? const Color(0x26FFFFFF) : const Color(0x1F000000);
    final titleColor = d.isDark ? Colors.white : const Color(0xFF0F172A);
    final bodyColor =
        d.isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569);
    final actionColor =
        d.isDark ? const Color(0xFF4B9BFF) : const Color(0xFF0284C7);
    final inputBg =
        d.isDark ? const Color(0xFF10161D) : const Color(0xFFF1F5F9);
    final inputBorder = d.isDark ? Colors.white24 : const Color(0xFFCBD5E1);
    final inputTextColor = d.isDark ? Colors.white : const Color(0xFF0F172A);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Listener(
            // Pause auto-dismiss while touching; resume on release unless the
            // inline reply is open (then it stays open until send/close).
            onPointerDown: (_) => widget.onHoldStart(),
            onPointerUp: (_) {
              if (!_isReplying) widget.onHoldEnd();
            },
            onPointerCancel: (_) {
              if (!_isReplying) widget.onHoldEnd();
            },
            // Transparent Material so the inline reply TextField has the
            // Material ancestor it requires; the Container paints the card.
            child: Material(
              type: MaterialType.transparency,
              child: Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: borderColor),
                boxShadow: [
                  BoxShadow(
                    color: d.isDark
                        ? Colors.black45
                        : const Color(0x26000000),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      d.onTap();
                      widget.onDismiss();
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (d.body.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            d.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: bodyColor,
                              fontSize: 13,
                              height: 1.25,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (d.hasActions) ...[
                    const SizedBox(height: 12),
                    if (!_isReplying)
                      Row(
                        children: [
                          if (d.onReply != null)
                            _action('Reply', actionColor, _openReply),
                          if (d.onMarkRead != null)
                            _action('Mark as read', actionColor,
                                () => _runAndDismiss(d.onMarkRead)),
                          if (d.onMute != null)
                            _action('Mute', actionColor,
                                () => _runAndDismiss(d.onMute)),
                        ],
                      )
                    else
                      _replyRow(
                        actionColor: actionColor,
                        inputBg: inputBg,
                        inputBorder: inputBorder,
                        inputTextColor: inputTextColor,
                      ),
                  ],
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _action(String label, Color color, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _replyRow({
    required Color actionColor,
    required Color inputBg,
    required Color inputBorder,
    required Color inputTextColor,
  }) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: inputBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: inputBorder),
            ),
            child: TextField(
              controller: _replyController,
              focusNode: _replyFocusNode,
              style: TextStyle(color: inputTextColor, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Type reply...',
                hintStyle: TextStyle(
                  color: widget.data.isDark ? Colors.white38 : Colors.black38,
                  fontSize: 12.5,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
              onSubmitted: (_) => _handleSend(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (_isSending)
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: actionColor),
          )
        else
          IconButton(
            icon: Icon(Icons.send_rounded, color: actionColor, size: 20),
            onPressed: _handleSend,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        IconButton(
          icon: Icon(
            Icons.close_rounded,
            color: widget.data.isDark ? Colors.white54 : Colors.black54,
            size: 18,
          ),
          onPressed: _closeReply,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
      ],
    );
  }
}
