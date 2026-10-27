import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'user_location_service.dart';

/// Blocks the application shell until foreground location permission is
/// available and the system Location service is enabled.
///
/// This is intentionally outside AuthUiGate so it also protects restored
/// sessions: a user who is already signed in but has disabled Location sees
/// this gate before Home/IoT/Device screens are entered.
class LocationStartupGate extends StatefulWidget {
  const LocationStartupGate({
    super.key,
    required this.child,
    this.initialReady,
  });

  final Widget child;
  final bool? initialReady;

  /// Global cached state to allow instant zero-flicker routing from startup splash.
  static bool isReady = false;
  static DateTime? lastEvaluatedAt;
  static const Duration locationCheckCacheWindow = Duration(minutes: 10);

  /// Pre-evaluates location permission and service status during startup splash.
  static Future<bool> prewarm() async {
    try {
      final permission = await Geolocator.checkPermission().timeout(
        const Duration(seconds: 2),
        onTimeout: () => LocationPermission.denied,
      );
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled().timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        );
        isReady = serviceEnabled;
        lastEvaluatedAt = DateTime.now();
        return isReady;
      }
    } catch (e) {
      debugPrint('[LocationStartupGate] prewarm error: $e');
    }
    isReady = false;
    return false;
  }

  static void resetCache() {
    isReady = false;
    lastEvaluatedAt = null;
  }

  @override
  State<LocationStartupGate> createState() => _LocationStartupGateState();
}

enum _LocationGateState {
  checking,
  ready,
  permissionDenied,
  permissionDeniedForever,
  serviceDisabled,
}

class _LocationStartupGateState extends State<LocationStartupGate>
    with WidgetsBindingObserver {
  _LocationGateState _state = _LocationGateState.checking;
  bool _busy = false;
  String? _error;
  DateTime? _lastEvaluatedAt;
  Timer? _watchdogTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialReady == true ||
        (LocationStartupGate.isReady &&
            LocationStartupGate.lastEvaluatedAt != null &&
            DateTime.now().difference(LocationStartupGate.lastEvaluatedAt!) <
                LocationStartupGate.locationCheckCacheWindow)) {
      _state = _LocationGateState.ready;
      _lastEvaluatedAt =
          LocationStartupGate.lastEvaluatedAt ?? DateTime.now();
    } else {
      _evaluate(requestPermission: true);
    }
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_state == _LocationGateState.ready &&
          _lastEvaluatedAt != null &&
          DateTime.now().difference(_lastEvaluatedAt!) <
              LocationStartupGate.locationCheckCacheWindow) {
        return;
      }
      _evaluate(requestPermission: false);
    }
  }

  Future<void> _evaluate({required bool requestPermission}) async {
    if (_busy) return;

    if (_state == _LocationGateState.ready &&
        !requestPermission &&
        _lastEvaluatedAt != null &&
        DateTime.now().difference(_lastEvaluatedAt!) <
            LocationStartupGate.locationCheckCacheWindow) {
      return;
    }

    _busy = true;

    if (mounted && _state != _LocationGateState.ready) {
      setState(() {
        _state = _LocationGateState.checking;
        _error = null;
      });
    }

    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 3, milliseconds: 500), () {
      if (mounted && _state == _LocationGateState.checking) {
        debugPrint(
          '[LocationStartupGate] Watchdog expired: bypassing stuck checking state',
        );
        setState(() {
          _state = _LocationGateState.ready;
          _busy = false;
        });
      }
    });

    try {
      var permission = await Geolocator.checkPermission().timeout(
        const Duration(seconds: 2),
        onTimeout: () => LocationPermission.denied,
      );

      if (permission == LocationPermission.denied && requestPermission) {
        permission = await Geolocator.requestPermission().timeout(
          const Duration(seconds: 6),
          onTimeout: () => LocationPermission.denied,
        );
      }

      if (!mounted) return;

      if (permission == LocationPermission.deniedForever) {
        setState(() => _state = _LocationGateState.permissionDeniedForever);
        return;
      }

      if (permission == LocationPermission.denied) {
        setState(() => _state = _LocationGateState.permissionDenied);
        return;
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      if (!mounted) return;

      _lastEvaluatedAt = DateTime.now();
      final isReady = serviceEnabled;
      LocationStartupGate.isReady = isReady;
      LocationStartupGate.lastEvaluatedAt = _lastEvaluatedAt;
      setState(
        () => _state = isReady
            ? _LocationGateState.ready
            : _LocationGateState.serviceDisabled,
      );

      if (isReady) {
        unawaited(UserLocationService.instance.sendCurrentLocation());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _LocationGateState.permissionDenied;
        _error = error.toString();
      });
    } finally {
      _watchdogTimer?.cancel();
      _busy = false;
      if (mounted && _state == _LocationGateState.checking) {
        setState(() => _state = _LocationGateState.ready);
      }
    }
  }

  Future<void> _primaryAction() async {
    switch (_state) {
      case _LocationGateState.permissionDenied:
        await _evaluate(requestPermission: true);
        break;
      case _LocationGateState.permissionDeniedForever:
        await Geolocator.openAppSettings();
        break;
      case _LocationGateState.serviceDisabled:
        await Geolocator.openLocationSettings();
        break;
      case _LocationGateState.checking:
      case _LocationGateState.ready:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _LocationGateState.ready) {
      return widget.child;
    }

    if (_state == _LocationGateState.checking) {
      const checkingWidget = Scaffold(
        backgroundColor: Color(0xFF0D121C),
        body: Center(
          child: SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6750A4)),
            ),
          ),
        ),
      );
      if (Directionality.maybeOf(context) == null) {
        return const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: checkingWidget,
        );
      }
      return checkingWidget;
    }

    final promptScaffold = Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(
                        Icons.location_on_outlined,
                        size: 44,
                        color: Color(0xFF2563EB),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _title,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _message,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 18),
                      const _RequirementRow(
                        icon: Icons.my_location_outlined,
                        title: 'Location permission',
                      ),
                      const SizedBox(height: 12),
                      const _RequirementRow(
                        icon: Icons.location_searching_outlined,
                        title: 'Device location service',
                      ),
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 14),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Color(0xFFB91C1C),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _primaryAction,
                          icon: const Icon(Icons.settings_outlined),
                          label: Text(_buttonLabel),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () =>
                                    _evaluate(requestPermission: false),
                          child: const Text('Check again'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: () {
                            setState(() {
                              _state = _LocationGateState.ready;
                            });
                          },
                          child: const Text(
                            'Continue without Location',
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w500,
                            ),
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
    );

    if (Directionality.maybeOf(context) == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: InkRipple.splashFactory,
        ),
        home: promptScaffold,
      );
    }
    return promptScaffold;
  }

  String get _title {
    switch (_state) {
      case _LocationGateState.serviceDisabled:
        return 'Turn on device location';
      case _LocationGateState.permissionDeniedForever:
        return 'Allow location in app settings';
      case _LocationGateState.permissionDenied:
        return 'Location permission is required';
      case _LocationGateState.checking:
      case _LocationGateState.ready:
        return 'Location access';
    }
  }

  String get _message {
    switch (_state) {
      case _LocationGateState.serviceDisabled:
        return 'Device location is currently turned off. Turn it on so nearby-device and Wi-Fi provisioning features can work correctly.';
      case _LocationGateState.permissionDeniedForever:
        return 'Location permission was disabled for this app. Open app settings and allow location while using the app.';
      case _LocationGateState.permissionDenied:
        return 'Allow location while using the app. This permission is required by nearby-device and Wi-Fi provisioning flows on supported devices.';
      case _LocationGateState.checking:
      case _LocationGateState.ready:
        return '';
    }
  }

  String get _buttonLabel {
    switch (_state) {
      case _LocationGateState.serviceDisabled:
        return 'Turn on location';
      case _LocationGateState.permissionDeniedForever:
        return 'Open app settings';
      case _LocationGateState.permissionDenied:
        return 'Allow location';
      case _LocationGateState.checking:
      case _LocationGateState.ready:
        return 'Continue';
    }
  }
}

class _RequirementRow extends StatelessWidget {
  const _RequirementRow({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, color: const Color(0xFF2563EB)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
