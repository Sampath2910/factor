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
  const LocationStartupGate({super.key, required this.child});

  final Widget child;

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
  static const Duration _locationCheckCacheWindow = Duration(minutes: 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _evaluate(requestPermission: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_state == _LocationGateState.ready &&
          _lastEvaluatedAt != null &&
          DateTime.now().difference(_lastEvaluatedAt!) <
              _locationCheckCacheWindow) {
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
            _locationCheckCacheWindow) {
      return;
    }

    _busy = true;

    if (mounted && _state != _LocationGateState.ready) {
      setState(() {
        _state = _LocationGateState.checking;
        _error = null;
      });
    }

    try {
      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied && requestPermission) {
        permission = await Geolocator.requestPermission();
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

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!mounted) return;

      _lastEvaluatedAt = DateTime.now();
      final isReady = serviceEnabled;
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
      _busy = false;
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

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        splashFactory: InkRipple.splashFactory,
      ),
      home: Scaffold(
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
                    child: _state == _LocationGateState.checking
                        ? const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              CircularProgressIndicator(),
                              SizedBox(height: 18),
                              Text('Checking location access…'),
                            ],
                          )
                        : Column(
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
      ),
    );
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
