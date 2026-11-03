import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';

/// Status of an SDUI user tap interaction.
enum TapDiagnosticStatus {
  dispatched,
  blocked,
  warning,
}

/// Detailed diagnostic report for a single tap event.
class TapDiagnosticReport {
  TapDiagnosticReport({
    required this.timestamp,
    required this.componentType,
    required this.controlId,
    required this.binding,
    required this.currentValue,
    required this.attemptedValue,
    required this.status,
    required this.reason,
    required this.fixSuggestion,
    required this.transport,
    this.control,
    this.node,
    this.props,
  });

  final DateTime timestamp;
  final String componentType;
  final String controlId;
  final String binding;
  final dynamic currentValue;
  final dynamic attemptedValue;
  final TapDiagnosticStatus status;
  final String reason;
  final String fixSuggestion;
  final String transport;
  final Map<String, dynamic>? control;
  final Map<String, dynamic>? node;
  final Map<String, dynamic>? props;

  String toFormattedString() {
    final timeStr =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}.${timestamp.millisecond.toString().padLeft(3, '0')}';
    final statusTag = status == TapDiagnosticStatus.dispatched
        ? 'DISPATCHED 🚀'
        : status == TapDiagnosticStatus.blocked
            ? 'BLOCKED 🛑'
            : 'WARNING ⚠️';

    final buffer = StringBuffer();
    buffer.writeln('════════════════════ [SDUI TAP DIAGNOSTIC] ════════════════════');
    buffer.writeln('Time        : $timeStr');
    buffer.writeln('Component   : $componentType (ID: ${controlId.isEmpty ? 'unspecified' : controlId})');
    buffer.writeln('Binding     : ${binding.isEmpty ? 'NONE' : binding}');
    buffer.writeln('Status      : $statusTag');
    buffer.writeln('Current Val : $currentValue ──► Attempted: $attemptedValue');
    buffer.writeln('Reason      : $reason');
    if (fixSuggestion.isNotEmpty) {
      buffer.writeln('Fix Suggest : $fixSuggestion');
    }
    buffer.writeln('Transport   : $transport');
    if (control != null) {
      buffer.writeln('Control Meta: writable=${control!['writable']}, readOnly=${control!['readOnly']}, access=${control!['access']}');
    }
    buffer.writeln('═══════════════════════════════════════════════════════════════');
    return buffer.toString();
  }
}

/// Centralized In-App Tap Diagnostic Inspector & Visual Overlay (Method 3).
///
/// Automatically intercepts user taps on SDUI controls (switches, buttons,
/// sliders, regulators), analyzes the 5-stage SDUI pipeline:
/// 1. Gesture Hit-Test
/// 2. Permission Gate (`isBindingWritable`)
/// 3. Binding Key Prefix (`device.parameters.*`)
/// 4. Command Dispatch / Action
/// 5. Network Transport Route
///
/// Renders an immediate, non-intrusive on-screen visual overlay banner
/// and detailed console log so the developer can identify why taps fail.
class TapDiagnosticInspector {
  TapDiagnosticInspector._();
  static final TapDiagnosticInspector instance = TapDiagnosticInspector._();

  /// Whether tap diagnostics are active. Enabled by default.
  bool isEnabled = true;

  /// In-memory ring buffer of recent tap reports.
  final List<TapDiagnosticReport> history = [];

  /// ValueNotifier for listening to the most recent tap event.
  final ValueNotifier<TapDiagnosticReport?> latestReportNotifier =
      ValueNotifier<TapDiagnosticReport?>(null);

  OverlayEntry? _overlayEntry;
  Timer? _dismissTimer;

  /// Cancels active overlay and timer.
  void clearActiveOverlay() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  /// Inspects a tap event, runs permission checks, triggers the action if allowed,
  /// displays the on-screen visual overlay, and emits high-visibility console logs.
  void inspectTap({
    required BuildContext context,
    required String componentType,
    required String controlId,
    required String binding,
    required dynamic currentValue,
    required dynamic attemptedValue,
    required AppState state,
    Map<String, dynamic>? node,
    Map<String, dynamic>? props,
    dynamic action,
    VoidCallback? onDispatched,
  }) {
    if (!isEnabled) {
      onDispatched?.call();
      return;
    }

    final effectiveBinding = binding.trim();
    final effectiveControlId = (controlId.isNotEmpty)
        ? controlId
        : (node?['id']?.toString() ?? props?['id']?.toString() ?? '');

    // 1. Resolve matching control from AppState.controls
    Map<String, dynamic>? matchedControl;
    for (final ctrl in state.controls) {
      if (effectiveBinding.isNotEmpty &&
          ctrl['binding']?.toString() == effectiveBinding) {
        matchedControl = ctrl;
        break;
      }
      if (effectiveControlId.isNotEmpty &&
          ctrl['id']?.toString() == effectiveControlId) {
        matchedControl = ctrl;
        break;
      }
    }
    matchedControl ??= node;

    // 2. Resolve Transport Status
    String transport = 'Offline';
    try {
      final connLabel = state.resolveBinding('state.connectivityLabel')?.toString();
      if (connLabel != null && connLabel.isNotEmpty) {
        transport = connLabel;
      }
    } catch (_) {}

    // 3. Permission & Pipeline Analysis
    TapDiagnosticStatus status = TapDiagnosticStatus.dispatched;
    String reason = 'Interaction permitted and state update scheduled.';
    String fixSuggestion = '';

    // Checkpoint A: Binding prefix check for parameter-driven controls
    final isParameterControl = componentType == 'switch' ||
        componentType == 'slider' ||
        componentType == 'sliderwithlabel' ||
        componentType == 'schemaslider' ||
        componentType == 'powerbutton' ||
        componentType == 'ToggleButton';

    if (isParameterControl) {
      if (effectiveBinding.isEmpty) {
        status = TapDiagnosticStatus.blocked;
        reason = 'Missing required "binding" property in schema control.';
        fixSuggestion =
            'Add "binding": "device.parameters.<parameter_key>" to the control schema.';
      } else if (!effectiveBinding.startsWith('device.parameters.') &&
          !effectiveBinding.startsWith('state.parameters.') &&
          !effectiveBinding.startsWith('parameters.')) {
        status = TapDiagnosticStatus.warning;
        reason =
            'Binding "$effectiveBinding" does not start with "device.parameters.".\nAppState.setBinding will ignore device parameter dispatch!';
        fixSuggestion =
            'Prefix the binding with "device.parameters." (e.g. "device.parameters.$effectiveBinding").';
      }
    }

    // Checkpoint B: Writable Permission Gate
    if (status != TapDiagnosticStatus.blocked && effectiveBinding.isNotEmpty) {
      final isWritable = state.isBindingWritable(effectiveBinding);
      if (!isWritable) {
        status = TapDiagnosticStatus.blocked;
        final blockDiagnostics = _diagnoseBlockReason(matchedControl);
        reason = blockDiagnostics.reason;
        fixSuggestion = blockDiagnostics.fix;
      }
    }

    // Checkpoint C: Button Action Validation
    if (componentType == 'button' ||
        componentType == 'elevatedbutton' ||
        componentType == 'IconButton') {
      final hasAction = action != null ||
          (props != null && (props['action'] != null || props['events'] != null));
      if (!hasAction && effectiveBinding.isEmpty) {
        status = TapDiagnosticStatus.warning;
        reason =
            'Button has no "action", "events", or "binding" defined in schema. Tap is a no-op.';
        fixSuggestion =
            'Add an "action" or "events" array to the button schema definition.';
      }
    }

    // 4. Create Diagnostic Report
    final report = TapDiagnosticReport(
      timestamp: DateTime.now(),
      componentType: componentType,
      controlId: effectiveControlId,
      binding: effectiveBinding,
      currentValue: currentValue,
      attemptedValue: attemptedValue,
      status: status,
      reason: reason,
      fixSuggestion: fixSuggestion,
      transport: transport,
      control: matchedControl,
      node: node,
      props: props,
    );

    // Record in history & update notifier
    history.insert(0, report);
    if (history.length > 50) history.removeLast();
    latestReportNotifier.value = report;

    // 5. High-visibility console log
    // ignore: avoid_print
    print(report.toFormattedString());

    // 6. Execute callback only if permitted
    if (status == TapDiagnosticStatus.dispatched) {
      try {
        onDispatched?.call();
      } catch (e, stack) {
        // ignore: avoid_print
        print('[SDUI TAP DISPATCH ERROR] Failed to execute callback: $e\n$stack');
      }
    }

    // 7. Render On-Screen Visual Overlay Banner
    _showVisualOverlay(context, report);
  }

  /// Extracts the exact schema attribute that caused `isBindingWritable` to return false.
  static ({String reason, String fix}) _diagnoseBlockReason(
    Map<String, dynamic>? control,
  ) {
    if (control == null) {
      return (
        reason:
            'Control marked read-only or not registered as writable in schema controls[].',
        fix: 'Ensure the control is present in controls[] with "writable": true.',
      );
    }

    if (control['writable'] == false) {
      return (
        reason: 'Control explicitly declares "writable": false.',
        fix:
            'In backend schema (api_schema.php), set "writable": true for this control.',
      );
    }

    if (control['readOnly'] == true) {
      return (
        reason: 'Control explicitly declares "readOnly": true.',
        fix:
            'In backend schema, set "readOnly": false (or remove readOnly property).',
      );
    }

    final access = control['access']?.toString().trim();
    if (access != null &&
        access.isNotEmpty &&
        !access.toLowerCase().replaceAll(' ', '').contains('write')) {
      return (
        reason:
            'Control declares access="$access" (permission denied: missing "write").',
        fix:
            'Change control "access" to "Read/Write" in backend schema/database.',
      );
    }

    final protocolMeta = control['protocolMeta'] as Map?;
    final protoAccess = protocolMeta?['access']?.toString().trim();
    if (protoAccess != null &&
        protoAccess.isNotEmpty &&
        !protoAccess.toLowerCase().replaceAll(' ', '').contains('write')) {
      return (
        reason:
            'protocolMeta declares access="$protoAccess" (missing "write").',
        fix:
            'Change protocolMeta.access to "Read/Write" in device protocol config.',
      );
    }

    final frame = control['deviceFrame'] as Map?;
    final commands = frame?['commands'] as List?;
    if (commands != null) {
      for (final raw in commands.whereType<Map>()) {
        final desc = raw['ui_description']?.toString().trim();
        if (desc != null &&
            desc.isNotEmpty &&
            !desc.toLowerCase().replaceAll(' ', '').contains('write')) {
          return (
            reason:
                'deviceFrame command ui_description="$desc" (missing "write").',
            fix:
                'Change deviceFrame.commands[].ui_description from "$desc" to "Read/Write".',
          );
        }
      }
    }

    if (control['interactive'] == false) {
      return (
        reason: 'Control explicitly declares "interactive": false.',
        fix: 'Set "interactive": true in control schema.',
      );
    }

    return (
      reason:
          'Control access resolution evaluated to Read-Only by AppState._isControlWritable().',
      fix:
          'Verify control.access or protocolMeta.access has "Read/Write" in the schema.',
    );
  }

  /// Displays the floating diagnostic toast banner at the top of the screen.
  void _showVisualOverlay(BuildContext context, TapDiagnosticReport report) {
    try {
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) {
        _showFallbackSnackBar(context, report);
        return;
      }

      _dismissTimer?.cancel();
      _overlayEntry?.remove();
      _overlayEntry = null;

      final entry = OverlayEntry(
        builder: (ctx) => _TapDiagnosticBanner(
          report: report,
          onDismiss: () {
            _dismissTimer?.cancel();
            _overlayEntry?.remove();
            _overlayEntry = null;
          },
          onTapDetails: () {
            _dismissTimer?.cancel();
            _overlayEntry?.remove();
            _overlayEntry = null;
            showTapDiagnosticModal(context, report);
          },
        ),
      );

      _overlayEntry = entry;
      overlay.insert(entry);

      _dismissTimer = Timer(const Duration(milliseconds: 3800), () {
        _overlayEntry?.remove();
        _overlayEntry = null;
      });
    } catch (_) {
      _showFallbackSnackBar(context, report);
    }
  }

  void _showFallbackSnackBar(BuildContext context, TapDiagnosticReport report) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    final isDispatched = report.status == TapDiagnosticStatus.dispatched;
    final isBlocked = report.status == TapDiagnosticStatus.blocked;
    final bgColor = isDispatched
        ? const Color(0xFF065F46)
        : isBlocked
            ? const Color(0xFF991B1B)
            : const Color(0xFF92400E);

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: bgColor,
        content: Text(
          '[${report.status.name.toUpperCase()}] ${report.componentType} (${report.controlId})\n${report.reason}',
          style: const TextStyle(fontSize: 12, color: Colors.white),
        ),
      ),
    );
  }

  /// Opens the detailed inspection modal bottom sheet.
  static void showTapDiagnosticModal(
    BuildContext context,
    TapDiagnosticReport report,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _TapDiagnosticDetailSheet(report: report),
    );
  }

  /// Opens a modal bottom sheet showing the complete history of recent taps.
  static void showTapHistoryModal(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _TapDiagnosticHistorySheet(),
    );
  }
}

/// Floating visual banner rendered on screen.
class _TapDiagnosticBanner extends StatelessWidget {
  const _TapDiagnosticBanner({
    required this.report,
    required this.onDismiss,
    required this.onTapDetails,
  });

  final TapDiagnosticReport report;
  final VoidCallback onDismiss;
  final VoidCallback onTapDetails;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top + 8;
    final isDispatched = report.status == TapDiagnosticStatus.dispatched;
    final isBlocked = report.status == TapDiagnosticStatus.blocked;

    final gradientColors = isDispatched
        ? const [Color(0xFF064E3B), Color(0xFF022C22)]
        : isBlocked
            ? const [Color(0xFF881337), Color(0xFF4C0519)]
            : const [Color(0xFF78350F), Color(0xFF451A03)];

    final borderColor = isDispatched
        ? const Color(0xFF10B981)
        : isBlocked
            ? const Color(0xFFF43F5E)
            : const Color(0xFFF59E0B);

    final tagBg = isDispatched
        ? const Color(0xFF059669)
        : isBlocked
            ? const Color(0xFFE11D48)
            : const Color(0xFFD97706);

    final statusLabel = isDispatched
        ? 'TAP DISPATCHED'
        : isBlocked
            ? 'TAP BLOCKED'
            : 'TAP WARNING';

    final statusIcon = isDispatched
        ? Icons.check_circle_outline_rounded
        : isBlocked
            ? Icons.block_flipped
            : Icons.warning_amber_rounded;

    return Positioned(
      top: topPadding,
      left: 14,
      right: 14,
      child: Material(
        type: MaterialType.transparency,
        child: GestureDetector(
          onTap: onTapDetails,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: gradientColors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: tagBg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, color: Colors.white, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            statusLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${report.componentType} (${report.controlId.isEmpty ? "no-id" : report.controlId})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkWell(
                      onTap: onDismiss,
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          color: Colors.white70,
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (report.binding.isNotEmpty)
                  Text(
                    'Binding: ${report.binding}',
                    style: TextStyle(
                      color: Colors.cyanAccent.shade100,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 2),
                Text(
                  isDispatched
                      ? 'New Value: ${report.attemptedValue} | Transport: ${report.transport}'
                      : report.reason,
                  style: TextStyle(
                    color: isBlocked
                        ? const Color(0xFFFECDD3)
                        : Colors.white.withValues(alpha: 0.9),
                    fontSize: 11,
                    fontWeight: isBlocked ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      'Tap banner to inspect full JSON details ↗',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Detailed bottom sheet displaying full diagnostics and copyable JSON report.
class _TapDiagnosticDetailSheet extends StatelessWidget {
  const _TapDiagnosticDetailSheet({required this.report});

  final TapDiagnosticReport report;

  @override
  Widget build(BuildContext context) {
    final isDispatched = report.status == TapDiagnosticStatus.dispatched;
    final isBlocked = report.status == TapDiagnosticStatus.blocked;
    final statusColor = isDispatched
        ? const Color(0xFF10B981)
        : isBlocked
            ? const Color(0xFFF43F5E)
            : const Color(0xFFF59E0B);

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 20,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                isDispatched
                    ? Icons.check_circle_rounded
                    : isBlocked
                        ? Icons.error_rounded
                        : Icons.warning_rounded,
                color: statusColor,
                size: 24,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Tap Diagnostic Inspector',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
                tooltip: 'Close',
              ),
            ],
          ),
          const Divider(color: Colors.white12, height: 20),
          Expanded(
            child: ListView(
              children: [
                _buildInfoTile('Status', report.status.name.toUpperCase(), statusColor),
                _buildInfoTile('Component', report.componentType, Colors.white),
                _buildInfoTile('Control ID', report.controlId.isEmpty ? '(none)' : report.controlId, Colors.white),
                _buildInfoTile('Binding', report.binding.isEmpty ? '(none)' : report.binding, Colors.cyanAccent),
                _buildInfoTile('Current Value', '${report.currentValue}', Colors.white70),
                _buildInfoTile('Attempted Value', '${report.attemptedValue}', Colors.white),
                _buildInfoTile('Transport Route', report.transport, Colors.lightGreenAccent),
                const SizedBox(height: 12),
                const Text(
                  'Analysis & Diagnostic Reason:',
                  style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(
                    report.reason,
                    style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4),
                  ),
                ),
                if (report.fixSuggestion.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Recommended Fix:',
                    style: TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0C4A6E).withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF0284C7)),
                    ),
                    child: Text(
                      report.fixSuggestion,
                      style: const TextStyle(color: Color(0xFFBAE6FD), fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Raw Control Metadata (JSON):',
                  style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0F1D),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: SelectableText(
                    report.control != null
                        ? const JsonEncoder.withIndent('  ').convert(report.control)
                        : '(No matching control node found)',
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: report.toFormattedString()));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Diagnostic report copied to clipboard!'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy Full Report'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                ),
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTile(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: label == 'Binding' ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal bottom sheet showing history of recent SDUI taps.
class _TapDiagnosticHistorySheet extends StatefulWidget {
  const _TapDiagnosticHistorySheet();

  @override
  State<_TapDiagnosticHistorySheet> createState() =>
      _TapDiagnosticHistorySheetState();
}

class _TapDiagnosticHistorySheetState
    extends State<_TapDiagnosticHistorySheet> {
  @override
  Widget build(BuildContext context) {
    final history = TapDiagnosticInspector.instance.history;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.history_rounded, color: Colors.cyanAccent, size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'SDUI Tap Diagnostic Log',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (history.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setState(() {
                      TapDiagnosticInspector.instance.history.clear();
                    });
                  },
                  child: const Text('Clear', style: TextStyle(color: Colors.white60)),
                ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
              ),
            ],
          ),
          const Divider(color: Colors.white12),
          Expanded(
            child: history.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No taps recorded yet.\nTap any switch, button, or slider on the screen to view its diagnostic trace.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: history.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (context, index) {
                      final item = history[index];
                      final isDispatched =
                          item.status == TapDiagnosticStatus.dispatched;
                      final isBlocked =
                          item.status == TapDiagnosticStatus.blocked;
                      final statusColor = isDispatched
                          ? const Color(0xFF10B981)
                          : isBlocked
                              ? const Color(0xFFF43F5E)
                              : const Color(0xFFF59E0B);

                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        leading: Icon(
                          isDispatched
                              ? Icons.check_circle_rounded
                              : isBlocked
                                  ? Icons.block_flipped
                                  : Icons.warning_rounded,
                          color: statusColor,
                          size: 20,
                        ),
                        title: Text(
                          '${item.componentType} (${item.controlId.isEmpty ? "no-id" : item.controlId})',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          isDispatched
                              ? 'Dispatched ──► val: ${item.attemptedValue} (${item.transport})'
                              : item.reason,
                          style: TextStyle(
                            color: isBlocked
                                ? const Color(0xFFFECDD3)
                                : Colors.white60,
                            fontSize: 11,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white38,
                          size: 18,
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          TapDiagnosticInspector.showTapDiagnosticModal(
                            context,
                            item,
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Floating diagnostic action button (pill) for quick access on any screen.
class TapDiagnosticFab extends StatelessWidget {
  const TapDiagnosticFab({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      right: 16,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => TapDiagnosticInspector.showTapHistoryModal(context),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF38BDF8), width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  'Tap Inspector',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
