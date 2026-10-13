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
    final stable = uri.replace(query: '', fragment: '').toString();
    return 'web_snapshot_${_hash(stable)}.html';
  }

  static Future<void> save(Uri uri, String html) async {
    final stripped = stripScripts(html).trim();
    if (stripped.length < 64) return;
    if (stripped.toLowerCase().contains('err_internet_disconnected')) return;
    await SchemaDiskCache.writeString(fileNameFor(uri), stripped);
  }

  static Future<String?> read(Uri uri) {
    return SchemaDiskCache.readString(fileNameFor(uri));
  }

  /// Removes executable tags so a restored page stays on the last view.
  static String stripScripts(String html) {
    return html.replaceAll(
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
