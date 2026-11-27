import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'call_lifecycle_tracker.dart';

/// Service managing the active, connected call state.
/// Runs an Android Foreground Service (microphone, plus camera for video)
/// with an "Ongoing call · tap to return" notification, keeping WebRTC
/// audio/video alive in the background.
class OngoingCallService {
  OngoingCallService._() {
    CallLifecycleTracker.isForegroundCallActive = () => _isCallActive;
    _channel.setMethodCallHandler(_handleNativeCall);
  }
  static final OngoingCallService instance = OngoingCallService._();

  static const MethodChannel _channel =
      MethodChannel('tech.efactor/circle_connect');

  /// Emits the current audio-route snapshot ({selectedRouteId, routes}) each
  /// time native publishes one (startup, user route change, device connect/
  /// disconnect). The webview forwards it to the web client as
  /// `circleConnectAudioRoutesChanged`.
  final StreamController<Map<String, dynamic>> _routesController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get routesChanged => _routesController.stream;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onAudioRoutesChanged') {
      final snapshot = _asStringKeyedMap(call.arguments);
      if (snapshot != null) _routesController.add(snapshot);
    }
    return null;
  }

  static Map<String, dynamic>? _asStringKeyedMap(dynamic value) {
    if (value is Map) {
      return value.map((key, v) => MapEntry(key.toString(), v));
    }
    return null;
  }

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

    unawaited(CallLifecycleTracker.setOngoingCallActive(true, callId: _activeCallId));

    debugPrint(
      '[OngoingCallService] >>> startCall: callId=$_activeCallId, type=$_activeCallType, name=$_activeCallerName, isGroup=$_isGroup',
    );

    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await _channel.invokeMethod<bool>('startOngoingCallService', {
          'callId': _activeCallId,
          'callType': _activeCallType,
          'name': _activeCallerName,
          'isGroup': _isGroup,
        });
      } catch (e) {
        debugPrint('[OngoingCallService] Failed starting ongoing call service: $e');
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

    final stoppedId = _activeCallId;

    debugPrint(
      '[OngoingCallService] <<< stopCall for callId=$_activeCallId',
    );

    _isCallActive = false;
    _activeCallId = null;
    _activeCallType = null;
    _activeCallerName = null;
    _isGroup = false;

    unawaited(CallLifecycleTracker.setOngoingCallActive(false, callId: callId ?? stoppedId));

    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await _channel.invokeMethod<bool>('stopOngoingCallService');
      } catch (e) {
        debugPrint('[OngoingCallService] Failed stopping ongoing call service: $e');
      }
    }
  }

  // --- Call-audio contract (web client owns call UI; native owns OS audio
  // focus + physical output routing). All over the same channel. ---

  /// Acquires transient VoIP audio focus (no ducking — media pauses), sets the
  /// communication mode, and applies the default output route for the call
  /// type. [preferredRoute] is 'phone' | 'speaker' | 'bluetooth' | 'wired';
  /// [focus] is informational (e.g. 'transient-voip').
  Future<void> startCallAudio({
    required String callId,
    required bool video,
    String? preferredRoute,
    String? focus,
  }) =>
      _invokeAudio('startCallAudio', <String, dynamic>{
        'callId': callId,
        'video': video,
        'preferredRoute': preferredRoute,
        'focus': focus,
      });

  /// Asks native to (re)publish the current routes via [routesChanged].
  Future<void> getCallAudioRoutes() =>
      _invokeAudio('getCallAudioRoutes', const <String, dynamic>{});

  /// Switches the active communication device without recreating the WebRTC
  /// session. Native confirms the applied route via [routesChanged].
  Future<void> setCallAudioRoute({
    required String routeId,
    String? routeType,
    String? deviceName,
  }) =>
      _invokeAudio('setCallAudioRoute', <String, dynamic>{
        'routeId': routeId,
        'routeType': routeType,
        'deviceName': deviceName,
      });

  /// Voice call upgraded to/from video: keep the same session/focus, only
  /// refresh native metadata and any not-user-overridden default route.
  Future<void> callMediaTypeChanged({
    required String callId,
    required bool video,
  }) =>
      _invokeAudio('callMediaTypeChanged', <String, dynamic>{
        'callId': callId,
        'video': video,
      });

  /// Clears the communication device, restores pre-call mode, abandons the
  /// exact focus request, unregisters route callbacks, and deactivates the
  /// session so external music can resume.
  Future<void> endCallAudio(String callId) =>
      _invokeAudio('endCallAudio', <String, dynamic>{'callId': callId});

  Future<void> _invokeAudio(String method, Map<String, dynamic> args) async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (e) {
      debugPrint('[OngoingCallService] $method failed: $e');
    }
  }
}
