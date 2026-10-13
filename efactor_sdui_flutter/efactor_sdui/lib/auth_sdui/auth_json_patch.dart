import 'dart:convert';

/// Small RFC-6902 compatible JSON Patch executor used for schema deltas.
///
/// The backend schema currently names the response field `patch` but does not
/// explicitly advertise a patch media type. For safety this executor is used
/// only when every operation has a valid RFC-6902 `op` + JSON Pointer `path`.
/// Any malformed/unsupported patch throws and the caller falls back to a full
/// schema fetch instead of risking a partially corrupted cached schema.
class AuthJsonPatch {
  const AuthJsonPatch._();

  static Map<String, dynamic> apply(
    Map<String, dynamic> source,
    List<dynamic> operations,
  ) {
    dynamic document = _clone(source);

    for (var index = 0; index < operations.length; index++) {
      final raw = operations[index];
      if (raw is! Map) {
        throw FormatException(
          'JSON Patch operation[$index] must be an object.',
        );
      }

      final operation = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
      final op = operation['op']?.toString().trim().toLowerCase();
      final path = operation['path']?.toString();

      if (op == null || op.isEmpty || path == null) {
        throw FormatException(
          'JSON Patch operation[$index] requires op and path.',
        );
      }

      switch (op) {
        case 'add':
          if (!operation.containsKey('value')) {
            throw FormatException(
              'JSON Patch add operation[$index] requires value.',
            );
          }
          document = _add(document, path, _clone(operation['value']));
          break;
        case 'remove':
          document = _remove(document, path);
          break;
        case 'replace':
          if (!operation.containsKey('value')) {
            throw FormatException(
              'JSON Patch replace operation[$index] requires value.',
            );
          }
          document = _replace(document, path, _clone(operation['value']));
          break;
        case 'move':
          final from = operation['from']?.toString();
          if (from == null) {
            throw FormatException(
              'JSON Patch move operation[$index] requires from.',
            );
          }
          final value = _clone(_read(document, from));
          document = _remove(document, from);
          document = _add(document, path, value);
          break;
        case 'copy':
          final from = operation['from']?.toString();
          if (from == null) {
            throw FormatException(
              'JSON Patch copy operation[$index] requires from.',
            );
          }
          document = _add(document, path, _clone(_read(document, from)));
          break;
        case 'test':
          if (!operation.containsKey('value')) {
            throw FormatException(
              'JSON Patch test operation[$index] requires value.',
            );
          }
          final actual = _read(document, path);
          if (!_deepEquals(actual, operation['value'])) {
            throw StateError('JSON Patch test operation[$index] failed.');
          }
          break;
        default:
          throw UnsupportedError('Unsupported JSON Patch op "$op".');
      }
    }

    if (document is! Map) {
      throw const FormatException(
        'Auth schema patch must leave an object at the document root.',
      );
    }

    return Map<String, dynamic>.from(document.cast<dynamic, dynamic>());
  }

  static dynamic _add(dynamic document, String path, dynamic value) {
    final tokens = _tokens(path);
    if (tokens.isEmpty) return value;

    final target = _resolveParent(document, tokens);
    final key = tokens.last;

    if (target is Map<String, dynamic>) {
      target[key] = value;
      return document;
    }

    if (target is List) {
      if (key == '-') {
        target.add(value);
        return document;
      }
      final index = _arrayIndex(key, target.length, allowEnd: true);
      target.insert(index, value);
      return document;
    }

    throw FormatException(
      'JSON Pointer parent for "$path" is not a container.',
    );
  }

  static dynamic _remove(dynamic document, String path) {
    final tokens = _tokens(path);
    if (tokens.isEmpty) {
      throw const FormatException(
        'Removing the complete auth schema is invalid.',
      );
    }

    final target = _resolveParent(document, tokens);
    final key = tokens.last;

    if (target is Map<String, dynamic>) {
      if (!target.containsKey(key)) {
        throw FormatException('JSON Pointer "$path" does not exist.');
      }
      target.remove(key);
      return document;
    }

    if (target is List) {
      final index = _arrayIndex(key, target.length, allowEnd: false);
      target.removeAt(index);
      return document;
    }

    throw FormatException(
      'JSON Pointer parent for "$path" is not a container.',
    );
  }

  static dynamic _replace(dynamic document, String path, dynamic value) {
    final tokens = _tokens(path);
    if (tokens.isEmpty) return value;

    final target = _resolveParent(document, tokens);
    final key = tokens.last;

    if (target is Map<String, dynamic>) {
      if (!target.containsKey(key)) {
        throw FormatException('JSON Pointer "$path" does not exist.');
      }
      target[key] = value;
      return document;
    }

    if (target is List) {
      final index = _arrayIndex(key, target.length, allowEnd: false);
      target[index] = value;
      return document;
    }

    throw FormatException(
      'JSON Pointer parent for "$path" is not a container.',
    );
  }

  static dynamic _read(dynamic document, String path) {
    var current = document;
    final tokens = _tokens(path);

    for (final token in tokens) {
      if (current is Map<String, dynamic>) {
        if (!current.containsKey(token)) {
          throw FormatException('JSON Pointer "$path" does not exist.');
        }
        current = current[token];
        continue;
      }

      if (current is List) {
        final index = _arrayIndex(token, current.length, allowEnd: false);
        current = current[index];
        continue;
      }

      throw FormatException('JSON Pointer "$path" traverses a scalar value.');
    }

    return current;
  }

  static dynamic _resolveParent(dynamic document, List<String> tokens) {
    var current = document;
    for (final token in tokens.take(tokens.length - 1)) {
      if (current is Map<String, dynamic>) {
        if (!current.containsKey(token)) {
          throw FormatException(
            'JSON Pointer segment "$token" does not exist.',
          );
        }
        current = current[token];
        continue;
      }

      if (current is List) {
        final index = _arrayIndex(token, current.length, allowEnd: false);
        current = current[index];
        continue;
      }

      throw FormatException(
        'JSON Pointer segment "$token" traverses a scalar value.',
      );
    }
    return current;
  }

  static List<String> _tokens(String path) {
    if (path.isEmpty) return const <String>[];
    if (!path.startsWith('/')) {
      throw FormatException('JSON Pointer must start with "/": "$path".');
    }

    return path
        .substring(1)
        .split('/')
        .map((token) => token.replaceAll('~1', '/').replaceAll('~0', '~'))
        .toList(growable: false);
  }

  static int _arrayIndex(String raw, int length, {required bool allowEnd}) {
    if (raw == '-') {
      if (allowEnd) return length;
      throw const FormatException('"-" is only valid for JSON Patch add.');
    }

    final index = int.tryParse(raw);
    if (index == null || index < 0) {
      throw FormatException('Invalid JSON array index "$raw".');
    }

    final maximum = allowEnd ? length : length - 1;
    if (index > maximum) {
      throw RangeError('JSON array index $index is outside 0..$maximum.');
    }
    return index;
  }

  static dynamic _clone(dynamic value) {
    if (value == null || value is bool || value is num || value is String) {
      return value;
    }
    return jsonDecode(jsonEncode(value));
  }

  static bool _deepEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a.runtimeType != b.runtimeType) {
      if (a is num && b is num) return a == b;
      return false;
    }

    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }

    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }

    return a == b;
  }
}
