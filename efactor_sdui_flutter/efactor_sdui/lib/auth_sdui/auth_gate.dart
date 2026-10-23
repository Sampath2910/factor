import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../sdui/schema_pull_to_refresh.dart';
import '../sdui/sdui_network_image_cache.dart';
import '../services/app_cache_manager.dart';
import '../services/efactor_cloud_service.dart';
import '../services/incoming_call_service.dart';
import '../services/schema_invalidation_event.dart';
import '../services/schema_prefetch.dart';
import 'auth_renderer.dart';
import 'auth_schema_repository.dart';
import 'auth_secure_storage.dart';
import 'auth_state.dart';

typedef AuthenticatedBuilder =
    Widget Function(BuildContext context, AuthState state);

/// Schema-owned authentication gate.
///
/// Auth schema startup is cached-first. The first validated server schema is
/// persisted according to the schema's cachePolicy, then lightweight metadata
/// revalidation/delta sync happens in the background. WebSocket
/// `schema_changed` is only an invalidation signal; authoritative schema bytes
/// always come from HTTPS through AuthSchemaRepository.
class AuthUiGate extends StatefulWidget {
  const AuthUiGate({
    super.key,
    required this.authenticatedBuilder,
    this.initialSchema,
  });

  final AuthenticatedBuilder authenticatedBuilder;
  final Map<String, dynamic>? initialSchema;

  @override
  State<AuthUiGate> createState() => _AuthUiGateState();
}

class _AuthUiGateState extends State<AuthUiGate> with WidgetsBindingObserver {
  final AuthSchemaRepository _repository = AuthSchemaRepository();
  StreamSubscription<SchemaInvalidationEvent>? _schemaInvalidationSubscription;
  StreamSubscription<bool>? _cloudConnectionSubscription;
  bool _cloudDisconnectedAfterConnect = false;

  AuthState? _state;
  String? _error;
  bool _loading = true;
  bool _schemaSyncInProgress = false;
  bool _pendingAuthSchemaRefresh = false;
  bool _pendingRefreshScheduled = false;
  bool _queuedSchemaSync = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialSchema != null) {
      _state = AuthState(widget.initialSchema!);
      _loading = false;
      unawaited(_state!.restoreSession());
    }
    _schemaInvalidationSubscription = EfactorCloudService
        .instance
        .schemaInvalidations
        .listen(_onSchemaInvalidation);
    _cloudConnectionSubscription = EfactorCloudService
        .instance
        .connectionChanges
        .listen(_onCloudConnectionChanged);

    // Cached-first. On first install/load the repository transparently falls
    // back to the complete live schema and stores it if cachePolicy allows it.
    _load(false);
  }

  void _onSchemaInvalidation(SchemaInvalidationEvent event) {
    final state = _state;
    if (state == null) return;

    final schemaId = state.schema['schemaId']?.toString().trim();
    final matches =
        event.matchesScope('auth') || event.matchesSchemaId(schemaId);
    if (!matches) return;

    final currentRevision = _schemaRevision(state.schema);
    final currentHash = _schemaHash(state.schema);
    if (event.revision != null &&
        currentRevision != null &&
        event.revision! <= currentRevision &&
        (event.contentHash == null || event.contentHash == currentHash)) {
      return;
    }

    // The Cloud socket is authenticated, so Auth invalidations normally arrive
    // while the authenticated application is active. Synchronize the local
    // cache immediately, but never replace an authenticated AuthState in place.
    // That would risk dropping a non-persisted in-memory session.
    unawaited(
      _syncSchema(
        event: event,
        applyIfUnauthenticated: false,
        reason: 'websocket',
      ),
    );
  }

  void _onCloudConnectionChanged(bool connected) {
    if (!connected) {
      if (EfactorCloudService.instance.libraryInitialized) {
        _cloudDisconnectedAfterConnect = true;
      }
      return;
    }

    if (!_cloudDisconnectedAfterConnect) return;
    _cloudDisconnectedAfterConnect = false;

    // The current backend schema's missed-event syncToken route is internally
    // inconsistent, so Auth safely reconciles through its declared metadata
    // endpoint after reconnect. This catches a missed Auth revision without
    // polling or downloading the full schema unnecessarily.
    unawaited(
      _syncSchema(applyIfUnauthenticated: false, reason: 'websocket_reconnect'),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState != AppLifecycleState.resumed) return;

    final state = _state;
    if (state == null || !_revalidateOnForeground(state.schema)) return;

    final initialPage = state.schema['app']?['initialPageId']?.toString();
    final safeToApply = !state.isAuthenticated && state.pageId == initialPage;

    unawaited(
      _syncSchema(
        applyIfUnauthenticated: safeToApply,
        reason: 'app_foreground',
      ),
    );
  }

  Future<void> _load(bool forceRefresh) async {
    try {
      if (forceRefresh) {
        await SduiAuthImageCache.manager.emptyCache();
      }
      final schema = await SchemaLoadQueue.instance.loadAuth(
        forceRefresh: forceRefresh,
      );
      final next = AuthState(schema);
      try {
        await next.restoreSession();
      } catch (sessionError) {
        debugPrint('[AUTH][GATE] Session restore error ignored: $sessionError');
      }

      if (!mounted) {
        next.dispose();
        return;
      }

      final old = _state;
      setState(() {
        _state = next;
        _error = null;
        _loading = false;
      });
      old?.dispose();

      // stale-while-revalidate: render the validated local schema first, then
      // check the lightweight metadata endpoint without blocking first paint.
      if (schema['_clientAuthSchemaCacheHit'] == true) {
        unawaited(
          _syncSchema(
            applyIfUnauthenticated: !next.isAuthenticated,
            reason: 'startup_revalidate',
            forceFull: false,
          ),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('[AUTH][GATE][LOAD_ERROR] $error');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _syncSchema({
    SchemaInvalidationEvent? event,
    required bool applyIfUnauthenticated,
    required String reason,
    bool forceFull = false,
  }) async {
    if (_schemaSyncInProgress) {
      _queuedSchemaSync = true;
      return;
    }

    final current = _state;
    if (current == null) return;

    _schemaSyncInProgress = true;
    try {
      final result = await _repository.revalidate(
        event: event,
        accessToken: current.accessToken,
        forceFull: forceFull,
      );

      if (!result.changed || !mounted) return;

      debugPrint(
        '[AUTH][SCHEMA_SYNC] reason=$reason '
        'source=${result.source} delta=${result.usedDelta}',
      );

      // Re-check the active state after network I/O. The user may have logged
      // in or out while metadata/delta synchronization was in flight.
      final active = _state;
      if (active == null) return;

      if (active.isAuthenticated) {
        // The new schema is already safely persisted. Apply it after logout or
        // the next unauthenticated gate boundary.
        _pendingAuthSchemaRefresh = true;
        debugPrint('[AUTH][SCHEMA_SYNC] deferredUntilUnauthenticated');
        return;
      }

      final initialPage = active.schema['app']?['initialPageId']?.toString();
      final onInitialPage =
          initialPage == null || initialPage.isEmpty || active.pageId == initialPage;
      if (!applyIfUnauthenticated && !onInitialPage) {
        // Do not destroy data a user may currently be typing into Login/Signup/
        // Forgot Password after a lifecycle resume. Cache is current and will
        // become active at the next safe gate start/boundary.
        _pendingAuthSchemaRefresh = true;
        return;
      }

      await _replaceState(result.schema);
    } catch (error, stackTrace) {
      // Revalidation is background work. A network/delta failure must not make
      // an already validated cached Auth UI unusable.
      debugPrint('[AUTH][SCHEMA_SYNC][ERROR] reason=$reason $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _schemaSyncInProgress = false;
      if (_queuedSchemaSync && mounted) {
        _queuedSchemaSync = false;
        unawaited(
          _syncSchema(
            applyIfUnauthenticated: applyIfUnauthenticated,
            reason: '${reason}_queued',
            forceFull: forceFull,
          ),
        );
      }
    }
  }

  /// Pull-to-refresh always requests a full live auth schema (forceFull).
  Future<void> _pullRefreshAuthSchema() async {
    final current = _state;
    if (current == null) {
      await _load(true);
      return;
    }

    try {
      await _syncSchema(
        applyIfUnauthenticated: true,
        reason: 'pull_refresh',
        forceFull: true,
      );
    } catch (error, stackTrace) {
      debugPrint('[AUTH][PULL_REFRESH] $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _replaceState(Map<String, dynamic> schema) async {
    final next = AuthState(schema);
    try {
      await next.restoreSession();
    } catch (sessionError) {
      debugPrint('[AUTH][GATE] Replace state session restore error: $sessionError');
    }

    if (!mounted) {
      next.dispose();
      return;
    }

    final old = _state;
    setState(() {
      _state = next;
      _error = null;
      _loading = false;
    });
    old?.dispose();
  }

  int? _schemaRevision(Map<String, dynamic> schema) {
    final raw = schema['revision'] ?? schema['schemaRevision'];
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString().trim() ?? '');
  }

  String? _schemaHash(Map<String, dynamic> schema) {
    for (final raw in <dynamic>[
      schema['contentHash'],
      schema['content_hash'],
      schema['schema_hash'],
    ]) {
      final value = raw?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  bool _revalidateOnForeground(Map<String, dynamic> schema) {
    final rawPolicy = schema['cachePolicy'];
    if (rawPolicy is! Map) return false;
    final rawSchemaPolicy = rawPolicy['schema'];
    if (rawSchemaPolicy is! Map) return false;
    final raw = rawSchemaPolicy['revalidateOn'];
    if (raw is! List) return false;
    return raw.any(
      (value) => value.toString().trim().toLowerCase() == 'app_foreground',
    );
  }

  Future<void> _resetAndReload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AuthSecureStorage().clearSession();
      await AppCacheManager.clearAllOnLogout();
    } catch (e) {
      debugPrint('[AUTH][GATE] Reset error: $e');
    }
    await _load(true);
  }

  String _friendlyErrorMessage(String rawError) {
    final lower = rawError.toLowerCase();
    if (lower.contains('badpadding') ||
        lower.contains('bad_decrypt') ||
        lower.contains('keystore') ||
        lower.contains('cipher') ||
        lower.contains('platformexception')) {
      return 'The saved login credentials on this device cannot be decrypted (often caused by an Android update or device security change).\n\n'
          'To resolve this: Tap "Reset Cache & Re-login" below to reset your local credentials and sign in fresh.';
    }
    if (lower.contains('socket') ||
        lower.contains('timeout') ||
        lower.contains('network') ||
        lower.contains('connection') ||
        lower.contains('failed host lookup')) {
      return 'Unable to connect to the authentication server.\n\n'
          'To resolve this: Check your Wi-Fi or mobile data connection and tap "Retry Connection".';
    }
    return 'An unexpected issue occurred while starting the authentication service.\n\n'
        'To resolve this: Tap "Retry Connection" to try again, or tap "Reset Cache & Re-login" to start fresh.';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _schemaInvalidationSubscription?.cancel();
    _cloudConnectionSubscription?.cancel();
    _state?.dispose();
    _repository.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _state == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFF0D121C),
          body: SizedBox.expand(),
        ),
      );
    }

    if (_error != null && _state == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF6750A4),
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SchemaPullToRefresh(
            fillViewport: true,
            onRefresh: _pullRefreshAuthSchema,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Colors.red.withAlpha(25),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.shield_outlined,
                        size: 36,
                        color: Colors.redAccent,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Startup Issue',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.3,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _friendlyErrorMessage(_error!),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Color(0xFF4A5568),
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        onPressed: () => _load(true),
                        label: const Text('Retry Connection'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.cleaning_services_rounded, size: 20),
                        onPressed: _resetAndReload,
                        label: const Text('Reset Cache & Re-login'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final state = _state!;

    if (!state.isAuthenticated &&
        _pendingAuthSchemaRefresh &&
        !_pendingRefreshScheduled) {
      _pendingRefreshScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _pendingAuthSchemaRefresh = false;
        try {
          // The WebSocket-triggered revalidation already updated the cache.
          // Load the validated cached publication instead of downloading the
          // complete schema again.
          await _load(false);
        } finally {
          _pendingRefreshScheduled = false;
        }
      });
    }

    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final textTheme = _authTextTheme(state);

        if (state.isAuthenticated) {
          // Keep the authenticated application inside a MaterialApp.
          return MaterialApp(
            title: state.schema['app']?['name']?.toString() ?? '',
            debugShowCheckedModeBanner: false,
            navigatorKey: IncomingCallService.instance.navigatorKey,
            theme: ThemeData(
              useMaterial3: true,
              splashFactory: InkRipple.splashFactory,
              textTheme: textTheme,
            ),
            home: widget.authenticatedBuilder(context, state),
          );
        }

        return MaterialApp(
          title: state.schema['app']?['name']?.toString() ?? '',
          debugShowCheckedModeBanner: false,
          navigatorKey: IncomingCallService.instance.navigatorKey,
          theme: ThemeData(
            useMaterial3: true,
            splashFactory: InkRipple.splashFactory,
            textTheme: textTheme,
          ),
          home: AuthRenderer(
            state,
            onPullRefresh: _pullRefreshAuthSchema,
          ).build(context),
        );
      },
    );
  }

  TextTheme? _authTextTheme(AuthState state) {
    final family = state.schema['theme']?['typography']?['fontFamily']
        ?.toString()
        .split(',')
        .first
        .trim();

    if (family == null || family.isEmpty) return null;

    try {
      return GoogleFonts.getTextTheme(family);
    } catch (error) {
      debugPrint('[AUTH][FONT] Could not resolve "$family": $error');
      return null;
    }
  }
}
