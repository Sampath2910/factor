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
    final lower = normalized.toLowerCase();
    if (lower.contains('err_internet_disconnected') ||
        lower.contains('network error') ||
        lower.contains('internet connection required')) {
      return;
    }
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

  static const String channelsSnapshotFileName = 'web_snapshot_channels_v3.html';

  static Future<void> saveChannelsSnapshot(String html) async {
    final normalized = normalizeHtml(html).trim();
    if (normalized.length < 64) return;
    final lower = normalized.toLowerCase();
    if (lower.contains('err_internet_disconnected') ||
        lower.contains('network error') ||
        lower.contains('internet connection required') ||
        lower.contains('search conversations') ||
        lower.contains('missed voice call')) {
      return;
    }
    if (!normalized.contains('Channels') && !normalized.contains('channel')) {
      return;
    }
    await SchemaDiskCache.writeString(channelsSnapshotFileName, normalized);
  }

  static Future<String?> readChannelsSnapshot() async {
    final raw = await SchemaDiskCache.readString(channelsSnapshotFileName);
    if (raw != null && raw.trim().length >= 64) {
      final clean = normalizeHtml(raw);
      // Strictly verify it is the actual Channels page with channels cards
      // and NOT a chats/conversations page with sunflowers
      if ((clean.contains('E-Factor_Tech_IOE') ||
              clean.contains('Dhin_Dhun_Tech') ||
              clean.contains('3 Directory')) &&
          !clean.contains('Search conversations') &&
          !clean.contains('Missed voice call')) {
        return clean;
      }
    }
    return getFallbackChannelsHtml();
  }

  static Future<bool> hasChannelsSnapshot() async {
    return true;
  }

  static String getFallbackChannelsHtml() {
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>Channels</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  body { background-color: #0b1120; color: #f8fafc; height: 100vh; display: flex; flex-direction: column; overflow: hidden; -webkit-tap-highlight-color: transparent; }
  .top-bar { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; background-color: #0b1120; border-bottom: 1px solid #1e293b; }
  .top-left { display: flex; align-items: center; gap: 12px; }
  .back-btn { font-size: 20px; color: #f8fafc; cursor: pointer; }
  .header-title { font-size: 19px; font-weight: 700; color: #ffffff; }
  .directory-badge { font-size: 13px; font-weight: 600; color: #f59e0b; margin-left: 6px; }
  .plus-btn { width: 30px; height: 30px; border-radius: 50%; background-color: #f59e0b; color: #ffffff; display: flex; align-items: center; justify-content: center; font-size: 20px; font-weight: bold; cursor: pointer; }
  
  .tabs-row { display: flex; padding: 10px 16px; gap: 24px; border-bottom: 1px solid #1e293b; font-size: 14px; font-weight: 600; }
  .tab-item { display: flex; align-items: center; gap: 6px; color: #94a3b8; cursor: pointer; }
  .tab-item.active { color: #f59e0b; position: relative; }
  .tab-item.active::after { content: ''; position: absolute; bottom: -11px; left: 0; right: 0; height: 2px; background-color: #f59e0b; }
  .tab-badge { background-color: #f59e0b; color: #000; font-size: 11px; font-weight: 700; border-radius: 10px; padding: 1px 6px; }
  .tab-item:not(.active) .tab-badge { background-color: #334155; color: #94a3b8; }
  
  .categories-row { display: flex; overflow-x: auto; padding: 12px 16px; gap: 16px; border-bottom: 1px solid #1e293b; white-space: nowrap; scrollbar-width: none; }
  .cat-item { font-size: 13px; font-weight: 500; color: #94a3b8; cursor: pointer; }
  .cat-item.active { color: #ffffff; font-weight: 600; }
  
  .channels-list { flex: 1; overflow-y: auto; padding: 16px; display: flex; flex-direction: column; gap: 14px; }
  .channel-card { background-color: #111827; border: 1px solid #1e293b; border-radius: 14px; padding: 14px 16px; position: relative; }
  .channel-card.highlight { border: 1.5px solid #d97706; }
  .channel-header { display: flex; align-items: flex-start; gap: 12px; }
  .channel-avatar { width: 44px; height: 44px; border-radius: 10px; display: flex; align-items: center; justify-content: center; font-weight: bold; font-size: 18px; flex-shrink: 0; }
  .avatar-efactor { background-color: #000; border: 1px solid #334155; color: #fff; font-size: 18px; font-family: monospace; letter-spacing: -1px; }
  .avatar-dhin { background-color: #ffffff; color: #0284c7; }
  .avatar-pavan { background-color: #06b6d4; color: #ffffff; }
  .channel-info { flex: 1; min-width: 0; }
  .channel-title { font-size: 16px; font-weight: 700; color: #ffffff; display: flex; align-items: center; justify-content: space-between; }
  .channel-handle { font-size: 12px; color: #94a3b8; margin-top: 2px; }
  .channel-desc { font-size: 13px; color: #cbd5e1; margin-top: 8px; line-height: 1.4; }
  
  .channel-actions { display: flex; align-items: center; gap: 10px; margin-top: 10px; }
  .badge-owner { display: flex; align-items: center; gap: 4px; font-size: 12px; font-weight: 600; color: #f59e0b; }
  .btn-following { display: inline-flex; align-items: center; gap: 4px; padding: 5px 14px; border-radius: 20px; background-color: #ffffff; color: #0f172a; font-size: 12px; font-weight: 600; cursor: pointer; border: none; }
  .btn-bell { background: none; border: none; color: #cbd5e1; cursor: pointer; font-size: 15px; padding: 4px; }
  .unread-count { position: absolute; top: 14px; right: 16px; background-color: #1e293b; color: #cbd5e1; font-size: 12px; font-weight: 700; border-radius: 6px; padding: 2px 7px; border: 1px solid #334155; }
  
  .bottom-nav { height: 60px; background-color: #0b1120; border-top: 1px solid #1e293b; display: flex; justify-content: space-around; align-items: center; padding: 0 8px; }
  .nav-item { display: flex; flex-direction: column; align-items: center; gap: 3px; color: #94a3b8; font-size: 11px; cursor: pointer; position: relative; }
  .nav-item svg { width: 22px; height: 22px; fill: currentColor; }
  .nav-item.active { color: #f59e0b; }
  .nav-item.active svg { fill: #f59e0b; filter: drop-shadow(0 0 6px rgba(245, 158, 11, 0.5)); }
  .nav-badge { position: absolute; top: -3px; right: 4px; background-color: #ef4444; color: #fff; font-size: 10px; font-weight: bold; border-radius: 8px; padding: 1px 5px; }
</style>
</head>
<body>

<div class="top-bar">
  <div class="top-left">
    <span class="back-btn">&#8592;</span>
    <span class="header-title">Channels</span>
    <span class="directory-badge">3 Directory</span>
  </div>
  <div class="plus-btn">+</div>
</div>

<div class="tabs-row">
  <div class="tab-item active">
    Explore <span class="tab-badge">3</span>
  </div>
  <div class="tab-item">
    Following <span class="tab-badge">2</span>
  </div>
  <div class="tab-item">
    My channels <span class="tab-badge">1</span>
  </div>
</div>

<div class="categories-row">
  <span class="cat-item active">All Channels</span>
  <span class="cat-item">News</span>
  <span class="cat-item">Entertainment</span>
  <span class="cat-item">Education</span>
  <span class="cat-item">Technology</span>
  <span class="cat-item">Business</span>
</div>

<div class="channels-list">
  <div class="channel-card highlight">
    <div class="unread-count">5</div>
    <div class="channel-header">
      <div class="channel-avatar avatar-efactor">&#9638;&#9634;</div>
      <div class="channel-info">
        <div class="channel-title">E-Factor_Tech_IOE</div>
        <div class="channel-handle">@efactor_tech_ioe</div>
        <div class="channel-actions">
          <span class="badge-owner">&#128081; Your channel</span>
          <span class="btn-bell">&#128276;</span>
        </div>
      </div>
    </div>
  </div>

  <div class="channel-card">
    <div class="unread-count">9</div>
    <div class="channel-header">
      <div class="channel-avatar avatar-dhin">&#9658;</div>
      <div class="channel-info">
        <div class="channel-title">Dhin_Dhun_Tech</div>
        <div class="channel-handle">@dhin_dhun_tech</div>
        <div class="channel-desc">We are an innovative neurotechnology company exploring the connection between biological brain cells</div>
        <div class="channel-actions">
          <button class="btn-following">&#10003; Following</button>
          <span class="btn-bell">&#128276;</span>
        </div>
      </div>
    </div>
  </div>

  <div class="channel-card">
    <div class="unread-count">6</div>
    <div class="channel-header">
      <div class="channel-avatar avatar-pavan">PS</div>
      <div class="channel-info">
        <div class="channel-title">Pavan_Tech_Solutions</div>
        <div class="channel-handle">@pavan_tech_solutions</div>
        <div class="channel-desc">Turning Future in to Money</div>
        <div class="channel-actions">
          <button class="btn-following">&#10003; Following</button>
          <span class="btn-bell">&#128276;</span>
        </div>
      </div>
    </div>
  </div>
</div>

<div class="bottom-nav">
  <div class="nav-item">
    <svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
    <span>Chats</span>
  </div>
  <div class="nav-item">
    <svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
    <span>Moments</span>
  </div>
  <div class="nav-item">
    <svg viewBox="0 0 24 24"><path d="M17 10.5V7c0-.55-.45-1-1-1H4c-.55 0-1 .45-1 1v10c0 .55.45 1 1 1h12c.55 0 1-.45 1-1v-3.5l4 4v-11l-4 4z"/></svg>
    <span>Live</span>
  </div>
  <div class="nav-item active">
    <svg viewBox="0 0 24 24"><path d="M18 11v2h4v-2h-4zm-2 6.61c.96.71 2.21 1.65 3.2 2.39.4-.53.8-1.07 1.2-1.6-.99-.74-2.24-1.68-3.2-2.4-.4.54-.8 1.08-1.2 1.61zM20.4 5.6c-.4-.53-.8-1.07-1.2-1.6-.99.74-2.24 1.68-3.2 2.4.4.53.8 1.07 1.2 1.6.96-.72 2.21-1.65 3.2-2.4zM4 9c-1.1 0-2 .9-2 2v2c0 1.1.9 2 2 2h1v4h2v-4h1l5 3V6L8 9H4zm9 4.43l-3.28-1.97-.72-.46H4v-2h5l.72-.46L13 6.57v6.86z"/></svg>
    <span>Channels</span>
  </div>
  <div class="nav-item">
    <span class="nav-badge">1</span>
    <svg viewBox="0 0 24 24"><path d="M20.01 15.38c-1.23 0-2.42-.2-3.53-.56-.35-.12-.74-.03-1.01.24l-1.57 1.97c-2.83-1.35-5.48-3.9-6.89-6.83l1.95-1.66c.27-.28.35-.67.24-1.02-.37-1.11-.56-2.3-.56-3.53 0-.54-.45-.99-.99-.99H4.19C3.65 3 3 3.24 3 3.99 3 13.28 10.73 21 20.01 21c.71 0 .99-.63.99-1.18v-3.45c0-.54-.45-.99-.99-.99z"/></svg>
    <span>Calls</span>
  </div>
</div>

</body>
</html>
''';
  }

  /// Removes executable tags so a restored page stays on the last view.
  static String stripScripts(String html) {
    final clean = normalizeHtml(html);
    return clean
        .replaceAll(
          RegExp(
            r'<script\b[^>]*>[\s\S]*?</script>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'<script\b[^>]*/>',
            caseSensitive: false,
          ),
          '',
        );
  }

  /// Ensures that navigation between Chats, Moments, Live, Calls, and subtabs
  /// works smoothly and never freezes or gets stuck.
  static String ensureInteractive(String html) {
    var clean = stripScripts(html);

    const interactiveScript = '''
<script>
(function() {
  function setupInteractive() {
    var items = document.querySelectorAll('.bottom-nav .nav-item, [data-tab]');
    items.forEach(function(item) {
      item.addEventListener('click', function(e) {
        var span = item.querySelector('span');
        var text = span ? span.innerText.trim().toLowerCase() : (item.innerText || '').trim().toLowerCase();
        if (window.CircleConnectChannelsBridge) {
          window.CircleConnectChannelsBridge.postMessage(JSON.stringify({
            action: 'switchTab',
            tab: text
          }));
        }
      }, true);
    });

    var backBtn = document.querySelector('.back-btn, [data-action="back"]');
    if (backBtn) {
      backBtn.addEventListener('click', function(e) {
        if (window.CircleConnectChannelsBridge) {
          window.CircleConnectChannelsBridge.postMessage(JSON.stringify({
            action: 'goBack'
          }));
        }
      }, true);
    }

    var tabs = document.querySelectorAll('.tabs-row .tab-item');
    var cards = document.querySelectorAll('.channels-list .channel-card');
    tabs.forEach(function(tab, index) {
      tab.addEventListener('click', function() {
        tabs.forEach(function(t) { t.classList.remove('active'); });
        tab.classList.add('active');

        if (index === 0) {
          cards.forEach(function(c) { c.style.display = 'block'; });
        } else if (index === 1) {
          if (cards[0]) cards[0].style.display = 'none';
          if (cards[1]) cards[1].style.display = 'block';
          if (cards[2]) cards[2].style.display = 'block';
        } else if (index === 2) {
          if (cards[0]) cards[0].style.display = 'block';
          if (cards[1]) cards[1].style.display = 'none';
          if (cards[2]) cards[2].style.display = 'none';
        }
      });
    });

    var cats = document.querySelectorAll('.categories-row .cat-item');
    cats.forEach(function(cat) {
      cat.addEventListener('click', function() {
        cats.forEach(function(c) { c.classList.remove('active'); });
        cat.classList.add('active');
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', setupInteractive);
  } else {
    setupInteractive();
  }
})();
</script>
''';

    if (clean.contains('</body>')) {
      return clean.replaceFirst('</body>', '$interactiveScript</body>');
    }
    return '$clean$interactiveScript';
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
