import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/track_api_client.dart';
import 'gps/gps_source.dart';
import 'identity/tracker_identity.dart';
import 'models/breadcrumb.dart';
import 'models/tracking_event.dart';
import 'models/tracking_policy.dart';
import 'storage/breadcrumb_outbox.dart';
import 'sync/sync_dispatcher.dart';

/// Public facade for the field-tracking engine. A host app initializes it once
/// and starts/stops duty; the engine pulls its policy, samples GPS per policy,
/// buffers offline, and uploads in batches.
///
/// ```dart
/// await FieldTracker.instance.initialize(
///   tokenProvider: () => authState.accessToken,
///   tenantId: 'tenant_demo_001',   // Phase 0 seed; real source TBD
///   userId: '42',
/// );
/// await FieldTracker.instance.startDuty();
/// ```
/// The GPS sampling the engine should run right now. `null` means "do not
/// sample" (e.g. background tracking disabled while the app is backgrounded).
class SamplingConfig {
  const SamplingConfig({required this.intervalSeconds, this.distanceMeters});

  final int intervalSeconds;

  /// Non-null => distance mode (emit every N metres; no time gate).
  final int? distanceMeters;

  @override
  bool operator ==(Object other) =>
      other is SamplingConfig &&
      other.intervalSeconds == intervalSeconds &&
      other.distanceMeters == distanceMeters;

  @override
  int get hashCode => Object.hash(intervalSeconds, distanceMeters);

  @override
  String toString() =>
      'SamplingConfig(interval=${intervalSeconds}s, distance=$distanceMeters)';
}

/// Derives the effective sampling from the policy and app state. Foreground
/// follows the top-level policy; background follows `policy.background`
/// (Phase 5). Pure + exported so it is unit-testable.
SamplingConfig? resolveSampling(
  TrackingPolicy p, {
  required bool isForeground,
}) {
  int clamp(int s) => s <= 0 ? 5 : s;
  if (isForeground) {
    // Phase 0 foreground policy is interval-only.
    return SamplingConfig(intervalSeconds: clamp(p.intervalSeconds));
  }
  if (!p.backgroundEnabled) return null; // honour background on/off
  final mode = p.backgroundMode == 'same' ? p.mode : p.backgroundMode;
  final interval = clamp(p.backgroundIntervalSeconds ?? p.intervalSeconds);
  final distance = p.backgroundDistanceMeters;
  if (mode == 'distance' && distance != null && distance > 0) {
    return SamplingConfig(intervalSeconds: interval, distanceMeters: distance);
  }
  return SamplingConfig(intervalSeconds: interval);
}

class FieldTracker with WidgetsBindingObserver {
  FieldTracker._();
  static final FieldTracker instance = FieldTracker._();

  static const String _kPolicyCache = 'efactor.field_tracker.policy_cache';

  TrackApiClient? _api;
  BreadcrumbOutbox? _outbox;
  SyncDispatcher? _sync;
  GpsSource _gps = const GeolocatorGpsSource();
  TrackerIdentity? _identity;
  TrackingPolicy? _policy;
  StreamSubscription<GpsFix>? _sampleSub;
  DateTime? _lastSampleAt;
  bool _initialized = false;
  bool _onDuty = false;
  bool _isForeground = true;

  bool get isInitialized => _initialized;
  TrackingPolicy? get currentPolicy => _policy;
  TrackerIdentity? get identity => _identity;

  Future<void> initialize({
    required String Function() tokenProvider,
    required String tenantId,
    required String userId,
    String appId = 'efactor_field_tracker',
    String baseUrl = TrackApiClient.defaultBaseUrl,
    GpsSource? gpsSource,
    BreadcrumbOutbox? outbox,
  }) async {
    _api = TrackApiClient(tokenProvider: tokenProvider, baseUrl: baseUrl);
    _outbox = outbox ?? PrefsBreadcrumbOutbox();
    if (gpsSource != null) _gps = gpsSource;
    _identity = await TrackerIdentityStore(appId: appId)
        .resolve(tenantId: tenantId, userId: userId);
    _sync = SyncDispatcher(
      api: _api!,
      outbox: _outbox!,
      identityProvider: () => _identity!,
    );
    _policy = await _loadCachedPolicy();
    _initialized = true;
  }

  void _assertReady() {
    if (!_initialized || _identity == null) {
      throw StateError('FieldTracker.initialize() must be called first.');
    }
  }

  /// Begins tracking. Refreshes the policy, verifies location availability,
  /// then starts interval sampling + background upload. Returns false if
  /// location permission/service is unavailable (the host handles that UI).
  Future<bool> startDuty() async {
    _assertReady();
    await refreshPolicy();
    final available = await _gps.ensureAvailable();
    if (!available) return false;
    _onDuty = true;
    WidgetsBinding.instance.addObserver(this);
    _applyPolicy();
    _sync!.start();
    unawaited(_sync!.flush());
    return true;
  }

  void stopDuty() {
    _onDuty = false;
    WidgetsBinding.instance.removeObserver(this);
    _sampleSub?.cancel();
    _sampleSub = null;
    _lastSampleAt = null;
    _sync?.stop();
  }

  /// Foreground/background transitions re-derive the sampling (e.g. switch to
  /// the background cadence, or pause entirely if background is disabled).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _isForeground) return;
    _isForeground = fg;
    if (_onDuty) _applyPolicy();
  }

  /// Updates the tenant/user without reinitializing. Use when the backend later
  /// returns `tenant_id` in the login response (device_id and app_id are kept).
  void updateIdentity({String? tenantId, String? userId}) {
    final current = _identity;
    if (current == null) return;
    _identity = TrackerIdentity(
      appId: current.appId,
      tenantId: tenantId ?? current.tenantId,
      userId: userId ?? current.userId,
      deviceId: current.deviceId,
    );
  }

  /// Pulls the effective policy (304 → keep cached) and applies any change.
  Future<void> refreshPolicy() async {
    _assertReady();
    try {
      final res = await _api!.fetchEffectivePolicy(
        identity: _identity!,
        currentVersion: _policy?.version,
      );
      if (!res.notModified && res.policy != null) {
        _policy = res.policy;
        await _saveCachedPolicy(_policy!);
        if (_onDuty) _applyPolicy();
      }
    } catch (_) {
      // Offline / transient: keep the cached policy.
    }
  }

  void _applyPolicy() {
    final p = _policy;
    if (p == null) return;
    _sync!.configure(
      batchMaxPoints: p.batchMaxPoints,
      batchMaxIntervalSeconds: p.batchMaxIntervalSeconds,
      wifiOnly: p.wifiOnly,
    );
    _sampleSub?.cancel();
    _sampleSub = null;
    _lastSampleAt = null;

    final cfg = resolveSampling(p, isForeground: _isForeground);
    if (cfg == null) return; // background tracking disabled while backgrounded

    // Interval mode: iOS streams continuously (no interval knob), so gate to
    // one fix per interval (0.9x margin so Android's on-time fixes still pass).
    // Distance mode: take every fix the OS emits (already distance-filtered).
    final minGap = Duration(milliseconds: cfg.intervalSeconds * 900);
    _sampleSub = _gps
        .fixStream(
          intervalSeconds: cfg.intervalSeconds,
          distanceMeters: cfg.distanceMeters,
        )
        .listen((fix) {
      if (cfg.distanceMeters == null) {
        final now = DateTime.now();
        if (_lastSampleAt != null && now.difference(_lastSampleAt!) < minGap) {
          return;
        }
        _lastSampleAt = now;
      }
      _enqueueFix(fix);
    });
  }

  Future<void> _enqueueFix(GpsFix fix) async {
    await _outbox!.enqueue(
      Breadcrumb(
        recordedAt: fix.recordedAt ?? DateTime.now(),
        lat: fix.lat,
        lng: fix.lng,
        accuracyM: fix.accuracyM,
        speedMps: fix.speedMps,
        heading: fix.heading,
        altitudeM: fix.altitudeM,
        provider: fix.provider,
      ),
    );
  }

  Future<bool> recordCheckIn({String? siteId, String? note}) =>
      _recordEvent(TrackingEventType.checkIn, siteId: siteId, note: note);

  Future<bool> recordCheckOut({String? siteId, String? note}) =>
      _recordEvent(TrackingEventType.checkOut, siteId: siteId, note: note);

  Future<bool> _recordEvent(
    TrackingEventType type, {
    String? siteId,
    String? note,
  }) async {
    _assertReady();
    if (_policy?.checkInOutEnabled == false) return false;
    final fix = await _gps.currentFix();
    if (fix == null) return false;
    final event = TrackingEvent(
      type: type,
      recordedAt: fix.recordedAt ?? DateTime.now(),
      lat: fix.lat,
      lng: fix.lng,
      accuracyM: fix.accuracyM,
      siteId: siteId,
      note: note,
    );
    try {
      return await _api!.postEvent(identity: _identity!, event: event);
    } catch (_) {
      return false;
    }
  }

  /// Number of breadcrumbs still waiting to upload (diagnostics).
  Future<int> pendingCount() async =>
      _outbox == null ? 0 : await _outbox!.count();

  Future<TrackingPolicy?> _loadCachedPolicy() async {
    final prefs = await SharedPreferences.getInstance();
    return TrackingPolicy.tryDecode(prefs.getString(_kPolicyCache));
  }

  Future<void> _saveCachedPolicy(TrackingPolicy policy) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPolicyCache, policy.encode());
  }
}
