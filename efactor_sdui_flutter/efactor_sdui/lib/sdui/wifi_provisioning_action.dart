import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../wifi_sdui/dynamic_wifi_sdui_page.dart';

/// Opens the Wi-Fi SDUI runtime.
///
/// The screen definition must be present at `$.wifiProvisioning` in the current
/// server device schema. There is intentionally no asset or hardcoded-screen
/// fallback.
Future<void> handleOpenWifiConfig(
  BuildContext context,
  AppState state,
  Map<String, dynamic> action,
) async {
  final contract = state.schema['wifiProvisioning'];

  if (contract is! Map) {
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Wi-Fi schema missing'),
        content: const SelectableText(
          'Required server schema path is missing:\n'
          r'$.wifiProvisioning'
          '\n\nNo hardcoded Wi-Fi screen fallback will be used.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    return;
  }

  final result = await Navigator.of(context).push<Map<String, dynamic>>(
    MaterialPageRoute<Map<String, dynamic>>(
      builder: (_) => DynamicWifiSduiPage(state: state, action: action),
    ),
  );

  if (result == null) return;

  final connected =
      result['connected'] == true ||
      result['onlineConfirmed'] == true ||
      result['online_confirmed'] == true;

  if (!connected) {
    debugPrint(
      '[SDUI][WiFi] Provisioning returned without online confirmation.',
    );
    return;
  }

  final synchronized = await state.handleWifiProvisioningResult(result);
  final deviceStateRefreshed = await state
      .refreshDeviceStateAfterProvisioning();

  if (!context.mounted) return;

  final fullySynchronized = synchronized && deviceStateRefreshed;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        fullySynchronized
            ? 'Wi-Fi provisioning completed and post-provision state refreshed.'
            : 'Wi-Fi provisioning completed, but one or more post-provision refresh steps failed.',
      ),
    ),
  );
}
