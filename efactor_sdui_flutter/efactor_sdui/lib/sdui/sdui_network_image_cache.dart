import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Disk-backed persistent cache for general SDUI network images (Home / Grid / IoT / Device).
///
/// Images are persisted on local disk for up to 365 days so previously viewed or prefetched
/// artwork, device icons, banners, and logos render immediately and seamlessly when offline.
class SduiNetworkImageCache {
  SduiNetworkImageCache._();

  static const String storeKey = 'sduiNetworkImagesV1';

  static final CacheManager manager = CacheManager(
    Config(
      storeKey,
      stalePeriod: const Duration(days: 365),
      maxNrOfCacheObjects: 2000,
    ),
  );

  /// Proactive warm and local disk save of all image URLs found in a schema document.
  ///
  /// Uses [CacheManager.getSingleFile] which downloads and persists missing files to disk,
  /// while immediately serving already-cached files without re-downloading.
  static Future<void> prefetchSchemaImages(
    Map<String, dynamic> schema, {
    int maxUrls = 150,
  }) async {
    final urls = collectImageUrls(schema, maxUrls: maxUrls);
    for (final url in urls) {
      try {
        await manager.getSingleFile(url);
      } catch (_) {
        // Offline or unreachable during prefetch — continue; cache hit later if already saved.
      }
    }
  }

  /// Backward-compatible alias for [collectImageUrls].
  static List<String> collectHttpsImageUrls(
    dynamic root, {
    int maxUrls = 150,
  }) => collectImageUrls(root, maxUrls: maxUrls);

  /// Harvests all valid HTTP/HTTPS image URLs from any schema map or list tree.
  static List<String> collectImageUrls(
    dynamic root, {
    int maxUrls = 150,
  }) {
    const imageKeys = <String>{
      'imageUrl',
      'image',
      'url',
      'src',
      'avatarUrl',
      'avatar',
      'logoUrl',
      'logo',
      'iconUrl',
      'icon',
      'thumbnailUrl',
      'thumbnail',
      'bannerUrl',
      'banner',
      'coverUrl',
      'cover',
      'backgroundImage',
      'backgroundImageUrl',
      'bgImage',
      'qrImageUrl',
      'previewUrl',
      'deviceImage',
      'device_image',
    };

    final found = <String>{};

    void add(dynamic raw) {
      if (found.length >= maxUrls) return;
      final text = raw?.toString().trim() ?? '';
      if (text.isEmpty) return;
      final uri = Uri.tryParse(text);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) return;
      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'https' && scheme != 'http') return;
      found.add(uri.toString());
    }

    void walk(dynamic node) {
      if (found.length >= maxUrls) return;
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString();
          if (imageKeys.contains(key)) {
            add(entry.value);
          }
          if (key == 'qrImageUrlsByMode' && entry.value is Map) {
            for (final value in (entry.value as Map).values) {
              add(value);
            }
          }
          walk(entry.value);
        }
      } else if (node is List) {
        for (final child in node) {
          walk(child);
        }
      } else if (node is String) {
        final text = node.trim();
        final matches = RegExp(
          r"""https?://[^\s"'<>)]+\.(?:png|jpe?g|webp|gif|bmp|svg)(?:\?[^\s"'<>]*)?""",
          caseSensitive: false,
        ).allMatches(text);
        for (final match in matches) {
          add(match.group(0));
        }
      }
    }

    walk(root);
    return found.toList(growable: false);
  }

  /// Completely purges all local disk image caches and in-memory decoded image bitmaps on logout.
  static Future<void> clearAll() async {
    try {
      await manager.emptyCache();
    } catch (_) {}
    try {
      await SduiAuthImageCache.manager.emptyCache();
    } catch (_) {}
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
  }
}

/// Durable cache for auth logos and assets.
class SduiAuthImageCache {
  SduiAuthImageCache._();

  static const String storeKey = 'sduiAuthNetworkImagesV1';

  static final CacheManager manager = CacheManager(
    Config(
      storeKey,
      stalePeriod: const Duration(days: 365),
      maxNrOfCacheObjects: 200,
    ),
  );
}
