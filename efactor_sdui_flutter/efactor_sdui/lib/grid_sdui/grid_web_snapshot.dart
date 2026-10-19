import 'dart:convert';

import '../services/schema_offline.dart';

/// Last rendered Grid web page, saved after a successful online visit.
///
/// Professional Space / Circle Connect are remote sites. Airplane mode cannot
/// reload them from the network. The snapshot is the DOM after the page
/// finished, with scripts removed so the saved view does not immediately
/// try to boot the live app and fail offline.
class GridWebSnapshot {
  static String fileNameFor(Uri uri) {
    var stable = uri.replace(query: '', fragment: '').toString();
    while (stable.contains('/index.php/index.php/')) {
      stable = stable.replaceAll('/index.php/index.php/', '/index.php/');
    }
    final canonical = stable.replaceAll('/index.php/', '/');
    return 'web_snapshot_${_hash(canonical)}.html';
  }

  static String normalizeHtml(String html) {
    var text = html;
    if (text.contains(r'\u003C') ||
        text.contains(r'\u003c') ||
        text.contains(r'\u003E') ||
        text.contains(r'\u003e') ||
        text.contains(r'\u0026') ||
        text.contains(r'\"')) {
      text = text
          .replaceAll(r'\u003C', '<')
          .replaceAll(r'\u003c', '<')
          .replaceAll(r'\u003E', '>')
          .replaceAll(r'\u003e', '>')
          .replaceAll(r'\u0026', '&')
          .replaceAll(r'\"', '"')
          .replaceAll(r"\'", "'")
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\\', r'\');
    }
    return text;
  }

  static Future<void> save(Uri uri, String html) async {
    final normalized = normalizeHtml(html).trim();
    if (normalized.length < 64) return;
    if (normalized.toLowerCase().contains('err_internet_disconnected')) return;
    await SchemaDiskCache.writeString(fileNameFor(uri), normalized);
  }

  static Future<String?> read(Uri uri) async {
    final primary = await SchemaDiskCache.readString(fileNameFor(uri));
    if (primary != null && primary.trim().isNotEmpty) {
      return normalizeHtml(primary);
    }

    final stable = uri.replace(query: '', fragment: '').toString();
    final fallback = await SchemaDiskCache.readString('web_snapshot_${_hash(stable)}.html');
    return fallback != null ? normalizeHtml(fallback) : null;
  }

  /// Removes executable tags so a restored page stays on the last view.
  static String stripScripts(String html) {
    final clean = normalizeHtml(html);
    return clean.replaceAll(
      RegExp(
        r'<script\b[^>]*>[\s\S]*?</script>',
        caseSensitive: false,
      ),
      '',
    );
  }

  static String _hash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(value)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
  }
}
