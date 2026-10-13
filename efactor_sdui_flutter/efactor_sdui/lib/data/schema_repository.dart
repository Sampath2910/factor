import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../sdui/sdui_network_image_cache.dart';
import '../services/json_http.dart';
import '../services/schema_offline.dart';

// Top-level functions required for compute() — must not be closures.
dynamic _jsonDecodeAny(String raw) => jsonDecode(raw);

/// Loads the live SDUI schema using the MODEL_ID and NODE_ID entered by
/// the user on the connection screen.
///
/// Dynamic schema request, one document per pager slot. The first screen is
/// `page_no=1`. Every later screen is loaded from the URL that document
/// publishes, not from the pager index:
///
///   data.paging.pages[].pageApi
///   data.paging.nextPageApi
///   data.paging.prevPageApi
///
/// A page's own `pageNo` is the query value. The second screen can be
/// `page_no=3` while it is index 1 in `pages`. The URL without `page_no`
/// (`fullSchemaApi`) is the combined document and is not requested.
///
/// Scanner POST endpoint stored in the loaded schema:
///   POST http://efactor.tech/v8/api_scan.php
///
/// The model and node values are never hardcoded here. They are supplied to
/// [load] by the UI and are URL encoded before the request is sent.
class SchemaRepository {
  SchemaRepository({
    http.Client? client,
    String? schemaUrlTemplate,
    String? scanUrlTemplate,
  }) : _client = client ?? http.Client(),
       _schemaUrlTemplate = schemaUrlTemplate ?? defaultSchemaUrlTemplate,
       _scanUrlTemplate = scanUrlTemplate ?? defaultScanUrlTemplate;

  static const String defaultSchemaUrlTemplate = String.fromEnvironment(
    'SCHEMA_URL_TEMPLATE',
    defaultValue:
        'https://efactor.tech/v8/api_schema.php'
        '?model_no={modelId}&node_id={nodeId}',
  );

  static const String defaultScanUrlTemplate = String.fromEnvironment(
    'SCAN_URL_TEMPLATE',
    defaultValue: 'https://efactor.tech/v8/api_scan.php',
  );

  /// When `true`, every model/page schema is saved locally after the first
  /// successful load. Later opens paint from disk/memory immediately and
  /// refresh in the background only when the server document changed.
  static const bool storeDevicePagesLocally = true;

  static const Duration _responseHeaderTimeout = Duration(seconds: 20);
  static const Duration _unknownLengthBodyTimeout = Duration(seconds: 120);
  static const Duration _cacheMaxAge = Duration(hours: 24);
  static const Duration _negativeCacheTtl = Duration(minutes: 10);
  static const Duration _freshCacheRevalidateAfter = Duration(minutes: 15);

  static Duration _bodyTimeoutForLength(int? contentLength) {
    if (contentLength == null || contentLength <= 0) {
      return _unknownLengthBodyTimeout;
    }

    const chunkBytes = 64 * 1024;
    final chunks = (contentLength + chunkBytes - 1) ~/ chunkBytes;
    final seconds = (15 + (chunks * 2)).clamp(15, 180);

    return Duration(seconds: seconds);
  }

  static final Map<String, _ParsedSchemaCache> _memoryCache =
      <String, _ParsedSchemaCache>{};
  static final Map<String, Future<Map<String, dynamic>>> _inFlight =
      <String, Future<Map<String, dynamic>>>{};
  static final Map<String, Future<Map<String, dynamic>>> _pageFlights =
      <String, Future<Map<String, dynamic>>>{};
  static final Map<String, _NegativeSchemaCache> _negativeCache =
      <String, _NegativeSchemaCache>{};

  final http.Client _client;
  final String _schemaUrlTemplate;
  final String _scanUrlTemplate;

  Future<Map<String, dynamic>> load({
    required String modelId,
    required String nodeId,
    bool forceRefresh = false,
  }) async {
    final model = _required(modelId, 'MODEL_ID');
    final node = _required(nodeId, 'NODE_ID');
    final cacheKey = _cacheKey(modelId: model, nodeId: node);
    final flightKey = '$cacheKey|${forceRefresh ? 'live' : 'any'}';

    if (storeDevicePagesLocally && !forceRefresh) {
      final negative = _negativeCache[cacheKey];
      if (negative != null && DateTime.now().isBefore(negative.until)) {
        throw negative.error;
      }
      final memory = _memoryHit(cacheKey);
      if (memory != null) return memory;
      final cached = await _readCache(
        modelId: model,
        nodeId: node,
        allowStale: true,
      );
      if (cached != null) return cached;
      // Airplane mode: show the last saved device schema immediately.
      // A fresh-cache miss must not block on a host lookup that cannot succeed.
      if (await _isOffline()) {
        final stale = await _readCache(
          modelId: model,
          nodeId: node,
          allowStale: true,
        );
        if (stale != null) {
          logDebug('[SchemaRepository] OFFLINE — using saved schema');
          return stale;
        }
      }
    }

    final existing = _inFlight[flightKey] ??
        (forceRefresh ? null : _inFlight['$cacheKey|live']);
    if (existing != null) return existing;

    final pending = () async {
      try {
        return await _fetchAndStoreLive(
          model: model,
          node: node,
          forceRefresh: forceRefresh,
        );
      } catch (error) {
        if (_isNegativeCacheable(error)) {
          _negativeCache[cacheKey] = _NegativeSchemaCache(
            until: DateTime.now().add(_negativeCacheTtl),
            error: error,
          );
        }
        if (!isTransientNetworkFailure(error)) rethrow;
        final stale = await _readCache(
          modelId: model,
          nodeId: node,
          allowStale: true,
        );
        if (stale == null) rethrow;
        logDebug('[SchemaRepository] OFFLINE FALLBACK to saved schema');
        return stale;
      }
    }();

    _inFlight[flightKey] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_inFlight[flightKey], pending)) {
        _inFlight.remove(flightKey);
      }
    }
  }

  /// The schema for the first pager slot, or a saved document when one exists.
  ///
  /// This does not wait for the other slots. The screen can paint page 1
  /// while [completePages] downloads the rest.
  Future<Map<String, dynamic>> loadOpeningPage({
    required String modelId,
    required String nodeId,
    bool forceRefresh = false,
  }) async {
    final model = _required(modelId, 'MODEL_ID');
    final node = _required(nodeId, 'NODE_ID');
    if (storeDevicePagesLocally && !forceRefresh) {
      final memory = _memoryHit(_cacheKey(modelId: model, nodeId: node));
      if (memory != null) return memory;
      final cached = await _readCache(
        modelId: model,
        nodeId: node,
        allowStale: true,
      );
      if (cached != null) return cached;
    }
    return _downloadPreparedPage(
      model: model,
      node: node,
      pageNo: 1,
      forceRefresh: storeDevicePagesLocally ? forceRefresh : true,
      persist: storeDevicePagesLocally,
    );
  }

  /// Loads Page 1 and merges all locally available page slots into a unified
  /// schema so that all cached pages and slides are immediately ready on screen startup.
  Future<Map<String, dynamic>> loadMergedDeviceSchema({
    required String modelId,
    required String nodeId,
    bool forceRefresh = false,
  }) async {
    final model = _required(modelId, 'MODEL_ID');
    final node = _required(nodeId, 'NODE_ID');

    var merged = await loadOpeningPage(
      modelId: model,
      nodeId: node,
      forceRefresh: forceRefresh,
    );

    if (!storeDevicePagesLocally) return merged;

    final published = publishedPageNumbers(merged);
    final otherPages = published.where((p) => p != 1).toList();
    if (otherPages.isNotEmpty) {
      final cachedPages = await Future.wait(
        otherPages.map(
          (pageNo) => readFromCache(
            modelId: model,
            nodeId: node,
            pageNo: pageNo,
            allowStale: true,
          ),
        ),
      );
      for (final cached in cachedPages) {
        if (cached != null) {
          merged = mergeDevicePageSchema(merged, cached);
        }
      }
    }

    return merged;
  }

  /// One complete schema document for pager slot [pageNo].
  ///
  /// Slot 1 is `page_no=1`, slot 2 is `page_no=2`. The saved copy for that
  /// slot is used when it exists. The caller replaces the schema on screen.
  Future<Map<String, dynamic>> loadSchemaPage({
    required String modelId,
    required String nodeId,
    required int pageNo,
    bool forceRefresh = false,
  }) async {
    final model = _required(modelId, 'MODEL_ID');
    final node = _required(nodeId, 'NODE_ID');
    final slot = pageNo < 1 ? 1 : pageNo;
    if (storeDevicePagesLocally && !forceRefresh) {
      final cached = await _readCache(
        modelId: model,
        nodeId: node,
        allowStale: true,
        pageNo: slot,
      );
      if (cached != null) return cached;
    }
    return _downloadPreparedPage(
      model: model,
      node: node,
      pageNo: slot,
      forceRefresh: storeDevicePagesLocally ? forceRefresh : true,
      persist: storeDevicePagesLocally,
    );
  }

  /// Downloads the page documents [base] links to and does not yet contain.
  ///
  /// The links are `paging.pages[].pageApi`, `paging.nextPageApi`, and
  /// `paging.prevPageApi`. A downloaded page can publish the next link, so
  /// the walk follows those too. Returns null when [base] already has every
  /// published control. A failed later page keeps the pages that did download.
  Future<Map<String, dynamic>?> completePages({
    required String modelId,
    required String nodeId,
    required Map<String, dynamic> base,
    bool forceRefresh = false,
  }) async {
    final model = _required(modelId, 'MODEL_ID');
    final node = _required(nodeId, 'NODE_ID');
    if (!forceRefresh &&
        schemaCoversPublishedControls(base) &&
        emptyPageSlides(base) == 0) {
      return null;
    }

    var merged = base;
    var changed = false;
    final pending = <String>[];
    final seen = <String>{};

    void enqueue(Map<String, dynamic> schema) {
      for (final url in publishedPageSchemaUrls(schema)) {
        if (!seen.add(url)) continue;
        pending.add(url);
      }
    }

    enqueue(merged);
    var index = 0;
    while (index < pending.length && index < 32) {
      final url = pending[index++];
      if (!forceRefresh && pageSchemaAlreadyLoaded(merged, url)) continue;
      if (!forceRefresh && schemaCoversPublishedControls(merged)) break;
      try {
        final page = await _downloadPreparedPage(
          model: model,
          node: node,
          pageUri: Uri.parse(url),
          forceRefresh: forceRefresh,
          persist: false,
        );
        final next = mergeDevicePageSchema(merged, page);
        final before = merged['controls'];
        final after = next['controls'];
        if (before is! List ||
            after is! List ||
            before.length != after.length ||
            emptyPageSlides(next) != emptyPageSlides(merged)) {
          changed = true;
        }
        merged = next;
        enqueue(page);
      } catch (error) {
        logDebug(
          '[SchemaRepository] page schema failed for $model/$node '
          'url=$url error=$error',
        );
        break;
      }
    }

    if (!changed && !forceRefresh) return null;
    if (!schemaCoversPublishedControls(merged) && !changed) return null;

    merged['_clientSchemaHash'] = contentHash(<String, dynamic>{
      'controls': merged['controls'],
      'pages': merged['pages'],
      'slides': _pageSlideChildIds(merged),
    });

    await _storeDeviceSchema(
      schema: merged,
      model: model,
      node: node,
      raw: jsonEncode(merged),
    );
    return merged;
  }

  static bool isFreshCache(Map<String, dynamic> schema) {
    if (schema['_clientSchemaCacheHit'] != true) return false;
    final raw = schema['_clientSchemaCachedAtMs'];
    final savedAtMs = raw is int
        ? raw
        : raw is num
            ? raw.toInt()
            : int.tryParse(raw?.toString() ?? '');
    if (savedAtMs == null) return false;
    return DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(savedAtMs),
        ) <
        _freshCacheRevalidateAfter;
  }

  Future<Map<String, dynamic>> _fetchAndStoreLive({
    required String model,
    required String node,
    required bool forceRefresh,
  }) async {
    final first = await _downloadPreparedPage(
      model: model,
      node: node,
      pageNo: 1,
      forceRefresh: forceRefresh || !storeDevicePagesLocally,
      persist: storeDevicePagesLocally,
    );
    if (!storeDevicePagesLocally) return first;
    if (schemaCoversPublishedControls(first)) {
      await _storeDeviceSchema(
        schema: first,
        model: model,
        node: node,
        raw: jsonEncode(first),
      );
      return first;
    }

    final merged = await completePages(
      modelId: model,
      nodeId: node,
      base: first,
    );
    if (merged != null) return merged;
    await _storeDeviceSchema(
      schema: first,
      model: model,
      node: node,
      raw: jsonEncode(first),
    );
    return first;
  }

  Future<Map<String, dynamic>> _downloadPreparedPage({
    required String model,
    required String node,
    int? pageNo,
    Uri? pageUri,
    required bool forceRefresh,
    required bool persist,
  }) async {
    final schemaUri = _pageRequestUri(
      model: model,
      node: node,
      pageNo: pageNo,
      pageUri: pageUri,
      forceRefresh: forceRefresh,
    );
    final flightIdentity =
        normalizedPageSchemaUrl(schemaUri.toString()) ?? schemaUri.toString();
    final flightKey =
        '${_cacheKey(modelId: model, nodeId: node)}|page:$flightIdentity|${forceRefresh ? 'live' : 'any'}';
    final existing = _pageFlights[flightKey];
    if (existing != null) return existing;

    final pending = _downloadPreparedPageBody(
      model: model,
      node: node,
      schemaUri: schemaUri,
      forceRefresh: forceRefresh,
      persist: persist,
    );
    _pageFlights[flightKey] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_pageFlights[flightKey], pending)) {
        _pageFlights.remove(flightKey);
      }
    }
  }

  Uri _pageRequestUri({
    required String model,
    required String node,
    required int? pageNo,
    required Uri? pageUri,
    required bool forceRefresh,
  }) {
    final built = pageUri ??
        _buildSchemaUri(
          modelId: model,
          nodeId: node,
          addRefreshQuery: false,
          pageNo: pageNo,
        );
    if (!forceRefresh) return built;
    final query = Map<String, String>.from(built.queryParameters);
    query['_ts'] = DateTime.now().microsecondsSinceEpoch.toString();
    return built.replace(queryParameters: query);
  }

  Future<Map<String, dynamic>> _downloadPreparedPageBody({
    required String model,
    required String node,
    required Uri schemaUri,
    required bool forceRefresh,
    required bool persist,
  }) async {
    final pageNo = int.tryParse(schemaUri.queryParameters['page_no'] ?? '');

    logDebug('[SchemaRepository] LIVE GET $schemaUri');

    final request = http.Request('GET', schemaUri)
      ..headers.addAll(<String, String>{
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip, deflate',
        'X-Model-Id': model,
        'X-Node-Id': node,
        if (forceRefresh) 'Cache-Control': 'no-cache',
        if (forceRefresh) 'Pragma': 'no-cache',
      });

    final streamed = await _client
        .send(request)
        .timeout(_responseHeaderTimeout);

    final contentLength = streamed.contentLength;
    final bodyTimeout = _bodyTimeoutForLength(contentLength);

    logDebug(
      '[SchemaRepository] RESPONSE_HEADERS '
      'status=${streamed.statusCode} '
      'contentLength=${contentLength ?? 'unknown'} '
      'bodyTimeout=${bodyTimeout.inSeconds}s',
    );

    final bodyBytes = await streamed.stream.toBytes().timeout(bodyTimeout);

    final response = http.Response.bytes(
      bodyBytes,
      streamed.statusCode,
      request: request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'Schema request failed with HTTP '
        '${response.statusCode}. '
        '${_safeResponseMessage(response.body)}',
        schemaUri,
      );
    }

    final raw = utf8.decode(response.bodyBytes).trim();

    if (raw.isEmpty) {
      throw FormatException(
        'The schema API returned an empty response. '
        'URL: $schemaUri',
      );
    }

    ensureDecodableJson(
      body: raw,
      contentType: response.headers['content-type'],
      source: schemaUri.toString(),
    );

    dynamic decoded;

    try {
      // Parse JSON on a background isolate to keep the UI thread free.
      decoded = await compute(_jsonDecodeAny, raw);
    } on FormatException catch (error) {
      throw FormatException(
        'The schema API did not return valid JSON. '
        'URL: $schemaUri. '
        'Response: ${_safeResponseMessage(raw)}. '
        'Parser error: ${error.message}',
      );
    }

    logDebug(
      '[SchemaRepository] HTTP_STATUS=${response.statusCode} '
      'ROOT_TYPE=${decoded.runtimeType}',
    );

    final schema = _extractSchema(decoded);
    final scanUri = _resolveScanUri(schema);

    final originalModelId = _readOriginalModelId(schema);
    final originalNodeId = _readOriginalNodeId(schema);

    final canonical = _buildSchemaUri(
      modelId: model,
      nodeId: node,
      addRefreshQuery: false,
    );
    _applyConnectionContext(
      schema,
      modelId: model,
      nodeId: node,
      schemaUri: canonical,
      scanUri: scanUri,
      originalModelId: originalModelId,
      originalNodeId: originalNodeId,
    );

    _validateSchema(schema);

    schema['_clientSchemaHash'] = contentHashString(raw);
    schema['_clientSchemaSource'] = canonical.toString();
    schema['_clientSchemaCacheHit'] = false;
    schema['_clientSchemaCachedAtMs'] = DateTime.now().millisecondsSinceEpoch;
    schema['_clientSchemaPageNo'] = pageNo;

    logDebug(
      '[SchemaRepository] LIVE SCHEMA LOADED '
      'modelId=$model '
      'nodeId=$node '
      'pageNo=$pageNo '
      'bytes=${raw.length} '
      'controls=${(schema['controls'] as List).length} '
      'pages=${(schema['pages'] as List).length} '
      'scanApi=$scanUri',
    );

    if (persist) {
      final diskPayload = jsonEncode(schema);
      schema['_clientSchemaHash'] = contentHashString(diskPayload);
      await _storeDeviceSchema(
        schema: schema,
        model: model,
        node: node,
        raw: diskPayload,
        pageNo: pageNo ?? 1,
      );
    }
    return schema;
  }

  Future<void> _storeDeviceSchema({
    required Map<String, dynamic> schema,
    required String model,
    required String node,
    required String raw,
    int pageNo = 1,
  }) async {
    if (!storeDevicePagesLocally) return;
    final cacheKey = _pageCacheKey(modelId: model, nodeId: node, pageNo: pageNo);
    schema['_clientSchemaCacheHit'] = false;
    schema['_clientSchemaCachedAtMs'] = DateTime.now().millisecondsSinceEpoch;
    _rememberParsed(cacheKey, schema, DateTime.now());
    _negativeCache.remove(cacheKey);
    await _writeCache(raw: raw, modelId: model, nodeId: node, pageNo: pageNo);
  }

  String _cacheKey({required String modelId, required String nodeId}) {
    final raw = '$modelId|$nodeId';
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in utf8.encode(raw)) {
      hash ^= BigInt.from(byte);
      hash = (hash * prime) & mask;
    }
    return 'efactor.device.server_schema.v1.${hash.toRadixString(16)}';
  }

  String _pageCacheKey({
    required String modelId,
    required String nodeId,
    int pageNo = 1,
  }) {
    final base = _cacheKey(modelId: modelId, nodeId: nodeId);
    if (pageNo <= 1) return base;
    return '$base.page.$pageNo';
  }

  Future<Map<String, dynamic>?> _readCache({
    required String modelId,
    required String nodeId,
    bool allowStale = false,
    int pageNo = 1,
  }) async {
    if (!storeDevicePagesLocally) return null;
    final memoryFirst = _memoryHit(
      _pageCacheKey(modelId: modelId, nodeId: nodeId, pageNo: pageNo),
    );
    if (memoryFirst != null) return memoryFirst;

    final prefs = await SharedPreferences.getInstance();
    final key = _pageCacheKey(
      modelId: modelId,
      nodeId: nodeId,
      pageNo: pageNo,
    );
    var savedAtMs = prefs.getInt('$key.savedAt');
    String? raw;
    try {
      raw = await SchemaDiskCache.readString('$key.json');
    } catch (error) {
      logDebug('[SchemaRepository] DISK CACHE READ FAILED: $error');
    }
    raw ??= prefs.getString(key);
    savedAtMs ??= await SchemaDiskCache.modifiedAtMs('$key.json');
    if (raw == null || savedAtMs == null) return null;

    final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
    final age = DateTime.now().difference(savedAt);
    if (age > _cacheMaxAge && !allowStale) {
      return null;
    }

    final memory = _memoryHit(key);
    if (memory != null) return memory;

    try {
      final decoded = await compute(_jsonDecodeAny, raw);
      final schema = _extractSchema(decoded);
      final schemaUri = _buildSchemaUri(
        modelId: modelId,
        nodeId: nodeId,
        addRefreshQuery: false,
      );
      final scanUri = _resolveScanUri(schema);
      final originalModelId = _readOriginalModelId(schema);
      final originalNodeId = _readOriginalNodeId(schema);
      _applyConnectionContext(
        schema,
        modelId: modelId,
        nodeId: nodeId,
        schemaUri: schemaUri,
        scanUri: scanUri,
        originalModelId: originalModelId,
        originalNodeId: originalNodeId,
      );
      _validateSchema(schema);
      schema['_clientSchemaHash'] = contentHashString(raw);
      schema['_clientSchemaSource'] = schemaUri.toString();
      schema['_clientSchemaCacheHit'] = true;
      schema['_clientSchemaPageNo'] = pageNo;
      schema['_clientSchemaCachedAtMs'] = savedAtMs;
      _rememberParsed(key, schema, savedAt);
      logDebug(
        '[SchemaRepository] CACHE HIT '
        'age=${age.inSeconds}s stale=${age > _cacheMaxAge}',
      );
      return schema;
    } catch (error) {
      logDebug('[SchemaRepository] CACHE INVALID: $error');
      await prefs.remove(key);
      await prefs.remove('$key.savedAt');
      try {
        await SchemaDiskCache.remove('$key.json');
      } catch (_) {}
      return null;
    }
  }

  Future<void> _writeCache({
    required String raw,
    required String modelId,
    required String nodeId,
    int pageNo = 1,
  }) async {
    if (!storeDevicePagesLocally) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _pageCacheKey(
        modelId: modelId,
        nodeId: nodeId,
        pageNo: pageNo,
      );
      await SchemaDiskCache.writeString('$key.json', raw);
      await prefs.remove(key);
      await prefs.setInt('$key.savedAt', DateTime.now().millisecondsSinceEpoch);
      await rememberKnownDevice(modelId: modelId, nodeId: nodeId);
      await LocalSchemaManifest.record(
        schemaKey: pageNo <= 1
            ? 'device:$modelId:$nodeId'
            : 'device:$modelId:$nodeId:page:$pageNo',
        schemaType: 'device',
        contentHash: contentHashString(raw),
        fileName: '$key.json',
      );
      logDebug(
        '[SchemaRepository] CACHE SAVED bytes=${raw.length} key=$key pageNo=$pageNo',
      );
    } catch (error) {
      logDebug('[SchemaRepository] CACHE SAVE FAILED: $error');
    }
  }

  Future<void> saveToCache({
    required String modelId,
    required String nodeId,
    required Map<String, dynamic> schema,
  }) async {
    final raw = jsonEncode(schema);
    await _writeCache(raw: raw, modelId: modelId, nodeId: nodeId);
    final cacheKey = _cacheKey(modelId: modelId, nodeId: nodeId);
    _rememberParsed(cacheKey, schema, DateTime.now());
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }

  /// Already-parsed schema for this model, without reading the disk file.
  /// Opening a device that was loaded in this session paints immediately.
  Map<String, dynamic>? peekMemory({
    required String modelId,
    required String nodeId,
    int pageNo = 1,
  }) {
    final model = modelId.trim();
    final node = nodeId.trim();
    if (!storeDevicePagesLocally) return null;
    if (model.isEmpty || node.isEmpty) return null;
    return _memoryHit(
      _pageCacheKey(modelId: model, nodeId: node, pageNo: pageNo),
    );
  }

  Future<Map<String, dynamic>?> readFromCache({
    required String modelId,
    required String nodeId,
    bool allowStale = true,
    int pageNo = 1,
  }) {
    return _readCache(
      modelId: modelId,
      nodeId: nodeId,
      allowStale: allowStale,
      pageNo: pageNo,
    );
  }

  static const String _knownDevicesKey = 'efactor.device.schema_index.v1';
  static const int _knownDevicesLimit = 50;

  static Future<List<KnownDeviceSchema>> listKnownDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_knownDevicesKey);
      if (raw == null || raw.isEmpty) return const <KnownDeviceSchema>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <KnownDeviceSchema>[];
      final items = <KnownDeviceSchema>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry.cast<dynamic, dynamic>());
        final modelId = map['modelId']?.toString().trim() ?? '';
        final nodeId = map['nodeId']?.toString().trim() ?? '';
        if (modelId.isEmpty || nodeId.isEmpty) continue;
        items.add(KnownDeviceSchema(modelId: modelId, nodeId: nodeId));
      }
      return items;
    } catch (error) {
      logDebug('[SchemaRepository] DEVICE INDEX READ FAILED: $error');
      return const <KnownDeviceSchema>[];
    }
  }

  static Future<void> rememberKnownDevice({
    required String modelId,
    required String nodeId,
  }) async {
    final model = modelId.trim();
    final node = nodeId.trim();
    if (model.isEmpty || node.isEmpty) return;
    try {
      final current = await listKnownDevices();
      final next = <KnownDeviceSchema>[
        ...current.where((item) => item.modelId != model || item.nodeId != node),
        KnownDeviceSchema(modelId: model, nodeId: node),
      ];
      if (next.length > _knownDevicesLimit) {
        next.removeRange(0, next.length - _knownDevicesLimit);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _knownDevicesKey,
        jsonEncode(
          next
              .map(
                (item) => <String, String>{
                  'modelId': item.modelId,
                  'nodeId': item.nodeId,
                },
              )
              .toList(growable: false),
        ),
      );
    } catch (error) {
      logDebug('[SchemaRepository] DEVICE INDEX SAVE FAILED: $error');
    }
  }

  /// Completely clears all in-memory and disk-persisted device schemas on logout.
  static Future<void> clearAllCache() async {
    _memoryCache.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().toList();
      for (final key in keys) {
        if (key.startsWith('efactor.device.server_schema.v1.') ||
            key == _knownDevicesKey) {
          await prefs.remove(key);
          await prefs.remove('$key.savedAt');
          try {
            await SchemaDiskCache.remove('$key.json');
          } catch (_) {}
        }
      }
      logDebug('[SchemaRepository] Cleared all device schemas and memory cache');
    } catch (error) {
      logDebug('[SchemaRepository] Failed to clear device schema cache: $error');
    }
  }

  /// Every `page_no` this document says exists.
  ///
  /// The range is `1..pageCount`, plus each `pageNo` and `pageApi` page
  /// number, plus `deviceConfig.total_pages` when that is higher. A model
  /// with four pages and another with one page therefore request different
  /// sets.
  static List<int> publishedPageNumbers(Map<String, dynamic> schema) {
    final numbers = <int>{};
    void add(dynamic value) {
      if (value is int && value > 0) {
        numbers.add(value);
        return;
      }
      if (value is num && value > 0) {
        numbers.add(value.toInt());
        return;
      }
      final parsed = int.tryParse(value?.toString().trim() ?? '');
      if (parsed != null && parsed > 0) numbers.add(parsed);
    }

    final count = publishedPageCount(schema);
    for (var pageNo = 1; pageNo <= count; pageNo++) {
      numbers.add(pageNo);
    }

    final paging = schema['paging'];
    if (paging is Map) {
      add(paging['pageNo']);
      final pages = paging['pages'];
      if (pages is List) {
        for (final page in pages) {
          if (page is! Map) continue;
          add(page['pageNo']);
          final api = Uri.tryParse(page['pageApi']?.toString() ?? '');
          add(api?.queryParameters['page_no']);
        }
      }
    }

    final pages = schema['pages'];
    if (pages is List) {
      for (final page in pages) {
        if (page is Map) add(page['pageNo']);
      }
    }

    final config = schema['deviceConfig'];
    final devices = config is Map ? config['devices'] : null;
    if (devices is List) {
      for (final device in devices) {
        if (device is! Map) continue;
        final total = int.tryParse(device['total_pages']?.toString() ?? '');
        if (total == null || total < 1) continue;
        for (var pageNo = 1; pageNo <= total; pageNo++) {
          numbers.add(pageNo);
        }
      }
    }

    if (numbers.isEmpty) numbers.add(1);
    final ordered = numbers.toList()..sort();
    return ordered;
  }

  /// Saved response body for one page, when that page was stored before.
  Future<String?> readCachedPageRaw({
    required String modelId,
    required String nodeId,
    required int pageNo,
  }) async {
    final model = modelId.trim();
    final node = nodeId.trim();
    if (model.isEmpty || node.isEmpty || pageNo < 1) return null;
    final key = _pageCacheKey(modelId: model, nodeId: node, pageNo: pageNo);
    try {
      return await SchemaDiskCache.readString('$key.json');
    } catch (error) {
      logDebug('[SchemaRepository] PAGE RAW READ FAILED page_no=$pageNo: $error');
      return null;
    }
  }

  /// Writes one page response to the disk file the device screen reads.
  ///
  /// The body is stored as received. Parsing happens when that page is opened,
  /// so a background save of the other pages does not freeze the open screen.
  Future<void> writeCachedPageBody({
    required String modelId,
    required String nodeId,
    required int pageNo,
    required String raw,
  }) {
    return _writeCache(
      raw: raw,
      modelId: modelId,
      nodeId: nodeId,
      pageNo: pageNo < 1 ? 1 : pageNo,
    );
  }

  /// True when this page already has a disk file. Does not parse it.
  Future<bool> cachedPageExists({
    required String modelId,
    required String nodeId,
    int pageNo = 1,
  }) async {
    final model = modelId.trim();
    final node = nodeId.trim();
    if (model.isEmpty || node.isEmpty || pageNo < 1) return false;
    final key = _pageCacheKey(modelId: model, nodeId: node, pageNo: pageNo);
    try {
      return await SchemaDiskCache.exists('$key.json');
    } catch (_) {
      return false;
    }
  }

  /// Stores one already-downloaded page response on disk under its page number.
  Future<void> persistPageRaw({
    required String modelId,
    required String nodeId,
    required int pageNo,
    required String raw,
  }) async {
    final model = _required(modelId, 'MODEL_ID');
    final node = _required(nodeId, 'NODE_ID');
    final slot = pageNo < 1 ? 1 : pageNo;
    final schema = _extractSchema(await compute(_jsonDecodeAny, raw));
    _validateSchema(schema);
    final diskPayload = jsonEncode(schema);
    schema['_clientSchemaHash'] = contentHashString(diskPayload);
    schema['_clientSchemaPageNo'] = slot;
    schema['_clientSchemaCacheHit'] = false;
    schema['_clientSchemaCachedAtMs'] = DateTime.now().millisecondsSinceEpoch;
    await _storeDeviceSchema(
      schema: schema,
      model: model,
      node: node,
      raw: diskPayload,
      pageNo: slot,
    );
  }

  /// Page count published in schema metadata.
  ///
  /// `paging.pageCount` and `meta.pageCount` are the pager length. `pages`
  /// is the fallback. `deviceConfig.total_pages` is not this count.
  static int publishedPageCount(Map<String, dynamic> schema) {
    int? asCount(dynamic value) {
      if (value is int && value > 0) return value;
      if (value is num && value > 0) return value.toInt();
      final parsed = int.tryParse(value?.toString().trim() ?? '');
      if (parsed != null && parsed > 0) return parsed;
      return null;
    }

    final paging = schema['paging'];
    if (paging is Map) {
      final count = asCount(paging['pageCount']);
      if (count != null) return count;
    }
    final meta = schema['meta'];
    if (meta is Map) {
      final count = asCount(meta['pageCount']);
      if (count != null) return count;
    }
    final rendering = schema['rendering'];
    if (rendering is Map) {
      final count = asCount(rendering['pageCount']);
      if (count != null) return count;
    }
    final pages = schema['pages'];
    if (pages is List && pages.isNotEmpty) return pages.length;
    return 1;
  }

  /// True when pager slot [pageNo] (1-based) already has its controls and slide.
  static bool pageSlotReady(Map<String, dynamic> schema, int pageNo) {
    if (pageNo < 1) return false;
    final pages = schema['pages'];
    if (pages is! List || pageNo > pages.length) return false;
    final page = pages[pageNo - 1];
    if (page is! Map) return false;
    final ids = _controlIdsForPage(
      schema,
      pageNo: page['pageNo']?.toString(),
      pageId: page['id']?.toString(),
    );
    if (ids.isEmpty) return false;
    final controls = schema['controls'];
    if (controls is! List) return false;
    final have = <String>{
      for (final raw in controls)
        if (raw is Map && raw['id'] != null) raw['id'].toString(),
    };
    for (final id in ids) {
      if (!have.contains(id)) return false;
    }
    final slide = _pageSlideChildren(
      schema,
      pageNo: page['pageNo']?.toString(),
      pageId: page['id']?.toString(),
    );
    if (slide != null && slide.isEmpty) return false;
    return true;
  }

  /// How many `page_no` requests this document publishes.
  ///
  /// The count is `pages.length`. `deviceConfig.total_pages` is a different
  /// field and is not the pager length.
  static int publishedPageSlots(Map<String, dynamic> schema) {
    final pages = schema['pages'];
    if (pages is List && pages.isNotEmpty) return pages.length;
    return 1;
  }

  /// True when every id in `pages[].controlIds` is already in `controls`.
  ///
  /// A combined document and a finished page merge both pass. A single
  /// `page_no` response fails until the other slots are merged, because its
  /// `pages` list names controls that are not in that response.
  static bool schemaCoversPublishedControls(Map<String, dynamic> schema) {
    final pages = schema['pages'];
    final controls = schema['controls'];
    if (pages is! List || pages.isEmpty) return controls is List;
    if (controls is! List) return false;
    final have = <String>{
      for (final raw in controls)
        if (raw is Map && raw['id'] != null) raw['id'].toString(),
    };
    var expected = 0;
    for (final page in pages) {
      if (page is! Map) continue;
      final ids = page['controlIds'];
      if (ids is! List) continue;
      for (final id in ids) {
        final text = id?.toString() ?? '';
        if (text.isEmpty) continue;
        expected++;
        if (!have.contains(text)) return false;
      }
    }
    return expected > 0 || have.isNotEmpty;
  }

  /// Adds [incoming] controls and parameter seeds onto [base].
  ///
  /// Existing controls and parameter values stay. A later page only fills
  /// ids the open page did not carry. The base map is not mutated.
  static Map<String, dynamic> mergeDevicePageSchema(
    Map<String, dynamic> base,
    Map<String, dynamic> incoming,
  ) {
    final merged = Map<String, dynamic>.from(base);
    merged.remove('_clientSchemaHash');
    merged.remove('_clientHomeSchemaHash');
    merged.remove('_clientIotSchemaHash');

    final controls = <dynamic>[
      if (base['controls'] is List) ...(base['controls'] as List),
    ];
    final seen = <String>{
      for (final raw in controls)
        if (raw is Map && raw['id'] != null) raw['id'].toString(),
    };
    final incomingControls = incoming['controls'];
    if (incomingControls is List) {
      for (final raw in incomingControls) {
        if (raw is! Map) {
          controls.add(raw);
          continue;
        }
        final id = raw['id']?.toString() ?? '';
        if (id.isEmpty || seen.add(id)) controls.add(raw);
      }
    }
    merged['controls'] = controls;

    final baseState = base['state'] is Map
        ? Map<String, dynamic>.from((base['state'] as Map).cast<dynamic, dynamic>())
        : <String, dynamic>{};
    final incomingState = incoming['state'] is Map
        ? (incoming['state'] as Map).cast<dynamic, dynamic>()
        : const <dynamic, dynamic>{};
    final baseDevice = baseState['device'] is Map
        ? Map<String, dynamic>.from(
            (baseState['device'] as Map).cast<dynamic, dynamic>(),
          )
        : <String, dynamic>{};
    final incomingDevice = incomingState['device'] is Map
        ? (incomingState['device'] as Map).cast<dynamic, dynamic>()
        : const <dynamic, dynamic>{};
    final params = baseDevice['parameters'] is Map
        ? Map<String, dynamic>.from(
            (baseDevice['parameters'] as Map).cast<dynamic, dynamic>(),
          )
        : <String, dynamic>{};
    final incomingParams = incomingDevice['parameters'];
    if (incomingParams is Map) {
      for (final entry in incomingParams.entries) {
        params.putIfAbsent(entry.key.toString(), () => entry.value);
      }
    }
    baseDevice['parameters'] = params;
    baseState['device'] = baseDevice;
    merged['state'] = baseState;

    final accumulatedPages = <Map<String, dynamic>>[];
    final basePages = base['pages'];
    if (basePages is List) {
      for (final p in basePages) {
        if (p is Map) accumulatedPages.add(Map<String, dynamic>.from(p));
      }
    }

    final incomingPages = incoming['pages'];
    if (incomingPages is List) {
      for (var i = 0; i < incomingPages.length; i++) {
        final inc = incomingPages[i];
        if (inc is! Map) continue;
        final incNo = inc['pageNo']?.toString() ?? (i + 1).toString();
        final incId = inc['id']?.toString();

        final existingIdx = accumulatedPages.indexWhere((p) {
          if (incId != null && p['id']?.toString() == incId) return true;
          return p['pageNo']?.toString() == incNo;
        });

        if (existingIdx >= 0) {
          final existing = accumulatedPages[existingIdx];
          final existingControlIds = existing['controlIds'] as List? ?? const [];
          final incomingControlIds = inc['controlIds'] as List? ?? const [];
          if (incomingControlIds.isNotEmpty || existingControlIds.isEmpty) {
            accumulatedPages[existingIdx] = Map<String, dynamic>.from(inc);
          }
        } else {
          accumulatedPages.add(Map<String, dynamic>.from(inc));
        }
      }
    }

    final totalCount = publishedPageCount(base) > publishedPageCount(incoming)
        ? publishedPageCount(base)
        : publishedPageCount(incoming);

    for (var pageNo = 1; pageNo <= totalCount; pageNo++) {
      final pNoStr = pageNo.toString();
      final hasSlot = accumulatedPages.any((p) => p['pageNo']?.toString() == pNoStr);
      if (!hasSlot) {
        accumulatedPages.add(<String, dynamic>{
          'id': 'page_$pageNo',
          'pageNo': pageNo,
          'title': 'Page $pageNo',
          'subtitle': 'Page $pageNo',
          'controlIds': <dynamic>[],
        });
      }
    }

    accumulatedPages.sort((a, b) {
      final aNo = int.tryParse(a['pageNo']?.toString() ?? '') ?? 0;
      final bNo = int.tryParse(b['pageNo']?.toString() ?? '') ?? 0;
      return aNo.compareTo(bNo);
    });

    merged['pages'] = accumulatedPages;
    final paging = preferPublishedPaging(base['paging'], incoming['paging']);
    if (paging != null) merged['paging'] = paging;
    if (base['ui'] != null && incoming['ui'] != null) {
      merged['ui'] = mergePageSlides(base['ui'], incoming['ui']);
    }
    ensurePlaceholderSlides(merged);

    final baseHash = base['_clientSchemaHash']?.toString() ?? 'base';
    final incHash = incoming['_clientSchemaHash']?.toString() ??
        incoming['id']?.toString() ??
        'page_${incoming['pageNo'] ?? incoming['page_no'] ?? controls.length}';
    merged['_clientSchemaHash'] = contentHash(<String, dynamic>{
      'base': baseHash,
      'incoming': incHash,
      'controls': merged['controls'],
      'pages': merged['pages'],
      'slides': _pageSlideChildIds(merged),
    });

    return merged;
  }

  /// Fills page slides that the open document left empty.
  ///
  /// Page 1 publishes every slide, but only the open slide has its
  /// child controls (`schemaControlList`). The next page document carries that list
  /// for its own slide and leaves the others empty.
  ///
  /// This method recursively traverses `widgetTree` and child hierarchies,
  /// matching slides by `id`, `properties.pageNo`, or `properties.pageId`,
  /// and copies the filled children into the empty slide without replacing
  /// slides that already have content.
  static dynamic mergePageSlides(dynamic base, dynamic incoming) {
    if (base is! Map || incoming is! Map) return base;
    final merged = Map<String, dynamic>.from(base);

    // Recursively merge widgetTree if present (used in SDUI v4.0.0 server schemas)
    if (base['widgetTree'] != null && incoming['widgetTree'] != null) {
      merged['widgetTree'] =
          mergePageSlides(base['widgetTree'], incoming['widgetTree']);
    }

    final baseChildren = base['children'];
    final incomingChildren = incoming['children'];
    if (baseChildren is List && incomingChildren is List) {
      if (baseChildren.isEmpty && incomingChildren.isNotEmpty) {
        merged['children'] = [
          for (final child in incomingChildren) child,
        ];
        return merged;
      }

      final incomingById = <String, Map>{};
      final incomingByPageNo = <String, Map>{};
      final incomingByPageId = <String, Map>{};

      for (final child in incomingChildren) {
        if (child is! Map) continue;
        final id = child['id']?.toString();
        if (id != null && id.isNotEmpty) incomingById[id] = child;
        final props = child['properties'];
        if (props is Map) {
          final pNo = props['pageNo']?.toString();
          if (pNo != null && pNo.isNotEmpty) incomingByPageNo[pNo] = child;
          final pId = props['pageId']?.toString();
          if (pId != null && pId.isNotEmpty) incomingByPageId[pId] = child;
        }
      }

      final matchedIncoming = <dynamic>{};

      merged['children'] = [
        for (final child in baseChildren)
          if (child is Map) () {
            Map? match;
            final id = child['id']?.toString();
            if (id != null && incomingById.containsKey(id)) {
              match = incomingById[id];
            } else {
              final props = child['properties'];
              if (props is Map) {
                final pNo = props['pageNo']?.toString();
                final pId = props['pageId']?.toString();
                if (pNo != null && incomingByPageNo.containsKey(pNo)) {
                  match = incomingByPageNo[pNo];
                } else if (pId != null && incomingByPageId.containsKey(pId)) {
                  match = incomingByPageId[pId];
                }
              }
            }

            if (match != null) {
              matchedIncoming.add(match);
              final cChildren = child['children'];
              final mChildren = match['children'];
              if ((cChildren is! List || cChildren.isEmpty) &&
                  (mChildren is List && mChildren.isNotEmpty)) {
                final filledChild = Map<String, dynamic>.from(child);
                filledChild['children'] = [for (final gc in mChildren) gc];
                return filledChild;
              }
              return mergePageSlides(child, match);
            }
            return child;
          }()
          else
            child,
      ];

      final isSliderContainer = base['id'] == 'page_slider' ||
          base['type'] == 'page_slider' ||
          base['type'] == 'page_view' ||
          (base['properties'] is Map &&
              (base['properties']['physics'] == 'page' ||
                  base['properties']['pageMode'] == true));

      for (final inc in incomingChildren) {
        if (!matchedIncoming.contains(inc)) {
          final isSlideChild = inc is Map &&
              (inc['id']?.toString().startsWith('page_slide_') == true ||
                  (inc['properties'] is Map && inc['properties']['pageNo'] != null));
          if (isSliderContainer && isSlideChild) {
            (merged['children'] as List).add(inc);
          }
        }
      }

      if ((merged['children'] as List).any((c) =>
          c is Map &&
          (c['id']?.toString().startsWith('page_slide_') == true ||
              (c['properties'] is Map && c['properties']['pageNo'] != null)))) {
        (merged['children'] as List).sort((a, b) {
          int pageNoOf(dynamic node) {
            if (node is! Map) return 0;
            final props = node['properties'];
            final pNo = props is Map
                ? int.tryParse(props['pageNo']?.toString() ?? '')
                : null;
            if (pNo != null) return pNo;
            final id = node['id']?.toString() ?? '';
            if (id.startsWith('page_slide_')) {
              return (int.tryParse(id.substring('page_slide_'.length)) ?? 0) + 1;
            }
            return 0;
          }

          return pageNoOf(a).compareTo(pageNoOf(b));
        });
      }
    }
    return merged;
  }

  /// Ensures that any page slider in the schema contains a slide slot for each
  /// published page in `paging.pages`. If a slot does not exist, an empty
  /// placeholder slide is created so that PageView and scroll controllers have
  /// stable bounds and can display the loading state while the page loads.
  static void ensurePlaceholderSlides(Map<String, dynamic> schema) {
    final totalCount = publishedPageCount(schema);
    if (totalCount <= 0) return;

    // Ensure schema['pages'] has entries for all 1..totalCount pages so pager
    // controls and page counts are consistent throughout the application.
    final existingPages = schema['pages'] is List
        ? List<dynamic>.from(schema['pages'] as List)
        : <dynamic>[];
    final existingNos = <String>{
      for (final p in existingPages)
        if (p is Map && p['pageNo'] != null) p['pageNo'].toString(),
    };
    var pagesUpdated = false;
    for (var pageNo = 1; pageNo <= totalCount; pageNo++) {
      if (!existingNos.contains(pageNo.toString())) {
        existingPages.add(<String, dynamic>{
          'id': 'page_$pageNo',
          'pageNo': pageNo,
          'title': 'Page $pageNo',
          'subtitle': 'Page $pageNo',
          'controlIds': <dynamic>[],
        });
        pagesUpdated = true;
      }
    }
    if (pagesUpdated) {
      existingPages.sort((a, b) {
        final aNo = a is Map ? (int.tryParse(a['pageNo']?.toString() ?? '') ?? 0) : 0;
        final bNo = b is Map ? (int.tryParse(b['pageNo']?.toString() ?? '') ?? 0) : 0;
        return aNo.compareTo(bNo);
      });
      schema['pages'] = existingPages;
    }

    Map<dynamic, dynamic>? findPageSlider(dynamic node) {
      if (node is! Map) return null;
      if (node['type'] == 'listView' &&
          node['properties'] is Map &&
          node['properties']['physics'] == 'page') {
        return node;
      }
      for (final val in node.values) {
        if (val is Map) {
          final found = findPageSlider(val);
          if (found != null) return found;
        } else if (val is List) {
          for (final item in val) {
            final found = findPageSlider(item);
            if (found != null) return found;
          }
        }
      }
      return null;
    }

    final slider = findPageSlider(schema['ui']);
    if (slider == null) return;

    final existingChildren = slider['children'] is List
        ? List<dynamic>.from(slider['children'] as List)
        : <dynamic>[];

    final existingByPageNo = <String, Map<String, dynamic>>{};
    final existingByPageId = <String, Map<String, dynamic>>{};
    for (final child in existingChildren) {
      if (child is! Map) continue;
      final childMap = Map<String, dynamic>.from(child);
      final props = childMap['properties'];
      if (props is Map) {
        final pNo = props['pageNo']?.toString();
        final pId = props['pageId']?.toString();
        if (pNo != null && pNo.isNotEmpty) existingByPageNo[pNo] = childMap;
        if (pId != null && pId.isNotEmpty) existingByPageId[pId] = childMap;
      }
      final id = childMap['id']?.toString() ?? '';
      if (id.startsWith('page_slide_')) {
        final numPart = id.substring('page_slide_'.length);
        final inferredPageNo = (int.tryParse(numPart) ?? -1) + 1;
        if (inferredPageNo > 0) {
          existingByPageNo.putIfAbsent(
            inferredPageNo.toString(),
            () => childMap,
          );
        }
      }
    }

    final pagesByPageNo = <String, Map>{};
    for (final p in existingPages) {
      if (p is Map) {
        final pNo = p['pageNo']?.toString();
        if (pNo != null) pagesByPageNo[pNo] = p;
      }
    }

    final allSlides = <Map<String, dynamic>>[];
    for (var i = 0; i < totalCount; i++) {
      final pageNo = (i + 1).toString();
      final page = pagesByPageNo[pageNo];
      final pageId = page?['id']?.toString() ?? 'page_${i + 1}';
      final pageTitle = page?['title']?.toString() ??
          page?['subtitle']?.toString() ??
          'Page $pageNo';

      final existing = existingByPageNo[pageNo] ?? existingByPageId[pageId];
      if (existing != null) {
        allSlides.add(existing);
      } else {
        allSlides.add(<String, dynamic>{
          'id': 'page_slide_$i',
          'type': 'column',
          'properties': {
            'pageId': pageId,
            'pageNo': pageNo,
            'pageName': pageTitle,
            'visibility': true,
            'opacity': 1,
            'crossAxisAlignment': 'stretch',
            'scrollable': true,
            'responsiveLayout': {
              'all': {'width': 'matchParent', 'scrollable': true},
            },
          },
          'children': <dynamic>[],
        });
      }
    }

    slider['children'] = allSlides;
  }

  /// Page-schema URLs published on [schema].
  ///
  /// Order is `paging.pages[].pageApi`, then `prevPageApi`, then
  /// `nextPageApi`. The combined document and the `{pageNo}` template are
  /// omitted. When the envelope paging block was not stored, each
  /// `pages[].pageNo` is requested on the schema host. That page number is
  /// the control's `pageNo`, so the second screen stays `page_no=3` when
  /// the schema says 3.
  static List<String> publishedPageSchemaUrls(Map<String, dynamic> schema) {
    final urls = <String>[];
    final source = schema['_clientSchemaSource']?.toString();
    final base = source == null ? null : Uri.tryParse(source);

    void add(dynamic raw) {
      final normalized = normalizedPageSchemaUrl(
        raw?.toString() ?? '',
        base: base,
      );
      if (normalized == null || urls.contains(normalized)) return;
      urls.add(normalized);
    }

    final paging = schema['paging'];
    if (paging is Map) {
      final pages = paging['pages'];
      if (pages is List) {
        for (final page in pages) {
          if (page is Map) add(page['pageApi']);
        }
      }
      add(paging['prevPageApi']);
      add(paging['nextPageApi']);
    }

    if (urls.isNotEmpty) return urls;

    final pages = schema['pages'];
    if (base == null || pages is! List) return urls;
    for (final page in pages) {
      if (page is! Map) continue;
      final pageNo = page['pageNo']?.toString().trim() ?? '';
      if (pageNo.isEmpty) continue;
      final query = Map<String, String>.from(base.queryParameters)
        ..remove('_ts');
      query['page_no'] = pageNo;
      add(base.replace(queryParameters: query).toString());
    }
    return urls;
  }

  /// True when every control id for the page named by [url] is already in
  /// [schema].
  static bool pageSchemaAlreadyLoaded(
    Map<String, dynamic> schema,
    String url,
  ) {
    final pageNo = Uri.tryParse(url)?.queryParameters['page_no'];
    String? pageId;
    final paging = schema['paging'];
    if (paging is Map && paging['pages'] is List) {
      for (final raw in paging['pages'] as List) {
        if (raw is! Map) continue;
        final api = normalizedPageSchemaUrl(raw['pageApi']?.toString() ?? '');
        if (api != null && api == url) {
          pageId = raw['id']?.toString();
        }
      }
    }

    final ids = _controlIdsForPage(
      schema,
      pageNo: pageNo,
      pageId: pageId,
    );
    if (ids.isEmpty) return false;
    final controls = schema['controls'];
    if (controls is! List) return false;
    final have = <String>{
      for (final raw in controls)
        if (raw is Map && raw['id'] != null) raw['id'].toString(),
    };
    for (final id in ids) {
      if (!have.contains(id)) return false;
    }
    final slide = _pageSlideChildren(
      schema,
      pageNo: pageNo,
      pageId: pageId,
    );
    if (slide != null && slide.isEmpty) return false;
    return true;
  }

  /// Columns the schema marks as a page (`properties.pageNo`) and leaves
  /// without a child control list.
  static int emptyPageSlides(Map<String, dynamic> schema) {
    var count = 0;
    void walk(dynamic node) {
      if (node is Map) {
        if (_isEmptyPageSlide(node)) count++;
        for (final value in node.values) {
          walk(value);
        }
      } else if (node is List) {
        for (final item in node) {
          walk(item);
        }
      }
    }

    walk(schema['ui']);
    return count;
  }

  static bool sameControlIds(
    Map<String, dynamic> left,
    Map<String, dynamic> right,
  ) {
    List<String> ids(Map<String, dynamic> schema) {
      final controls = schema['controls'];
      if (controls is! List) return const <String>[];
      return [
        for (final raw in controls)
          if (raw is Map) raw['id']?.toString() ?? '',
      ];
    }

    final a = ids(left);
    final b = ids(right);
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Keeps the paging block that lists more screens.
  static Map<String, dynamic>? preferPublishedPaging(
    dynamic current,
    dynamic incoming,
  ) {
    int pagesOf(dynamic raw) {
      if (raw is! Map) return -1;
      final pages = raw['pages'];
      return pages is List ? pages.length : 0;
    }

    final currentPages = pagesOf(current);
    final incomingPages = pagesOf(incoming);
    final chosen = incomingPages > currentPages
        ? incoming
        : currentPages >= 0
            ? current
            : incoming;
    if (chosen is! Map) return null;
    return Map<String, dynamic>.from(chosen);
  }

  static String? normalizedPageSchemaUrl(String raw, {Uri? base}) {
    final text = raw.trim();
    if (text.isEmpty || text.toLowerCase() == 'null' || text.contains('{')) {
      return null;
    }
    var uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (!uri.hasScheme) {
      if (base == null) return null;
      uri = base.resolveUri(uri);
    }
    if (uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final pageNo = uri.queryParameters['page_no']?.trim() ?? '';
    if (pageNo.isEmpty || pageNo.contains('{')) return null;
    final query = Map<String, String>.from(uri.queryParameters)..remove('_ts');
    final keys = query.keys.toList()..sort();
    return uri
        .replace(
          queryParameters: <String, String>{
            for (final key in keys) key: query[key] ?? '',
          },
        )
        .toString();
  }

  static bool _isEmptyPageSlide(Map node) {
    if (node['type']?.toString() != 'column') return false;
    final props = node['properties'];
    if (props is! Map) return false;
    final pageNo = props['pageNo']?.toString().trim() ?? '';
    if (pageNo.isEmpty) return false;
    final children = node['children'];
    return children is List && children.isEmpty;
  }

  static List<dynamic>? _pageSlideChildren(
    Map<String, dynamic> schema, {
    required String? pageNo,
    required String? pageId,
  }) {
    List<dynamic>? found;
    void walk(dynamic node) {
      if (found != null || node == null) return;
      if (node is Map) {
        if (node['type']?.toString() == 'column') {
          final props = node['properties'];
          final no = props is Map ? props['pageNo']?.toString() : null;
          final id = props is Map ? props['pageId']?.toString() : null;
          final matchesNo =
              pageNo != null && pageNo.isNotEmpty && no == pageNo;
          final matchesId =
              pageId != null && pageId.isNotEmpty && id == pageId;
          final children = node['children'];
          if ((matchesNo || matchesId) && children is List) {
            found = children;
            return;
          }
        }
        for (final value in node.values) {
          walk(value);
        }
      } else if (node is List) {
        for (final item in node) {
          walk(item);
        }
      }
    }

    walk(schema['ui']);
    return found;
  }

  static List<String> _pageSlideChildIds(Map<String, dynamic> schema) {
    final ids = <String>[];
    void walk(dynamic node) {
      if (node is Map) {
        if (node['type']?.toString() == 'column') {
          final props = node['properties'];
          final pageNo = props is Map ? props['pageNo']?.toString() ?? '' : '';
          final children = node['children'];
          if (pageNo.isNotEmpty && children is List) {
            ids.add(
              '$pageNo:${[
                for (final child in children)
                  if (child is Map) child['id']?.toString() ?? '',
              ].join(',')}',
            );
          }
        }
        for (final value in node.values) {
          walk(value);
        }
      } else if (node is List) {
        for (final item in node) {
          walk(item);
        }
      }
    }

    walk(schema['ui']);
    return ids;
  }

  static List<String> _controlIdsForPage(
    Map<String, dynamic> schema, {
    required String? pageNo,
    required String? pageId,
  }) {
    List<String> from(dynamic pages) {
      if (pages is! List) return const <String>[];
      for (final raw in pages) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString();
        final no = raw['pageNo']?.toString();
        final matchesId =
            pageId != null && pageId.isNotEmpty && id == pageId;
        final matchesNo =
            pageNo != null && pageNo.isNotEmpty && no == pageNo;
        if (!matchesId && !matchesNo) continue;
        final ids = raw['controlIds'];
        if (ids is! List) return const <String>[];
        return [
          for (final value in ids)
            if (value.toString().trim().isNotEmpty) value.toString().trim(),
        ];
      }
      return const <String>[];
    }

    final fromPages = from(schema['pages']);
    if (fromPages.isNotEmpty) return fromPages;
    return from(schema['navigation'] is Map
        ? (schema['navigation'] as Map)['pages']
        : null);
  }

  void _attachPublishedPaging(
    dynamic decoded,
    Map<String, dynamic> schema,
  ) {
    final published = _findPublishedPaging(decoded);
    final paging = preferPublishedPaging(schema['paging'], published);
    if (paging != null) schema['paging'] = paging;
  }

  Map<String, dynamic>? _findPublishedPaging(dynamic decoded) {
    Map<String, dynamic>? read(dynamic node, int depth) {
      if (node is! Map || depth > 4) return null;
      final paging = node['paging'];
      if (paging is Map &&
          (paging['pages'] is List ||
              paging.containsKey('nextPageApi') ||
              paging.containsKey('prevPageApi') ||
              paging.containsKey('pageApiTemplate'))) {
        return Map<String, dynamic>.from(paging);
      }
      for (final key in const ['data', 'result', 'payload', 'response']) {
        final found = read(node[key], depth + 1);
        if (found != null) return found;
      }
      return null;
    }

    return read(decoded, 0);
  }

  Uri _buildSchemaUri({
    required String modelId,
    required String nodeId,
    required bool addRefreshQuery,
    int? pageNo,
  }) {
    final endpoint = _schemaUrlTemplate
        .replaceAll('{modelId}', Uri.encodeComponent(modelId))
        .replaceAll('{nodeId}', Uri.encodeComponent(nodeId))
        .trim();

    final parsed = Uri.parse(endpoint);

    if (!parsed.hasScheme || parsed.host.isEmpty) {
      throw FormatException(
        'Invalid schema API URL template: '
        '$_schemaUrlTemplate',
      );
    }

    final query = <String, String>{...parsed.queryParameters};

    // Support a custom SCHEMA_URL_TEMPLATE that does not contain placeholders.
    // The values still come dynamically from load(modelId:, nodeId:).
    if (!_schemaUrlTemplate.contains('{modelId}')) {
      query['model_no'] = modelId;
    }

    if (!_schemaUrlTemplate.contains('{nodeId}')) {
      query['node_id'] = nodeId;
    }

    if (pageNo != null && pageNo > 0) {
      query['page_no'] = pageNo.toString();
    }

    if (addRefreshQuery) {
      query['_ts'] = DateTime.now().microsecondsSinceEpoch.toString();
    }

    return parsed.replace(queryParameters: query.isEmpty ? null : query);
  }

  Uri _resolveScanUri(Map<String, dynamic> schema) {
    final apiContracts = schema['apiContracts'];
    final dataSources = schema['dataSources'];
    final meta = schema['meta'];

    final candidates = <dynamic>[
      _nestedMapValue(apiContracts, 'scan', 'url'),
      _nestedMapValue(apiContracts, 'scanResult', 'url'),
      _nestedMapValue(dataSources, 'scan', 'url'),
      _nestedMapValue(dataSources, 'scanResult', 'url'),
      _nestedMapValue(meta, 'links', 'scan'),
    ];

    for (final candidate in candidates) {
      final raw = candidate?.toString().trim() ?? '';
      if (raw.isEmpty) continue;

      final uri = Uri.tryParse(raw);
      if (uri != null &&
          uri.host.isNotEmpty &&
          (uri.scheme == 'https' || uri.scheme == 'http')) {
        return uri;
      }
    }

    return _buildScanUri();
  }

  dynamic _nestedMapValue(dynamic root, String firstKey, String secondKey) {
    if (root is! Map) return null;

    final nested = root[firstKey];
    if (nested is! Map) return null;

    return nested[secondKey];
  }

  Uri _buildScanUri() {
    final endpoint = _scanUrlTemplate.trim();
    final uri = Uri.parse(endpoint);

    if (!uri.hasScheme || uri.host.isEmpty) {
      throw FormatException('Invalid scan API URL: $_scanUrlTemplate');
    }

    // The scanner endpoint must remain exactly api_scan.php. MODEL_ID and
    // NODE_ID belong in the JSON request body handled by ScanRepository,
    // not in this URL.
    return uri;
  }

  /// Prunes large redundant structures inside controls (such as large
  /// `protocolMeta.ui_components` arrays duplicated in each control on multi-page
  /// devices).
  ///
  /// The SDUI renderer only inspects `raw['ui_type']` from `ui_components`
  /// (in `ParameterCard`), so condensing this array preserves complete
  /// functionality while shedding duplicate payload across all device pages.
  static void pruneHeavyProtocolMeta(Map<String, dynamic> schema) {
    final controls = schema['controls'];
    if (controls is! List) return;

    for (final control in controls) {
      if (control is! Map) continue;
      final protocolMeta = control['protocolMeta'];
      if (protocolMeta is! Map) continue;

      final uiComponents = protocolMeta['ui_components'];
      if (uiComponents is List && uiComponents.isNotEmpty) {
        final pruned = <Map<String, dynamic>>[];
        for (final item in uiComponents) {
          if (item is Map && item['ui_type'] != null) {
            pruned.add(<String, dynamic>{
              'ui_type': item['ui_type'].toString(),
            });
          }
        }
        protocolMeta['ui_components'] = pruned;
      }
    }
  }

  Map<String, dynamic> _extractSchema(dynamic decoded) {
    final apiError = _readApiError(decoded);

    if (apiError != null) {
      throw FormatException(apiError);
    }

    final schema = _findDeviceUiSchema(decoded, depth: 0);

    if (schema != null) {
      pruneHeavyProtocolMeta(schema);
      _attachPublishedPaging(decoded, schema);
      ensurePlaceholderSlides(schema);
      logDebug(
        '[SchemaRepository] DEVICE_UI_SCHEMA_EXTRACTED '
        'schemaVersion=${schema['schemaVersion']}',
      );

      return schema;
    }

    final rootDescription = decoded is Map
        ? 'Root keys: ${decoded.keys.join(', ')}'
        : 'Root type: ${decoded.runtimeType}';

    throw FormatException(
      'The server response does not contain a device-ui schema. '
      'The v8 API is expected to return it at '
      'data.schema_json. $rootDescription',
    );
  }

  /// Recursively locates a schema whose schemaType is `device-ui`.
  ///
  /// The current v8 endpoint returns:
  /// {
  ///   "status": true,
  ///   "data": {
  ///     "schema_json": { ...device-ui schema... }
  ///   }
  /// }
  ///
  /// Older endpoints may return the schema directly or under data/schema/result,
  /// so those formats remain supported.
  Map<String, dynamic>? _findDeviceUiSchema(
    dynamic value, {
    required int depth,
  }) {
    if (value == null || depth > 10) {
      return null;
    }

    if (value is String) {
      final raw = value.trim();

      if (raw.isEmpty || (!raw.startsWith('{') && !raw.startsWith('['))) {
        return null;
      }

      try {
        return _findDeviceUiSchema(jsonDecode(raw), depth: depth + 1);
      } on FormatException {
        return null;
      }
    }

    if (value is List) {
      for (final item in value) {
        final found = _findDeviceUiSchema(item, depth: depth + 1);

        if (found != null) {
          return found;
        }
      }

      return null;
    }

    if (value is! Map) {
      return null;
    }

    final map = Map<String, dynamic>.from(value);

    if (map['schemaType']?.toString() == 'device-ui') {
      return map;
    }

    // Check known API wrapper keys first. `schema_json` is the required
    // wrapper used by https://efactor.tech/v8/api_schema.php.
    for (final key in const <String>[
      'schema_json',
      'schemaJson',
      'schema',
      'data',
      'result',
      'payload',
      'response',
    ]) {
      if (!map.containsKey(key)) {
        continue;
      }

      final found = _findDeviceUiSchema(map[key], depth: depth + 1);

      if (found != null) {
        return found;
      }
    }

    // Fallback for any future wrapper name without hardcoding its key.
    for (final entry in map.entries) {
      if (const <String>{
        'schema_json',
        'schemaJson',
        'schema',
        'data',
        'result',
        'payload',
        'response',
      }.contains(entry.key)) {
        continue;
      }

      final candidate = entry.value;

      if (candidate is! Map && candidate is! List && candidate is! String) {
        continue;
      }

      final found = _findDeviceUiSchema(candidate, depth: depth + 1);

      if (found != null) {
        return found;
      }
    }

    return null;
  }

  String? _readApiError(dynamic decoded) {
    if (decoded is! Map) {
      return null;
    }

    final response = Map<String, dynamic>.from(decoded);

    final status = response['status'];
    final success = response['success'];

    final failed =
        status == false ||
        status == 0 ||
        status?.toString().toLowerCase() == 'false' ||
        success == false ||
        success == 0 ||
        success?.toString().toLowerCase() == 'false';

    if (!failed) {
      return null;
    }

    final message =
        response['message'] ??
        response['error'] ??
        response['detail'] ??
        'The schema API reported a failure.';

    return 'Schema API error: ${message.toString().trim()}';
  }

  String? _readOriginalModelId(Map<String, dynamic> schema) {
    final candidates = <dynamic>[
      schema['meta']?['app']?['modelId'],
      schema['meta']?['app']?['model_id'],
      schema['meta']?['app']?['modelNo'],
      schema['deviceConfig']?['info']?['model'],
      schema['state']?['device']?['model_id'],
    ];

    return _firstText(candidates);
  }

  String? _readOriginalNodeId(Map<String, dynamic> schema) {
    final rootNode = schema['node_id'];

    final candidates = <dynamic>[
      schema['meta']?['app']?['nodeId'],
      rootNode is Map ? rootNode['id'] : rootNode,
      schema['state']?['node_id'],
      schema['state']?['device']?['node_id'],
      schema['deviceConfig']?['node_id'],
      schema['deviceState']?['node_id'],
      schema['nodes'],
    ];

    return _firstText(candidates);
  }

  String? _firstText(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) {
        return text;
      }
    }
    return null;
  }

  void _applyConnectionContext(
    Map<String, dynamic> schema, {
    required String modelId,
    required String nodeId,
    required Uri schemaUri,
    required Uri scanUri,
    required String? originalModelId,
    required String? originalNodeId,
  }) {
    schema['_clientConnection'] = <String, dynamic>{
      'modelId': modelId,
      'nodeId': nodeId,
      'deviceId': nodeId,
      'schemaUrl': schemaUri.toString(),
      'scanUrl': scanUri.toString(),
      'username': schema['state']?['user']?['username']?.toString() ?? '',
    };

    _normalizeIdentityFields(
      schema,
      modelId: modelId,
      nodeId: nodeId,
      originalModelId: originalModelId,
      originalNodeId: originalNodeId,
      path: const <String>[],
    );

    final meta = _ensureMap(schema, 'meta');
    final app = _ensureMap(meta, 'app');

    app
      ..['modelNo'] = modelId
      ..['modelId'] = modelId
      ..['model_id'] = modelId
      ..['nodeId'] = nodeId
      ..['deviceId'] = nodeId;

    final links = _ensureMap(meta, 'links');
    links
      ..['schema'] = schemaUri.toString()
      ..['scan'] = scanUri.toString();

    final rootNode = schema['node_id'];

    if (rootNode is Map) {
      rootNode
        ..['id'] = nodeId
        ..['value'] = nodeId
        ..['modelNo'] = modelId
        ..['model_id'] = modelId
        ..['source'] = 'url';
    } else {
      schema['node_id'] = <String, dynamic>{
        'id': nodeId,
        'value': nodeId,
        'modelNo': modelId,
        'model_id': modelId,
        'source': 'url',
        'binding': 'node_id.id',
      };
    }

    schema['nodes'] = nodeId;

    final state = _ensureMap(schema, 'state');
    state['node_id'] = nodeId;

    final scanResult = _ensureMap(state, 'scanResult');
    scanResult
      ..putIfAbsent('value', () => null)
      ..putIfAbsent('format', () => null)
      ..putIfAbsent('scannedAt', () => null)
      ..['modelId'] = modelId
      ..['nodeId'] = nodeId
      ..['apiUrl'] = scanUri.toString();

    final device = _ensureMap(state, 'device');
    device
      ..['node_id'] = nodeId
      ..['device_id'] = nodeId
      ..['model_id'] = modelId
      ..['modelId'] = modelId;

    _normalizeDeviceConfig(
      schema['deviceConfig'],
      modelId: modelId,
      nodeId: nodeId,
    );

    _normalizeDeviceConfig(device['config'], modelId: modelId, nodeId: nodeId);

    _normalizeDeviceConfig(
      schema['deviceState']?['config'],
      modelId: modelId,
      nodeId: nodeId,
    );

    final deviceState = schema['deviceState'];

    if (deviceState is Map) {
      deviceState
        ..['node_id'] = nodeId
        ..['device_id'] = nodeId
        ..['model_id'] = modelId
        ..['modelId'] = modelId;
    }

    final nodeDetails = schema['node_details'];

    if (nodeDetails is List) {
      for (var index = 0; index < nodeDetails.length; index++) {
        final item = nodeDetails[index];

        if (item is! Map) continue;

        final shouldNormalize =
            nodeDetails.length == 1 ||
            item['id']?.toString() == originalNodeId ||
            item['id']?.toString() == nodeId ||
            item['config']?['node_id']?.toString() == originalNodeId;

        if (!shouldNormalize) continue;

        item['id'] = nodeId;

        _normalizeDeviceConfig(
          item['config'],
          modelId: modelId,
          nodeId: nodeId,
        );
      }
    }

    final apiContracts = _ensureMap(schema, 'apiContracts');

    final schemaContract = _ensureMap(apiContracts, 'schema');
    schemaContract
      ..['id'] = 'schema'
      ..['type'] = 'rest'
      ..['method'] = 'GET'
      ..['url'] = schemaUri.toString();

    final scanContract = _ensureMap(apiContracts, 'scan');
    scanContract
      ..['id'] = 'scan'
      ..['type'] = 'rest'
      ..['method'] = 'POST'
      ..['url'] = scanUri.toString()
      ..['contentType'] = 'application/json'
      ..['requestFields'] = <String>[
        'model_no',
        'username',
        'device_id',
        'qr_value',
        'temperature',
        'fan_speed',
      ];
  }

  void _normalizeIdentityFields(
    dynamic node, {
    required String modelId,
    required String nodeId,
    required String? originalModelId,
    required String? originalNodeId,
    required List<String> path,
  }) {
    if (node is List) {
      for (var index = 0; index < node.length; index++) {
        _normalizeIdentityFields(
          node[index],
          modelId: modelId,
          nodeId: nodeId,
          originalModelId: originalModelId,
          originalNodeId: originalNodeId,
          path: <String>[...path, index.toString()],
        );
      }
      return;
    }

    if (node is! Map) return;

    final entries = node.entries.toList();

    for (final entry in entries) {
      final rawKey = entry.key;
      final key = rawKey.toString().toLowerCase();
      final value = entry.value;
      final nextPath = <String>[...path, key];

      switch (key) {
        case 'modelid':
        case 'model_id':
        case 'modelno':
          node[rawKey] = modelId;
          continue;
        case 'nodeid':
        case 'deviceid':
        case 'device_id':
          node[rawKey] = nodeId;
          continue;
        case 'node_id':
          if (value is Map) {
            value
              ..['id'] = nodeId
              ..['value'] = nodeId
              ..['modelNo'] = modelId
              ..['model_id'] = modelId;
          } else {
            node[rawKey] = nodeId;
          }
          continue;
        case 'nodes':
          if (value is String) {
            node[rawKey] = nodeId;
            continue;
          }
      }

      if (value is String && _isConnectionStringPath(nextPath)) {
        node[rawKey] = _rewriteConnectionString(
          value,
          modelId: modelId,
          nodeId: nodeId,
          originalModelId: originalModelId,
          originalNodeId: originalNodeId,
        );
        continue;
      }

      _normalizeIdentityFields(
        value,
        modelId: modelId,
        nodeId: nodeId,
        originalModelId: originalModelId,
        originalNodeId: originalNodeId,
        path: nextPath,
      );
    }

    final attributeName = node['name']?.toString().trim().toLowerCase();

    if (attributeName == 'device id' ||
        attributeName == 'device_id' ||
        attributeName == 'node id' ||
        attributeName == 'node_id') {
      node['value'] = nodeId;
    } else if (attributeName == 'model' ||
        attributeName == 'model id' ||
        attributeName == 'model_id') {
      node['value'] = modelId;
    }
  }

  bool _isConnectionStringPath(List<String> path) {
    if (path.isEmpty) return false;

    const directKeys = <String>{
      'url',
      'route',
      'deeplink',
      'schemaid',
      'clientidpattern',
      'topic',
      'command',
      'telemetry',
      'presence',
    };

    const connectionContainers = <String>{
      'links',
      'apicontracts',
      'datasources',
      'mqtt',
      'websocket',
      'subscriptions',
      'deeplinks',
      'graph',
      'transport',
    };

    if (directKeys.contains(path.last)) {
      return true;
    }

    return path.any(connectionContainers.contains);
  }

  String _rewriteConnectionString(
    String input, {
    required String modelId,
    required String nodeId,
    required String? originalModelId,
    required String? originalNodeId,
  }) {
    var output = input
        .replaceAll('{modelId}', Uri.encodeComponent(modelId))
        .replaceAll('{nodeId}', Uri.encodeComponent(nodeId));

    output = _replaceIdentity(
      output,
      oldValue: originalModelId,
      newValue: modelId,
    );

    output = _replaceIdentity(
      output,
      oldValue: originalNodeId,
      newValue: nodeId,
    );

    return output;
  }

  String _replaceIdentity(
    String input, {
    required String? oldValue,
    required String newValue,
  }) {
    final oldText = oldValue?.trim();

    if (oldText == null || oldText.isEmpty || oldText == newValue) {
      return input;
    }

    return input
        .replaceAll(Uri.encodeComponent(oldText), Uri.encodeComponent(newValue))
        .replaceAll(oldText, newValue);
  }

  void _normalizeDeviceConfig(
    dynamic candidate, {
    required String modelId,
    required String nodeId,
  }) {
    if (candidate is! Map) return;

    candidate
      ..['node_id'] = nodeId
      ..['model_id'] = modelId;

    if (candidate.containsKey('primary')) {
      candidate['primary'] = nodeId;
    }

    final info = candidate['info'];

    if (info is Map) {
      info
        ..['model'] = modelId
        ..['name'] = modelId;
    }

    final devices = candidate['devices'];

    if (devices is List) {
      for (final device in devices) {
        if (device is! Map) continue;

        device
          ..['name'] = modelId
          ..['Device Id'] = nodeId
          ..['device_id'] = nodeId;

        if (device.containsKey('primary')) {
          device['primary'] = nodeId;
        }

        final attributes = device['attributes'];

        if (attributes is List) {
          for (final attribute in attributes) {
            if (attribute is! Map) continue;

            final name = attribute['name']?.toString().trim().toLowerCase();

            if (name == 'device id' || name == 'node id') {
              attribute['value'] = nodeId;
            } else if (name == 'model' || name == 'model id') {
              attribute['value'] = modelId;
            }
          }
        }
      }
    }
  }

  Map<String, dynamic> _ensureMap(Map<dynamic, dynamic> parent, String key) {
    final current = parent[key];

    if (current is Map<String, dynamic>) {
      return current;
    }

    if (current is Map) {
      final converted = Map<String, dynamic>.from(current);
      parent[key] = converted;
      return converted;
    }

    final created = <String, dynamic>{};
    parent[key] = created;
    return created;
  }

  void _validateSchema(Map<String, dynamic> schema) {
    if (schema['schemaType'] != 'device-ui') {
      throw FormatException(
        'schemaType must be "device-ui". '
        'Received: ${schema['schemaType']}',
      );
    }

    if (schema['schemaVersion'] is! String) {
      throw const FormatException('schemaVersion is missing.');
    }

    if (schema['controls'] is! List) {
      throw const FormatException('controls must be an array.');
    }

    if (schema['pages'] is! List) {
      throw const FormatException('pages must be an array.');
    }

    if (schema['state'] is! Map) {
      throw const FormatException('state must be an object.');
    }

    final state = schema['state'] as Map;

    if (state['device'] is! Map) {
      throw const FormatException('state.device must be an object.');
    }

    final device = state['device'] as Map;

    if (device['parameters'] is! Map) {
      throw const FormatException('state.device.parameters must be an object.');
    }

    schema.putIfAbsent('actions', () => <String, dynamic>{});

    schema.putIfAbsent('settings', () => <String, dynamic>{});
  }

  String _safeResponseMessage(String body) {
    final compact = body.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (compact.isEmpty) {
      return 'The server returned an empty response.';
    }

    return compact.length <= 300 ? compact : '${compact.substring(0, 300)}...';
  }

  String _required(String value, String fieldName) {
    final normalized = value.trim();

    if (normalized.isEmpty) {
      throw FormatException('$fieldName is required.');
    }

    return normalized;
  }

  Map<String, dynamic>? _memoryHit(String cacheKey) {
    final cached = _memoryCache[cacheKey];
    if (cached == null) return null;
    final age = DateTime.now().difference(cached.savedAt);
    if (age > _cacheMaxAge) return null;
    cached.schema['_clientSchemaCacheHit'] = true;
    cached.schema['_clientSchemaCachedAtMs'] =
        cached.savedAt.millisecondsSinceEpoch;
    logDebug(
      '[SchemaRepository] MEMORY HIT age=${age.inSeconds}s',
    );
    return cached.schema;
  }

  void _rememberParsed(
    String cacheKey,
    Map<String, dynamic> schema,
    DateTime savedAt,
  ) {
    _memoryCache[cacheKey] = _ParsedSchemaCache(schema, savedAt);
    // Expand capacity to 30 to keep all pages of multi-page devices in memory,
    // avoiding cache thrashing and disk re-reads during active tab navigation.
    if (_memoryCache.length > 30) {
      final oldest = _memoryCache.entries.reduce(
        (left, right) =>
            left.value.savedAt.isBefore(right.value.savedAt) ? left : right,
      );
      _memoryCache.remove(oldest.key);
    }
  }

  bool _isNegativeCacheable(Object error) {
    if (isTransientNetworkFailure(error)) return false;
    final text = error.toString().toLowerCase();
    return text.contains('schema api error') ||
        text.contains('schema not found') ||
        text.contains('does not contain a device-ui schema');
  }

  Future<bool> _isOffline() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result.isEmpty ||
          result.every((item) => item == ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _client.close();
  }
}

class KnownDeviceSchema {
  const KnownDeviceSchema({required this.modelId, required this.nodeId});

  final String modelId;
  final String nodeId;
}

class _ParsedSchemaCache {
  const _ParsedSchemaCache(this.schema, this.savedAt);

  final Map<String, dynamic> schema;
  final DateTime savedAt;
}

class _NegativeSchemaCache {
  const _NegativeSchemaCache({required this.until, required this.error});

  final DateTime until;
  final Object error;
}
