import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Downloads, verifies and stores the Circle Connect (GRID Chat) self-contained
/// offline shell so iOS can render cached chats offline.
///
/// Background: iOS WKWebView does not run Service Workers (that needs app-wide
/// App-Bound Domains, which we cannot enable), so it cannot serve the live site
/// offline the way Android's WebView does. The GRID Chat web team therefore ship
/// a single self-contained HTML shell (React + all chunks + CSS + fonts inlined,
/// no https asset requests to boot). We cache it while online and, when offline,
/// load it via `loadHtmlString(..., baseUrl: https://efactor.tech/...)` so the
/// page keeps the efactor.tech origin and reads the same CircleConnectDB.
///
/// Contract (from the GRID Chat team):
///  - Manifest: GET /index.php/grid-chat/offline-shell/manifest  (authenticated)
///      { success, data: { buildId, sha256, bytes, minimumHostVersion, shellUrl } }
///  - Shell:    GET /index.php/grid-chat/offline-shell           (authenticated)
///      One self-contained HTML document; sets the offline marker itself.
///  - Verify SHA-256 over the decompressed HTML bytes, replace atomically,
///    keep the previous valid shell if anything fails.
///
/// This service is only used on iOS. Android keeps its Service Worker path.
class GridOfflineShellService {
  GridOfflineShellService._();
  static final GridOfflineShellService instance = GridOfflineShellService._();

  /// The highest offline-shell contract version this app understands. If the
  /// manifest's `minimumHostVersion` is greater than this, we skip the shell
  /// (the server shipped a newer contract than this build supports).
  static const int hostVersion = 1;

  static const String _origin = 'https://efactor.tech';
  static const String manifestUrl =
      '$_origin/index.php/grid-chat/offline-shell/manifest';

  Directory? _dir;
  // Guards against overlapping syncs for the same scope.
  final Set<String> _inFlight = <String>{};

  Future<Directory> get _baseDir async {
    if (_dir != null) return _dir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/grid_offline_shell');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  String _scope(int? userId) => userId != null ? 'user_$userId' : 'shared';
  String _shellFileName(int? userId) => 'shell_${_scope(userId)}.html';
  String _metaFileName(int? userId) => 'shell_${_scope(userId)}.json';

  Future<File> _shellFile(int? userId) async =>
      File('${(await _baseDir).path}/${_shellFileName(userId)}');
  Future<File> _metaFile(int? userId) async =>
      File('${(await _baseDir).path}/${_metaFileName(userId)}');

  /// Returns the cached offline-shell HTML for [userId], or null if none is
  /// stored. Safe to call on any platform.
  Future<String?> getStoredShell({int? userId}) async {
    try {
      final file = await _shellFile(userId);
      if (!file.existsSync()) return null;
      final html = await file.readAsString();
      if (html.trim().length < 64) return null;
      return html;
    } catch (e) {
      debugPrint('[GridOfflineShell] getStoredShell error: $e');
      return null;
    }
  }

  Future<String?> storedBuildId({int? userId}) async {
    try {
      final meta = await _metaFile(userId);
      if (!meta.existsSync()) return null;
      final json = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      return json['buildId']?.toString();
    } catch (_) {
      return null;
    }
  }

  /// Fetches the manifest and, if the server build differs from the cached one,
  /// downloads + verifies + atomically stores the new shell. Never throws; on
  /// any failure the previously stored (valid) shell is kept.
  ///
  /// Call this while ONLINE, using the authenticated WebView session's cookies.
  Future<void> syncShell({
    String? accessToken,
    int? userId,
    String? cookieHeader,
  }) async {
    final scopeKey = _scope(userId);
    if (_inFlight.contains(scopeKey)) return;
    _inFlight.add(scopeKey);
    try {
      final headers = _authHeaders(accessToken, cookieHeader, isHtml: false);

      final manifestResp = await http
          .get(Uri.parse(manifestUrl), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (manifestResp.statusCode != 200) {
        debugPrint(
            '[GridOfflineShell] manifest HTTP ${manifestResp.statusCode} — keeping cached shell');
        return;
      }

      final Map<String, dynamic> body =
          jsonDecode(manifestResp.body) as Map<String, dynamic>;
      // Accept both manifest shapes:
      //  - wrapped envelope: { success: true, data: { buildId, sha256, ... } }
      //  - flat object:      { buildId, sha256, shellUrl, ... }
      // If a `success` flag is present and explicitly false, treat as failure;
      // otherwise read fields from `data` when present, else the top-level body.
      if (body['success'] == false) {
        debugPrint('[GridOfflineShell] manifest success=false — skipping');
        return;
      }
      final Map<String, dynamic> data = (body['data'] is Map)
          ? (body['data'] as Map).cast<String, dynamic>()
          : body;
      final buildId = data['buildId']?.toString() ?? '';
      final expectedSha = data['sha256']?.toString().toLowerCase() ?? '';
      final shellUrl = data['shellUrl']?.toString() ?? '';
      final minHost = (data['minimumHostVersion'] is num)
          ? (data['minimumHostVersion'] as num).toInt()
          : 1;

      if (buildId.isEmpty || shellUrl.isEmpty || expectedSha.isEmpty) {
        debugPrint('[GridOfflineShell] manifest missing fields — skipping');
        return;
      }
      if (minHost > hostVersion) {
        debugPrint(
            '[GridOfflineShell] manifest minimumHostVersion=$minHost > hostVersion=$hostVersion — app too old, skipping');
        return;
      }

      final existing = await storedBuildId(userId: userId);
      if (existing == buildId && (await getStoredShell(userId: userId)) != null) {
        debugPrint('[GridOfflineShell] shell up to date (build $buildId)');
        return;
      }

      // Download the shell. Advertise gzip only so dart:io auto-decompresses and
      // bodyBytes are the DECOMPRESSED HTML bytes the SHA-256 is computed over.
      final shellResp = await http
          .get(Uri.parse(shellUrl),
              headers: _authHeaders(accessToken, cookieHeader, isHtml: true))
          .timeout(const Duration(seconds: 60));
      if (shellResp.statusCode != 200) {
        debugPrint(
            '[GridOfflineShell] shell HTTP ${shellResp.statusCode} — keeping cached shell');
        return;
      }

      final bytes = shellResp.bodyBytes;
      final actualSha = sha256.convert(bytes).toString().toLowerCase();
      if (actualSha != expectedSha) {
        debugPrint(
            '[GridOfflineShell] SHA-256 mismatch (expected $expectedSha got $actualSha) — discarding download, keeping cached shell');
        return;
      }

      // Atomic replace: write temp, then rename over the real files.
      final dir = await _baseDir;
      final tmpShell = File('${dir.path}/.tmp_${_shellFileName(userId)}');
      final tmpMeta = File('${dir.path}/.tmp_${_metaFileName(userId)}');
      await tmpShell.writeAsBytes(bytes, flush: true);
      await tmpMeta.writeAsString(
        jsonEncode(<String, dynamic>{
          'buildId': buildId,
          'sha256': expectedSha,
          'bytes': bytes.length,
          'savedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      await tmpShell.rename((await _shellFile(userId)).path);
      await tmpMeta.rename((await _metaFile(userId)).path);
      debugPrint(
          '[GridOfflineShell] stored shell build $buildId (${bytes.length} bytes) for $scopeKey');
    } on TimeoutException {
      debugPrint('[GridOfflineShell] sync timed out — keeping cached shell');
    } catch (e) {
      debugPrint('[GridOfflineShell] sync error: $e — keeping cached shell');
    } finally {
      _inFlight.remove(scopeKey);
    }
  }

  Map<String, String> _authHeaders(
    String? accessToken,
    String? cookieHeader, {
    required bool isHtml,
  }) {
    final token = accessToken?.trim() ?? '';
    return <String, String>{
      'Accept': isHtml ? 'text/html' : 'application/json',
      // Only advertise gzip so the http client transparently decompresses and
      // bodyBytes match the SHA-256 computed over decompressed HTML.
      'Accept-Encoding': 'gzip',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (token.isNotEmpty) 'X-Efactor-Access-Token': token,
      if (cookieHeader != null && cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };
  }

  /// Removes stored shells. Call on logout / gridChatClearOfflineData.
  Future<void> clear({int? userId}) async {
    try {
      if (userId != null) {
        final s = await _shellFile(userId);
        final m = await _metaFile(userId);
        if (s.existsSync()) s.deleteSync();
        if (m.existsSync()) m.deleteSync();
      }
      // Also clear the shared-scope copy.
      final ss = await _shellFile(null);
      final sm = await _metaFile(null);
      if (ss.existsSync()) ss.deleteSync();
      if (sm.existsSync()) sm.deleteSync();
    } catch (e) {
      debugPrint('[GridOfflineShell] clear error: $e');
    }
  }
}
