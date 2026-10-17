import 'package:flutter/material.dart';

/// Manages pre-warmed, keep-alive instances of Circle Connect and Professional Space.
///
/// Instead of destroying and recreating WebViews every time the user navigates,
/// instances are kept alive in memory. This eliminates the 2-4 second white
/// loading spinner, delivering instant (<16ms) tab transitions just like native apps.
class GridShellPool {
  GridShellPool._();
  static final GridShellPool instance = GridShellPool._();

  final Map<String, Widget> _warmedShells = <String, Widget>{};
  final Map<String, DateTime> _shellCreationTimes = <String, DateTime>{};
  static const Duration _maxWarmAge = Duration(minutes: 60);

  /// Normalizes the key based on host and path so Circle Connect and Professional Space
  /// map to consistent singleton instances.
  String _poolKey(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.contains('circle') || path.contains('chat')) {
      return 'circle_connect';
    }
    if (path.contains('professional') || path.contains('space') || path.contains('profile')) {
      return 'professional_space';
    }
    return '${uri.host}_${uri.path}';
  }

  /// Checks if an instance for this destination already exists in the pool.
  bool hasWarmInstance(Uri uri) {
    return _warmedShells.containsKey(_poolKey(uri));
  }

  /// Gets or creates a warmed shell widget, refreshing if older than [maxAge].
  Widget getOrCreateWarmShell({
    required Uri uri,
    required Widget Function() shellBuilder,
    Duration maxAge = _maxWarmAge,
  }) {
    final key = _poolKey(uri);
    final created = _shellCreationTimes[key];
    if (created != null && DateTime.now().difference(created) > maxAge) {
      _warmedShells.remove(key);
      _shellCreationTimes.remove(key);
    }
    _shellCreationTimes.putIfAbsent(key, DateTime.now);
    return _warmedShells.putIfAbsent(key, shellBuilder);
  }

  /// Clears the warmed shells when logging out.
  void clearAll() {
    _warmedShells.clear();
    _shellCreationTimes.clear();
  }
}
