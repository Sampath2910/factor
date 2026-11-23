import 'dart:async';

import 'package:efactor_field_tracker/efactor_field_tracker.dart';
import 'package:flutter/widgets.dart';

import 'field_tracking_command.dart';

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
class FieldTrackerIntegration with WidgetsBindingObserver {
  FieldTrackerIntegration._();
  static final FieldTrackerIntegration instance = FieldTrackerIntegration._();

  /// Master switch — OFF unless explicitly enabled at build/run time.
  static const bool enabled = bool.fromEnvironment('ENABLE_FIELD_TRACKER');

  /// Fallback tenant for old installs whose login didn't carry `tenant_id`
  /// (overridable at build time). The real tenant now comes from login.
  static const String fallbackTenantId = String.fromEnvironment(
    'FIELD_TRACKER_TENANT',
    defaultValue: 'tenant_demo_001',
  );

  bool _started = false;
  bool _observing = false;
  String Function()? _tokenProvider;

  /// Initializes (once) and starts duty for the authenticated user. No-op when
  /// the feature is disabled or the user id is missing.
  Future<void> maybeStart({
    required String Function() tokenProvider,
    required String userId,
    String? tenantId,
  }) async {
    if (!enabled || userId.isEmpty) return;
    _tokenProvider = tokenProvider;
    final hasTenant = tenantId != null && tenantId.isNotEmpty;
    final tenant = hasTenant ? tenantId : fallbackTenantId;
    try {
      if (!FieldTracker.instance.isInitialized) {
        await FieldTracker.instance.initialize(
          tokenProvider: tokenProvider,
          tenantId: tenant,
          userId: userId,
        );
      } else {
        FieldTracker.instance.updateIdentity(tenantId: tenant, userId: userId);
      }
      // Old install with no tenant_id from login: resolve the real one.
      if (!hasTenant) {
        await FieldTracker.instance.backfillTenantId();
      }
      // Apply anything queued by the FCM background isolate before (re)starting.
      await _applyPendingCommand();
      if (!_observing) {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      }
      final ok = await FieldTracker.instance.startDuty();
      _started = ok;
      debugPrint(
        '[FieldTracker] startDuty=$ok tenant=${FieldTracker.instance.identity?.tenantId} '
        'user=$userId policy=${FieldTracker.instance.currentPolicy}',
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

  /// Entry point for a `type == "field_tracking"` FCM push. Returns true when
  /// the push was a field-tracking command (handled), so the caller stops.
  ///
  /// Foreground pushes are applied immediately. Background-isolate pushes are
  /// queued to disk and applied by the main isolate on next resume/start
  /// ([FieldTracker] and the native location service live only in the main
  /// isolate). shortcut: a start push while backgrounded takes effect on the
  /// next resume, not instantly; upgrade needs a native service trigger.
  Future<bool> handlePush(
    Map<String, dynamic> data, {
    required bool foreground,
  }) async {
    final cmd = FieldTrackingCommand.tryParse(data);
    if (cmd == null) return false;
    if (!enabled) return true;

    final store = FieldTrackingCommandStore.instance;
    final ok = shouldApplyFieldTrackingCommand(
      cmd: cmd,
      ourDeviceId: await store.readOurDeviceId(),
      lastAppliedIssuedAt: await store.readLastIssuedAt(cmd.scopeKey),
      appliedCommandIds: await store.readAppliedIds(cmd.scopeKey),
    );
    if (!ok) return true;

    if (foreground) {
      await _apply(cmd);
      await store.markApplied(cmd);
    } else {
      await store.writePendingIfNewer(cmd);
    }
    return true;
  }

  /// Applies a command queued by the background isolate, if any.
  Future<void> _applyPendingCommand() async {
    final store = FieldTrackingCommandStore.instance;
    final cmd = await store.readPending();
    if (cmd == null) {
      return;
    }
    final ok = shouldApplyFieldTrackingCommand(
      cmd: cmd,
      ourDeviceId: await store.readOurDeviceId(),
      lastAppliedIssuedAt: await store.readLastIssuedAt(cmd.scopeKey),
      appliedCommandIds: await store.readAppliedIds(cmd.scopeKey),
    );
    if (ok) {
      await _apply(cmd);
      await store.markApplied(cmd);
    }
    await store.clearPending();
  }

  Future<void> _apply(FieldTrackingCommand cmd) async {
    try {
      if (!FieldTracker.instance.isInitialized) {
        final provider = _tokenProvider;
        if (provider == null) return; // not logged in yet; stays queued-applied
        await FieldTracker.instance.initialize(
          tokenProvider: provider,
          tenantId: cmd.tenantId.isNotEmpty ? cmd.tenantId : fallbackTenantId,
          userId: cmd.userId,
        );
      }
      if (cmd.isStart) {
        await FieldTracker.instance.refreshPolicy();
        _started = await FieldTracker.instance.startDuty();
      } else if (cmd.isStop) {
        FieldTracker.instance.stopDuty();
        _started = false;
      }
      debugPrint('[FieldTracker] applied command ${cmd.action} '
          'started=$_started');
    } catch (e) {
      debugPrint('[FieldTracker] apply command failed: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_applyPendingCommand());
    }
  }
}
