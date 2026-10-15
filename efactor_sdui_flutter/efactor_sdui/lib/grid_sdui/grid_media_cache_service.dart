import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Production-ready local media caching engine for Circle Connect & Professional Space.
///
/// Stores images, audio voice notes (.m4a), and video reel chunks directly on
/// the phone's physical flash storage so they play/display instantly with 0ms
/// latency even when the device is completely offline.
class GridMediaCacheService {
  GridMediaCacheService._();
  static final GridMediaCacheService instance = GridMediaCacheService._();

  Directory? _mediaDir;
  final Map<String, String> _memoryUrlToPathIndex = <String, String>{};
  static const int maxCacheBytes = 500 * 1024 * 1024; // 500 MB disk budget (LRU)

  /// Initializes the local media directory on the device.
  Future<Directory> get mediaDirectory async {
    if (_mediaDir != null) return _mediaDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/efactor_media');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _mediaDir = dir;
    return dir;
  }

  /// Generates a safe file name based on the remote URL.
  String _hashUrl(String url) {
    final sanitized = url
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final prefix = sanitized.length > 24 ? sanitized.substring(sanitized.length - 24) : sanitized;
    final hash = url.hashCode.abs().toRadixString(16);
    final ext = _extractExtension(url);
    return '${prefix}_$hash.$ext';
  }

  String _extractExtension(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final dotIndex = path.lastIndexOf('.');
      if (dotIndex != -1 && dotIndex < path.length - 1) {
        final ext = path.substring(dotIndex + 1).toLowerCase();
        if (ext.length <= 4 && RegExp(r'^[a-z0-9]+$').hasMatch(ext)) {
          return ext;
        }
      }
    } catch (_) {}
    return 'dat';
  }

  /// Checks if a media URL is already cached locally on disk.
  Future<String?> getLocalMediaPath(String remoteUrl) async {
    final cleanUrl = remoteUrl.trim();
    if (cleanUrl.isEmpty) return null;

    if (_memoryUrlToPathIndex.containsKey(cleanUrl)) {
      final path = _memoryUrlToPathIndex[cleanUrl]!;
      if (File(path).existsSync()) {
        return path;
      }
    }

    final dir = await mediaDirectory;
    final fileName = _hashUrl(cleanUrl);
    final file = File('${dir.path}/$fileName');
    if (file.existsSync()) {
      _memoryUrlToPathIndex[cleanUrl] = file.path;
      return file.path;
    }
    return null;
  }

  /// Retrieves the media file path: returns immediately if cached locally,
  /// or downloads and saves to disk in the background.
  Future<String> getOrDownloadMedia(String remoteUrl) async {
    final cached = await getLocalMediaPath(remoteUrl);
    if (cached != null) {
      return cached;
    }

    final dir = await mediaDirectory;
    final fileName = _hashUrl(remoteUrl);
    final targetFile = File('${dir.path}/$fileName');

    try {
      final client = http.Client();
      final response = await client
          .get(Uri.parse(remoteUrl))
          .timeout(const Duration(seconds: 25));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await targetFile.writeAsBytes(response.bodyBytes);
        _memoryUrlToPathIndex[remoteUrl] = targetFile.path;
        debugPrint('[GridMediaCache] Cached: $remoteUrl -> ${targetFile.path}');
        unawaited(_enforceLruCacheBudget());
        return targetFile.path;
      }
    } catch (e) {
      debugPrint('[GridMediaCache] Download failed for $remoteUrl: $e');
    }
    return remoteUrl; // Fallback to remote if offline & not cached yet
  }

  /// Saves a freshly recorded voice note or captured camera image directly to local storage.
  Future<String> saveLocalMediaBytes({
    required List<int> bytes,
    required String extension,
    String? mediaId,
  }) async {
    final dir = await mediaDirectory;
    final id = mediaId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final file = File('${dir.path}/local_$id.$extension');
    await file.writeAsBytes(bytes);
    debugPrint('[GridMediaCache] Saved local media: ${file.path}');
    return file.path;
  }

  /// Automatically purges oldest files if the cache exceeds 500 MB (LRU Strategy).
  Future<void> _enforceLruCacheBudget() async {
    try {
      final dir = await mediaDirectory;
      final entities = dir.listSync().whereType<File>().toList();

      int totalBytes = 0;
      for (final f in entities) {
        totalBytes += f.lengthSync();
      }

      if (totalBytes > maxCacheBytes) {
        // Sort files by last modified time ascending (oldest first)
        entities.sort(
          (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
        );

        for (final f in entities) {
          if (totalBytes <= maxCacheBytes * 0.8) break; // Clear down to 80%
          final size = f.lengthSync();
          f.deleteSync();
          totalBytes -= size;
        }
      }
    } catch (e) {
      debugPrint('[GridMediaCache] LRU maintenance error: $e');
    }
  }

  /// Total disk usage of cached media in bytes.
  Future<int> calculateCacheSizeBytes() async {
    try {
      final dir = await mediaDirectory;
      final files = dir.listSync().whereType<File>();
      int total = 0;
      for (final f in files) {
        total += f.lengthSync();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Clears all cached media files from disk.
  Future<void> clearCache() async {
    try {
      final dir = await mediaDirectory;
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        _mediaDir = null;
        _memoryUrlToPathIndex.clear();
      }
    } catch (e) {
      debugPrint('[GridMediaCache] Clear cache error: $e');
    }
  }
}
