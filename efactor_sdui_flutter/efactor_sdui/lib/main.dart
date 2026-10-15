import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'auth_sdui/auth_gate.dart';
import 'auth_sdui/auth_state.dart';
import 'home_sdui/dynamic_home_sdui_page.dart';
import 'iot_sdui/dynamic_iot_sdui_page.dart';
import 'iot_sdui/iot_schema_repository.dart';
import 'grid_sdui/dynamic_grid_sdui_page.dart';
import 'grid_sdui/grid_offline_outbox_service.dart';
import 'device_sdui/device_ui_screen.dart';
import 'package:google_fonts/google_fonts.dart';

import 'services/app_cache_manager.dart';
import 'services/efactor_cloud_service.dart';
import 'services/incoming_call_service.dart';
import 'services/location_startup_gate.dart';
import 'services/push_notification_bootstrap.dart';
import 'services/schema_prefetch.dart';
import 'services/user_location_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        // ignore: avoid_print
        print(message);
      }
    };
    // ignore: avoid_print
    print('[Efactor] MAIN_STARTED_AUTH_INTEGRATED_BUILD');
  } else {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  EfactorCloudService.instance.configureLogs();

  runApp(
    const LocationStartupGate(
      child: AuthUiGate(authenticatedBuilder: _buildAuthenticatedFlow),
    ),
  );

  // Initialize push notifications and offline outbox sync asynchronously.
  unawaited(PushNotificationBootstrap.instance.initialize());
  unawaited(GridOfflineOutboxService.instance.initialize());
}

Widget _buildAuthenticatedFlow(BuildContext context, AuthState authState) {
  return AuthenticatedHomeGate(authState: authState);
}

/// Temporary post-authentication bridge:
/// Home -> selected model -> existing DeviceConnectionGate -> dynamic SDUI.
class AuthenticatedHomeGate extends StatefulWidget {
  const AuthenticatedHomeGate({super.key, required this.authState});

  final AuthState authState;

  @override
  State<AuthenticatedHomeGate> createState() => _AuthenticatedHomeGateState();
}

class _AuthenticatedHomeGateState extends State<AuthenticatedHomeGate> {
  String? _initializedToken;

  @override
  void initState() {
    super.initState();
    _syncAuthenticatedServices();
  }

  @override
  void didUpdateWidget(covariant AuthenticatedHomeGate oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.authState.accessToken != widget.authState.accessToken) {
      _syncAuthenticatedServices();
    }
  }

  Future<void> _syncAuthenticatedServices() async {
    final token = widget.authState.accessToken?.trim() ?? '';

    if (token.isEmpty || token == _initializedToken) {
      return;
    }

    final email = widget.authState.read('auth.email')?.toString().trim();

    final username = widget.authState.read('auth.username')?.toString().trim();

    final identity = email != null && email.isNotEmpty ? email : username;

    if (!mounted) return;

    _initializedToken = token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startAuthenticatedBackground(token, identity));
    });
  }

  Future<void> _startAuthenticatedBackground(
    String token,
    String? identity,
  ) async {
    await EfactorCloudService.instance.initialize(
      accessToken: token,
      username: identity,
    );
    await prefetchAuthenticatedSchemas(
      accessToken: token,
      userId: _authenticatedUserId(),
    );

    final uid = _authenticatedUserId()?.toString() ?? '';
    if (uid.isNotEmpty) {
      // Permission + FCM token + backend register (no-ops if Firebase missing).
      unawaited(
        PushNotificationBootstrap.instance.ensureTokenSynced(
          userId: uid,
          accessToken: token,
        ),
      );
    }

    // Report current user location and device metadata on session establishment.
    unawaited(UserLocationService.instance.sendCurrentLocation());
  }

  int? _authenticatedUserId() {
    final rawCandidates = <dynamic>[
      widget.authState.read('auth.userId'),
      widget.authState.read('auth.user_id'),
      widget.authState.read('auth.id'),
    ];

    for (final raw in rawCandidates) {
      if (raw is num) {
        return raw.toInt();
      }

      final parsed = int.tryParse(raw?.toString().trim() ?? '');

      if (parsed != null) {
        return parsed;
      }
    }

    return null;
  }

  List<String>? _authenticatedRoles() {
    final rawCandidates = <dynamic>[
      widget.authState.read('auth.roles'),
      widget.authState.read('auth.role'),
      widget.authState.read('auth.userType'),
      widget.authState.read('auth.user_type'),
    ];

    for (final raw in rawCandidates) {
      if (raw is List) {
        final roles = raw
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false);

        if (roles.isNotEmpty) {
          return roles;
        }
      }

      final single = raw?.toString().trim();

      if (single != null && single.isNotEmpty) {
        return <String>[single.toLowerCase()];
      }
    }

    return null;
  }

  String? _authenticatedEmail() {
    final raw = widget.authState.read('auth.email')?.toString().trim();

    return raw == null || raw.isEmpty ? null : raw;
  }

  String? _authenticatedUsername() {
    final raw = widget.authState.read('auth.username')?.toString().trim();

    return raw == null || raw.isEmpty ? null : raw;
  }

  @override
  Widget build(BuildContext context) {
    return DynamicHomeSduiPage(
      accessToken: widget.authState.accessToken ?? '',
      refreshToken: widget.authState.refreshToken,
      userId: _authenticatedUserId(),
      email: _authenticatedEmail(),
      username: _authenticatedUsername(),
      roles: _authenticatedRoles(),
      onLogout: () async {
        final currentUserId = _authenticatedUserId();
        final currentToken = widget.authState.accessToken;
        await IncomingCallService.instance.unregisterDeviceTokenOnLogout(
          userId: currentUserId?.toString(),
          accessToken: currentToken,
        );
        await AppCacheManager.clearAllOnLogout(
          userId: currentUserId,
          accessToken: currentToken,
        );
        await widget.authState.clearSession();
      },
      onOpenDevice: ({
        required String modelId,
        required String nodeId,
        bool? online,
      }) async {
        SchemaLoadQueue.instance.prioritizeDevice(
          modelId: modelId,
          nodeId: nodeId,
        );
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (deviceContext) => DeviceUiScreen(
              modelId: modelId,
              nodeId: nodeId,
              accessToken: widget.authState.accessToken ?? '',
              initialOnline: online,
              onAuthenticationFailure: () async {
                final currentUserId = _authenticatedUserId();
                final currentToken = widget.authState.accessToken;
                await AppCacheManager.clearAllOnLogout(
                  userId: currentUserId,
                  accessToken: currentToken,
                );
                await widget.authState.clearSession();
              },
              onDisconnect: () {
                if (Navigator.of(deviceContext).canPop()) {
                  Navigator.of(deviceContext).pop();
                }
              },
            ),
          ),
        );
      },
      onOpenGrid: () async {
        final token = widget.authState.accessToken?.trim() ?? '';
        if (token.isEmpty) {
          throw StateError(
            'Cannot open Grid because the authenticated access token is empty.',
          );
        }
        SchemaLoadQueue.instance.prioritizeGrid(
          accessToken: token,
          userId: _authenticatedUserId(),
        );

        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => DynamicGridSduiPage(
              accessToken: token,
              userId: _authenticatedUserId(),
            ),
          ),
        );
      },
      onOpenIot: () async {
        final token = widget.authState.accessToken?.trim() ?? '';
        if (token.isEmpty) {
          throw StateError(
            'Cannot open IoT because the authenticated access token is empty.',
          );
        }
        SchemaLoadQueue.instance.prioritizeIot(accessToken: token);

        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => DynamicIotSduiPage(
              accessToken: token,
              source: IotSchemaSource.fromEnvironment(),
              onOpenDevice: ({
                required String modelId,
                required String nodeId,
                bool? online,
              }) async {
                SchemaLoadQueue.instance.prioritizeDevice(
                  modelId: modelId,
                  nodeId: nodeId,
                );
                await Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (deviceContext) => DeviceUiScreen(
                      modelId: modelId,
                      nodeId: nodeId,
                      accessToken: widget.authState.accessToken ?? '',
                      initialOnline: online,
                      onAuthenticationFailure: () async {
                        await EfactorCloudService.instance.disconnect();
                        await widget.authState.clearSession();
                      },
                      onDisconnect: () {
                        if (Navigator.of(deviceContext).canPop()) {
                          Navigator.of(deviceContext).pop();
                        }
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// First screen shown before the dynamic Device SDUI.
///
/// The model can now be prefilled by the temporary Home.
/// NODE_ID is still entered here because no node-selection backend contract
/// has been supplied yet.
class DeviceConnectionGate extends StatefulWidget {
  const DeviceConnectionGate({
    super.key,
    this.initialModelId = '',
    required this.accessToken,
    required this.onAuthenticationFailure,
    this.onBackToHome,
  });

  final String initialModelId;
  final String accessToken;
  final Future<void> Function() onAuthenticationFailure;
  final VoidCallback? onBackToHome;

  @override
  State<DeviceConnectionGate> createState() => _DeviceConnectionGateState();
}

class _DeviceConnectionGateState extends State<DeviceConnectionGate> {
  String? _modelId;
  String? _nodeId;

  void _connect({required String modelId, required String nodeId}) {
    if (widget.accessToken.isNotEmpty &&
        !EfactorCloudService.instance.cloudConnected) {
      unawaited(
        EfactorCloudService.instance.initialize(
          accessToken: widget.accessToken,
        ),
      );
    }
    setState(() {
      _modelId = modelId.trim();
      _nodeId = nodeId.trim();
    });
  }

  void _disconnect() {
    setState(() {
      _modelId = null;
      _nodeId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final modelId = _modelId;
    final nodeId = _nodeId;

    if (modelId == null || nodeId == null) {
      return ConnectionEntryApp(
        initialModelId: modelId ?? widget.initialModelId,
        initialNodeId: nodeId ?? '',
        onConnect: _connect,
        onBack: widget.onBackToHome,
      );
    }

    return DeviceUiScreen(
      modelId: modelId,
      nodeId: nodeId,
      accessToken: widget.accessToken,
      onAuthenticationFailure: widget.onAuthenticationFailure,
      onDisconnect: _disconnect,
    );
  }
}

class ConnectionEntryApp extends StatelessWidget {
  const ConnectionEntryApp({
    super.key,
    required this.initialModelId,
    required this.initialNodeId,
    required this.onConnect,
    this.onBack,
  });

  final String initialModelId;
  final String initialNodeId;
  final void Function({required String modelId, required String nodeId})
      onConnect;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Device Connection',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        splashFactory: InkRipple.splashFactory,
        textTheme: GoogleFonts.poppinsTextTheme(),
      ),
      home: ConnectionEntryScreen(
        initialModelId: initialModelId,
        initialNodeId: initialNodeId,
        onConnect: onConnect,
        onBack: onBack,
      ),
    );
  }
}

class ConnectionEntryScreen extends StatefulWidget {
  const ConnectionEntryScreen({
    super.key,
    required this.initialModelId,
    required this.initialNodeId,
    required this.onConnect,
    this.onBack,
  });

  final String initialModelId;
  final String initialNodeId;
  final void Function({required String modelId, required String nodeId})
      onConnect;
  final VoidCallback? onBack;

  @override
  State<ConnectionEntryScreen> createState() => _ConnectionEntryScreenState();
}

class _ConnectionEntryScreenState extends State<ConnectionEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _modelController;
  late final TextEditingController _nodeController;

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(text: widget.initialModelId);
    _nodeController = TextEditingController(text: widget.initialNodeId);
  }

  @override
  void dispose() {
    _modelController.dispose();
    _nodeController.dispose();
    super.dispose();
  }

  String? _requiredValue(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required';
    }
    return null;
  }

  void _submit() {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    widget.onConnect(
      modelId: _modelController.text,
      nodeId: _nodeController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Card(
                elevation: 0,
                color: scheme.surfaceContainerLowest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.onBack != null) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: IconButton(
                              tooltip: 'Back to Home',
                              onPressed: widget.onBack,
                              icon: const Icon(Icons.arrow_back_rounded),
                            ),
                          ),
                          const SizedBox(height: 6),
                        ],
                        Icon(
                          Icons.hub_outlined,
                          size: 54,
                          color: scheme.primary,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Connect Device',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Enter the model and node identifiers '
                          'to load the live schema.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 28),
                        TextFormField(
                          controller: _modelController,
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'ENTER MODEL_ID',
                            hintText: 'Model ID',
                            prefixIcon: Icon(Icons.devices_other),
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              _requiredValue(value, 'MODEL_ID'),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _nodeController,
                          textInputAction: TextInputAction.done,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'ENTER NODE_ID',
                            hintText: 'Node ID',
                            prefixIcon: Icon(Icons.memory_outlined),
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              _requiredValue(value, 'NODE_ID'),
                          onFieldSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 22),
                        FilledButton(
                          onPressed: _submit,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                          child: const Text(
                            'CONNECT',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
