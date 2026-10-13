import 'dart:io';

import 'package:efactor_provisioning/efactor_provisioning.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_capabilities.dart';
import 'device_command_transport.dart';
import 'efactor_cloud_service.dart';

/// Device transport backed by the eFactor native Data SDK.
///
/// The native SDK performs local-LAN routing when the node is discovered and
/// cloud fallback otherwise. Flutter supplies only runtime identity plus the
/// final frame compiled from the schema.
class EfactorDeviceApiTransport implements DeviceCommandTransport {
  EfactorDeviceApiTransport({DeviceCapabilities? capabilities})
      : _capabilities = capabilities ?? DeviceCapabilities();

  final DeviceCapabilities _capabilities;

  static const int _locationCacheSeconds = int.fromEnvironment(
    'DEVICE_COMMAND_LOCATION_CACHE_SECONDS',
    defaultValue: 600,
  );

  _RuntimeLocation? _lastLocation;
  Future<_RuntimeLocation?>? _locationRequest;

  Future<_RuntimeLocation?> _resolveRuntimeLocation() async {
    final cached = _lastLocation;
    if (cached != null &&
        DateTime.now().difference(cached.capturedAt) <=
            const Duration(seconds: _locationCacheSeconds)) {
      return cached;
    }

    final inFlight = _locationRequest;
    if (inFlight != null) return inFlight;

    final future = _readRuntimeLocation();
    _locationRequest = future;
    try {
      return await future;
    } finally {
      _locationRequest = null;
    }
  }

  Future<_RuntimeLocation?> _readRuntimeLocation() async {
    final position = await _capabilities.getCurrentPosition();
    if (position == null) return null;

    final resolved = _RuntimeLocation(
      latitude: position.latitude.toString(),
      longitude: position.longitude.toString(),
      capturedAt: DateTime.now(),
    );
    _lastLocation = resolved;
    return resolved;
  }

  @override
  Future<DeviceCommandResult> send(DeviceCommandRequest request) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const DeviceCommandResult(
        status: DeviceCommandStatus.invalidCommand,
        message:
            '[Device Command] eFactor sendData is supported on Android and '
            'iOS physical devices only.',
      );
    }

    final token = request.accessToken?.trim() ?? '';
    final pageName = request.pageName?.trim() ?? '';
    final frame = request.finalFrame?.trim() ?? '';
    final numericValue = request.numericValue;

    if (token.isEmpty) {
      return const DeviceCommandResult(
        status: DeviceCommandStatus.authFailure,
        message:
            '[Device Command] deviceApi requires the current access token.',
      );
    }
    if (pageName.isEmpty || request.parameter.trim().isEmpty) {
      return DeviceCommandResult(
        status: DeviceCommandStatus.invalidCommand,
        message:
            '[Device Command] deviceApi requires schema pageName and parameterName. '
            'Control: ${request.controlId ?? "unknown"}.',
      );
    }
    if (frame.isEmpty || numericValue == null) {
      return DeviceCommandResult(
        status: DeviceCommandStatus.invalidCommand,
        message:
            '[Device Command] deviceApi requires a final schema-built frame and '
            'numeric transport value. Control: ${request.controlId ?? "unknown"}.',
      );
    }

    // The native Data SDK requires real runtime coordinates. A fresh GPS fix
    // used to be requested for every toggle/slider command, which can add
    // seconds of avoidable latency. Reuse a recently captured real position
    // for a short configurable window; no coordinates are invented.
    final position = await _resolveRuntimeLocation();
    if (position == null) {
      return const DeviceCommandResult(
        status: DeviceCommandStatus.invalidCommand,
        message:
            '[Device Command] Current eFactor native sendData requires runtime '
            'latitude/longitude. Location service/permission is unavailable. '
            'No coordinates were hardcoded or invented.',
      );
    }

    final isLocal = EfactorCloudService.instance.isNodeLocal(request.nodeId);
    final localDev = EfactorCloudService.instance.getLocalDevice(request.nodeId);
    debugPrint(
      '[DEVICE TRANSPORT] adapter=deviceApi '
      'routing=${isLocal ? "LOCAL_LAN (${localDev?.ip}:${localDev?.port})" : "CLOUD_FALLBACK"} '
      'protocol=${request.protocol ?? "unknown"} '
      'control=${request.controlId ?? "unknown"} page=$pageName '
      'parameter=${request.parameter} frame=$frame',
    );

    try {
      await EfactorCloudService.instance.ensureDiscoveryStarted();
      final result = await EfactorData.instance.sendData(
        apiKey: token,
        nodeId: request.nodeId,
        deviceId: request.nodeId,
        pageName: pageName,
        paramName: request.parameter,
        value: numericValue,
        data: frame,
        latitude: position.latitude,
        longitude: position.longitude,
      );

      if (result.ok) {
        debugPrint(
          '[DEVICE TRANSPORT] SUCCESS via ${isLocal ? "LOCAL LAN" : "CLOUD"} '
          'nodeId=${request.nodeId} control=${request.controlId}',
        );
        return DeviceCommandResult(
          status: DeviceCommandStatus.delivered,
          message: isLocal
              ? 'eFactor deviceApi executed locally over LAN.'
              : 'eFactor deviceApi accepted the command (cloud fallback).',
          rawResponse: result.raw,
          responseBody: result.raw['response']?.toString(),
        );
      }

      final isNetwork = result.errorKind == 'network';
      return DeviceCommandResult(
        status: isNetwork
            ? DeviceCommandStatus.offline
            : DeviceCommandStatus.rejected,
        message: '[Device Command] eFactor deviceApi rejected the command '
            '(${result.errorKind ?? "unknown"}).',
        rawResponse: result.raw,
        responseBody: result.raw['response']?.toString(),
      );
    } on MissingPluginException catch (error) {
      return DeviceCommandResult(
        status: DeviceCommandStatus.invalidCommand,
        message:
            '[Device Command] eFactor sendData plugin is unavailable: $error',
      );
    } on PlatformException catch (error) {
      return DeviceCommandResult(
        status: DeviceCommandStatus.rejected,
        message: '[Device Command] eFactor native sendData failed '
            '(${error.code}): ${error.message ?? "no message"}',
      );
    } catch (error) {
      return DeviceCommandResult(
        status: DeviceCommandStatus.rejected,
        message: '[Device Command] eFactor deviceApi failed: $error',
      );
    }
  }
}

class _RuntimeLocation {
  const _RuntimeLocation({
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
  });

  final String latitude;
  final String longitude;
  final DateTime capturedAt;
}
