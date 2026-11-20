import 'package:efactor_field_tracker/efactor_field_tracker.dart';
import 'package:flutter/foundation.dart';

/// Thin, OPT-IN bridge between the app's auth session and the shared
/// [FieldTracker] GPS engine.
///
/// It is gated OFF by default via [enabled], so the app's existing behaviour is
/// completely unchanged in normal builds — `maybeStart`/`stop` are no-ops. It
/// only activates when the app is run/built with:
///
///   flutter run --dart-define=ENABLE_FIELD_TRACKER=true
///
/// (optionally `--dart-define=FIELD_TRACKER_TENANT=<id>`).
class FieldTrackerIntegration {
  FieldTrackerIntegration._();
  static final FieldTrackerIntegration instance = FieldTrackerIntegration._();

  /// Master switch — OFF unless explicitly enabled at build/run time.
  static const bool enabled = bool.fromEnvironment('ENABLE_FIELD_TRACKER');

  /// Phase 0 seed tenant until the backend returns `tenant_id` at login.
  static const String tenantId = String.fromEnvironment(
    'FIELD_TRACKER_TENANT',
    defaultValue: 'tenant_demo_001',
  );

  bool _started = false;

  /// Initializes (once) and starts duty for the authenticated user. No-op when
  /// the feature is disabled or the user id is missing.
  Future<void> maybeStart({
    required String Function() tokenProvider,
    required String userId,
  }) async {
    if (!enabled || userId.isEmpty) return;
    try {
      if (!FieldTracker.instance.isInitialized) {
        await FieldTracker.instance.initialize(
          tokenProvider: tokenProvider,
          tenantId: tenantId,
          userId: userId,
        );
      } else {
        FieldTracker.instance.updateIdentity(userId: userId);
      }
      final ok = await FieldTracker.instance.startDuty();
      _started = ok;
      debugPrint(
        '[FieldTracker] startDuty=$ok tenant=$tenantId user=$userId '
        'policy=${FieldTracker.instance.currentPolicy}',
      );
    } catch (e) {
      debugPrint('[FieldTracker] start failed: $e');
    }
  }

  /// Stops tracking (e.g. on logout). No-op when disabled or not started.
  void stop() {
    if (!enabled || !_started) return;
    try {
      FieldTracker.instance.stopDuty();
    } catch (e) {
      debugPrint('[FieldTracker] stopDuty failed on logout: $e');
    }
    _started = false;
  }
}
