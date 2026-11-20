import 'dart:convert';
import 'package:flutter/foundation.dart';

void logDebug(String message) {
  // No-op in release builds: these are developer diagnostics only, and keeping
  // them out of production avoids synchronous logcat I/O on hot paths.
  if (kReleaseMode) return;
  // ignore: avoid_print
  print(message);
}

bool looksLikeHtml(String body) {
  final trimmed = body.trimLeft();
  if (trimmed.isEmpty) return false;
  final head =
      (trimmed.length > 80 ? trimmed.substring(0, 80) : trimmed).toLowerCase();
  return head.startsWith('<!doctype') ||
      head.startsWith('<html') ||
      head.contains('<head') ||
      head.contains('<body');
}

bool isJsonContentType(String? contentType) {
  if (contentType == null || contentType.trim().isEmpty) return false;
  final lower = contentType.toLowerCase();
  return lower.contains('application/json') || lower.contains('+json');
}

void ensureDecodableJson({
  required String body,
  String? contentType,
  required String source,
}) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) {
    throw FormatException('Empty response from $source.');
  }
  if (looksLikeHtml(body)) {
    throw FormatException(
      'API returned HTML instead of JSON from $source. '
      'This is usually a login, WAF, or gateway error page.',
    );
  }
  if (contentType != null &&
      contentType.trim().isNotEmpty &&
      !isJsonContentType(contentType) &&
      !trimmed.startsWith('{') &&
      !trimmed.startsWith('[')) {
    throw FormatException(
      'API returned non-JSON content-type "$contentType" from $source.',
    );
  }
}

/// Extracts a valid JSON string when the server prepends or appends non-JSON text
/// (e.g. PHP warnings, SMTP debug logs, or notices).
///
/// shortcut: picks the first '{'/'[' to the last '}'/']'. If the leading noise
/// itself contains a stray bracket before the real payload, the slice is wrong
/// and decode fails into the caller's error path (fails safe, never wrong data).
/// Upgrade to a brace-matching scan if the server starts emitting bracketed
/// noise before clean JSON.
String extractJsonPayload(String body) {
  final trimmed = body.trim();
  // Fast path only when the body is clean on BOTH ends; a body that starts with
  // '{' but has trailing noise still needs slicing.
  if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    return trimmed;
  }
  final startBrace = trimmed.indexOf('{');
  final startBracket = trimmed.indexOf('[');
  int start = -1;
  if (startBrace != -1 && startBracket != -1) {
    start = startBrace < startBracket ? startBrace : startBracket;
  } else if (startBrace != -1) {
    start = startBrace;
  } else if (startBracket != -1) {
    start = startBracket;
  }

  if (start == -1) return trimmed;

  final endBrace = trimmed.lastIndexOf('}');
  final endBracket = trimmed.lastIndexOf(']');
  final end = endBrace > endBracket ? endBrace : endBracket;
  if (end == -1 || end <= start) return trimmed;

  return trimmed.substring(start, end + 1);
}

dynamic decodeJsonBody({
  required String body,
  String? contentType,
  required String source,
}) {
  final sanitized = extractJsonPayload(body);
  ensureDecodableJson(body: sanitized, contentType: contentType, source: source);
  try {
    return jsonDecode(sanitized);
  } on FormatException catch (error) {
    throw FormatException('Invalid JSON from $source: ${error.message}');
  }
}

dynamic _isolateJsonDecode(String body) => jsonDecode(body);

/// Asynchronously decodes JSON, offloading bodies larger than 50KB to a background
/// isolate via [compute] to prevent UI thread frame drops.
Future<dynamic> decodeJsonBodyAsync({
  required String body,
  String? contentType,
  required String source,
}) async {
  final sanitized = extractJsonPayload(body);
  ensureDecodableJson(body: sanitized, contentType: contentType, source: source);
  try {
    if (sanitized.length > 50 * 1024) {
      return await compute(_isolateJsonDecode, sanitized);
    }
    return jsonDecode(sanitized);
  } on FormatException catch (error) {
    throw FormatException('Invalid JSON from $source: ${error.message}');
  }
}

String contentHash(Object? value) {
  return contentHashString(jsonEncode(value));
}

String contentHashString(String raw) {
  // BigInt keeps FNV-1a 64-bit exact on both VM and JavaScript.
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  for (final unit in raw.codeUnits) {
    hash ^= BigInt.from(unit);
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

void assignClientHash(
  Map<String, dynamic> schema,
  String key, {
  String? rawSource,
}) {
  if (rawSource != null && rawSource.isNotEmpty) {
    schema[key] = contentHashString(rawSource);
    return;
  }
  final copy = Map<String, dynamic>.from(schema)
    ..removeWhere((name, _) => name.startsWith('_client'));
  schema[key] = contentHash(copy);
}

String schemaFingerprint(Map<String, dynamic> schema) {
  for (final key in const [
    '_clientGridSchemaHash',
    '_clientHomeSchemaHash',
    '_clientSchemaHash',
    '_clientIotSchemaHash',
  ]) {
    final value = schema[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  final version = (schema['schemaVersion'] ?? schema['version'] ?? '').toString();
  final updated = (schema['updatedAt'] ??
          schema['generatedAt'] ??
          schema['generatedAtIso'] ??
          schema['revision'] ??
          '')
      .toString();

  final rawControls = schema['controls'];
  final controls = rawControls is List ? rawControls : null;
  final rawPages = schema['pages'];
  final pages = rawPages is List ? rawPages : null;
  final rawPaging = schema['paging'];
  final paging = rawPaging is Map ? rawPaging : null;
  final pageNo = paging?['page_no'] ?? paging?['currentPage'];

  if (controls != null || pages != null || pageNo != null) {
    final controlsLen = controls?.length ?? 0;
    final firstControlId = (controls != null && controls.isNotEmpty && controls.first is Map)
        ? controls.first['id']?.toString() ?? ''
        : '';
    final lastControlId = (controls != null && controls.isNotEmpty && controls.last is Map)
        ? controls.last['id']?.toString() ?? ''
        : '';
    final pagesLen = pages?.length ?? 0;
    final pageIndicator = pageNo != null ? 'p$pageNo:' : '';
    if (version.isNotEmpty || updated.isNotEmpty) {
      return '$version|$updated|$pageIndicator${controlsLen}c[${firstControlId}_$lastControlId]:${pagesLen}p';
    }
  } else if (version.isNotEmpty || updated.isNotEmpty) {
    return '$version|$updated';
  }

  return contentHash(
    Map<String, dynamic>.from(schema)
      ..removeWhere((key, _) => key.startsWith('_client')),
  );
}
