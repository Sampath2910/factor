import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Represents a pending offline action (e.g. Chat Message, Like, Comment).
class OfflineOutboxAction {
  final String actionId;
  final String actionType; // 'send_message', 'like_post', 'add_comment'
  final String targetUrl;
  final Map<String, dynamic> payload;
  final int createdAtEpochMs;
  int retryCount;

  OfflineOutboxAction({
    required this.actionId,
    required this.actionType,
    required this.targetUrl,
    required this.payload,
    required this.createdAtEpochMs,
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
    'actionId': actionId,
    'actionType': actionType,
    'targetUrl': targetUrl,
    'payload': payload,
    'createdAtEpochMs': createdAtEpochMs,
    'retryCount': retryCount,
  };

  factory OfflineOutboxAction.fromJson(Map<String, dynamic> json) {
    return OfflineOutboxAction(
      actionId: json['actionId']?.toString() ?? '',
      actionType: json['actionType']?.toString() ?? 'send_message',
      targetUrl: json['targetUrl']?.toString() ?? '',
      payload: Map<String, dynamic>.from(json['payload'] as Map? ?? {}),
      createdAtEpochMs: (json['createdAtEpochMs'] as num?)?.toInt() ?? 0,
      retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Production Outbox synchronization worker.
///
/// Ensures all user actions taken while in airplane mode or with no connectivity
/// are safely stored on the phone's flash storage and automatically flushed
/// in sequential order the moment connectivity returns.
class GridOfflineOutboxService {
  GridOfflineOutboxService._();
  static final GridOfflineOutboxService instance =
      GridOfflineOutboxService._();

  File? _outboxFile;
  final List<OfflineOutboxAction> _pendingQueue = <OfflineOutboxAction>[];
  bool _isFlushing = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  final StreamController<OfflineOutboxAction> _onActionSynced =
      StreamController<OfflineOutboxAction>.broadcast();
  Stream<OfflineOutboxAction> get onActionSynced => _onActionSynced.stream;

  Future<File> get _file async {
    if (_outboxFile != null) return _outboxFile!;
    final appDir = await getApplicationDocumentsDirectory();
    final f = File('${appDir.path}/efactor_outbox.json');
    if (!f.existsSync()) {
      f.writeAsStringSync(jsonEncode([]));
    }
    _outboxFile = f;
    return f;
  }

  /// Initializes the outbox listener on app startup.
  Future<void> initialize() async {
    await _loadQueueFromDisk();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (isOnline && _pendingQueue.isNotEmpty && !_isFlushing) {
        debugPrint(
          '[GridOutbox] Network restored, auto-flushing ${_pendingQueue.length} pending actions...',
        );
        unawaited(flush());
      }
    });
  }

  /// Adds a new action to the offline queue and saves to persistent disk.
  Future<void> enqueue({
    required String actionType,
    required String targetUrl,
    required Map<String, dynamic> payload,
    String? customActionId,
  }) async {
    final action = OfflineOutboxAction(
      actionId:
          customActionId ??
          'act_${DateTime.now().millisecondsSinceEpoch}_${_pendingQueue.length}',
      actionType: actionType,
      targetUrl: targetUrl,
      payload: payload,
      createdAtEpochMs: DateTime.now().millisecondsSinceEpoch,
    );

    _pendingQueue.add(action);
    await _saveQueueToDisk();
    debugPrint(
      '[GridOutbox] Enqueued action: ${action.actionType} (${action.actionId}). Total pending: ${_pendingQueue.length}',
    );

    // If online right now, try to flush immediately
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.any((r) => r != ConnectivityResult.none)) {
      unawaited(flush());
    }
  }

  /// Flushes all pending outbox actions over HTTP.
  Future<void> flush() async {
    if (_isFlushing || _pendingQueue.isEmpty) return;
    _isFlushing = true;

    final client = http.Client();
    try {
      while (_pendingQueue.isNotEmpty) {
        final current = _pendingQueue.first;
        bool success = false;

        try {
          final uri = Uri.parse(current.targetUrl);
          final response = await client
              .post(
                uri,
                headers: <String, String>{
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                },
                body: jsonEncode(current.payload),
              )
              .timeout(const Duration(seconds: 15));

          if (response.statusCode >= 200 && response.statusCode < 300) {
            success = true;
          } else {
            current.retryCount++;
            debugPrint(
              '[GridOutbox] Server returned ${response.statusCode} for ${current.actionId}',
            );
          }
        } catch (e) {
          debugPrint('[GridOutbox] Sync attempt failed for ${current.actionId}: $e');
          break; // Stop flushing if network dropped again
        }

        if (success || current.retryCount > 5) {
          _pendingQueue.removeAt(0);
          await _saveQueueToDisk();
          if (success) {
            _onActionSynced.add(current);
            debugPrint(
              '[GridOutbox] Successfully synced: ${current.actionType} (${current.actionId})',
            );
          }
        }
      }
    } finally {
      client.close();
      _isFlushing = false;
    }
  }

  int get pendingCount => _pendingQueue.length;

  Future<void> _loadQueueFromDisk() async {
    try {
      final f = await _file;
      if (f.existsSync()) {
        final content = await f.readAsString();
        if (content.trim().isNotEmpty) {
          final List<dynamic> list = jsonDecode(content) as List<dynamic>;
          _pendingQueue.clear();
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              _pendingQueue.add(OfflineOutboxAction.fromJson(item));
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[GridOutbox] Load error: $e');
    }
  }

  Future<void> _saveQueueToDisk() async {
    try {
      final f = await _file;
      final jsonList = _pendingQueue.map((a) => a.toJson()).toList();
      await f.writeAsString(jsonEncode(jsonList));
    } catch (e) {
      debugPrint('[GridOutbox] Save error: $e');
    }
  }

  void dispose() {
    _connectivitySub?.cancel();
    _onActionSynced.close();
  }
}
