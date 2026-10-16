import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:efactor_provisioning/efactor_provisioning.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sdui/icons.dart';
import '../sdui/schema_guard.dart';
import '../sdui/schema_pull_to_refresh.dart';
import '../services/efactor_cloud_service.dart';
import '../state/app_state.dart';
import 'wifi_native_service.dart';

class DynamicWifiSduiPage extends StatefulWidget {
  const DynamicWifiSduiPage({
    super.key,
    required this.state,
    required this.action,
  });

  final AppState state;
  final Map<String, dynamic> action;

  @override
  State<DynamicWifiSduiPage> createState() => _DynamicWifiSduiPageState();
}

class _DynamicWifiSduiPageState extends State<DynamicWifiSduiPage> {
  final WifiNativeService _native = WifiNativeService.instance;
  final EfactorProvision _provision = EfactorProvision.instance;
  final EfactorCloud _cloud = EfactorCloud.instance;
  final TextEditingController _passwordController = TextEditingController();
  bool _showPassword = false;

  StreamSubscription<EfProvisioningEvent>? _provisionSubscription;
  StreamSubscription<EfCloudEvent>? _cloudSubscription;

  late final Map<String, dynamic> _contract;
  late final Map<String, Map<String, dynamic>> _screens;

  String _screenId = '';
  bool _busy = false;
  bool _onlineConfirmed = false;
  String? _errorCode;
  String? _errorMessage;

  List<WifiRuntimeNetwork> _networks = const <WifiRuntimeNetwork>[];
  WifiRuntimeNetwork? _selectedRouter;
  WifiRuntimeNetwork? _deviceSoftAp;

  String _stage = 'idle';
  int _stageIndex = 0;
  final Set<String> _enteredScreens = <String>{};
  final List<String> _screenHistory = <String>[];
  bool _provisionCancelled = false;
  String? _cloudConfirmedNodeId;
  bool _cloudConnected = false;
  bool _networkQuiescedForProvision = false;

  // iOS-only continuous retry tracking for provisioning start
  static const int _kMaxProvisionAttempts = 5;
  bool _isRetryingIosProvision = false;
  int _iosProvisionAttempt = 0;
  Timer? _iosRetryTimer;
  Map<String, String>? _lastProvisionParams;

  @override
  void initState() {
    super.initState();

    final raw = widget.state.schema['wifiProvisioning'];
    if (raw is! Map) {
      _contract = const <String, dynamic>{};
      _screens = const <String, Map<String, dynamic>>{};
      return;
    }

    _contract = Map<String, dynamic>.from(raw);
    _screens = <String, Map<String, dynamic>>{
      for (final item in (_contract['screens'] as List? ?? const <dynamic>[]))
        if (item is Map && item['id'] != null)
          item['id'].toString(): Map<String, dynamic>.from(item),
    };

    final entry = _contract['entryScreen']?.toString().trim() ?? '';
    _screenId = entry.isNotEmpty
        ? entry
        : (_screens.isEmpty ? '' : _screens.keys.first);

    _provisionSubscription = _provision.events.listen(_onProvisionEvent);
    _cloudSubscription = _cloud.events.listen(_onCloudEvent);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreSavedWifi());
      unawaited(_prepareIosWifiEnvironment());
      _runOnEnterIfNeeded();
    });
  }

  Future<void> _restoreSavedWifi() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSsid = prefs.getString('efactor_saved_wifi_ssid')?.trim() ?? '';
      final savedPass = prefs.getString('efactor_saved_wifi_pass') ?? '';

      if (savedPass.isNotEmpty && _passwordController.text.isEmpty) {
        _passwordController.text = savedPass;
      }

      if (savedSsid.isNotEmpty) {
        if (_networks.any((n) => n.ssid == savedSsid)) {
          _selectedRouter = _networks.firstWhere((n) => n.ssid == savedSsid);
        } else if (_networks.isEmpty) {
          _networks = <WifiRuntimeNetwork>[
            WifiRuntimeNetwork(
              ssid: savedSsid,
              bssid: '',
              rssi: -50,
              frequency: 2412,
              securityLabel: 'WPA2',
              security: 'WPA2',
              isOpen: false,
            ),
          ];
          _selectedRouter = _networks.first;
        }
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('[SDUI][WiFi] restore saved wifi error: $e');
    }
  }

  Future<void> _persistLastWifi(String ssid, [String? password]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ssid.trim().isNotEmpty) {
        await prefs.setString('efactor_saved_wifi_ssid', ssid.trim());
      }
      if (password != null && password.isNotEmpty) {
        await prefs.setString('efactor_saved_wifi_pass', password);
      }
    } catch (e) {
      debugPrint('[SDUI][WiFi] persist wifi error: $e');
    }
  }

  /// iOS SoftAP sessions talk to `http://192.168.4.1`. That requires Location
  /// (SSID/Hotspot) and Local Network permission *before* the native library
  /// opens the session — otherwise it fails with "couldn't create session".
  Future<void> _prepareIosWifiEnvironment() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _ensureWifiPermission(interactive: false);
      await _native.primeLocalNetworkAccess();
    } catch (error) {
      debugPrint('[SDUI][WiFi][iOS] environment prime failed: $error');
    }
  }

  @override
  void dispose() {
    _provisionCancelled = true;
    _isRetryingIosProvision = false;
    _iosRetryTimer?.cancel();
    _passwordController.dispose();
    _provisionSubscription?.cancel();
    _cloudSubscription?.cancel();
    _provision.cancel().catchError((_) {});
    _native.disconnectDeviceSoftAp().catchError((_) {});
    if (_networkQuiescedForProvision) {
      unawaited(_resumeNetworkAfterProvisioning());
    }
    super.dispose();
  }

  /// Pull-to-refresh: Wi‑Fi has no separate schema API — reload the live
  /// device schema via the host callback (`forceRefresh: true` upstream).
  Future<void> _refreshLiveSchema() async {
    if (_busy) return;
    final refresh = widget.state.onPostProvisionRefresh;
    if (refresh == null) return;
    await refresh();
  }

  Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  Map<String, dynamic> _capability(String name) {
    final capabilities = _map(_contract['nativeCapabilities']);
    return _map(capabilities[name]);
  }

  Map<String, dynamic> _theme() {
    final scoped = _map(_contract['theme']);
    if (scoped.isNotEmpty) return scoped;
    return _map(widget.state.schema['theme']);
  }

  Map<String, dynamic> _deepMergeMaps(
    Map<String, dynamic> base,
    Map<String, dynamic> override,
  ) {
    final result = Map<String, dynamic>.from(base);
    for (final entry in override.entries) {
      final current = result[entry.key];
      final incoming = entry.value;
      if (current is Map && incoming is Map) {
        result[entry.key] = _deepMergeMaps(
          Map<String, dynamic>.from(current),
          Map<String, dynamic>.from(incoming),
        );
      } else {
        result[entry.key] = incoming;
      }
    }
    return result;
  }

  Map<String, dynamic> _resolveReferenceMap(dynamic rawRef) {
    final ref = rawRef?.toString().trim() ?? '';
    if (ref.isEmpty) return const <String, dynamic>{};

    var path = ref;
    if (path.startsWith(r'$.')) path = path.substring(2);
    if (path.startsWith('wifiProvisioning.')) {
      path = path.substring('wifiProvisioning.'.length);
    }

    final resolved = _readPath(_contract, path);
    return _map(resolved);
  }

  Map<String, dynamic> _resolveComponentStyle(Map<String, dynamic> component) {
    final referenced = _resolveReferenceMap(component['styleRef']);
    final direct = _map(component['style']);
    return _deepMergeMaps(referenced, direct);
  }

  Alignment _schemaAlignment(dynamic raw, Alignment fallback) {
    switch (raw?.toString()) {
      case 'topLeft':
        return Alignment.topLeft;
      case 'topCenter':
        return Alignment.topCenter;
      case 'topRight':
        return Alignment.topRight;
      case 'centerLeft':
        return Alignment.centerLeft;
      case 'center':
        return Alignment.center;
      case 'centerRight':
        return Alignment.centerRight;
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottomCenter':
        return Alignment.bottomCenter;
      case 'bottomRight':
        return Alignment.bottomRight;
      default:
        return fallback;
    }
  }

  Gradient? _schemaGradient(dynamic raw) {
    final map = _map(raw);
    if (map.isEmpty) return null;
    final colors = (map['colors'] as List? ?? const <dynamic>[])
        .map(_color)
        .whereType<Color>()
        .toList(growable: false);
    if (colors.length < 2) return null;
    return LinearGradient(
      begin: _schemaAlignment(map['begin'], Alignment.topCenter),
      end: _schemaAlignment(map['end'], Alignment.bottomCenter),
      colors: colors,
    );
  }

  Widget _wifiIcon(String? name, {double size = 18, Color? color}) {
    final resolvedName = name?.trim() ?? '';
    if (resolvedName.isEmpty) return const SizedBox.shrink();
    final effectiveColor = color ??
        _color(_map(_theme()['colors'])['accent']) ??
        Theme.of(context).colorScheme.primary;
    return SduiIcon(
      schema: widget.state.schema,
      name: resolvedName,
      size: size,
      color: effectiveColor,
    );
  }

  dynamic _runtimeValue(String name) {
    final identity = widget.state.resolveDeviceIdentity();
    final input = _map(_map(_contract['runtimeInputs'])[name]);
    final source = input['source']?.toString();

    if (name == 'nodeId' || source == '_clientConnection.nodeId') {
      return identity.nodeId;
    }
    if (name == 'devicePop') {
      if (input['policy']?.toString() == 'sameAsNodeId' ||
          source == '_clientConnection.nodeId') {
        return identity.nodeId;
      }
    }
    if (name == 'accessToken' || source == 'authenticatedSession.accessToken') {
      return widget.state.accessToken;
    }
    if (name == 'userId' ||
        name == 'userName' ||
        name == 'username' ||
        source == 'authenticatedSession.userId' ||
        source == 'authenticatedSession.emailOrUsername') {
      // Delivery client_test / native lib expect JWT custom:user_id.
      return _userIdFromJwt(widget.state.accessToken);
    }
    return null;
  }

  /// Matches efactor_client_test: plugin expects JWT `custom:user_id` / `user_id`.
  String _userIdFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return '';
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final map = jsonDecode(payload);
      if (map is! Map) return '';
      return (map['custom:user_id'] ?? map['user_id'] ?? '').toString().trim();
    } catch (_) {
      return '';
    }
  }

  dynamic _resolveRuntimeExpression(dynamic raw) {
    if (raw is! String) return raw;
    final value = raw.trim();
    if (value.startsWith(r'$runtime.')) {
      return _runtimeValue(value.substring(r'$runtime.'.length));
    }
    if (value == r'$state.wifiProvisioning.selectedRouter.ssid') {
      return _selectedRouter?.ssid;
    }
    if (value == r'$state.wifiProvisioning.selectedRouter.securityLabel') {
      return _selectedRouter?.securityLabel;
    }
    if (value == r'$state.wifiProvisioning.routerPassword') {
      return _selectedRouter?.isOpen == true ? '' : _passwordController.text;
    }
    if (value == r'$state.wifiProvisioning.selectedDeviceSoftAp.ssid') {
      return _deviceSoftAp?.ssid;
    }
    return raw;
  }

  String? _capabilityMethod(String capability) {
    final config = _capability(capability);
    final method = config['method']?.toString().trim() ?? '';
    return method.isEmpty ? null : method;
  }

  double _progressPercent() {
    final progress = _contract['progressMap'] as List? ?? const <dynamic>[];
    if (progress.isEmpty) return 0;
    final maxIndex = progress
        .whereType<Map>()
        .map((item) => (item['stageIndex'] as num?)?.toInt() ?? 0)
        .fold<int>(0, (a, b) => a > b ? a : b);
    if (maxIndex <= 0) return 0;
    return (_stageIndex / maxIndex).clamp(0.0, 1.0) * 100.0;
  }

  dynamic _readPath(dynamic root, String path) {
    var clean = path.trim();
    if (clean.startsWith(r'$.')) clean = clean.substring(2);
    if (clean.startsWith(r'$')) clean = clean.substring(1);
    if (clean.startsWith('{') && clean.endsWith('}')) {
      clean = clean.substring(1, clean.length - 1);
    }

    dynamic current = root;
    for (final part in clean.split('.').where((part) => part.isNotEmpty)) {
      if (current is! Map) return null;
      current = current[part];
    }
    return current;
  }

  dynamic _resolveSchemaValue(dynamic value) {
    if (value is! String) return value;
    final text = value.trim();
    if (text.startsWith('{') && text.endsWith('}')) {
      return _readPath(widget.state.schema, text);
    }
    return value;
  }

  Color? _color(dynamic value) {
    final resolved = _resolveSchemaValue(value);
    if (resolved is! String) return null;
    var hex = resolved.trim().replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final parsed = int.tryParse(hex, radix: 16);
    return parsed == null ? null : Color(parsed);
  }

  double _number(dynamic value, double fallback) {
    final resolved = _resolveSchemaValue(value);
    return resolved is num
        ? resolved.toDouble()
        : double.tryParse(resolved?.toString() ?? '') ?? fallback;
  }

  String? _flowScreen(String key) {
    final flow = _map(_contract['flow']);
    final value = flow[key]?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }

  String? _screenTarget(Map<String, dynamic>? action, String key) {
    final value = action?[key]?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }

  String? _currentOnEnterTarget(String key) {
    final screen = _screens[_screenId];
    final onEnter = _map(screen?['onEnter']);
    return _screenTarget(onEnter, key);
  }

  Future<void> _ensureWifiPermission({bool interactive = true}) async {
    final isApple = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;

    if (isApple) {
      // 1. Direct query of native CLLocationManager via Geolocator.
      // This bypasses CocoaPods stubbing and succeeds immediately if the user
      // has already granted location permission in iPhone Settings.
      var geoStatus = await geo.Geolocator.checkPermission();
      if (geoStatus == geo.LocationPermission.whileInUse ||
          geoStatus == geo.LocationPermission.always) {
        return;
      }

      // In silent/background preparation, do not show popups or interrupt
      if (!interactive) return;

      // 2. If permanently denied in Settings, show an in-app dialog directing the user to Settings
      if (geoStatus == geo.LocationPermission.deniedForever) {
        if (!mounted) {
          throw StateError(
            'Location permission is required on iOS to configure device Wi‑Fi. Please enable "While Using the App" in Settings.',
          );
        }
        final openSettings = await _showLocationPermissionDialog(isPermanentlyDenied: true);
        if (openSettings) {
          await geo.Geolocator.openAppSettings();
        }
        throw const _WifiFlowCancelled();
      }

      // 3. Status is denied (not yet prompted). Present polite in-app pop-up rationale before triggering system prompt
      if (!mounted) return;
      final userAgreed = await _showLocationPermissionDialog(isPermanentlyDenied: false);
      if (!userAgreed) {
        throw const _WifiFlowCancelled();
      }

      // 4. User accepted our pop-up: trigger native iOS permission request
      geoStatus = await geo.Geolocator.requestPermission();
      try {
        await Permission.locationWhenInUse.request();
      } catch (_) {}

      if (geoStatus == geo.LocationPermission.whileInUse ||
          geoStatus == geo.LocationPermission.always) {
        return; // Granted! Proceed smoothly
      }

      if (geoStatus == geo.LocationPermission.deniedForever) {
        if (mounted) {
          final openSettings = await _showLocationPermissionDialog(isPermanentlyDenied: true);
          if (openSettings) {
            await geo.Geolocator.openAppSettings();
          }
        }
        throw const _WifiFlowCancelled();
      }

      throw StateError(
        'Location permission is required by Apple iOS to read the Wi‑Fi network and provision your eFactor device.',
      );
    }

    // Android: Check permission first
    final locStatus = await Permission.locationWhenInUse.status;
    if (locStatus.isGranted) {
      try {
        final android = await DeviceInfoPlugin().androidInfo;
        if (android.version.sdkInt >= 33) {
          await Permission.nearbyWifiDevices.request();
        }
      } catch (_) {}
      return;
    }

    if (!interactive) return;

    if (locStatus.isPermanentlyDenied) {
      if (!mounted) {
        throw StateError(
          'Location permission is required to detect nearby Wi‑Fi networks on Android.',
        );
      }
      final openSettings = await _showLocationPermissionDialog(isPermanentlyDenied: true);
      if (openSettings) {
        unawaited(openAppSettings());
      }
      throw const _WifiFlowCancelled();
    }

    if (!mounted) return;
    final userAgreed = await _showLocationPermissionDialog(isPermanentlyDenied: false);
    if (!userAgreed) {
      throw const _WifiFlowCancelled();
    }

    final newLocStatus = await Permission.locationWhenInUse.request();
    if (!newLocStatus.isGranted) {
      if (newLocStatus.isPermanentlyDenied && mounted) {
        final openSettings = await _showLocationPermissionDialog(isPermanentlyDenied: true);
        if (openSettings) {
          unawaited(openAppSettings());
        }
      }
      throw const _WifiFlowCancelled();
    }

    try {
      final android = await DeviceInfoPlugin().androidInfo;
      if (android.version.sdkInt >= 33) {
        await Permission.nearbyWifiDevices.request();
      }
    } catch (_) {}
  }

  Future<bool> _showLocationPermissionDialog({
    required bool isPermanentlyDenied,
  }) async {
    if (!mounted) return false;
    final isIos = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final theme = Theme.of(context);
    final platformName = isIos ? 'Apple iOS' : 'Android';
    final settingsPath = isIos
        ? 'Settings > Efactor IoE > Location > "While Using the App"'
        : 'Settings > Apps > Efactor > Permissions > Location';

    return (await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.near_me_rounded,
                  color: theme.colorScheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isPermanentlyDenied
                      ? 'Location Required'
                      : 'Location Permission',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                isPermanentlyDenied
                    ? 'Location access was turned off for this app.\n\n'
                      '$platformName requires location access to read the Wi‑Fi network and connect your eFactor device.\n\n'
                      'Please open Settings and set Location to "While Using the App".'
                    : '$platformName requires Location Permission to identify nearby Wi‑Fi networks and connect with your eFactor device during setup.\n\n'
                      'Your location data is only used locally for Wi‑Fi device provisioning and is never stored or tracked.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
              if (isPermanentlyDenied) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.settings_outlined,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          settingsPath,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                isPermanentlyDenied ? 'Open Settings' : 'Continue',
              ),
            ),
          ],
        );
      },
    )) ?? false;
  }

  Future<void> _runPrerequisites(Map<String, dynamic> screen) async {
    final prerequisites =
        (screen['prerequisites'] as List? ?? const <dynamic>[])
            .map((item) => item.toString())
            .where((item) => item.trim().isNotEmpty);

    for (final capability in prerequisites) {
      await _invokeCapability(capability, const <String, dynamic>{});
      if (_errorMessage != null) return;
    }
  }

  Future<void> _scanRouters() async {
    final config = _capability('scanRouterNetworks');
    final filter = _map(config['filter']);
    final frequency = _map(filter['frequencyMHz']);

    await _guardBusy(() async {
      await _ensureWifiPermission();

      List<WifiRuntimeNetwork> values = const <WifiRuntimeNetwork>[];
      try {
        values = await _native.scanRouterNetworks(
          excludeSsidPrefix: filter['excludeSsidPrefix']?.toString(),
          minFrequencyMHz: (frequency['min'] as num?)?.toInt(),
          maxFrequencyMHz: (frequency['max'] as num?)?.toInt(),
        );
      } catch (error) {
        debugPrint('[SDUI][WiFi] scanRouterNetworks error: $error');
        if (defaultTargetPlatform == TargetPlatform.iOS && _networks.isEmpty) {
          final manual = await _promptManualSsid(
            title: 'Enter home Wi‑Fi name',
            message: (error is PlatformException ? error.message : null) ??
                'Connect this iPhone to your home Wi‑Fi in Settings, or type '
                    'the network name (SSID) here.',
          );
          if (manual != null && manual.isNotEmpty) {
            values = <WifiRuntimeNetwork>[
              WifiRuntimeNetwork(
                ssid: manual,
                bssid: '',
                rssi: -50,
                frequency: 0,
                securityLabel: 'WPA2',
                security: 'WPA2',
                isOpen: false,
              ),
            ];
          }
        }
      }

      if (values.isEmpty && defaultTargetPlatform == TargetPlatform.iOS && _networks.isEmpty) {
        final manual = await _promptManualSsid(
          title: 'Enter home Wi‑Fi name',
          message:
              'iOS cannot list nearby networks. Type your home Wi‑Fi SSID, or '
              'join that network in Settings and retry.',
        );
        if (manual != null && manual.isNotEmpty) {
          values = <WifiRuntimeNetwork>[
            WifiRuntimeNetwork(
              ssid: manual,
              bssid: '',
              rssi: -50,
              frequency: 0,
              securityLabel: 'WPA2',
              security: 'WPA2',
              isOpen: false,
            ),
          ];
        }
      }

      // If scan found networks, preserve any existing selected/saved router if missing
      if (values.isNotEmpty) {
        final savedSsid = _selectedRouter?.ssid;
        if (savedSsid != null &&
            savedSsid.isNotEmpty &&
            !values.any((n) => n.ssid == savedSsid)) {
          values = <WifiRuntimeNetwork>[_selectedRouter!, ...values];
        }
      } else if (_networks.isNotEmpty) {
        values = _networks;
      }

      if (!mounted) return;
      setState(() {
        _networks = values;
        if (_selectedRouter != null) {
          final match = _networks.where((n) => n.ssid == _selectedRouter!.ssid).firstOrNull;
          if (match != null) _selectedRouter = match;
        } else if (_networks.isNotEmpty) {
          _selectedRouter = _networks.first;
        }
      });
    });
  }

  Future<void> _findDeviceSoftAp() async {
    final config = _capability('scanDeviceSoftAp');
    final filter = _map(config['filter']);
    final selection = _map(config['selection']);
    final identity = _map(_contract['identity']);

    await _guardBusy(() async {
      await _ensureWifiPermission();

      final expected = _readOptionalRuntimeString(const <List<String>>[
        <String>['state', 'wifiConfig', 'deviceSoftApSsid'],
        <String>['state', 'wifiConfig', 'softApSsid'],
        <String>['meta', 'provisioning', 'deviceSoftApSsid'],
      ]);

      final prefix = filter['ssidPrefix']?.toString() ??
          identity['softApPrefix']?.toString();
      final minimumRssiDbm = (selection['minimumRssiDbm'] as num?)?.toInt();

      WifiRuntimeNetwork device;

      if (expected != null && expected.trim().isNotEmpty) {
        // Backend/runtime supplied an exact SoftAP SSID. Use it directly.
        try {
          device = await _native.scanDeviceSoftAp(
            expectedSsid: expected.trim(),
            ssidPrefix: prefix,
            minimumRssiDbm: minimumRssiDbm,
          );
        } on PlatformException catch (error) {
          if (defaultTargetPlatform != TargetPlatform.iOS) rethrow;
          // Exact SSID is enough on iOS — native may still refuse without a scan.
          device = WifiRuntimeNetwork(
            ssid: expected.trim(),
            bssid: '',
            rssi: -50,
            frequency: 0,
            securityLabel: 'Open',
            security: 'Open',
            isOpen: true,
          );
          debugPrint(
            '[SDUI][WiFi][iOS] using schema SoftAP SSID despite scan error: '
            '${error.message}',
          );
        }
      } else {
        // No exact SSID is available. Ask native for matching provisioning
        // networks. Never allow the native bridge or Flutter to guess when more
        // than one physical eFactor device is in provisioning mode.
        List<WifiRuntimeNetwork> candidates;
        try {
          candidates = await _native.scanDeviceSoftApCandidates(
            ssidPrefix: prefix,
            minimumRssiDbm: minimumRssiDbm,
          );
        } on PlatformException catch (error) {
          if (defaultTargetPlatform != TargetPlatform.iOS) rethrow;
          candidates = const <WifiRuntimeNetwork>[];
          debugPrint(
            '[SDUI][WiFi][iOS] SoftAP candidate scan unavailable: '
            '${error.message}',
          );
        }

        if (candidates.isEmpty && defaultTargetPlatform == TargetPlatform.iOS) {
          final manual = await _promptManualSsid(
            title: 'Enter device Wi‑Fi name',
            message:
                'iOS cannot scan for SoftAP networks. Join the device Wi‑Fi'
                '${prefix == null || prefix.isEmpty ? '' : ' ("$prefix…")'}'
                ' in Settings → Wi‑Fi, or type the exact SoftAP SSID here.',
          );
          if (manual == null || manual.isEmpty) {
            throw StateError(
              'No matching eFactor provisioning network was found.',
            );
          }
          candidates = <WifiRuntimeNetwork>[
            WifiRuntimeNetwork(
              ssid: manual,
              bssid: '',
              rssi: -50,
              frequency: 0,
              securityLabel: 'Open',
              security: 'Open',
              isOpen: true,
            ),
          ];
        }

        if (candidates.isEmpty) {
          throw StateError(
            'No matching eFactor provisioning network was found.',
          );
        }

        if (candidates.length == 1) {
          device = candidates.first;
        } else {
          final chosen = await _chooseDeviceSoftAp(candidates);
          if (chosen == null) {
            throw const _WifiFlowCancelled();
          }
          device = chosen;
        }
      }

      // Discovery is verification/identity only. Do NOT create a second
      // WifiNetworkSpecifier connection here. The authoritative eFactor
      // provisioning library owns its createDevice -> connect/getcrds ->
      // provision sequence. A separate Flutter/native pre-connect can wait on
      // Android approval and prevent EfactorProvision.start() from ever being
      // called even though the EWIFI_* device is visible.
      if (!mounted) return;
      setState(() => _deviceSoftAp = device);
    });
  }

  Future<String?> _promptManualSsid({
    required String title,
    required String message,
  }) async {
    if (!mounted) return null;
    final controller = TextEditingController();
    try {
      return showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(message),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'SSID',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (value) =>
                      Navigator.of(dialogContext).pop(value.trim()),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text.trim()),
                child: const Text('Continue'),
              ),
            ],
          );
        },
      );
    } finally {
      // Dialog may outlive this frame; dispose after the route closes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
    }
  }

  Future<WifiRuntimeNetwork?> _chooseDeviceSoftAp(
    List<WifiRuntimeNetwork> candidates,
  ) async {
    if (!mounted) return null;

    return showDialog<WifiRuntimeNetwork>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Select your eFactor device'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 360),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: candidates.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, index) {
                final device = candidates[index];
                return ListTile(
                  leading: const Icon(Icons.wifi),
                  title: Text(device.ssid),
                  subtitle: Text('Signal ${device.rssi} dBm'),
                  onTap: () => Navigator.of(dialogContext).pop(device),
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _startProvisioning() async {
    final config = _capability('startProvisioning');
    final arguments = _map(config['arguments']);
    final nodeId = (_resolveRuntimeExpression(arguments['nodeId']) ??
                _runtimeValue('nodeId'))
            ?.toString()
            .trim() ??
        '';
    final pop = (_resolveRuntimeExpression(arguments['devicePop']) ??
                _runtimeValue('devicePop'))
            ?.toString()
            .trim() ??
        '';
    final token = (_resolveRuntimeExpression(arguments['accessToken']) ??
                _runtimeValue('accessToken'))
            ?.toString()
            .trim() ??
        '';
    final routerSsid = (_resolveRuntimeExpression(arguments['routerSsid']) ??
                _selectedRouter?.ssid)
            ?.toString()
            .trim() ??
        '';
    final password = (_resolveRuntimeExpression(arguments['routerPassword']) ??
                (_selectedRouter?.isOpen == true
                    ? ''
                    : _passwordController.text))
            ?.toString() ??
        '';

    if (nodeId.isEmpty) {
      throw StateError('Missing runtime Node ID.');
    }
    if (pop.isEmpty) {
      throw StateError('Missing runtime device POP.');
    }
    if (token.isEmpty) {
      throw StateError('Current authenticated access token is missing.');
    }
    final userName = (_resolveRuntimeExpression(arguments['userName']) ??
                _resolveRuntimeExpression(arguments['username']) ??
                _resolveRuntimeExpression(arguments['userId']) ??
                _runtimeValue('userName') ??
                _runtimeValue('username') ??
                _userIdFromJwt(token))
            ?.toString()
            .trim() ??
        '';
    if (userName.isEmpty) {
      throw StateError(
        'Missing cloud user id (JWT custom:user_id / user_id) required for '
        'device provisioning.',
      );
    }
    if (routerSsid.isEmpty) {
      throw StateError('A router must be selected before provisioning.');
    }
    // Do not require a Flutter-side SoftAP scan/selection before provisioning.
    // The authoritative eFactor library owns its device discovery/connection
    // sequence. Requiring _deviceSoftAp here can strand the UI forever on the
    // legacy schema deviceDiscovery screen even though the device is present.

    _provisionCancelled = false;

    await _guardBusy(() async {
      final progressMap =
          (_contract['progressMap'] as List? ?? const <dynamic>[]);
      final first = progressMap.whereType<Map>().cast<Map>().firstOrNull;
      final firstStage = first?['event']?.toString();

      setState(() {
        _stage = firstStage?.isNotEmpty == true ? firstStage! : _stage;
        _stageIndex = _stageIndexFor(_stage);
      });

      // Match efactor_client_test: clear stale SoftAP bindings, stop mDNS,
      // keep cloud online for getcrds, then hand SoftAP to the library.
      await _native.disconnectDeviceSoftAp().catchError((_) {});
      await _quiesceNetworkForProvisioning();

      await _ensureWifiPermission();
      unawaited(_persistLastWifi(routerSsid, password));

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _native.primeLocalNetworkAccess();
      }

      await _cloud.setProvisionStarted(true);

      debugPrint(
        '[SDUI][WiFi] provStart router=$routerSsid popLen=${pop.length} '
        'user=$userName platform=$defaultTargetPlatform '
        '(client_test-aligned iOS SoftAP path)',
      );

      _lastProvisionParams = <String, String>{
        'pop': pop,
        'token': token,
        'userName': userName,
        'routerSsid': routerSsid,
        'password': password,
      };

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        _isRetryingIosProvision = true;
        _iosProvisionAttempt = 0;
        await _executeProvisionStartWithIosRetry();
      } else {
        await _provision.start(
          pop: pop,
          apiKey: token,
          userName: userName,
          ssid: routerSsid,
          password: password,
          security: 'SEC1',
        );
      }
    }, keepBusyOnSuccess: true);
  }

  /// iOS-only automatic retry loop:
  /// Continually attempts to initiate provisioning until success or user cancellation.
  Future<void> _executeProvisionStartWithIosRetry() async {
    final params = _lastProvisionParams;
    if (params == null || !mounted || !_isRetryingIosProvision || _provisionCancelled) return;

    while (mounted && _isRetryingIosProvision && !_provisionCancelled) {
      if (_iosProvisionAttempt >= _kMaxProvisionAttempts) {
        debugPrint(
          '[SDUI][WiFi][iOS] Reached maximum provision attempts ($_kMaxProvisionAttempts). Stopping retries.',
        );
        _isRetryingIosProvision = false;
        _iosRetryTimer?.cancel();
        _busy = false;
        _errorCode = 'JOIN_FAILED_MAX_ATTEMPTS';
        _errorMessage = 'Could not join device network after $_kMaxProvisionAttempts attempts. Please verify the device is powered on and in setup mode, then try again.';
        if (mounted) setState(() {});
        final target = _currentOnEnterTarget('onFailureScreen') ??
            _flowScreen('errorScreen');
        if (target != null) _goTo(target);
        break;
      }

      _iosProvisionAttempt++;
      debugPrint(
        '[SDUI][WiFi][iOS] provStart attempt #$_iosProvisionAttempt of $_kMaxProvisionAttempts '
        'router=${params["routerSsid"]} popLen=${params["pop"]?.length}',
      );

      setState(() {
        _busy = true;
        _errorCode = null;
        _errorMessage = null;
        if (_iosProvisionAttempt > 1) {
          _stage = 'retrying';
        }
      });

      try {
        await _native.disconnectDeviceSoftAp().catchError((_) {});
        if (!mounted || !_isRetryingIosProvision || _provisionCancelled) break;
        await _ensureWifiPermission(interactive: false).catchError((_) {});
        if (!mounted || !_isRetryingIosProvision || _provisionCancelled) break;
        await _native.primeLocalNetworkAccess().catchError((_) {});
        if (!mounted || !_isRetryingIosProvision || _provisionCancelled) break;

        await _provision.start(
          pop: params['pop']!,
          apiKey: params['token']!,
          userName: params['userName']!,
          ssid: params['routerSsid']!,
          password: params['password']!,
          security: 'SEC1',
        );
        debugPrint(
          '[SDUI][WiFi][iOS] provStart method call initiated on attempt #$_iosProvisionAttempt of $_kMaxProvisionAttempts. '
          'Awaiting native events...',
        );
        break; // Successfully initiated; native events will drive progress
      } catch (error) {
        debugPrint(
          '[SDUI][WiFi][iOS] provStart threw on attempt #$_iosProvisionAttempt of $_kMaxProvisionAttempts: $error.',
        );
        if (!mounted ||
            !_isRetryingIosProvision ||
            _provisionCancelled ||
            _iosProvisionAttempt >= _kMaxProvisionAttempts) {
          _isRetryingIosProvision = false;
          _iosRetryTimer?.cancel();
          setState(() {
            _busy = false;
            _errorCode = 'JOIN_FAILED_MAX_ATTEMPTS';
            _errorMessage = 'Could not join device network after $_kMaxProvisionAttempts attempts. Please verify the device is powered on and in setup mode, then try again.';
          });
          final target = _currentOnEnterTarget('onFailureScreen') ??
              _flowScreen('errorScreen');
          if (target != null) _goTo(target);
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Password / setup: stop local mDNS discovery + SoftAP leftovers.
  /// Keep cloud connected so getcrds can run on home Wi‑Fi (and cellular
  /// fallback) — matching efactor_client_test / delivery README.
  Future<void> _quiesceNetworkForProvisioning() async {
    debugPrint('[SDUI][WiFi] stop discovery for SoftAP provisioning');
    await EfactorCloudService.instance.pauseForProvisioning(
      disconnectCloud: false,
    );
    await _cloud.setProvisionStarted(true).catchError((_) {});
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _ensureWifiPermission(interactive: false).catchError((_) {});
      await _native.primeLocalNetworkAccess();
    }
    _networkQuiescedForProvision = true;
  }

  Future<void> _resumeNetworkAfterProvisioning() async {
    if (!_networkQuiescedForProvision &&
        EfactorCloudService.instance.cloudConnected) {
      return;
    }
    _networkQuiescedForProvision = false;
    await EfactorCloudService.instance.resumeAfterProvisioning().catchError((
      error,
    ) {
      debugPrint('[SDUI][WiFi] resumeAfterProvisioning failed: $error');
    });
  }

  String _resolvedProvisionStage(EfProvisioningEvent event) {
    final raw = event.stage?.trim() ?? '';
    if (raw.isEmpty) return _stage;

    // First preference: exact server progressMap event name.
    final progressMap =
        (_contract['progressMap'] as List? ?? const <dynamic>[]);
    final exact = progressMap.whereType<Map>().any(
          (item) => item['event']?.toString() == raw,
        );
    if (exact) return raw;

    // Library-adapter aliases only. These are generic SDK lifecycle events,
    // never model/device-specific values. They let older schemas continue to
    // display meaningful progress until backend progressMap is regenerated
    // with the new 19-08 library event names.
    switch (raw) {
      case 'connected':
        return _progressEventAvailable('connect') ? 'connect' : raw;
      case 'provision':
      case 'wifiConfigSent':
        return _progressEventAvailable('wifiConfigSent')
            ? 'wifiConfigSent'
            : (_progressEventAvailable('connect') ? 'connect' : raw);
      default:
        return raw;
    }
  }

  bool _progressEventAvailable(String event) {
    final progressMap =
        (_contract['progressMap'] as List? ?? const <dynamic>[]);
    return progressMap.whereType<Map>().any(
          (item) => item['event']?.toString() == event,
        );
  }

  bool get _requiresCloudConfirmation {
    final postProvision = _map(_contract['postProvision']);
    final condition = postProvision['controlReadyWhen']?.toString() ?? '';
    if (condition.contains('onlineConfirmed')) return true;

    final capabilities = _map(_contract['nativeCapabilities']);
    return capabilities.containsKey('confirmCloudOnline');
  }

  String? _cloudConfirmationScreen() {
    for (final entry in _screens.entries) {
      final onEnter = _map(entry.value['onEnter']);
      if (onEnter['capability']?.toString() == 'confirmCloudOnline') {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _routeProvisionedDeviceToCloudConfirmation() async {
    _isRetryingIosProvision = false;
    _iosRetryTimer?.cancel();
    await _cloud.setProvisionStarted(false).catchError((_) {});
    await _resumeNetworkAfterProvisioning();
    await _cloud.reconnect().catchError((_) {});

    if (!mounted) return;

    setState(() {
      _busy = false;
      _onlineConfirmed = false;
      if (_progressEventAvailable('onlineConfirmation')) {
        _stage = 'onlineConfirmation';
        _stageIndex = _stageIndexFor(_stage);
      }
    });

    final cloudScreen = _cloudConfirmationScreen();
    if (cloudScreen != null) {
      _goTo(cloudScreen);
      return;
    }

    // If a schema intentionally has no separate cloud screen, execute the
    // confirmation capability here before exposing device controls.
    if (_requiresCloudConfirmation) {
      await _confirmCloudOnline();
      return;
    }

    final target = _flowScreen('successScreen');
    if (target != null) _goTo(target);
  }

  void _onProvisionEvent(EfProvisioningEvent event) {
    if (!mounted || _provisionCancelled) return;

    if (!event.isTerminal) {
      final resolvedStage = _resolvedProvisionStage(event);
      setState(() {
        _stage = resolvedStage;
        _stageIndex = _stageIndexFor(_stage);
      });

      // After SoftAP join starts, drop the live WebSocket so it does not thrash
      // on a no-internet SoftAP. Do not race the library with our own SoftAP
      // TCP probes — Android binds the SoftAP; iOS SoftAPTransport owns session.
      final stageKey = (event.stage ?? resolvedStage).toLowerCase();
      if (stageKey.contains('join') ||
          stageKey == 'connected' ||
          stageKey == 'connect') {
        unawaited(
          EfactorCloudService.instance.disconnectCloudSocketOnly().catchError((_) {}),
        );
      }
      return;
    }

    if (event.isFailure) {
      if (defaultTargetPlatform == TargetPlatform.iOS &&
          _isRetryingIosProvision &&
          !_provisionCancelled &&
          _iosProvisionAttempt < _kMaxProvisionAttempts) {
        debugPrint(
          '[SDUI][WiFi][iOS] Provision attempt #$_iosProvisionAttempt of $_kMaxProvisionAttempts failed (${event.code}: ${event.detail}). '
          'Retrying in 2 seconds...',
        );
        setState(() {
          _busy = true;
          _stage = 'retrying';
        });
        _iosRetryTimer?.cancel();
        _iosRetryTimer = Timer(const Duration(seconds: 2), () {
          if (mounted &&
              _isRetryingIosProvision &&
              !_provisionCancelled &&
              _iosProvisionAttempt < _kMaxProvisionAttempts) {
            unawaited(_executeProvisionStartWithIosRetry());
          }
        });
        return;
      }

      _isRetryingIosProvision = false;
      _iosRetryTimer?.cancel();
      _cloud.setProvisionStarted(false).catchError((_) {});
      unawaited(_resumeNetworkAfterProvisioning());
      setState(() {
        _busy = false;
        _errorCode = event.code ?? 'PROVISIONING_FAILED';
        _errorMessage = _friendlyProvisionFailure(
          event.detail ??
              (_iosProvisionAttempt >= _kMaxProvisionAttempts
                  ? 'Device provisioning failed after $_kMaxProvisionAttempts attempts.'
                  : 'Device provisioning failed.'),
        );
      });

      final target = _currentOnEnterTarget('onFailureScreen') ??
          _flowScreen('errorScreen');
      if (target != null) _goTo(target);
      return;
    }

    // SUCCESS = device locally confirmed router join.
    // APPLIED_UNCONFIRMED = credentials were applied and the device left
    // SoftAP before local confirmation. This is explicitly NOT a failure.
    // Both continue on the existing automatic cloud-confirmation path.
    _routeProvisionedDeviceToCloudConfirmation();
  }

  String _friendlyProvisionFailure(String detail) {
    final lower = detail.toLowerCase();
    if (lower.contains("couldn't create session") ||
        lower.contains('could not create session') ||
        lower.contains('create session') ||
        lower.contains('appears to be offline')) {
      return '$detail\n\n'
          'On iPhone this usually means:\n'
          '1) Local Network access is off for this app — enable it in '
          'Settings → Privacy & Security → Local Network.\n'
          '2) The SoftAP join prompt was dismissed — put the device in '
          'pairing mode and tap Join when iOS asks to join EWIFI_… '
          '(short name like EWIFI_7E0005E8, not the full node id).\n'
          '3) If the device is already on home Wi‑Fi, SoftAP is off — '
          're-enter pairing mode so EWIFI_ appears in Settings → Wi‑Fi.\n'
          '4) Stay close to the device and keep it powered.';
    }
    if (lower.contains('softap') && lower.contains('join')) {
      return '$detail\n\n'
          'Approve the iOS “Join Wi‑Fi Network” prompt for the device SoftAP, '
          'then retry.';
    }
    return detail;
  }

  Future<void> _confirmCloudOnline() async {
    final identity = widget.state.resolveDeviceIdentity();
    var nodeId = identity.nodeId?.trim() ?? '';
    if (nodeId.isEmpty) {
      final softApSsid = _deviceSoftAp?.ssid?.trim() ?? '';
      if (softApSsid.startsWith('EWIFI_')) {
        nodeId = softApSsid.substring('EWIFI_'.length).trim();
      } else if (softApSsid.isNotEmpty) {
        nodeId = softApSsid;
      }
    }
    if (nodeId.isEmpty) {
      nodeId = (_runtimeValue('nodeId') ?? _runtimeValue('devicePop'))
              ?.toString()
              .trim() ??
          '';
    }

    final token = widget.state.accessToken.trim();

    if (token.isEmpty) {
      _setError(
        'CLOUD_CONFIRMATION_INPUT_MISSING',
        'Access token is missing.',
      );
      return;
    }

    _cloudConfirmedNodeId = null;

    // The provisioning library has completed its terminal local step. Release
    // any app-owned temporary SoftAP binding before asking the cloud for the
    // device status. This is safe even when the library already released it.
    await _native.disconnectDeviceSoftAp().catchError((_) {});
    await _cloud.setProvisionStarted(false).catchError((_) {});
    await _resumeNetworkAfterProvisioning();

    // Re-apply the authenticated token and start/restart the cloud connection.
    // Android can still be switching back from the temporary device network at
    // this point, so a single reconnect attempt is not sufficient.
    await _cloud.initialize(apiKey: token).catchError((error) {
      debugPrint('[SDUI][WiFi] cloud initialize failed: $error');
    });
    await _cloud.reconnect().catchError((error) {
      debugPrint('[SDUI][WiFi] initial cloud reconnect failed: $error');
    });
    await EfactorCloudService.instance.ensureDiscoveryStarted().catchError((_) {});

    final capability = _map(
      _map(_contract['nativeCapabilities'])['confirmCloudOnline'],
    );
    final timeoutSeconds = _number(
      capability['timeoutSeconds'] ?? capability['timeoutSec'],
      60,
    ).round().clamp(5, 600).toInt();
    final pollSeconds = _number(
      capability['pollIntervalSeconds'] ?? capability['pollIntervalSec'],
      5,
    ).round().clamp(1, 60).toInt();
    final reconnectSeconds = _number(
      capability['reconnectIntervalSeconds'] ??
          capability['reconnectIntervalSec'],
      math.max(3.0, pollSeconds.toDouble()),
    ).round().clamp(2, 60).toInt();

    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
    // Schedule the first reconnect attempt immediately; successful API calls
    // will push this back so we don't spam reconnects while polls succeed.
    var nextReconnectAt = DateTime.now();

    // Give Android a short grace period to switch back from the device SoftAP
    // network to the home network before issuing the first cloud query.
    // Without this, the first couple of polls will always fail on real devices
    // because the radio hasn't finished its handoff yet.
    const initialNetworkGraceMs = 3000;
    final firstPollAt = DateTime.now().add(
      const Duration(milliseconds: initialNetworkGraceMs),
    );

    while (mounted && !_provisionCancelled && DateTime.now().isBefore(deadline)) {
      if (_cloudConfirmedNodeId != null &&
          (nodeId.isEmpty || _cloudConfirmedNodeId == nodeId)) {
        _completeCloudConfirmation();
        return;
      }

      // Wait for the initial grace period before the very first poll.
      final now = DateTime.now();
      if (now.isBefore(firstPollAt)) {
        final tillFirst = firstPollAt.difference(now);
        final remaining = deadline.difference(now);
        await Future<void>.delayed(
          remaining < tillFirst ? remaining : tillFirst,
        );
        if (!mounted || _provisionCancelled) return;
        continue;
      }

      // Only reconnect when the cloud is confirmed offline AND enough time has
      // passed since the last reconnect attempt.
      if (!_cloudConnected && !now.isBefore(nextReconnectAt)) {
        debugPrint(
          '[SDUI][WiFi] cloud not connected; retrying reconnect for node=$nodeId',
        );
        await _cloud.initialize(apiKey: token).catchError((_) {});
        await _cloud.reconnect().catchError((_) {});
        nextReconnectAt = now.add(Duration(seconds: reconnectSeconds));
      }

      if (!mounted || _provisionCancelled) return;

      // Query on every poll cycle using both status endpoints to mirror efactor_aar_test.
      try {
        await _cloud.getAllNodesStatus(apiKey: token);
        if (nodeId.isNotEmpty) {
          await _cloud.getAllNodes(apiKey: token, nodeId: nodeId);
          unawaited(
            _cloud.getDevices(apiKey: token, nodeId: nodeId).catchError((_) {}),
          );
        }
        _cloudConnected = true;
      } catch (error) {
        debugPrint('[SDUI][WiFi] cloud query failed: $error');
        _cloudConnected = false;
        // Trigger a reconnect on the very next iteration.
        nextReconnectAt = DateTime.now();
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero || _provisionCancelled || !mounted) break;
      final wait = Duration(seconds: pollSeconds);
      await Future<void>.delayed(remaining < wait ? remaining : wait);
      if (!mounted || _provisionCancelled) return;
    }

    if (!mounted || _provisionCancelled) return;
    if (_cloudConfirmedNodeId != null &&
        (nodeId.isEmpty || _cloudConfirmedNodeId == nodeId)) {
      _completeCloudConfirmation();
      return;
    }

    _setError(
      'CLOUD_CONFIRMATION_TIMEOUT',
      'Wi-Fi credentials were applied, but the device did not report online before the confirmation timeout.',
    );
  }

  void _completeCloudConfirmation() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _onlineConfirmed = true;
    });
    final target = _currentOnEnterTarget('onSuccessScreen') ??
        _flowScreen('successScreen');
    if (target != null) _goTo(target);
  }

  void _onCloudEvent(EfCloudEvent event) {
    if (!mounted || _provisionCancelled) return;
    debugPrint('[SDUI][WiFi] cloud event: ${event.type.name} msg=${event.message ?? ""}');

    if (event.type == EfCloudEventType.connected) {
      _cloudConnected = true;
      debugPrint('[SDUI][WiFi] cloud connected');
      return;
    }
    if (event.type == EfCloudEventType.disconnected ||
        event.type == EfCloudEventType.error) {
      _cloudConnected = false;
      debugPrint(
        '[SDUI][WiFi] cloud ${event.type.name}: ${event.message ?? ''}',
      );
      return;
    }
    if (event.type != EfCloudEventType.message) return;

    final message = event.message;
    if (message == null || message.trim().isEmpty) return;

    final identity = widget.state.resolveDeviceIdentity();
    var target = identity.nodeId?.trim() ?? '';
    if (target.isEmpty) {
      final softApSsid = _deviceSoftAp?.ssid?.trim() ?? '';
      if (softApSsid.startsWith('EWIFI_')) {
        target = softApSsid.substring('EWIFI_'.length).trim();
      } else if (softApSsid.isNotEmpty) {
        target = softApSsid;
      }
    }
    if (target.isEmpty) {
      target = (_runtimeValue('nodeId') ?? _runtimeValue('devicePop'))
              ?.toString()
              .trim() ??
          '';
    }

    try {
      final decoded = jsonDecode(message);
      final isMatch = target.isNotEmpty
          ? _jsonContainsOnlineNode(decoded, target)
          : _containsAnyOnlineNode(decoded);

      if (isMatch) {
        final confirmedId = target.isNotEmpty ? target : 'confirmed_device';
        debugPrint('[SDUI][WiFi] exact cloud-online match for node=$confirmedId');
        _cloudConfirmedNodeId = confirmedId;

        // Do not wait for the next polling interval once the exact selected
        // node is already confirmed online by the cloud response.
        if (!_onlineConfirmed && mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_onlineConfirmed) {
              _completeCloudConfirmation();
            }
          });
        }
      }
    } catch (_) {
      // Native cloud callbacks can also contain informational non-JSON text
      // such as "Message Sent Successfully: ...". Forwarded without crash.
    }
  }

  bool _containsAnyOnlineNode(dynamic value) {
    if (value is Map) {
      final values = Map<String, dynamic>.from(value);
      final onlineValue = _firstValueForKeys(values, const <String>[
        'online',
        'connected',
        'is_online',
        'isOnline',
        'node_status',
        'device_status',
        'connection_status',
      ]);
      if (_isOnlineValue(onlineValue)) return true;
      for (final nested in values.values) {
        if (_containsAnyOnlineNode(nested)) return true;
      }
    } else if (value is List) {
      for (final item in value) {
        if (_containsAnyOnlineNode(item)) return true;
      }
    }
    return false;
  }

  bool _jsonContainsOnlineNode(dynamic value, String nodeId) {
    if (value is Map) {
      final values = Map<String, dynamic>.from(value);

      // The current eFactor all_nodes response keeps the node identity under
      // item.config.node_id and its connectivity state in the sibling
      // item.status.connectivity.connected. Treat that parent object as one
      // atomic node-status record so the exact runtime node can be confirmed.
      final configRaw = values['config'];
      if (configRaw is Map) {
        final config = Map<String, dynamic>.from(configRaw);
        final configNode = _firstValueForKeys(config, const <String>[
          'node_id',
          'nodeId',
          'nodeID',
          'nodeid',
        ])?.toString().trim();

        if (configNode == nodeId) {
          final statusRaw = values['status'];
          if (_containsOnlineStatus(statusRaw)) {
            return true;
          }

          // Keep compatibility with equivalent server shapes where the
          // connectivity block is placed directly beside config.
          final connectivityRaw = values['connectivity'];
          if (_containsOnlineStatus(connectivityRaw)) {
            return true;
          }
        }
      }

      final currentNode = _firstValueForKeys(values, const <String>[
        'node_id',
        'nodeId',
        'nodeID',
        'nodeid',
        'device_id',
        'deviceId',
        'deviceID',
      ])?.toString().trim();

      final onlineValue = _firstValueForKeys(values, const <String>[
        'online',
        'connected',
        'is_online',
        'isOnline',
        'node_status',
        'nodeStatus',
        'device_status',
        'deviceStatus',
        'connection_status',
        'connectionStatus',
        'status',
        'state',
      ]);

      if (currentNode == nodeId && _isOnlineValue(onlineValue)) return true;

      // Some cloud status responses use the exact node id as a JSON object key,
      // for example {"<nodeId>": true} or {"<nodeId>": {"status":"online"}}.
      if (values.containsKey(nodeId)) {
        final keyed = values[nodeId];
        if (_isOnlineValue(keyed) || _containsOnlineStatus(keyed)) return true;
      }

      for (final entry in values.entries) {
        final key = entry.key.toLowerCase();
        if ((key.contains('online') || key.contains('connected')) &&
            entry.value is List) {
          for (final item in entry.value as List) {
            if (item?.toString().trim() == nodeId) return true;
          }
        }
      }

      for (final nested in values.values) {
        if (_jsonContainsOnlineNode(nested, nodeId)) return true;
      }
    } else if (value is List) {
      for (final nested in value) {
        if (_jsonContainsOnlineNode(nested, nodeId)) return true;
      }
    }
    return false;
  }

  dynamic _firstValueForKeys(Map<String, dynamic> values, List<String> keys) {
    for (final key in keys) {
      if (values.containsKey(key)) return values[key];
    }
    return null;
  }

  bool _isOnlineValue(dynamic value) {
    if (value == true || value == 1) return true;
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' ||
        normalized == '1' ||
        normalized == 'online' ||
        normalized == 'connected' ||
        normalized == 'active';
  }

  bool _containsOnlineStatus(dynamic value) {
    if (_isOnlineValue(value)) return true;
    if (value is Map) {
      final values = Map<String, dynamic>.from(value);
      final status = _firstValueForKeys(values, const <String>[
        'online',
        'connected',
        'is_online',
        'isOnline',
        'node_status',
        'nodeStatus',
        'device_status',
        'deviceStatus',
        'connection_status',
        'connectionStatus',
        'status',
        'state',
      ]);
      if (_isOnlineValue(status)) return true;
      for (final nested in values.values) {
        if (_containsOnlineStatus(nested)) return true;
      }
    } else if (value is List) {
      for (final nested in value) {
        if (_containsOnlineStatus(nested)) return true;
      }
    }
    return false;
  }

  void _cancelActiveProvisioning() {
    _provisionCancelled = true;
    _isRetryingIosProvision = false;
    _iosRetryTimer?.cancel();
    _iosRetryTimer = null;
    _busy = false;

    unawaited(_provision.cancel().catchError((_) {}));
    unawaited(_native.disconnectDeviceSoftAp().catchError((_) {}));
    unawaited(_cloud.setProvisionStarted(false).catchError((_) {}));
    unawaited(_resumeNetworkAfterProvisioning().catchError((_) {}));
  }

  Future<void> _finishAndClose() async {
    _cancelActiveProvisioning();
    final router = _selectedRouter;
    final identity = widget.state.resolveDeviceIdentity();

    if (!mounted) return;

    Navigator.of(context).pop(<String, dynamic>{
      'status': _onlineConfirmed ? 'success' : 'closed',
      'ssid': router?.ssid,
      'password':
          router == null || router.isOpen ? '' : _passwordController.text,
      'security': router?.securityLabel,
      'connected': _onlineConfirmed,
      'onlineConfirmed': _onlineConfirmed,
      'nodeId': identity.nodeId,
      'deviceSsid': _deviceSoftAp?.ssid,
    });
  }

  int _stageIndexFor(String stage) {
    final progressMap =
        (_contract['progressMap'] as List? ?? const <dynamic>[]);
    for (final item in progressMap) {
      if (item is! Map) continue;
      if (item['event']?.toString() == stage) {
        return (item['stageIndex'] as num?)?.toInt() ?? _stageIndex;
      }
    }
    return _stageIndex;
  }

  String _stageLabel(String event, String fallback) {
    if (event == 'retrying') {
      return _iosProvisionAttempt > 1
          ? 'Retrying connection (attempt #$_iosProvisionAttempt of $_kMaxProvisionAttempts)...'
          : 'Connecting to device...';
    }
    final progressMap =
        (_contract['progressMap'] as List? ?? const <dynamic>[]);
    for (final item in progressMap) {
      if (item is! Map) continue;
      if (item['event']?.toString() == event) {
        final label = item['label']?.toString();
        if (label != null && label.isNotEmpty) return label;
      }
    }
    return fallback;
  }

  Future<void> _guardBusy(
    Future<void> Function() operation, {
    bool keepBusyOnSuccess = false,
    String? onErrorScreen,
  }) async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _errorCode = null;
      _errorMessage = null;
    });

    try {
      await operation();
      if (!keepBusyOnSuccess && mounted) {
        setState(() => _busy = false);
      }
    } on _WifiFlowCancelled {
      if (mounted) {
        setState(() {
          _busy = false;
          _errorCode = null;
          _errorMessage = null;
        });
      }
    } catch (error) {
      if (!mounted) return;
      _setError(
        'WIFI_RUNTIME_ERROR',
        error.toString(),
        targetScreen: onErrorScreen,
      );
    }
  }

  void _setError(String code, String message, {String? targetScreen}) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _errorCode = code;
      _errorMessage = message;
    });

    final target = targetScreen ?? _flowScreen('errorScreen');

    if (target != null && target != _screenId && _screens.containsKey(target)) {
      _goTo(target);
    }
  }

  void _goTo(String id, {bool addToHistory = true}) {
    if (!_screens.containsKey(id)) {
      _setMissingSchemaError('wifiProvisioning.screens[id="$id"]');
      return;
    }

    if (addToHistory && _screenId.isNotEmpty && _screenId != id) {
      _screenHistory.add(_screenId);
    }

    setState(() {
      _screenId = id;
      _busy = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runOnEnterIfNeeded();
    });
  }

  Future<void> _runOnEnterIfNeeded() async {
    if (_screenId.isEmpty || _enteredScreens.contains(_screenId)) return;
    _enteredScreens.add(_screenId);

    final screen = _screens[_screenId];
    if (screen == null) return;

    // On password entry (and SoftAP setup screens), stop local discovery and
    // disconnect the cloud socket so SoftAP session HTTP can succeed.
    if (_screenId == 'wifiPassword' ||
        _screenId == 'deviceDiscovery' ||
        _screenId == 'provisioning') {
      await _quiesceNetworkForProvisioning();
    }

    await _runPrerequisites(screen);
    if (_errorMessage != null) return;

    final onEnter = _map(screen['onEnter']);
    if (onEnter.isEmpty) return;

    await _executeAction(onEnter);
  }

  Future<void> _invokeCapability(
    String capability,
    Map<String, dynamic> action,
  ) async {
    final errorTarget = _screenTarget(action, 'onErrorScreen');
    final method = _capabilityMethod(capability);
    if (method == null) {
      _setMissingSchemaError(
        'wifiProvisioning.nativeCapabilities.$capability.method',
      );
      return;
    }

    switch (method) {
      case 'wifi.ensurePermissions':
        await _guardBusy(_ensureWifiPermission, onErrorScreen: errorTarget);
        break;

      case 'wifi.scanRouterNetworks':
        await _scanRouters();
        break;

      case 'wifi.scanDeviceSoftAp':
        // The current eFactor provisioning library owns device SoftAP
        // discovery/connection as part of EfactorProvision.start().  The live
        // schema still contains a legacy deviceDiscovery capability before
        // startProvisioning; treat that screen as a UX transition only rather
        // than blocking the SDK behind a second Android Wi-Fi scan.
        //
        // Do not infer an SSID from model/node data and do not auto-select a
        // nearby physical device here. The SDK remains authoritative.
        if (mounted) {
          final target = _screenTarget(action, 'onSuccessScreen');
          if (target != null) _goTo(target);
        }
        break;

      case 'wifi.startProvisioning':
        await _startProvisioning();
        break;

      case 'wifi.cancelProvisioning':
        _cancelActiveProvisioning();
        break;

      case 'wifi.confirmCloudOnline':
        await _confirmCloudOnline();
        break;

      default:
        _setMissingSchemaError(
          'Unsupported native Wi-Fi capability method: $method',
        );
    }
  }

  Future<void> _executeAction(dynamic raw) async {
    if (raw is! Map) return;
    final action = Map<String, dynamic>.from(raw);
    final type = action['type']?.toString();

    switch (type) {
      case 'nativeCapability':
        final capability = action['capability']?.toString().trim() ?? '';
        if (capability.isNotEmpty) {
          await _invokeCapability(capability, action);
        }
        break;

      case 'native':
        final value = action['value']?.toString().trim() ?? '';
        if (value == 'openScanner') {
          await widget.state.dispatchAction(<String, dynamic>{
            ...action,
            'type': 'native',
            'value': 'openScanner',
          }, context: context);
        } else {
          _setMissingSchemaError(
            'Unsupported native Wi-Fi action: ${value.isEmpty ? "<missing>" : value}',
          );
        }
        break;

      case 'wifi.findDevice':
        if (!_validatePasswordIfRequired(action)) return;
        await _quiesceNetworkForProvisioning();
        final next = action['nextScreen']?.toString().trim() ?? '';
        if (next.isNotEmpty) _goTo(next);
        break;

      case 'wifi.close':
        await _finishAndClose();
        break;

      case 'wifi.reset':
        _cancelActiveProvisioning();
        _screenHistory.clear();
        _enteredScreens.clear();

        setState(() {
          _selectedRouter = null;
          _deviceSoftAp = null;
          _networks = const <WifiRuntimeNetwork>[];
          _passwordController.clear();
          _stage = _map(_contract['state'])['stage']?.toString() ?? 'idle';
          _stageIndex =
              (_map(_contract['state'])['stageIndex'] as num?)?.toInt() ?? 0;
          _onlineConfirmed = false;
          _errorCode = null;
          _errorMessage = null;
        });

        final next = action['nextScreen']?.toString().trim() ??
            _contract['entryScreen']?.toString().trim() ??
            '';
        if (next.isNotEmpty) _goTo(next, addToHistory: false);
        break;

      case 'navigate':
        var next = action['screen']?.toString().trim() ?? '';
        if (next == 'wifiPassword' && (_selectedRouter?.isOpen == true)) {
          next = _contract['entryScreen']?.toString().trim() ?? 'wifiNetworkPicker';
        }
        if (next.isNotEmpty) {
          final entry = _contract['entryScreen']?.toString().trim() ?? 'wifiNetworkPicker';
          final isBackNav = _screenHistory.contains(next) || next == entry;
          if (isBackNav) {
            while (_screenHistory.isNotEmpty && _screenHistory.last != next) {
              _screenHistory.removeLast();
            }
            if (_screenHistory.isNotEmpty && _screenHistory.last == next) {
              _screenHistory.removeLast();
            }
            _goTo(next, addToHistory: false);
          } else {
            _goTo(next, addToHistory: true);
          }
        }
        break;

      case 'sequence':
        final steps = action['steps'] as List? ?? const <dynamic>[];
        for (final step in steps) {
          await _executeAction(step);
          if (!mounted) return;
        }
        break;

      default:
        _setMissingSchemaError(
          'Unsupported Wi-Fi action type: ${type ?? "<missing>"}',
        );
    }
  }

  bool _validatePasswordIfRequired(Map<String, dynamic> action) {
    final validate = _map(action['validate']);
    if (validate['passwordRequiredUnlessOpen'] != true) return true;

    final router = _selectedRouter;
    if (router == null || router.isOpen) return true;
    if (_passwordController.text.isNotEmpty) return true;

    setState(() {
      _errorCode = 'WIFI_PASSWORD_REQUIRED';
      _errorMessage = 'Password is required for the selected secured network.';
    });
    return false;
  }

  Future<void> _handleBack() async {
    _cancelActiveProvisioning();

    final entryScreen =
        _contract['entryScreen']?.toString().trim() ?? 'wifiNetworkPicker';

    // If currently on the entry screen, close immediately and return to previous state.
    if (_screenId == entryScreen || _screenId == 'wifiNetworkPicker') {
      await _finishAndClose();
      return;
    }

    // 1. If screen declares its own onBack action, execute it.
    final screen = _screens[_screenId];
    final onBack = _map(screen?['onBack']);
    if (onBack.isNotEmpty) {
      await _executeAction(onBack);
      return;
    }

    // 2. Fallback to history stack if available.
    while (_screenHistory.isNotEmpty) {
      final prev = _screenHistory.removeLast();
      if (_screens.containsKey(prev) && prev != _screenId) {
        if (prev == 'wifiPassword' && (_selectedRouter?.isOpen == true)) {
          _goTo(entryScreen, addToHistory: false);
        } else {
          _goTo(prev, addToHistory: false);
        }
        return;
      }
    }

    // 3. Fallback to flow.back schema definition (handles both String and Map).
    final flow = _map(_contract['flow']);
    final back = _map(flow['back']);
    final backEntry = back[_screenId];
    String target = '';
    if (backEntry is Map) {
      if (_selectedRouter?.isOpen == true && backEntry['whenOpen'] != null) {
        target = backEntry['whenOpen'].toString().trim();
      } else if (backEntry['screen'] != null) {
        target = backEntry['screen'].toString().trim();
      }
    } else if (backEntry != null) {
      target = backEntry.toString().trim();
    }

    if (target.isEmpty || target == 'close') {
      await _finishAndClose();
    } else {
      _goTo(target, addToHistory: false);
    }
  }

  String? _readOptionalRuntimeString(List<List<String>> paths) {
    for (final path in paths) {
      dynamic current = widget.state.schema;
      for (final part in path) {
        if (current is! Map) {
          current = null;
          break;
        }
        current = current[part];
      }
      final text = current?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  void _setMissingSchemaError(String path) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _errorCode = 'MISSING_WIFI_SCHEMA';
      _errorMessage = 'Required Wi-Fi schema path is missing: $path';
    });
  }

  FontWeight _fontWeight(dynamic value, FontWeight fallback) {
    final resolved = _resolveSchemaValue(value);
    final numeric = resolved is num
        ? resolved.toInt()
        : int.tryParse(resolved?.toString() ?? '');
    if (numeric == null) return fallback;
    if (numeric >= 900) return FontWeight.w900;
    if (numeric >= 800) return FontWeight.w800;
    if (numeric >= 700) return FontWeight.w700;
    if (numeric >= 600) return FontWeight.w600;
    if (numeric >= 500) return FontWeight.w500;
    if (numeric >= 400) return FontWeight.w400;
    if (numeric >= 300) return FontWeight.w300;
    if (numeric >= 200) return FontWeight.w200;
    return FontWeight.w100;
  }

  TextStyle _schemaTextStyle({
    required Color? color,
    double? size,
    FontWeight? weight,
  }) {
    final typography = _map(_theme()['typography']);
    final configuredSize = size ?? _number(typography['bodySize'], 14);
    final configuredWeight =
        weight ?? _fontWeight(typography['bodyWeight'], FontWeight.w400);
    final family = typography['fontFamily']?.toString().trim();

    return TextStyle(
      color: color,
      fontSize: configuredSize,
      fontWeight: configuredWeight,
      fontFamily: family == null || family.isEmpty ? null : family,
      letterSpacing: _number(typography['letterSpacing'], 0),
      height: _number(typography['lineHeight'], 1.35),
    );
  }

  BorderRadius _schemaRadius(dynamic value, {String themeKey = 'card'}) {
    final radiusMap = _map(_theme()['radius']);
    return BorderRadius.circular(_number(value ?? radiusMap[themeKey], 0));
  }

  List<BoxShadow> _schemaShadows(dynamic raw) {
    final shadow = _map(raw ?? _map(_theme()['shadows'])['card']);
    if (shadow.isEmpty) return const <BoxShadow>[];

    final color = _color(shadow['color']);
    return <BoxShadow>[
      BoxShadow(
        color: color ?? Colors.transparent,
        offset: Offset(
          _number(shadow['offsetX'], 0),
          _number(shadow['offsetY'], 0),
        ),
        blurRadius: _number(shadow['blurRadius'], 0),
        spreadRadius: _number(shadow['spreadRadius'], 0),
      ),
    ];
  }

  EdgeInsets _schemaInsets(dynamic raw, {double fallback = 0}) {
    if (raw is num) return EdgeInsets.all(raw.toDouble());
    final map = _map(raw);
    if (map.isEmpty) return EdgeInsets.all(fallback);
    return EdgeInsets.fromLTRB(
      _number(map['left'], fallback),
      _number(map['top'], fallback),
      _number(map['right'], fallback),
      _number(map['bottom'], fallback),
    );
  }

  String _networkSecurityValue(
    Map<String, dynamic> item,
    WifiRuntimeNetwork network,
  ) {
    final binding = item['securityBinding']?.toString();
    if (binding == null || binding.isEmpty) {
      return network.securityLabel;
    }
    return _networkBindingText(binding, network) ?? network.securityLabel;
  }

  bool _networkOpenValue(
    Map<String, dynamic> item,
    WifiRuntimeNetwork network,
  ) {
    final binding = item['openBinding']?.toString();
    if (binding == null || binding.isEmpty) return network.isOpen;
    final key = binding.split('.').last;
    final value = network.toMap()[key];
    if (value is bool) return value;
    return value?.toString().toLowerCase() == 'true';
  }

  PreferredSizeWidget _buildSchemaAppBar(
    Map<String, dynamic> screen,
    Color? fallbackTextColor,
  ) {
    final header = _map(screen['header']);
    final back = _map(header['backButton']);
    final titleStyle = _map(header['titleStyle']);
    final trailing = _map(header['trailing']);
    final trailingStyle = _resolveReferenceMap(trailing['styleRef']);

    final title =
        _resolveText(header['title']) ?? _resolveText(screen['title']) ?? '';
    final titleColor = _color(titleStyle['color']) ?? fallbackTextColor;
    final backColor = _color(back['background']) ?? Colors.transparent;
    final backIconColor = _color(back['iconColor']) ?? titleColor;
    final backWidth = _number(back['width'], 40);
    final backHeight = _number(back['height'], 40);
    final backRadius = _number(back['radius'], 999);

    Widget? trailingWidget;
    if (trailing.isNotEmpty) {
      final width = _number(trailingStyle['width'], 36);
      final height = _number(trailingStyle['height'], 36);
      final radius = _number(trailingStyle['radius'], 999);
      final background =
          _color(trailingStyle['background']) ?? Colors.transparent;
      final iconColor = _color(trailingStyle['iconColor']) ?? titleColor;
      final iconSize = _number(trailingStyle['iconSize'], 18);
      trailingWidget = Semantics(
        label: trailing['accessibilityLabel']?.toString() ??
            trailing['label']?.toString(),
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: () => _executeAction(trailing['action']),
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(radius),
            ),
            alignment: Alignment.center,
            child: _wifiIcon(
              trailing['icon']?.toString(),
              size: iconSize,
              color: iconColor,
            ),
          ),
        ),
      );
    }

    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leadingWidth: backWidth + 16,
      leading: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            label: 'Back',
            button: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(backRadius),
              onTap: _handleBack,
              child: Container(
                width: backWidth,
                height: backHeight,
                decoration: BoxDecoration(
                  color: backColor,
                  borderRadius: BorderRadius.circular(backRadius),
                ),
                alignment: Alignment.center,
                child: _wifiIcon(
                  back['icon']?.toString() ?? 'chevron-left',
                  size: math.min(backWidth, backHeight) * 0.5,
                  color: backIconColor,
                ),
              ),
            ),
          ),
        ),
      ),
      title: Text(
        title,
        style: _schemaTextStyle(
          color: titleColor,
          size: _number(titleStyle['fontSize'], 20),
          weight: _fontWeight(titleStyle['fontWeight'], FontWeight.w800),
        ).copyWith(letterSpacing: _number(titleStyle['letterSpacing'], -0.4)),
      ),
      actions: trailingWidget == null
          ? const <Widget>[]
          : <Widget>[Center(child: trailingWidget), const SizedBox(width: 12)],
    );
  }

  Widget _buildTracker(Map<String, dynamic> screen) {
    final tracker = _map(_contract['tracker']);
    if (tracker.isEmpty) return const SizedBox.shrink();
    final activeByScreen = _map(tracker['activeStepByScreen']);
    final rawActive = activeByScreen[_screenId] ?? screen['trackerStep'];
    if (rawActive == null) return const SizedBox.shrink();
    final active =
        (rawActive as num?)?.toInt() ?? int.tryParse(rawActive.toString()) ?? 0;
    final labels = (tracker['labels'] as List? ?? const <dynamic>[])
        .map((item) => item.toString())
        .toList(growable: false);
    if (labels.isEmpty) return const SizedBox.shrink();

    final geometry = _map(tracker['geometry']);
    final states = _map(tracker['states']);
    final circleSize = _number(geometry['circleSize'], 22);
    final lineHeight = _number(geometry['lineHeight'], 2);
    final gap = _number(geometry['gap'], 6);
    final labelGap = _number(geometry['labelGap'], 4);

    Map<String, dynamic> stateFor(int index) {
      if (index < active) return _map(states['completed']);
      if (index == active) return _map(states['active']);
      return _map(states['pending']);
    }

    return Padding(
      padding: _schemaInsets(geometry['padding'], fallback: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var i = 0; i < labels.length; i++) ...<Widget>[
            SizedBox(
              width: math.max(circleSize + 22, 54),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: circleSize,
                    height: circleSize,
                    decoration: BoxDecoration(
                      color: _color(stateFor(i)['circleFill']),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: i < active && stateFor(i)['icon'] != null
                        ? _wifiIcon(
                            stateFor(i)['icon']?.toString(),
                            size: circleSize * 0.55,
                            color: _color(stateFor(i)['circleText']),
                          )
                        : Text(
                            '${i + 1}',
                            style: _schemaTextStyle(
                              color: _color(stateFor(i)['circleText']),
                              size: 10,
                              weight: _fontWeight(
                                stateFor(i)['fontWeight'],
                                FontWeight.w800,
                              ),
                            ),
                          ),
                  ),
                  SizedBox(height: labelGap),
                  Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: _schemaTextStyle(
                      color: _color(stateFor(i)['labelColor']),
                      size: 9,
                      weight: _fontWeight(
                        stateFor(i)['fontWeight'],
                        FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (i != labels.length - 1)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(gap, circleSize / 2, gap, 0),
                  child: Container(
                    height: lineHeight,
                    decoration: BoxDecoration(
                      color: _color(
                        stateFor(i < active ? i : i + 1)['lineColor'],
                      ),
                      borderRadius: BorderRadius.circular(
                        _number(geometry['lineRadius'], 999),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  TextStyle _textStyleFromMap(
    Map<String, dynamic> map, {
    Color? fallbackColor,
  }) {
    final typography = _map(_theme()['typography']);
    return _schemaTextStyle(
      color: _color(map['color']) ?? fallbackColor,
      size: _number(
        map['fontSize'] ?? map['size'],
        _number(typography['bodySize'], 14),
      ),
      weight: _fontWeight(
        map['fontWeight'] ?? map['weight'],
        _fontWeight(typography['bodyWeight'], FontWeight.w400),
      ),
    ).copyWith(
      letterSpacing: map['letterSpacing'] is num
          ? (map['letterSpacing'] as num).toDouble()
          : null,
      height: map['lineHeight'] is num
          ? (map['lineHeight'] as num).toDouble()
          : null,
    );
  }

  bool _chipVisible(Map rawChip) {
    final chip = Map<String, dynamic>.from(rawChip);
    final binding =
        chip['stateBinding']?.toString() ?? chip['visibleBinding']?.toString();
    final expected = chip['visibleWhen'];
    if (binding == null || binding.isEmpty) return chip['visible'] != false;

    dynamic actual;
    if (binding.endsWith('onlineConfirmed')) {
      actual = _onlineConfirmed;
    } else if (binding.endsWith('selectedRouter.ssid')) {
      actual = _selectedRouter?.ssid;
    } else {
      actual = _resolveRuntimeExpression(binding);
    }

    if (expected != null) return actual == expected;
    if (actual is bool) return actual;
    return actual != null && actual.toString().trim().isNotEmpty;
  }

  Widget _buildChip(Map<String, dynamic> chip) {
    final style = _resolveComponentStyle(<String, dynamic>{
      ...chip,
      'styleRef': chip['styleRef'] ?? 'wifiProvisioning.componentStyles.chip',
    });
    final colors = _map(_theme()['colors']);
    final token = chip['token']?.toString().toLowerCase();
    final bg = token == 'success'
        ? _color(colors['successSoft']) ?? _color(style['background'])
        : _color(style['background']) ?? _color(colors['accentSoft']);
    final fg = token == 'success'
        ? _color(colors['success']) ?? _color(style['textColor'])
        : _color(style['textColor']) ?? _color(colors['accent']);
    final text = _resolveText(chip['text']) ??
        _resolveBindingText(chip['textBinding']) ??
        '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: _schemaInsets(style['padding'], fallback: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: _schemaRadius(style['radius']),
      ),
      child: Text(
        text,
        style: _textStyleFromMap(
          _map(style['textStyle']),
          fallbackColor: fg,
        ).copyWith(color: fg),
      ),
    );
  }

  Map<String, dynamic>? _networkQuality(
    Map<String, dynamic> component,
    WifiRuntimeNetwork network,
  ) {
    final quality = _map(component['signalQuality']);
    final thresholds = quality['thresholds'] as List? ?? const <dynamic>[];
    for (final raw in thresholds) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final min = item['minRssi'];
      if (min == null || network.rssi >= (min as num).toInt()) return item;
    }
    return null;
  }

  Widget _networkChip(String text, Color? background, Color? foreground) {
    final style = _resolveReferenceMap('wifiProvisioning.componentStyles.chip');
    final defaults = _map(style['default']);
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: BoxConstraints(minHeight: _number(style['minHeight'], 20)),
      padding: EdgeInsets.symmetric(
        horizontal: _number(style['paddingH'], 8),
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: background ?? _color(defaults['background']),
        borderRadius: BorderRadius.circular(_number(style['radius'], 999)),
      ),
      child: Text(
        text,
        style: _textStyleFromMap(
          _map(style['font']),
          fallbackColor: foreground ?? _color(defaults['color']),
        ).copyWith(color: foreground ?? _color(defaults['color'])),
      ),
    );
  }

  Widget _buildSignalBars(int rssi, Map<String, dynamic> config) {
    final count = _number(config['barCount'], 4).toInt().clamp(1, 6);
    final on =
        _color(config['onColor']) ?? Theme.of(context).colorScheme.primary;
    final off = _color(config['offColor']) ?? Theme.of(context).dividerColor;
    final normalized = ((rssi + 90) / 50).clamp(0.0, 1.0);
    final active = math.max(1, (normalized * count).ceil()).clamp(1, count);
    return SizedBox(
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (var i = 0; i < count; i++) ...<Widget>[
            Container(
              width: 3,
              height: 5.0 + i * 3,
              decoration: BoxDecoration(
                color: i < active ? on : off,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (i != count - 1) const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }

  Widget _buildCompactAction(
    Map<String, dynamic> config, {
    required Color accent,
  }) {
    final style = _resolveReferenceMap(config['styleRef']);
    final bg = _color(style['background']) ?? Colors.transparent;
    final fg =
        _color(style['iconColor']) ?? _color(style['textColor']) ?? accent;
    final radius = _number(style['radius'], 999);
    return Semantics(
      label: config['accessibilityLabel']?.toString() ??
          config['text']?.toString(),
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: _busy ? null : () => _executeAction(config['action']),
        child: Container(
          constraints: BoxConstraints(
            minWidth: _number(style['width'], 36),
            minHeight: _number(style['height'], 36),
          ),
          padding: _schemaInsets(style['padding'], fallback: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if ((config['icon']?.toString() ?? '').isNotEmpty)
                _wifiIcon(
                  config['icon']?.toString(),
                  size: _number(style['iconSize'], 18),
                  color: fg,
                ),
              if ((config['icon']?.toString() ?? '').isNotEmpty &&
                  (config['text']?.toString() ?? '').isNotEmpty)
                const SizedBox(width: 6),
              if ((config['text']?.toString() ?? '').isNotEmpty)
                Text(
                  config['text'].toString(),
                  style: _schemaTextStyle(color: fg, weight: FontWeight.w700),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_contract.isEmpty) {
      return const Scaffold(
        body: SafeArea(
          child: Center(
            child: SelectableText(
              r'Required schema path is missing: $.wifiProvisioning',
            ),
          ),
        ),
      );
    }

    final screen = _screens[_screenId];
    if (screen == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: SelectableText(
              'Required Wi-Fi screen is missing: $_screenId',
            ),
          ),
        ),
      );
    }

    final style = _map(screen['style']);
    final theme = _theme();
    final colors = _map(theme['colors']);
    final spacing = _map(theme['spacing']);
    final typography = _map(theme['typography']);

    final background = _color(style['backgroundColor']) ??
        _color(colors['background']);
    final textColor = _color(style['textColor']) ?? _color(colors['text']);
    final mutedTextColor =
        _color(style['mutedTextColor']) ?? _color(colors['mutedText']);
    final accent = _color(style['accentColor']) ?? _color(colors['accent']);

    if (background == null || textColor == null || accent == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SchemaIssueWidget(
                title: 'Schema color missing',
                details: [
                  if (background == null)
                    'Provide screens.$_screenId.style.backgroundColor '
                        'or theme.colors.background',
                  if (textColor == null)
                    'Provide screens.$_screenId.style.textColor '
                        'or theme.colors.text',
                  if (accent == null)
                    'Provide screens.$_screenId.style.accentColor '
                        'or theme.colors.accent',
                ],
              ),
            ),
          ),
        ),
      );
    }

    final pagePadding = _number(spacing['pagePadding'], 16);
    final cardGap = _number(spacing['sectionGap'] ?? spacing['cardGap'], 16);
    final subtitleSize = _number(
      style['subtitleFontSize'] ?? typography['subtitleSize'],
      13,
    );

    final header = _map(screen['header']);
    final hasHeaderTitle = (_resolveText(header['title']) ?? '').isNotEmpty;
    final title = hasHeaderTitle ? null : _resolveText(screen['title']);
    final subtitle = _resolveText(screen['subtitle']) ??
        _resolveBindingText(screen['subtitleBinding']);

    final rawBody = (screen['body'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['visible'] != false)
        .toList(growable: false);
    final regular = <Map<String, dynamic>>[];
    final anchored = <Map<String, dynamic>>[];
    for (final component in rawBody) {
      final resolvedStyle = _resolveComponentStyle(component);
      final placement = component['placement']?.toString() ??
          resolvedStyle['placement']?.toString();
      if (placement == 'bottomAnchored') {
        anchored.add(component);
      } else {
        regular.add(component);
      }
    }

    final screenGradient = _schemaGradient(style['gradient']) ??
        _schemaGradient(_map(theme['gradient'])['screen']);
    final bodyBackground = BoxDecoration(
      color: screenGradient == null ? background : null,
      gradient: screenGradient,
    );

    Widget componentWidget(Map<String, dynamic> component) => _buildComponent(
          component,
          style: style,
          accent: accent,
          textColor: textColor,
          mutedTextColor: mutedTextColor,
        );

    final scrollContent = SchemaPullToRefresh(
      onRefresh: _refreshLiveSchema,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(pagePadding, 8, pagePadding, pagePadding),
      children: <Widget>[
        _buildTracker(screen),
        if ((_map(_contract['tracker']).isNotEmpty) &&
            (_map(_contract['tracker'])['activeStepByScreen']
                    as Map?)?[_screenId] !=
                null)
          SizedBox(height: cardGap),
        if (title != null && title.isNotEmpty)
          Text(
            title,
            style: _schemaTextStyle(
              color: textColor,
              size: 20,
              weight: FontWeight.w800,
            ),
          ),
        if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
          if (title != null && title.isNotEmpty) SizedBox(height: cardGap / 2),
          Text(
            subtitle,
            style: _schemaTextStyle(
              color: mutedTextColor,
              size: subtitleSize,
              weight: FontWeight.w600,
            ),
          ),
        ],
        if (title != null || subtitle != null) SizedBox(height: cardGap),
        for (final component in regular) ...<Widget>[
          componentWidget(component),
          SizedBox(height: cardGap),
        ],
        if (_busy &&
            !regular.any(
              (item) =>
                  item['type'] == 'circularGauge' || item['type'] == 'progress',
            ))
          LinearProgressIndicator(color: accent),
        if (_errorMessage != null && _screenId != _flowScreen('errorScreen'))
          Padding(
            padding: EdgeInsets.only(top: cardGap),
            child: Text(
              _errorMessage!,
              style: _schemaTextStyle(
                color: _color(colors['error']) ??
                    Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: background,
        appBar: _buildSchemaAppBar(screen, textColor),
        body: DecoratedBox(
          decoration: bodyBackground,
          child: SafeArea(
            top: false,
            child: AbsorbPointer(
              absorbing: _busy && _screenId != 'qrScanner',
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxWidth = _number(
                    _map(screen['layout'])['maxContentWidth'],
                    constraints.maxWidth,
                  );
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth:
                            maxWidth > 0 ? maxWidth : constraints.maxWidth,
                      ),
                      child: Column(
                        children: <Widget>[
                          Expanded(child: scrollContent),
                          if (anchored.isNotEmpty)
                            Container(
                              color: _color(style['surfaceColor']) ??
                                  _color(colors['surface']) ??
                                  Colors.transparent,
                              padding: EdgeInsets.fromLTRB(
                                pagePadding,
                                8,
                                pagePadding,
                                pagePadding,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  for (final component in anchored) ...<Widget>[
                                    componentWidget(component),
                                    if (component != anchored.last)
                                      SizedBox(height: cardGap / 2),
                                  ],
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildComponent(
    Map<String, dynamic> component, {
    required Map<String, dynamic> style,
    required Color accent,
    required Color textColor,
    required Color? mutedTextColor,
  }) {
    final type = component['type']?.toString();
    final componentStyle = _resolveComponentStyle(component);
    final theme = _theme();
    final colors = _map(theme['colors']);
    final spacing = _map(theme['spacing']);

    final surface = _color(componentStyle['backgroundColor']) ??
        _color(style['surfaceColor']) ??
        _color(colors['surface']);
    final border = _color(componentStyle['borderColor']) ??
        _color(style['borderColor']) ??
        _color(colors['border']);
    final buttonBackground = _color(componentStyle['backgroundColor']) ??
        _color(colors['buttonBg']) ??
        accent;
    final buttonText = _color(componentStyle['textColor']) ??
        _color(colors['buttonText']);
    final cardPadding = _number(spacing['cardPadding'], 0);

    if (type == 'heroCard' ||
        type == 'statusCard' ||
        type == 'infoCard' ||
        type == 'networkCard' ||
        type == 'primaryButton' ||
        type == 'button') {
      final missing = <String>[
        if (surface == null && type != 'primaryButton' && type != 'button')
          'component.style.backgroundColor / screen.style.surfaceColor / theme.colors.surface',
        if (buttonText == null && (type == 'primaryButton' || type == 'button'))
          'component.style.textColor / theme.colors.buttonText',
      ];
      if (missing.isNotEmpty) {
        return SchemaIssueWidget(
          title: 'Schema color missing',
          details: missing,
          componentType: type,
          controlId: component['id']?.toString(),
        );
      }
    }

    switch (type) {
      case 'heroCard':
        final gradient = _schemaGradient(component['gradient']) ??
            _schemaGradient(componentStyle['gradient']);
        final iconBox = _map(componentStyle['iconBox']);
        final eyebrow = _resolveText(component['eyebrow']);
        final title = _resolveText(component['title']) ??
            _resolveBindingText(component['titleBinding']);
        final body = _resolveText(component['body']) ??
            _resolveBindingText(component['bodyBinding']);
        final iconColor = _color(iconBox['iconColor']);
        final eyebrowColor =
            _color(_map(_map(_theme()['typography'])['heroEyebrow'])['color']);
        final titleTypoColor =
            _color(_map(_map(_theme()['typography'])['heroTitle'])['color']);
        final bodyTypoColor =
            _color(_map(_map(_theme()['typography'])['heroBody'])['color']);
        if ((component['icon']?.toString() ?? '').isNotEmpty &&
            iconColor == null) {
          return SchemaIssueWidget(
            title: 'Schema color missing',
            details: const [
              'Provide component.style.iconBox.iconColor',
            ],
            componentType: type,
            controlId: component['id']?.toString(),
          );
        }
        return Container(
          constraints: BoxConstraints(
            minHeight: _number(componentStyle['minHeight'], 0),
          ),
          padding: _schemaInsets(
            componentStyle['padding'],
            fallback: _number(_map(_theme()['spacing'])['heroPadding'], 18),
          ),
          decoration: BoxDecoration(
            color: gradient == null ? surface : null,
            gradient: gradient,
            borderRadius: _schemaRadius(
              componentStyle['radius'],
              themeKey: 'hero',
            ),
            border: _map(componentStyle['border']).isEmpty
                ? null
                : Border.all(
                    color: _color(_map(componentStyle['border'])['color']) ??
                        Colors.transparent,
                    width: _number(_map(componentStyle['border'])['size'], 0),
                  ),
            boxShadow: _schemaShadows(componentStyle['shadow']),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if ((component['icon']?.toString() ?? '').isNotEmpty) ...<Widget>[
                Container(
                  width: _number(iconBox['size'], 52),
                  height: _number(iconBox['size'], 52),
                  decoration: BoxDecoration(
                    color: _color(iconBox['background']),
                    borderRadius: BorderRadius.circular(
                      _number(iconBox['radius'], 999),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: _wifiIcon(
                    component['icon']?.toString(),
                    size: _number(iconBox['iconSize'], 22),
                    color: iconColor!,
                  ),
                ),
                SizedBox(width: _number(componentStyle['gap'], 14)),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (eyebrow != null && eyebrow.isNotEmpty)
                      Text(
                        eyebrow.toUpperCase(),
                        style: _textStyleFromMap(
                          _map(_map(_theme()['typography'])['heroEyebrow']),
                          fallbackColor: eyebrowColor ?? mutedTextColor,
                        ),
                      ),
                    if (title != null && title.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        title,
                        style: _textStyleFromMap(
                          _map(_map(_theme()['typography'])['heroTitle']),
                          fallbackColor: titleTypoColor ?? textColor,
                        ),
                      ),
                    ],
                    if (body != null && body.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 5),
                      Text(
                        body,
                        style: _textStyleFromMap(
                          _map(_map(_theme()['typography'])['heroBody']),
                          fallbackColor: bodyTypoColor ?? mutedTextColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );

      case 'sectionHeader':
        final titleStyle = _map(componentStyle['titleStyle']);
        final trailing = _map(component['trailing']);
        return Padding(
          padding: _schemaInsets(componentStyle['padding'], fallback: 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _resolveText(component['title']) ?? '',
                  style: _textStyleFromMap(
                    titleStyle,
                    fallbackColor: textColor,
                  ),
                ),
              ),
              if (trailing.isNotEmpty)
                _buildCompactAction(trailing, accent: accent),
            ],
          ),
        );

      case 'selectedNetworkCard':
        final network = _selectedRouter;
        if (network == null) return const SizedBox.shrink();
        final borderMap = _map(componentStyle['border']);
        return Container(
          padding: _schemaInsets(componentStyle['padding'], fallback: 14),
          decoration: BoxDecoration(
            color: _color(componentStyle['background']) ?? surface,
            borderRadius: _schemaRadius(componentStyle['radius']),
            border: borderMap.isEmpty
                ? null
                : Border.all(
                    color: _color(borderMap['color']) ?? Colors.transparent,
                    width: _number(borderMap['size'], 0),
                  ),
            boxShadow: _schemaShadows(componentStyle['shadow']),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _color(_map(_theme()['colors'])['accentSoft']),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: _wifiIcon('wifi', size: 20, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      network.ssid,
                      style: _schemaTextStyle(
                        color: textColor,
                        size: 15,
                        weight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      network.securityLabel,
                      style: _schemaTextStyle(color: mutedTextColor, size: 11),
                    ),
                  ],
                ),
              ),
              Text(
                '${network.rssi} dBm',
                style: _schemaTextStyle(color: mutedTextColor, size: 11),
              ),
            ],
          ),
        );

      case 'helperNote':
        final font = _map(componentStyle['font']);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _wifiIcon(
              componentStyle['icon']?.toString(),
              size: _number(componentStyle['iconSize'], 14),
              color: _color(componentStyle['iconColor']) ?? accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _resolveText(component['text']) ?? '',
                style: _textStyleFromMap(font, fallbackColor: mutedTextColor),
              ),
            ),
          ],
        );

      case 'circularGauge':
        final value = component['percentFrom'] is Map
            ? _progressPercent()
            : _number(component['value'], _progressPercent());
        final normalized = (value / 100.0).clamp(0.0, 1.0);
        final size = _number(componentStyle['size'], 148);
        final strokeWidth = _number(componentStyle['strokeWidth'], 8);
        final caption = _resolveText(component['caption']) ??
            _resolveBindingText(component['captionBinding']) ??
            _stageLabel(_stage, _stage);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                SizedBox(
                  width: size,
                  height: size,
                  child: CircularProgressIndicator(
                    value: normalized,
                    strokeWidth: strokeWidth,
                    backgroundColor: _color(componentStyle['trackColor']),
                    color: _color(componentStyle['progressColor']) ?? accent,
                    strokeCap: StrokeCap.round,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '${value.round()}${componentStyle['valueSuffix'] ?? '%'}',
                      style: _textStyleFromMap(
                        _map(componentStyle['valueTypography']),
                        fallbackColor: textColor,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      caption.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: _textStyleFromMap(
                        _map(componentStyle['captionTypography']),
                        fallbackColor: mutedTextColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

      case 'dotProgress':
        final count = (_number(
          componentStyle['count'],
          (_contract['progressMap'] as List?)?.length.toDouble() ?? 0,
        )).toInt();
        final completed = component['completed'] == true;
        final activeIndex = completed
            ? count - 1
            : (component['activeIndex'] as num?)?.toInt() ?? _stageIndex;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            for (var i = 0; i < count; i++) ...<Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: _number(componentStyle['size'], 8) *
                    (i == activeIndex
                        ? _number(componentStyle['currentScale'], 1.4)
                        : 1),
                height: _number(componentStyle['size'], 8) *
                    (i == activeIndex
                        ? _number(componentStyle['currentScale'], 1.4)
                        : 1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _color(
                        i < activeIndex || completed
                            ? componentStyle['completed']
                            : i == activeIndex
                                ? componentStyle['current']
                                : componentStyle['pending'],
                      ) ??
                      accent,
                ),
              ),
              if (i != count - 1)
                SizedBox(width: _number(componentStyle['gap'], 7)),
            ],
          ],
        );

      case 'stageFocusCard':
        final borderMap = _map(componentStyle['border']);
        final leadingDot = _map(componentStyle['leadingDot']);
        final text = _resolveText(component['text']) ??
            _resolveBindingText(component['textBinding']) ??
            _stageLabel(_stage, _stage);
        return Container(
          constraints: BoxConstraints(
            minHeight: _number(componentStyle['minHeight'], 52),
          ),
          padding: _schemaInsets(componentStyle['padding'], fallback: 12),
          decoration: BoxDecoration(
            color: _color(componentStyle['background']) ?? surface,
            borderRadius: _schemaRadius(componentStyle['radius']),
            border: borderMap.isEmpty
                ? null
                : Border.all(
                    color: _color(borderMap['color']) ?? Colors.transparent,
                    width: _number(borderMap['size'], 0),
                  ),
            boxShadow: _schemaShadows(componentStyle['shadow']),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: _number(leadingDot['size'], 10),
                height: _number(leadingDot['size'], 10),
                decoration: BoxDecoration(
                  color: _color(leadingDot['color']) ?? accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: _schemaTextStyle(
                    color: textColor,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );

      case 'successCard':
        final iconBox = _map(componentStyle['iconBox']);
        final ssid = _resolveBindingText(component['ssidBinding']) ??
            _selectedRouter?.ssid ??
            '';
        final bodyPrefix = _resolveText(component['bodyPrefix']) ?? '';
        return Container(
          padding: _schemaInsets(componentStyle['padding'], fallback: 18),
          decoration: BoxDecoration(
            color: _color(componentStyle['background']) ?? surface,
            borderRadius: _schemaRadius(componentStyle['radius']),
            boxShadow: _schemaShadows(componentStyle['shadow']),
          ),
          child: Column(
            children: <Widget>[
              Container(
                width: _number(iconBox['size'], 72),
                height: _number(iconBox['size'], 72),
                decoration: BoxDecoration(
                  color: _color(iconBox['background']) ??
                      _color(colors['success']) ??
                      accent,
                  borderRadius: BorderRadius.circular(
                    _number(iconBox['radius'], 24),
                  ),
                ),
                alignment: Alignment.center,
                child: _wifiIcon(
                  component['icon']?.toString() ?? iconBox['icon']?.toString(),
                  size: 30,
                  color: _color(iconBox['iconColor']) ?? textColor,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _resolveText(component['title']) ?? '',
                textAlign: TextAlign.center,
                style: _schemaTextStyle(
                  color: textColor,
                  size: 18,
                  weight: FontWeight.w800,
                ),
              ),
              if (bodyPrefix.isNotEmpty || ssid.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  '$bodyPrefix$ssid',
                  textAlign: TextAlign.center,
                  style: _schemaTextStyle(color: mutedTextColor),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  for (final rawChip
                      in (component['chips'] as List? ?? const <dynamic>[]))
                    if (rawChip is Map && _chipVisible(rawChip))
                      _buildChip(Map<String, dynamic>.from(rawChip)),
                ],
              ),
            ],
          ),
        );

      case 'cameraScanner':
        final viewfinder = _map(componentStyle['viewfinder']);
        final instruction = _map(componentStyle['instruction']);
        final overlay = _map(component['overlay']);
        return InkWell(
          onTap: _busy ? null : () => _executeAction(component['action']),
          child: Container(
            constraints: const BoxConstraints(minHeight: 420),
            decoration: BoxDecoration(
              color: _color(componentStyle['background']) ?? Colors.black,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Container(
                  width: 250,
                  height: 250,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _color(viewfinder['cornerColor']) ?? accent,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(
                      _number(viewfinder['radius'], 28),
                    ),
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 28,
                  child: Column(
                    children: <Widget>[
                      Text(
                        _resolveText(overlay['instructionTitle']) ??
                            _resolveText(instruction['title']) ??
                            '',
                        textAlign: TextAlign.center,
                        style: _schemaTextStyle(
                          color: _color(instruction['color']) ?? Colors.white,
                          size: 18,
                          weight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _resolveText(overlay['instruction']) ??
                            _resolveText(instruction['body']) ??
                            '',
                        textAlign: TextAlign.center,
                        style: _schemaTextStyle(
                          color: _color(instruction['color']) ?? Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

      case 'wifiNetworkList':
        final item = _map(component['item']);
        final rowStyle = _deepMergeMaps(
          _resolveReferenceMap(
            'wifiProvisioning.componentStyles.wifiNetworkRow',
          ),
          _deepMergeMaps(_map(item['presentation']), _map(item['style'])),
        );
        final outerBorder = _map(componentStyle['border']);
        final leading = _map(rowStyle['leadingIcon']);
        final trailing = _map(rowStyle['trailing']);
        final chevron = _map(trailing['chevron']);
        final lock = _map(trailing['lockIcon']);
        final dividerColor = _color(rowStyle['dividerColor']) ??
            const Color(0x1F000000);

        Widget rowFor(WifiRuntimeNetwork network, int index) {
          final quality = _networkQuality(component, network);
          final title = _networkBindingText(item['titleBinding'], network) ??
              network.ssid;
          final subtitle =
              _networkBindingText(item['subtitleBinding'], network) ??
                  network.securityLabel;
          final isSelected = _selectedRouter?.ssid == network.ssid;
          return InkWell(
            onTap: () => _selectNetwork(component, network),
            child: Container(
              constraints: BoxConstraints(
                minHeight: _number(rowStyle['minHeight'], 74),
              ),
              padding: _schemaInsets(
                rowStyle['padding'],
                fallback: cardPadding,
              ),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: dividerColor, width: 1)),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: _number(leading['box'], 44),
                    height: _number(leading['box'], 44),
                    decoration: BoxDecoration(
                      color: _color(leading['background']) ??
                          accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(
                        _number(leading['radius'], 16),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: _wifiIcon(
                      leading['icon']?.toString() ?? 'wifi',
                      size: _number(leading['size'], 20),
                      color: _color(leading['color']) ?? accent,
                    ),
                  ),
                  SizedBox(width: _number(rowStyle['gap'], 12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _schemaTextStyle(
                            color: textColor,
                            size: 14,
                            weight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 5,
                          children: <Widget>[
                            _networkChip('2.4 GHz', null, null),
                            if (subtitle.isNotEmpty)
                              _networkChip(subtitle, null, null),
                            if (quality != null)
                              _networkChip(
                                quality['label']?.toString() ?? '',
                                _color(quality['background']),
                                _color(quality['color']),
                              ),
                            if (index == 0)
                              _networkChip(
                                _map(
                                  component['signalQuality'],
                                )['recommendedChip'] is Map
                                    ? _map(
                                          _map(
                                            component['signalQuality'],
                                          )['recommendedChip'],
                                        )['label']
                                            ?.toString() ??
                                        'Best'
                                    : 'Best',
                                _color(
                                  _map(
                                    _map(
                                      component['signalQuality'],
                                    )['recommendedChip'],
                                  )['background'],
                                ),
                                _color(
                                  _map(
                                    _map(
                                      component['signalQuality'],
                                    )['recommendedChip'],
                                  )['color'],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _buildSignalBars(
                        network.rssi,
                        _map(trailing['signalBars']),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (!network.isOpen)
                            _wifiIcon(
                              lock['icon']?.toString() ?? 'lock',
                              size: _number(lock['size'], 16),
                              color: _color(lock['color']) ?? mutedTextColor,
                            ),
                          if (!network.isOpen) const SizedBox(width: 5),
                          _wifiIcon(
                            chevron['icon']?.toString() ?? 'chevron-right',
                            size: _number(chevron['size'], 16),
                            color: isSelected
                                ? accent
                                : (_color(chevron['color']) ?? mutedTextColor),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        Widget manualEntryRow() {
          return InkWell(
            onTap: () => _handleManualNetworkEntry(component),
            child: Container(
              constraints: BoxConstraints(
                minHeight: _number(rowStyle['minHeight'], 74),
              ),
              padding: _schemaInsets(
                rowStyle['padding'],
                fallback: cardPadding,
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: _number(leading['box'], 44),
                    height: _number(leading['box'], 44),
                    decoration: BoxDecoration(
                      color: (_color(leading['background']) ?? accent)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(
                        _number(leading['radius'], 16),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.add_rounded,
                      size: _number(leading['size'], 22),
                      color: _color(leading['color']) ?? accent,
                    ),
                  ),
                  SizedBox(width: _number(rowStyle['gap'], 12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Join Other Network...',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _schemaTextStyle(
                            color: textColor,
                            size: 14,
                            weight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Enter 2.4 GHz network name (SSID) manually',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _schemaTextStyle(
                            color: mutedTextColor,
                            size: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _wifiIcon(
                    chevron['icon']?.toString() ?? 'chevron-right',
                    size: _number(chevron['size'], 16),
                    color: _color(chevron['color']) ?? mutedTextColor,
                  ),
                ],
              ),
            ),
          );
        }

        if (_networks.isEmpty) {
          return Container(
            decoration: BoxDecoration(
              color: _color(componentStyle['background']) ?? surface,
              borderRadius: _schemaRadius(componentStyle['radius']),
              border: outerBorder.isEmpty
                  ? null
                  : Border.all(
                      color: _color(outerBorder['color']) ?? Colors.transparent,
                      width: _number(outerBorder['size'], 0),
                    ),
              boxShadow: _schemaShadows(componentStyle['shadow']),
            ),
            clipBehavior: componentStyle['overflow'] == 'hidden'
                ? Clip.antiAlias
                : Clip.none,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 24,
                  ),
                  child: Column(
                    children: <Widget>[
                      Icon(
                        Icons.wifi_off_rounded,
                        size: 40,
                        color: mutedTextColor,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _resolveText(component['emptyText']) ??
                            'No 2.4 GHz Wi-Fi networks found.',
                        textAlign: TextAlign.center,
                        style: _schemaTextStyle(
                          color: textColor,
                          size: 14,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Ensure your router is in range and 2.4 GHz band is broadcasted, or join manually.',
                        textAlign: TextAlign.center,
                        style: _schemaTextStyle(
                          color: mutedTextColor,
                          size: 12,
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _scanRouters,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Scan Again'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: accent,
                          side: BorderSide(color: accent.withValues(alpha: 0.5)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(color: dividerColor, height: 1, thickness: 1),
                manualEntryRow(),
              ],
            ),
          );
        }

        return Container(
          decoration: BoxDecoration(
            color: _color(componentStyle['background']) ?? surface,
            borderRadius: _schemaRadius(componentStyle['radius']),
            border: outerBorder.isEmpty
                ? null
                : Border.all(
                    color: _color(outerBorder['color']) ?? Colors.transparent,
                    width: _number(outerBorder['size'], 0),
                  ),
            boxShadow: _schemaShadows(componentStyle['shadow']),
          ),
          clipBehavior: componentStyle['overflow'] == 'hidden'
              ? Clip.antiAlias
              : Clip.none,
          child: Column(
            children: <Widget>[
              for (var i = 0; i < _networks.length; i++)
                rowFor(_networks[i], i),
              manualEntryRow(),
            ],
          ),
        );

      case 'textField':
        final obscure = component['obscureText'] == true ||
            componentStyle['obscureText'] == true;
        final radius =
            componentStyle['radius'] ?? componentStyle['borderRadius'];
        final borderSize =
            componentStyle['borderSize'] ?? componentStyle['borderWidth'];
        final leading = _map(componentStyle['leadingIcon']);
        final toggle = _map(componentStyle['visibilityToggle']);
        final field = TextField(
          controller: _passwordController,
          obscureText: obscure && !_showPassword,
          enableSuggestions: !obscure,
          autocorrect: !obscure,
          onChanged: (_) => setState(() {}),
          style: _schemaTextStyle(color: textColor),
          decoration: InputDecoration(
            labelText: _resolveText(component['label']) ??
                _resolveText(componentStyle['label']) ??
                '',
            labelStyle: _schemaTextStyle(color: mutedTextColor),
            filled: true,
            fillColor: _color(componentStyle['background']) ?? surface,
            prefixIcon: leading.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.all(14),
                    child: _wifiIcon(
                      leading['icon']?.toString(),
                      size: _number(leading['size'], 18),
                      color: _color(leading['color']) ?? accent,
                    ),
                  ),
            suffixIcon: obscure && toggle.isNotEmpty
                ? IconButton(
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                    icon: _wifiIcon(
                      (_showPassword ? toggle['hideIcon'] : toggle['showIcon'])
                          ?.toString(),
                      size: _number(toggle['size'], 18),
                      color: _color(toggle['color']) ?? mutedTextColor,
                    ),
                  )
                : null,
            contentPadding: _schemaInsets(
              componentStyle['padding'],
              fallback: cardPadding,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: _schemaRadius(radius, themeKey: 'card'),
              borderSide: BorderSide(
                color: _color(componentStyle['borderColor']) ??
                    border ??
                    Colors.transparent,
                width: _number(borderSize, 1),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: _schemaRadius(radius, themeKey: 'card'),
              borderSide: BorderSide(
                color: _color(componentStyle['focusBorderColor']) ?? accent,
                width: _number(
                  componentStyle['focusBorderWidth'] ?? borderSize,
                  1.5,
                ),
              ),
            ),
          ),
        );
        final height = _number(componentStyle['height'], 0);
        return height > 0 ? SizedBox(height: height, child: field) : field;

      case 'button':
        final height = _number(componentStyle['height'], 0);
        final radius =
            componentStyle['radius'] ?? componentStyle['borderRadius'];
        final iconName = component['icon']?.toString();
        final labelColor = buttonText;
        if (labelColor == null) {
          return SchemaIssueWidget(
            title: 'Schema color missing',
            details: const [
              'Provide component.style.textColor or theme.colors.buttonText',
            ],
            componentType: type,
            controlId: component['id']?.toString(),
          );
        }
        final child = Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (iconName != null && iconName.isNotEmpty) ...<Widget>[
              _wifiIcon(iconName, size: 18, color: labelColor),
              const SizedBox(width: 8),
            ],
            Text(
              _resolveText(component['text']) ?? '',
              style: _schemaTextStyle(
                color: labelColor,
                weight: _fontWeight(
                  componentStyle['fontWeight'],
                  FontWeight.w800,
                ),
              ),
            ),
          ],
        );
        final button = FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: buttonBackground,
            foregroundColor: labelColor,
            padding: _schemaInsets(
              componentStyle['padding'],
              fallback: cardPadding,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: _schemaRadius(radius, themeKey: 'button'),
            ),
          ),
          onPressed: _busy ? null : () => _executeAction(component['action']),
          child: child,
        );
        return SizedBox(
          width: componentStyle['width'] == 'content' ? null : double.infinity,
          height: height > 0 ? height : null,
          child: button,
        );

      case 'progress':
        final indeterminate = component['indeterminate'] == true;
        if (indeterminate) {
          return Center(child: CircularProgressIndicator(color: accent));
        }

        final value = _stageIndex >= 0
            ? (_stageIndex + 1) /
                ((_contract['progressMap'] as List?)?.length ?? 1)
            : 0.0;

        return CircularProgressIndicator(
          value: value.clamp(0.0, 1.0),
          color: accent,
        );

      case 'stepProgress':
        final steps = (component['steps'] as List? ?? const <dynamic>[])
            .map((item) => item.toString())
            .toList(growable: false);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (var index = 0; index < steps.length; index++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  index <= _stageIndex
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: index <= _stageIndex ? accent : mutedTextColor,
                ),
                title: Text(
                  steps[index],
                  style: _schemaTextStyle(color: textColor),
                ),
                subtitle: index == _stageIndex
                    ? Text(
                        _stageLabel(_stage, _stage),
                        style: _schemaTextStyle(color: mutedTextColor),
                      )
                    : null,
              ),
          ],
        );

      case 'text':
        return Text(
          _resolveText(component['text']) ??
              _resolveBindingText(component['textBinding']) ??
              '',
          style: _schemaTextStyle(
            color: _color(componentStyle['textColor']) ?? textColor,
            size: _number(
              componentStyle['fontSize'],
              _number(_map(theme['typography'])['bodySize'], 14),
            ),
            weight: _fontWeight(
              componentStyle['fontWeight'],
              _fontWeight(
                _map(theme['typography'])['bodyWeight'],
                FontWeight.w400,
              ),
            ),
          ),
        );

      default:
        return SelectableText(
          'Unsupported Wi-Fi schema component type: ${type ?? "<missing>"}',
        );
    }
  }

  Future<void> _handleManualNetworkEntry(Map<String, dynamic> component) async {
    final manual = await _promptManualSsid(
      title: 'Join Other Network',
      message: 'Enter the exact network name (SSID) of your 2.4 GHz Wi-Fi router.',
    );
    if (manual == null || manual.trim().isEmpty) return;
    final ssid = manual.trim();

    WifiRuntimeNetwork selected;
    final existingIndex = _networks.indexWhere(
      (n) => n.ssid.toLowerCase() == ssid.toLowerCase(),
    );
    if (existingIndex >= 0) {
      selected = _networks[existingIndex];
    } else {
      selected = WifiRuntimeNetwork(
        ssid: ssid,
        bssid: '',
        rssi: -50,
        frequency: 2412,
        securityLabel: 'WPA2',
        security: 'WPA2',
        isOpen: false,
      );
      if (mounted) {
        setState(() {
          _networks = <WifiRuntimeNetwork>[selected, ..._networks];
        });
      }
    }
    _selectNetwork(component, selected);
  }

  void _selectNetwork(
    Map<String, dynamic> component,
    WifiRuntimeNetwork network,
  ) {
    setState(() {
      _selectedRouter = network;
      _errorCode = null;
      _errorMessage = null;
      if (network.isOpen) _passwordController.clear();
    });
    unawaited(_persistLastWifi(network.ssid));

    final onSelect = _map(component['onSelect']);
    final normal = onSelect['nextScreen']?.toString().trim() ?? '';
    final open = onSelect['nextScreenWhenOpen']?.toString().trim() ?? '';

    var next = network.isOpen && open.isNotEmpty ? open : normal;
    if (next.isEmpty && (_screenId == 'wifiNetworkPicker' || _screenId == 'gatewayDetails')) {
      next = 'wifiPassword';
    }
    // Entering password (or skipping straight to setup for open networks):
    // stop discovery + disconnect cloud immediately.
    if (next == 'wifiPassword' ||
        next == 'deviceDiscovery' ||
        next == 'provisioning') {
      unawaited(_quiesceNetworkForProvisioning());
    }
    if (next.isNotEmpty) _goTo(next);
  }

  String? _networkBindingText(dynamic binding, WifiRuntimeNetwork network) {
    final path = binding?.toString();
    if (path == null || path.isEmpty) return null;

    final item = network.toMap();
    final key = path.split('.').last;
    final value = item[key];
    return value?.toString();
  }

  String? _resolveText(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is Map) {
      return value['text']?.toString() ??
          value['fallback']?.toString() ??
          value[r'$i18n']?.toString();
    }
    return value.toString();
  }

  String? _resolveBindingText(dynamic binding) {
    final path = binding?.toString();
    if (path == null) return null;

    if (path.endsWith('selectedRouter.ssid')) {
      return _selectedRouter?.ssid;
    }
    if (path.endsWith('errorMessage')) {
      return _errorMessage;
    }
    if (path.endsWith('errorCode')) {
      return _errorCode;
    }
    if (path.endsWith('stage')) {
      return _stageLabel(_stage, _stage);
    }
    if (path.endsWith('stageIndex')) {
      return _stageIndex.toString();
    }
    if (path.endsWith('onlineConfirmed')) {
      return _onlineConfirmed.toString();
    }
    return null;
  }
}

extension _FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

class _WifiFlowCancelled implements Exception {
  const _WifiFlowCancelled();
}
