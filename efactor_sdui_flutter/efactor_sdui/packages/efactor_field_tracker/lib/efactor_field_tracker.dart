/// eFactor Field Tracker — a shared, server-driven GPS tracking engine.
///
/// Public API surface. Host apps use [FieldTracker]; the models and interfaces
/// are exported for custom wiring and tests.
library efactor_field_tracker;

export 'src/field_tracker.dart';
export 'src/api/track_api_client.dart'
    show TrackApiClient, EffectivePolicyResult;
export 'src/identity/tracker_identity.dart'
    show TrackerIdentity, TrackerIdentityStore;
export 'src/models/tracking_policy.dart';
export 'src/models/breadcrumb.dart';
export 'src/models/tracking_event.dart';
export 'src/storage/breadcrumb_outbox.dart';
export 'src/gps/gps_source.dart';
export 'src/sync/sync_dispatcher.dart' show SyncDispatcher;
