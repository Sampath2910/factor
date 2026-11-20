import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/breadcrumb.dart';

/// Offline-first local store for breadcrumbs awaiting upload. Points are
/// written here FIRST (with their `client_uuid`) so nothing is lost in dead
/// zones; the sync dispatcher drains them in batches.
///
/// Interface so the storage backend can be swapped (e.g. SQLite) without
/// touching the sync logic.
abstract interface class BreadcrumbOutbox {
  Future<void> enqueue(Breadcrumb point);
  Future<List<Breadcrumb>> peek(int limit);
  Future<void> remove(Iterable<String> clientUuids);
  Future<int> count();
  Future<void> clear();
}

/// Default SharedPreferences-backed outbox. Adequate for Phase 0 volumes
/// (interval sampling); a SQLite implementation can replace it later for very
/// large offline backlogs — the interface is unchanged.
class PrefsBreadcrumbOutbox implements BreadcrumbOutbox {
  PrefsBreadcrumbOutbox({this.maxItems = 5000});

  static const String _key = 'efactor.field_tracker.breadcrumb_outbox';

  /// Safety cap so a long offline period can't grow prefs unbounded; oldest
  /// points are dropped first if exceeded.
  final int maxItems;

  Future<List<String>> _raw(SharedPreferences prefs) =>
      Future<List<String>>.value(prefs.getStringList(_key) ?? <String>[]);

  @override
  Future<void> enqueue(Breadcrumb point) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _raw(prefs);
    list.add(point.encodeStore());
    if (list.length > maxItems) {
      list.removeRange(0, list.length - maxItems);
    }
    await prefs.setStringList(_key, list);
  }

  @override
  Future<List<Breadcrumb>> peek(int limit) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _raw(prefs);
    final take = limit <= 0 ? list.length : limit.clamp(0, list.length);
    final out = <Breadcrumb>[];
    for (var i = 0; i < take; i++) {
      try {
        final map = jsonDecode(list[i]);
        if (map is Map<String, dynamic>) out.add(Breadcrumb.fromStore(map));
      } catch (_) {
        // Skip a corrupt row; it will be pruned on the next successful remove.
      }
    }
    return out;
  }

  @override
  Future<void> remove(Iterable<String> clientUuids) async {
    final ids = clientUuids.toSet();
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = await _raw(prefs);
    final kept = <String>[];
    for (final row in list) {
      try {
        final map = jsonDecode(row);
        if (map is Map<String, dynamic> &&
            ids.contains(map['client_uuid']?.toString())) {
          continue; // drop uploaded point
        }
      } catch (_) {
        continue; // drop corrupt row
      }
      kept.add(row);
    }
    await prefs.setStringList(_key, kept);
  }

  @override
  Future<int> count() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[]).length;
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
