import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

/// Represents an active Circle Connect live location sharing session.
class LiveLocationSession {
  LiveLocationSession({
    required this.messageId,
    required this.conversationId,
    required this.until,
    required this.endpoint,
    required this.intervalSeconds,
    required this.minDistanceMeters,
    this.cookies = '',
  });

  final String messageId;
  final String conversationId;
  final DateTime until;
  final String endpoint;
  final int intervalSeconds;
  final double minDistanceMeters;
  String cookies;

  DateTime? lastPostTime;
  Position? lastPostedPosition;
  bool isStopping = false;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'messageId': messageId,
        'conversationId': conversationId,
        'until': until.toIso8601String(),
        'endpoint': endpoint,
        'intervalSeconds': intervalSeconds,
        'minDistanceMeters': minDistanceMeters,
      };
}

/// Singleton service managing Android foreground service location tracking,
/// multiple concurrent live shares, throttling, distance checks, and HTTP POSTs.
class GridLiveLocationService {
  GridLiveLocationService._();
  static final GridLiveLocationService instance = GridLiveLocationService._();

  static const int kNotificationId = 88231;
  static const String kChannelId = 'grid_live_location_v1';
  static const String kChannelName = 'Live Location Sharing';

  final Map<String, LiveLocationSession> _sessions =
      <String, LiveLocationSession>{};
  StreamSubscription<Position>? _positionSubscription;
  Timer? _periodicTimer;
  Position? _lastKnownPosition;

  bool get isRunning => _sessions.isNotEmpty;
  int get activeSessionCount => _sessions.length;

  /// Starts or registers a live location sharing session.
  /// If the session for [messageId] is already running, it is ignored (idempotent).
  Future<void> start({
    required String messageId,
    required String conversationId,
    required DateTime until,
    required String endpoint,
    required int intervalSeconds,
    required double minDistanceMeters,
    String? cookies,
  }) async {
    final id = messageId.trim();
    if (id.isEmpty) return;

    if (_sessions.containsKey(id)) {
      debugPrint(
        '[LiveLocation] Session $id already running, ignoring start request.',
      );
      if (cookies != null && cookies.isNotEmpty) {
        _sessions[id]?.cookies = cookies;
      }
      return;
    }

    final session = LiveLocationSession(
      messageId: id,
      conversationId: conversationId.trim(),
      until: until,
      endpoint: endpoint.trim(),
      intervalSeconds: intervalSeconds.clamp(5, 3600),
      minDistanceMeters: minDistanceMeters.clamp(1.0, 1000.0),
      cookies: cookies ?? '',
    );

    _sessions[id] = session;
    debugPrint(
      '[LiveLocation] Started session $id in conversation $conversationId '
      'until ${until.toIso8601String()}',
    );

    await _startLocationStreamIfNeeded();
    await _updateNotificationTray();

    // Immediately fetch position and transmit initial location
    try {
      final pos = await Geolocator.getCurrentPosition(
        timeLimit: const Duration(seconds: 10),
      );
      _lastKnownPosition = pos;
      await _evaluateAndPost(session, pos, force: true);
    } catch (e) {
      debugPrint('[LiveLocation] Initial position fetch error: $e');
    }
  }

  /// Stops a specific session by [messageId].
  /// If [postStop] is true, sends a final POST with stop=1 before removal.
  Future<void> stop(String messageId, {bool postStop = false}) async {
    final id = messageId.trim();
    final session = _sessions[id];
    if (session == null) return;

    if (postStop && !session.isStopping && _lastKnownPosition != null) {
      session.isStopping = true;
      await _postLocation(session, _lastKnownPosition!, stop: true);
    }

    _sessions.remove(id);
    debugPrint(
      '[LiveLocation] Stopped session $id. Remaining: ${_sessions.length}',
    );

    if (_sessions.isEmpty) {
      await _stopLocationStream();
      await _dismissNotificationTray();
    } else {
      await _updateNotificationTray();
    }
  }

  /// Stops all active sessions (e.g., when user taps Stop in notification tray).
  Future<void> stopAll({bool postStop = true}) async {
    debugPrint(
      '[LiveLocation] Stopping all active sessions (${_sessions.length})...',
    );
    final sessionsList = _sessions.values.toList();
    for (final session in sessionsList) {
      if (postStop && _lastKnownPosition != null) {
        session.isStopping = true;
        await _postLocation(session, _lastKnownPosition!, stop: true);
      }
    }
    _sessions.clear();
    await _stopLocationStream();
    await _dismissNotificationTray();
  }

  Future<void> _startLocationStreamIfNeeded() async {
    if (_positionSubscription != null) return;

    final earliestUntil = _getEarliestUntil();
    final untilText = _formatTime(earliestUntil);

    final androidSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 5),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: 'Sharing live location',
        notificationText: 'Circle Connect · until $untilText',
        notificationChannelName: kChannelName,
        notificationIcon: const AndroidResource(
          name: 'ic_notification',
          defType: 'drawable',
        ),
        enableWakeLock: true,
        enableWifiLock: true,
        setOngoing: true,
      ),
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: androidSettings,
    ).listen(
      _onPositionUpdate,
      onError: (dynamic error) {
        debugPrint('[LiveLocation] Location stream error: $error');
      },
    );

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _onPeriodicTick();
    });

    debugPrint('[LiveLocation] Foreground location stream and timer started.');
  }

  Future<void> _stopLocationStream() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    debugPrint('[LiveLocation] Foreground location stream and timer stopped.');
  }

  void _onPositionUpdate(Position position) {
    _lastKnownPosition = position;
    final now = DateTime.now();

    final sessionsList = _sessions.values.toList();
    for (final session in sessionsList) {
      // Expiration check: send one last POST with stop=1, then stop.
      if (now.isAfter(session.until) || now.isAtSameMomentAs(session.until)) {
        debugPrint(
          '[LiveLocation] Session ${session.messageId} reached expiration (${session.until}). Sending final stop.',
        );
        unawaited(_postLocation(session, position, stop: true).then((_) {
          stop(session.messageId, postStop: false);
        }));
        continue;
      }

      unawaited(_evaluateAndPost(session, position));
    }
  }

  void _onPeriodicTick() {
    if (_sessions.isEmpty) return;

    final now = DateTime.now();
    final pos = _lastKnownPosition;
    final sessionsList = _sessions.values.toList();

    for (final session in sessionsList) {
      if (now.isAfter(session.until) || now.isAtSameMomentAs(session.until)) {
        debugPrint(
          '[LiveLocation] Periodic check: Session ${session.messageId} expired.',
        );
        if (pos != null) {
          unawaited(_postLocation(session, pos, stop: true).then((_) {
            stop(session.messageId, postStop: false);
          }));
        } else {
          stop(session.messageId, postStop: false);
        }
        continue;
      }

      if (pos != null) {
        unawaited(_evaluateAndPost(session, pos));
      }
    }
  }

  Future<void> _evaluateAndPost(
    LiveLocationSession session,
    Position position, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    final secondsSinceLastPost = session.lastPostTime != null
        ? now.difference(session.lastPostTime!).inSeconds
        : 999999;

    // Spec rule: Never post more than once per 5 seconds per message
    if (!force && secondsSinceLastPost < 5) {
      return;
    }

    final distanceMoved = session.lastPostedPosition != null
        ? Geolocator.distanceBetween(
            session.lastPostedPosition!.latitude,
            session.lastPostedPosition!.longitude,
            position.latitude,
            position.longitude,
          )
        : double.infinity;

    // Spec rule: Post a position when the phone moved at least minDistanceMeters,
    // or every intervalSeconds even without moving
    final shouldPost = force ||
        distanceMoved >= session.minDistanceMeters ||
        secondsSinceLastPost >= session.intervalSeconds;

    if (shouldPost) {
      await _postLocation(session, position, stop: false);
    }
  }

  Future<void> _postLocation(
    LiveLocationSession session,
    Position position, {
    required bool stop,
  }) async {
    final endpoint = session.endpoint;
    if (endpoint.isEmpty) return;

    session.lastPostTime = DateTime.now();
    session.lastPostedPosition = position;

    try {
      final uri = Uri.parse(endpoint);
      final body = <String, String>{
        'message_id': session.messageId,
        'lat': position.latitude.toString(),
        'lng': position.longitude.toString(),
        'accuracy': position.accuracy.round().toString(),
        if (stop) 'stop': '1',
      };

      final headers = <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
        if (session.cookies.isNotEmpty) 'Cookie': session.cookies,
      };

      debugPrint(
        '[LiveLocation] POST $endpoint | message_id=${session.messageId} | '
        'lat=${position.latitude}, lng=${position.longitude}, acc=${position.accuracy.round()}m | stop=$stop',
      );

      final response = await http
          .post(
            uri,
            headers: headers,
            body: body,
          )
          .timeout(const Duration(seconds: 12));

      debugPrint(
        '[LiveLocation] Response status ${response.statusCode} from $endpoint: ${response.body}',
      );

      // Spec rule: Stop when HTTP status is 401 (logged out), 404 or 422
      if (response.statusCode == 401 ||
          response.statusCode == 404 ||
          response.statusCode == 422) {
        debugPrint(
          '[LiveLocation] Server returned status ${response.statusCode}, stopping session ${session.messageId}.',
        );
        this.stop(session.messageId, postStop: false);
        return;
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final dynamic resJson = jsonDecode(response.body);
          if (resJson is Map) {
            final dynamic data = resJson['data'];
            // Spec rule: The reply has data.ended: true -> stop
            if (data is Map && data['ended'] == true) {
              debugPrint(
                '[LiveLocation] data.ended is true in server reply, stopping session ${session.messageId}.',
              );
              this.stop(session.messageId, postStop: false);
              return;
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      // Spec rule: On a network error, keep going and send only the latest position next time. Don't queue old positions.
      debugPrint(
        '[LiveLocation] Network error posting location: $e (will retry on next interval with latest position)',
      );
    }
  }

  Future<void> _updateNotificationTray() async {
    if (_sessions.isEmpty) {
      await _dismissNotificationTray();
      return;
    }

    final earliestUntil = _getEarliestUntil();
    final untilText = _formatTime(earliestUntil);
    final count = _sessions.length;
    final title = count > 1
        ? 'Sharing live location in $count chats'
        : 'Sharing live location';
    final body = 'Circle Connect · until $untilText';

    final plugin = FlutterLocalNotificationsPlugin();
    const androidDetails = AndroidNotificationDetails(
      kChannelId,
      kChannelName,
      channelDescription:
          'Notifications for active Circle Connect live location sharing',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: true,
      icon: 'ic_notification',
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'stop_live_location',
          'Stop',
          showsUserInterface: false,
          cancelNotification: false,
        ),
      ],
    );

    await plugin.show(
      kNotificationId,
      title,
      body,
      const NotificationDetails(android: androidDetails),
      payload: jsonEncode(<String, dynamic>{'type': 'live_location'}),
    );
  }

  Future<void> _dismissNotificationTray() async {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.cancel(kNotificationId);
  }

  DateTime _getEarliestUntil() {
    if (_sessions.isEmpty) {
      return DateTime.now().add(const Duration(minutes: 15));
    }
    DateTime earliest = _sessions.values.first.until;
    for (final s in _sessions.values) {
      if (s.until.isBefore(earliest)) {
        earliest = s.until;
      }
    }
    return earliest;
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
