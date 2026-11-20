import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../api/track_api_client.dart';
import '../identity/tracker_identity.dart';
import '../storage/breadcrumb_outbox.dart';

/// Drains the breadcrumb outbox to the backend in batches, honoring the
/// policy's batch size / interval / wifi-only, with exponential backoff on
/// failure. Uploads are idempotent (each point carries a client_uuid), so a
/// retry after a lost response never double-counts.
class SyncDispatcher {
  SyncDispatcher({
    required this.api,
    required this.outbox,
    required this.identityProvider,
    Connectivity? connectivity,
  }) : _connectivity = connectivity ?? Connectivity();

  final TrackApiClient api;
  final BreadcrumbOutbox outbox;
  final TrackerIdentity Function() identityProvider;
  final Connectivity _connectivity;

  int _batchMaxPoints = 50;
  bool _wifiOnly = false;
  Duration _uploadInterval = const Duration(seconds: 60);

  Timer? _timer;
  bool _flushing = false;
  int _backoffAttempt = 0;

  void configure({
    required int batchMaxPoints,
    required int batchMaxIntervalSeconds,
    required bool wifiOnly,
  }) {
    _batchMaxPoints = batchMaxPoints <= 0 ? 50 : batchMaxPoints;
    _wifiOnly = wifiOnly;
    _uploadInterval = Duration(
      seconds: batchMaxIntervalSeconds <= 0 ? 60 : batchMaxIntervalSeconds,
    );
    if (_timer != null) _restartTimer();
  }

  void start() => _restartTimer();

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_uploadInterval, (_) => flush());
  }

  Future<bool> _online() async {
    final results = await _connectivity.checkConnectivity();
    if (results.contains(ConnectivityResult.none) && results.length == 1) {
      return false;
    }
    if (_wifiOnly) return results.contains(ConnectivityResult.wifi);
    return results.any((r) => r != ConnectivityResult.none);
  }

  /// Uploads as many full batches as are queued. Safe to call repeatedly.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      if (!await _online()) return;

      while (true) {
        final batch = await outbox.peek(_batchMaxPoints);
        if (batch.isEmpty) break;

        bool ok;
        try {
          ok = await api.postBreadcrumbs(
            identity: identityProvider(),
            points: batch,
          );
        } catch (_) {
          ok = false;
        }

        if (ok) {
          await outbox.remove(batch.map((b) => b.clientUuid));
          _backoffAttempt = 0;
          if (batch.length < _batchMaxPoints) break; // drained
        } else {
          _scheduleBackoff();
          break;
        }
      }
    } finally {
      _flushing = false;
    }
  }

  void _scheduleBackoff() {
    _backoffAttempt++;
    final seconds = (3 * (1 << (_backoffAttempt - 1))).clamp(3, 120);
    _timer?.cancel();
    _timer = Timer(Duration(seconds: seconds), () {
      _restartTimer();
      flush();
    });
  }
}
