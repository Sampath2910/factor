import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide theme mode. [system] follows the OS brightness; [dark]/[light]
/// force a mode. The app defaults to [dark] on first run.
enum AppThemeMode { system, light, dark }

/// Single source of truth for the app's theme, read by every surface and every
/// MaterialApp. Dark is the default; the choice is persisted on device.
///
/// This is intentionally additive and non-breaking: nothing that reads the
/// controller is required, and when no choice has been stored the controller
/// resolves to [AppThemeMode.dark], matching the app's current look.
class ThemeController extends ChangeNotifier {
  ThemeController._();

  /// Global singleton. Use [ThemeController.instance] everywhere.
  static final ThemeController instance = ThemeController._();

  static const String _prefKey = 'app.themeMode.v1';

  AppThemeMode _mode = AppThemeMode.dark;
  bool _loaded = false;

  /// The user's selected mode. Defaults to [AppThemeMode.dark].
  AppThemeMode get mode => _mode;

  /// True once the persisted value has been read from disk. Until then the
  /// controller safely reports the default (dark).
  bool get isLoaded => _loaded;

  /// True when the user explicitly picked light or dark (not "system" / unset).
  /// Used so a user choice can win over a server-forced theme.
  bool get userOverride => _loaded && _mode != AppThemeMode.system;

  /// Maps the app mode onto Flutter's [ThemeMode] for MaterialApp.
  ThemeMode get materialThemeMode {
    switch (_mode) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }

  /// Resolves the effective brightness, honoring the OS when mode is system.
  /// Pass a [context]; falls back to the platform dispatcher when none given.
  Brightness resolvedBrightness([BuildContext? context]) {
    switch (_mode) {
      case AppThemeMode.light:
        return Brightness.light;
      case AppThemeMode.dark:
        return Brightness.dark;
      case AppThemeMode.system:
        final platform = context != null
            ? MediaQuery.maybeOf(context)?.platformBrightness
            : null;
        return platform ??
            WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  /// Convenience: is the effective theme dark right now?
  bool isDark([BuildContext? context]) =>
      resolvedBrightness(context) == Brightness.dark;

  /// The theme word the webviews / backend expect: "dark" or "light".
  /// For "system", resolves against the OS so we always send a concrete value.
  String resolvedThemeWord([BuildContext? context]) =>
      isDark(context) ? 'dark' : 'light';

  /// Loads the persisted mode. Call once during app startup (before runApp or
  /// early in the first frame). Safe to call more than once.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefKey);
      _mode = _parse(stored) ?? AppThemeMode.dark;
    } catch (_) {
      // Storage unavailable (e.g. first run / restricted): keep the default.
      _mode = AppThemeMode.dark;
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Sets and persists the mode, notifying listeners so the whole app rebuilds.
  Future<void> setMode(AppThemeMode next) async {
    if (_mode == next && _loaded) return;
    _mode = next;
    _loaded = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, _serialize(next));
    } catch (_) {
      // Non-fatal: the in-memory choice still applies for this session.
    }
  }

  /// Cycles Dark -> Light -> System -> Dark. Handy for a simple toggle button.
  Future<void> cycle() async {
    switch (_mode) {
      case AppThemeMode.dark:
        return setMode(AppThemeMode.light);
      case AppThemeMode.light:
        return setMode(AppThemeMode.system);
      case AppThemeMode.system:
        return setMode(AppThemeMode.dark);
    }
  }

  static AppThemeMode? _parse(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'system':
        return AppThemeMode.system;
      case 'light':
        return AppThemeMode.light;
      case 'dark':
        return AppThemeMode.dark;
      default:
        return null;
    }
  }

  static String _serialize(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.system:
        return 'system';
      case AppThemeMode.light:
        return 'light';
      case AppThemeMode.dark:
        return 'dark';
    }
  }
}
