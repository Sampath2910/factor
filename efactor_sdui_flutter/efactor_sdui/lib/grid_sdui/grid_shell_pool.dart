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

  /// Normalizes the key based on host, path, and userId so Circle Connect and Professional Space
  /// map to consistent singleton instances scoped to the currently active user account.
  String _poolKey(Uri uri, {int? userId}) {
    final prefix = userId != null ? 'user_${userId}_' : '';
    final path = uri.path.toLowerCase();
    if (path.contains('scanner') || path.contains('scan')) {
      return '${prefix}grid_scanner';
    }
    if (path.contains('circle') || path.contains('chat')) {
      return '${prefix}circle_connect';
    }
    if (path.contains('professional') ||
        path.contains('space') ||
        path.contains('profile') ||
        path.endsWith('/grid') ||
        path.contains('/grid/') ||
        path.contains('/index.php/grid')) {
      return '${prefix}professional_space';
    }
    return '$prefix${uri.host}_${uri.path}';
  }

  /// Checks if an instance for this destination already exists in the pool.
  bool hasWarmInstance(Uri uri, {int? userId}) {
    return _warmedShells.containsKey(_poolKey(uri, userId: userId));
  }

  /// Gets or creates a warmed shell widget, refreshing if older than [maxAge].
  Widget getOrCreateWarmShell({
    required Uri uri,
    required Widget Function() shellBuilder,
    int? userId,
    Duration maxAge = _maxWarmAge,
  }) {
    final key = _poolKey(uri, userId: userId);
    final created = _shellCreationTimes[key];
    if (created != null && DateTime.now().difference(created) > maxAge) {
      _warmedShells.remove(key);
      _shellCreationTimes.remove(key);
    }
    _shellCreationTimes.putIfAbsent(key, DateTime.now);
    return _warmedShells.putIfAbsent(key, shellBuilder);
  }

  /// Removes a shell from the pool when its route is popped and disposed.
  void removeShell(Uri uri, {int? userId}) {
    final key = _poolKey(uri, userId: userId);
    _warmedShells.remove(key);
    _shellCreationTimes.remove(key);
  }

  /// Clears the warmed shells when logging out.
  void clearAll() {
    _warmedShells.clear();
    _shellCreationTimes.clear();
  }
}
