import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/efactor_cloud_diagnostic_sheet.dart';
import '../services/push_notification_diagnostic_sheet.dart';
import '../state/app_state.dart';

/// Signature for custom SDUI action handlers.
typedef SduiActionHandler =
    Future<void> Function({
      required BuildContext? context,
      required AppState state,
      required Map<String, dynamic> action,
      Map<String, dynamic>? parameters,
    });

/// Registry for all server-driven and client actions.
class ActionRegistry {
  ActionRegistry._() {
    _registerBuiltInActions();
  }

  static final ActionRegistry instance = ActionRegistry._();

  final Map<String, SduiActionHandler> _handlers = {};

  static String _normalize(String type) =>
      type.trim().toLowerCase().replaceAll('-', '').replaceAll('_', '');

  /// Register a new action handler dynamically without modifying renderer or AppState.
  void register(String actionType, SduiActionHandler handler) {
    if (actionType.trim().isEmpty) return;
    _handlers[_normalize(actionType)] = handler;
  }

  /// Check if an action type is registered.
  bool hasHandler(String actionType) =>
      _handlers.containsKey(_normalize(actionType));

  /// Register standard built-in actions.
  void _registerBuiltInActions() {
    // Native scanner action
    register('openScanner', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final handler = state.onOpenScanner;
      if (context != null && handler != null) {
        await handler(context, state, <String, dynamic>{
          ...action,
          'type': 'native',
          'value': 'openScanner',
        });
      } else {
        debugPrint(
          '[SDUI] openScanner requires context and onOpenScanner handler.',
        );
      }
    });

    // Native Wi-Fi provisioning action
    register('openWifiConfig', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final handler = state.onOpenWifiConfig;
      if (context != null && handler != null) {
        await handler(context, state, action);
      } else {
        debugPrint(
          '[SDUI] openWifiConfig requires context and onOpenWifiConfig handler.',
        );
      }
    });
    register('ui.wifi', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      await dispatch(
        context: context,
        state: state,
        action: <String, dynamic>{
          ...action,
          'type': 'openWifiConfig',
          'value': 'openWifiConfig',
        },
        parameters: parameters,
      );
    });

    // Cloud WebSocket diagnostic sheet action
    register('openCloudDiagnostic', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      if (context != null) {
        final identity = state.resolveDeviceIdentity();
        final apiKey = state.accessToken.isNotEmpty ? state.accessToken : null;
        await EfactorCloudDiagnosticSheet.show(
          context,
          initialApiKey: apiKey,
          initialNodeId: identity.nodeId,
        );
      }
    });
    register('openCloudDiagnostics', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      await dispatch(
        context: context,
        state: state,
        action: <String, dynamic>{
          ...action,
          'type': 'openCloudDiagnostic',
        },
        parameters: parameters,
      );
    });

    // Push notification & incoming call diagnostic sheet
    register('openPushDiagnostic', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      if (context != null) {
        final uid = state.resolveDeviceIdentity().userId.isNotEmpty
            ? state.resolveDeviceIdentity().userId
            : null;
        final token = state.accessToken.isNotEmpty ? state.accessToken : null;
        await PushNotificationDiagnosticSheet.show(
          context,
          userId: uid,
          accessToken: token,
        );
      }
    });
    register('openPushDiagnostics', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      await dispatch(
        context: context,
        state: state,
        action: <String, dynamic>{
          ...action,
          'type': 'openPushDiagnostic',
        },
        parameters: parameters,
      );
    });
    register('openNotificationDiagnostic', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      await dispatch(
        context: context,
        state: state,
        action: <String, dynamic>{
          ...action,
          'type': 'openPushDiagnostic',
        },
        parameters: parameters,
      );
    });

    // Native device info action
    register('openDeviceInfo', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final handler = state.onOpenInfo;
      if (context != null && handler != null) {
        await handler(context, state, action);
      } else {
        debugPrint(
          '[SDUI] openDeviceInfo requires context and onOpenInfo handler.',
        );
      }
    });
    register('openInfo', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      await dispatch(
        context: context,
        state: state,
        action: action,
        parameters: parameters,
        actionTypeOverride: 'openDeviceInfo',
      );
    });
    register('ui.info', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      await dispatch(
        context: context,
        state: state,
        action: action,
        parameters: parameters,
        actionTypeOverride: 'openDeviceInfo',
      );
    });

    // State update action
    register('update', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final binding = action['binding'] as String?;
      final value = action['value'];
      final expr = action['value'] as String?;

      if (binding != null &&
          value != null &&
          parameters?['actionValue'] != null) {
        state.setBinding(binding, parameters!['actionValue']);
      } else if (expr != null) {
        state.runExpression(expr);
      }
    });

    // Send binding value action — updates local state AND sends to device.
    register('send', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final binding = action['binding'] as String?;
      final actionValue = parameters?['actionValue'];
      if (binding != null) {
        if (actionValue != null) {
          // Update local state immediately (optimistic), then send to device.
          state.setBinding(binding, actionValue, dispatch: false);
        }
        // Always route through sendBinding for the transport layer.
        await state.sendBinding(binding);
      } else if (binding == null) {
        debugPrint(
          '[SDUI] send action is missing "binding" field. '
          'Action: $action',
        );
      }
    });

    // API action
    register('api', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final apiUrl = action['value']?.toString() ?? '';
      if (apiUrl.contains('device-ui-info')) {
        await dispatch(
          context: context,
          state: state,
          action: action,
          parameters: parameters,
          actionTypeOverride: 'openDeviceInfo',
        );
      } else {
        await state.executeApi(action);
      }
    });

    // Data operation action
    register('dataOperation', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      await state.executeDataOperation(action);
    });

    // Set universal parameter action
    register('setParameter', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final target = action['target']?.toString();
      final binding = state.bindingForUniversalParameter(target);
      if (binding != null) await state.sendBinding(binding);
    });

    // Navigation actions
    register('navigation', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final target = action['value']?.toString() ?? action['route']?.toString();
      final url = AppState.rewritePublicApiUrl(target);
      if (url != null) {
        try {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('[SDUI] Error launching navigation URL $url: $e');
        }
      }
    });
    register('navigate', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      await dispatch(
        context: context,
        state: state,
        action: action,
        parameters: parameters,
        actionTypeOverride: 'navigation',
      );
    });
    register('navigateBack', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      if (context != null && context.mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    // Pager navigation actions
    register('pagerPrevious', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      state.activePageIndex -= 1;
    });
    register('pagerNext', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      state.activePageIndex += 1;
    });
    register('pagerSelect', ({
      context,
      required state,
      required action,
      parameters,
    }) async {
      final index = parameters?['pageIndex'];
      if (index is num) state.activePageIndex = index.toInt();
    });
  }

  /// Dispatch an action by type or definition map.
  Future<void> dispatch({
    required BuildContext? context,
    required AppState state,
    required Map<String, dynamic> action,
    Map<String, dynamic>? parameters,
    String? actionTypeOverride,
  }) async {
    final type = actionTypeOverride ?? action['type']?.toString();
    final value = action['value']?.toString();
    final actionId = action['id']?.toString() ?? value;

    // Check alias checks for Scanner, Wi-Fi, and Device Info
    final isScanner =
        type == 'openScanner' ||
        value == 'openScanner' ||
        actionId == 'openScanner' ||
        (type == 'native' && value == 'openScanner');
    if (isScanner) {
      final handler = _handlers[_normalize('openScanner')];
      if (handler != null) {
        await handler(
          context: context,
          state: state,
          action: action,
          parameters: parameters,
        );
      }
      return;
    }

    final isWifi =
        type == 'openWifiConfig' ||
        value == 'openWifiConfig' ||
        type == 'ui.wifi' ||
        value == 'ui.wifi' ||
        actionId == 'openWifiConfig';
    if (isWifi) {
      final handler = _handlers[_normalize('openWifiConfig')];
      if (handler != null) {
        await handler(
          context: context,
          state: state,
          action: action,
          parameters: parameters,
        );
      }
      return;
    }

    final isInfo =
        type == 'openDeviceInfo' ||
        type == 'openInfo' ||
        type == 'ui.info' ||
        value == 'openDeviceInfo' ||
        value == 'openInfo' ||
        value == 'ui.info';
    if (isInfo) {
      final handler = _handlers[_normalize('openDeviceInfo')];
      if (handler != null) {
        await handler(
          context: context,
          state: state,
          action: action,
          parameters: parameters,
        );
      }
      return;
    }

    final targetType = type ?? '';
    final normalized = _normalize(targetType);

    if (_handlers.containsKey(normalized)) {
      await _handlers[normalized]!(
        context: context,
        state: state,
        action: action,
        parameters: parameters,
      );
      return;
    }

    // Try looking up actionId in schema if provided
    if (value != null && value.isNotEmpty && value != type) {
      final schemaAction = state.lookupActionMap(value);
      if (schemaAction != null) {
        await dispatch(
          context: context,
          state: state,
          action: schemaAction,
          parameters: parameters,
        );
        return;
      }
    }

    debugPrint('[SDUI] Action not registered: $type ($value)');
  }
}
