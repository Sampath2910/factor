import 'dart:async';

import '../data/schema_repository.dart';
import 'json_http.dart';

/// Manages local disk caching and sequential background synchronization for
/// IoT device SDUI pages across all hardware models.
///
/// Principles:
/// 1. User Priority: Active page paints immediately (local-first with 0 loading spinner).
/// 2. Sequential background queue: Remaining pages are downloaded and stored
///    one-by-one with cooperative delays so UI interaction stays 100% fluid.
/// 3. Validation: Only completely loaded and verified schemas are stored.
/// 4. Silent Background Revalidation: Server updates are detected and applied
///    seamlessly without disruptive full-screen spinners, matching iOS behavior.
class DevicePageCacheManager {
  DevicePageCacheManager._();

  static final DevicePageCacheManager instance = DevicePageCacheManager._();

  final Map<String, Future<List<int>>> _jobs = <String, Future<List<int>>>{};

  /// Checks whether a given page slot has already been completely saved on disk.
  Future<bool> isPageCached({
    required String modelId,
    required String nodeId,
    int pageNo = 1,
  }) async {
    final model = modelId.trim();
    final node = nodeId.trim();
    if (model.isEmpty || node.isEmpty || pageNo < 1) return false;
    final repo = SchemaRepository();
    try {
      return await repo.cachedPageExists(
        modelId: model,
        nodeId: node,
        pageNo: pageNo,
      );
    } finally {
      repo.dispose();
    }
  }

  /// Retrieves a completely saved page from local disk storage.
  Future<Map<String, dynamic>?> getCachedPage({
    required String modelId,
    required String nodeId,
    int pageNo = 1,
  }) async {
    final model = modelId.trim();
    final node = nodeId.trim();
    if (model.isEmpty || node.isEmpty || pageNo < 1) return null;
    final repo = SchemaRepository();
    try {
      return await repo.readFromCache(
        modelId: model,
        nodeId: node,
        pageNo: pageNo,
        allowStale: true,
      );
    } finally {
      repo.dispose();
    }
  }

  /// Synchronizes all published pages for [modelId] / [nodeId] sequentially.
  ///
  /// - Downloads missing pages one-by-one with cooperative yielding.
  /// - Silently revalidates already-cached pages in background.
  /// - Calls [onPageUpdated] whenever a page document changes on the server.
  Future<List<int>> syncModelPagesSequentially({
    required String modelId,
    required String nodeId,
    int activePageNo = 1,
    void Function(int pageNo, Map<String, dynamic> updatedSchema)? onPageUpdated,
  }) {
    if (!SchemaRepository.storeDevicePagesLocally) {
      return Future<List<int>>.value(const <int>[]);
    }
    final model = modelId.trim();
    final node = nodeId.trim();
    if (model.isEmpty || node.isEmpty) {
      return Future<List<int>>.value(const <int>[]);
    }

    final jobKey = '$model\n$node';
    return _jobs.putIfAbsent(jobKey, () async {
      try {
        return await _executeSequentialSync(
          model: model,
          node: node,
          activePageNo: activePageNo,
          onPageUpdated: onPageUpdated,
        );
      } finally {
        _jobs.remove(jobKey);
      }
    });
  }

  Future<List<int>> _executeSequentialSync({
    required String model,
    required String node,
    required int activePageNo,
    void Function(int pageNo, Map<String, dynamic> updatedSchema)? onPageUpdated,
  }) async {
    final repo = SchemaRepository();
    final changedPages = <int>[];

    try {
      // 1. Determine all published page numbers from the opening/active page schema.
      Map<String, dynamic>? activeDoc = await repo.readFromCache(
        modelId: model,
        nodeId: node,
        pageNo: activePageNo,
        allowStale: true,
      );
      activeDoc ??= await repo.loadOpeningPage(
        modelId: model,
        nodeId: node,
        forceRefresh: false,
      );

      final publishedNumbers = SchemaRepository.publishedPageNumbers(activeDoc);
      logDebug(
        '[DevicePageCacheManager] Starting sequential sync for $model/$node '
        'totalPublished=${publishedNumbers.length} pages=$publishedNumbers activePage=$activePageNo',
      );

      // 2. Process non-active pages sequentially one-by-one with cooperative yielding.
      final remaining = publishedNumbers.where((p) => p != activePageNo).toList();

      for (final pageNo in remaining) {
        try {
          final isCached = await repo.cachedPageExists(
            modelId: model,
            nodeId: node,
            pageNo: pageNo,
          );

          if (!isCached) {
            // Missing page: download and completely validate before persisting to disk.
            final downloaded = await repo.loadSchemaPage(
              modelId: model,
              nodeId: node,
              pageNo: pageNo,
              forceRefresh: false,
            );
            changedPages.add(pageNo);
            onPageUpdated?.call(pageNo, downloaded);
            logDebug(
              '[DevicePageCacheManager] Page $pageNo downloaded and saved to disk for $model/$node '
              'controls=${(downloaded['controls'] as List?)?.length ?? 0}',
            );
          } else {
            // Already cached: check freshness before making any live HTTP requests.
            final local = await repo.readFromCache(
              modelId: model,
              nodeId: node,
              pageNo: pageNo,
              allowStale: true,
            );
            if (local != null) {
              onPageUpdated?.call(pageNo, local);
            }
            if (local != null && SchemaRepository.isFreshCache(local)) {
              logDebug(
                '[DevicePageCacheManager] Page $pageNo cache is fresh (< 15 min), skipping network for $model/$node',
              );
            } else {
              // Stale cache: silent background revalidation over network.
              final fresh = await repo.loadSchemaPage(
                modelId: model,
                nodeId: node,
                pageNo: pageNo,
                forceRefresh: true,
              );

              if (local == null ||
                  schemaFingerprint(local) != schemaFingerprint(fresh)) {
                changedPages.add(pageNo);
                onPageUpdated?.call(pageNo, fresh);
                logDebug(
                  '[DevicePageCacheManager] Background revalidation: page $pageNo updated for $model/$node',
                );
              }
            }
          }
        } catch (error) {
          logDebug(
            '[DevicePageCacheManager] Page $pageNo sync error for $model/$node: $error',
          );
        }

        // Cooperative yield: allow UI thread and user interaction to breathe.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      // 3. Silent background revalidation on the active page itself (if previously cached and stale).
      try {
        final localActive = await repo.readFromCache(
          modelId: model,
          nodeId: node,
          pageNo: activePageNo,
          allowStale: true,
        );
        if (localActive != null) {
          if (SchemaRepository.isFreshCache(localActive)) {
            logDebug(
              '[DevicePageCacheManager] Active page $activePageNo cache is fresh, skipping live revalidation',
            );
          } else {
            final freshActive = await repo.loadSchemaPage(
              modelId: model,
              nodeId: node,
              pageNo: activePageNo,
              forceRefresh: true,
            );

            if (schemaFingerprint(localActive) != schemaFingerprint(freshActive)) {
              changedPages.add(activePageNo);
              onPageUpdated?.call(activePageNo, freshActive);
              logDebug(
                '[DevicePageCacheManager] Active page $activePageNo updated silently in background for $model/$node',
              );
            }
          }
        }
      } catch (error) {
        logDebug(
          '[DevicePageCacheManager] Active page $activePageNo revalidate error for $model/$node: $error',
        );
      }

      return changedPages;
    } catch (error) {
      logDebug('[DevicePageCacheManager] Sequential sync failed for $model/$node: $error');
      return changedPages;
    } finally {
      repo.dispose();
    }
  }
}
