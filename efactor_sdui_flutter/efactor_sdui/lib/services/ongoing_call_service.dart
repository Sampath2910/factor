import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service managing the active, connected call state.
/// Runs an Android Foreground Service (microphone, plus camera for video)
/// with an "Ongoing call · tap to return" notification, keeping WebRTC
/// audio/video alive in the background.
class OngoingCallService {
  OngoingCallService._();
  static final OngoingCallService instance = OngoingCallService._();

  static const MethodChannel _channel =
      MethodChannel('tech.efactor/circle_connect');

  bool _isCallActive = false;
  String? _activeCallId;
  String? _activeCallType;
  String? _activeCallerName;
  bool _isGroup = false;

  bool get isCallActive => _isCallActive;
  String? get activeCallId => _activeCallId;
  String? get activeCallType => _activeCallType;
  String? get activeCallerName => _activeCallerName;
  bool get isGroup => _isGroup;

  /// Starts the ongoing call foreground service and displays
  /// the persistent "Ongoing call · tap to return" status bar notification.
  Future<void> startCall({
    required String callId,
    required String callType,
    required String name,
    bool isGroup = false,
  }) async {
    _isCallActive = true;
    _activeCallId = callId.trim();
    _activeCallType = callType.trim().toLowerCase();
    _activeCallerName = name.trim();
    _isGroup = isGroup;

    debugPrint(
      '[OngoingCallService] >>> startCall: callId=$_activeCallId, type=$_activeCallType, name=$_activeCallerName, isGroup=$_isGroup',
    );

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod<bool>('startOngoingCallService', {
          'callId': _activeCallId,
          'callType': _activeCallType,
          'name': _activeCallerName,
          'isGroup': _isGroup,
        });
      } catch (e) {
        debugPrint('[OngoingCallService] Failed starting Android foreground service: $e');
      }
    }
  }

  /// Stops the ongoing call foreground service, releases locks,
  /// and removes the status bar notification.
  Future<void> stopCall([String? callId]) async {
    if (callId != null &&
        callId.isNotEmpty &&
        _activeCallId != null &&
        _activeCallId != callId) {
      debugPrint(
        '[OngoingCallService] Ignoring stopCall for mismatched callId ($callId != $_activeCallId)',
      );
      return;
    }

    debugPrint(
      '[OngoingCallService] <<< stopCall for callId=$_activeCallId',
    );

    _isCallActive = false;
    _activeCallId = null;
    _activeCallType = null;
    _activeCallerName = null;
    _isGroup = false;

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod<bool>('stopOngoingCallService');
      } catch (e) {
        debugPrint('[OngoingCallService] Failed stopping Android foreground service: $e');
      }
    }
  }
}
