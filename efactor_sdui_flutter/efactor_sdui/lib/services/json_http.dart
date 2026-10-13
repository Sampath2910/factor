import 'dart:convert';
import 'package:flutter/foundation.dart';

void logDebug(String message) {
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

dynamic decodeJsonBody({
  required String body,
  String? contentType,
  required String source,
}) {
  ensureDecodableJson(body: body, contentType: contentType, source: source);
  try {
    return jsonDecode(body);
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
  ensureDecodableJson(body: body, contentType: contentType, source: source);
  try {
    if (body.length > 50 * 1024) {
      return await compute(_isolateJsonDecode, body);
    }
    return jsonDecode(body);
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
