import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'scanner_page.dart';

/// Handles schema native action `openScanner`.
Future<void> handleOpenScanner(
  BuildContext context,
  AppState state,
  Map<String, dynamic> action,
) async {
  final payload = Map<String, dynamic>.from(
    action['payload'] as Map? ?? const {},
  );

  final resultBinding =
      payload['resultBinding']?.toString() ?? 'state.scanResult.value';

  // Default: QR only. Schema can still override formats if needed.
  final formats = _asStringList(payload['formats']) ?? const ['qr'];
  final camera = payload['camera']?.toString() ?? 'back';
  final qrOnly =
      payload['qrOnly'] != false &&
      formats.every((format) {
        final key = format.toLowerCase().trim();
        return key == 'qr' || key == 'qrcode' || key == 'qr_code';
      });

  final scan = await Navigator.of(context).push<Map<String, dynamic>>(
    MaterialPageRoute(
      builder: (_) => ScannerPage(
        formats: formats,
        camera: camera,
        qrOnly: qrOnly || formats.isEmpty,
      ),
    ),
  );

  if (!context.mounted) return;

  if (scan == null) {
    _showSnack(context, 'Scan cancelled.', isError: false, icon: Icons.close);
    await _invokeOptionalCallback(
      state,
      payload['onScanCancel'] ??
          payload['onCancelAction'] ??
          action['onScanCancel'] ??
          action['onCancelAction'],
    );
    return;
  }

  final value = scan['value']?.toString().trim() ?? '';
  final format = scan['format']?.toString().trim() ?? 'unknown';

  if (value.isEmpty) {
    _showSnack(
      context,
      'Empty QR code scanned. Please show a valid QR code.',
      isError: true,
      icon: Icons.warning_amber_rounded,
    );
    return;
  }

  final normalizedFormat = format.toLowerCase();
  final isQrFormat =
      normalizedFormat == 'qr' ||
      normalizedFormat == 'qrcode' ||
      normalizedFormat == 'qr_code' ||
      normalizedFormat == 'qr code';

  if (qrOnly && !isQrFormat) {
    _showSnack(
      context,
      'Only QR codes are accepted. Please scan a QR code.',
      isError: true,
      icon: Icons.qr_code_2,
    );
    return;
  }

  final scannedAt = DateTime.now().toUtc().toIso8601String();

  state.setBinding(resultBinding, value, dispatch: false);
  state.setBinding('state.scanResult.format', format, dispatch: false);
  state.setBinding('state.scanResult.scannedAt', scannedAt, dispatch: false);
  state.setBinding('state.scanResult.value', value, dispatch: false);

  if (payload['applyAsNodeId'] == true) {
    state.setBinding('state.scanResult.nodeId', value, dispatch: false);
  }

  // ── Build scan payload — 4 fields, all from schema/_clientConnection. ──────
  final buildResult = _buildScanApiPayload(
    state: state,
    actionPayload: payload,
    qrValue: value,
  );

  if (buildResult.error != null) {
    _showSnack(
      context,
      buildResult.error!,
      isError: true,
      icon: Icons.error_outline,
    );
    return;
  }

  _showSnack(
    context,
    'QR scanned. Sending to server…',
    isError: false,
    icon: Icons.cloud_upload_outlined,
  );

  final posted = await state.postScanResult(
    value: value,
    format: format,
    scannedAt: scannedAt,
    feature: payload['feature']?.toString() ?? 'qrBarcodeScan',
    extra: buildResult.payload,
  );

  if (!context.mounted) return;

  if (posted) {
    // Read the actual scan URL from schema so the dialog is always accurate.
    final scanUrl =
        state.schema['_clientConnection']?['scanUrl']?.toString() ??
        state.schema['apiContracts']?['scan']?['url']?.toString() ??
        state.schema['meta']?['links']?['scan']?.toString();
    final endpoint = scanUrl?.trim() ?? '';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.check_circle,
          color: Theme.of(dialogContext).colorScheme.primary,
          size: 40,
        ),
        title: const Text('Scan successful'),
        content: Text(
          endpoint.isEmpty
              ? 'QR information was sent successfully.'
              : 'QR information was sent successfully.\n\nPOST API:\n$endpoint',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  } else {
    _showSnack(
      context,
      'QR scanned, but failed to send to server.',
      isError: true,
      icon: Icons.cloud_off,
    );
  }

  await _invokeOptionalCallback(
    state,
    payload['onScanSuccess'] ??
        payload['onSuccessAction'] ??
        action['onScanSuccess'] ??
        action['onSuccessAction'],
  );
}

// ─────────────────────────────────────────────── payload builder ─────────────

/// Result of [_buildScanApiPayload].
class _PayloadResult {
  const _PayloadResult.success(this.payload) : error = null;
  const _PayloadResult.failure(this.error) : payload = const {};

  final Map<String, dynamic> payload;
  final String? error;
}

/// Builds the 4-field POST body sent to the scan API:
///
/// ```json
/// {
///   "model_no":  "<MODEL_ID>",
///   "node_id":   "<NODE_ID>",
///   "device_id": "<NODE_ID>",
///   "qr_value":  "<scanned value>"
/// }
/// ```
///
/// All values come from [AppState]'s `_clientConnection` (populated by
/// [SchemaRepository] from the MODEL_ID / NODE_ID entered at the connection
/// screen). No hardcoded fallbacks.
_PayloadResult _buildScanApiPayload({
  required AppState state,
  required Map<String, dynamic> actionPayload,
  required String qrValue,
}) {
  final connection = Map<String, dynamic>.from(
    state.schema['_clientConnection'] as Map? ?? const {},
  );

  // ── model_no  ─────────────────────────────────────────────────────────────
  // Source priority: action payload → _clientConnection.modelId →
  //                  meta.app.modelNo → meta.app.name
  final modelNo = _firstNonEmpty(<dynamic>[
    actionPayload['model_no'],
    actionPayload['modelNo'],
    connection['modelId'],
    state.schema['meta']?['app']?['modelNo'],
    state.schema['meta']?['app']?['name'],
  ]);
  if (modelNo.isEmpty) {
    return const _PayloadResult.failure(
      'Scan failed: model_no could not be resolved.\n'
      'Ensure a valid MODEL_ID was entered at the connection screen.',
    );
  }

  // ── node_id  ──────────────────────────────────────────────────────────────
  // Source: the NODE_ID entered at the connection screen → _clientConnection.nodeId
  final nodeId = _firstNonEmpty(<dynamic>[
    actionPayload['node_id'],
    actionPayload['nodeId'],
    connection['nodeId'],
  ]);
  if (nodeId.isEmpty) {
    return const _PayloadResult.failure(
      'Scan failed: node_id could not be resolved.\n'
      'Ensure a valid NODE_ID was entered at the connection screen.',
    );
  }

  // ── device_id  ────────────────────────────────────────────────────────────
  // Source priority: action payload → _clientConnection.deviceId → nodeId
  // (deviceId is set to nodeId in SchemaRepository._applyConnectionContext,
  //  so both resolve to the same NODE_ID unless the action overrides it)
  final deviceId = _firstNonEmpty(<dynamic>[
    actionPayload['device_id'],
    actionPayload['deviceId'],
    connection['deviceId'],
    connection['nodeId'],
  ]);
  if (deviceId.isEmpty) {
    return const _PayloadResult.failure(
      'Scan failed: device_id could not be resolved.\n'
      'Ensure a valid NODE_ID was entered at the connection screen.',
    );
  }

  // ── qr_value  ─────────────────────────────────────────────────────────────
  if (qrValue.isEmpty) {
    return const _PayloadResult.failure('Scan failed: QR value is empty.');
  }

  return _PayloadResult.success(<String, dynamic>{
    'model_no': modelNo,
    'node_id': nodeId,
    'device_id': deviceId,
    'qr_value': qrValue,
  });
}

// ─────────────────────────────────────────────── helpers ─────────────────────

String _firstNonEmpty(List<dynamic> values) {
  for (final value in values) {
    final normalized = value?.toString().trim();
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }
  }
  return '';
}

/// Shows a SnackBar using theme colors — no hardcoded hex values.
void _showSnack(
  BuildContext context,
  String message, {
  required bool isError,
  required IconData icon,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;

  final colorScheme = Theme.of(context).colorScheme;
  final background = isError ? colorScheme.error : colorScheme.primary;
  final foreground = isError ? colorScheme.onError : colorScheme.onPrimary;

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: background,
        behavior: SnackBarBehavior.floating,
        content: Row(
          children: [
            Icon(icon, color: foreground),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: TextStyle(color: foreground)),
            ),
          ],
        ),
      ),
    );
}

Future<void> _invokeOptionalCallback(AppState state, dynamic callback) async {
  if (callback == null) return;

  if (callback is String && callback.isNotEmpty) {
    await state.dispatchActionId(callback);
    return;
  }

  if (callback is Map) {
    await state.dispatchAction(Map<String, dynamic>.from(callback));
  }
}

List<String>? _asStringList(dynamic value) {
  if (value is! List) return null;
  return value.map((item) => item.toString()).toList();
}
