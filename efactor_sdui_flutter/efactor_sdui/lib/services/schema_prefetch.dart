import 'dart:async';

import '../auth_sdui/auth_schema_repository.dart';
import '../data/schema_repository.dart';
import '../grid_sdui/grid_schema_repository.dart';
import '../home_sdui/home_schema_repository.dart';
import '../iot_sdui/iot_schema_repository.dart';
import '../sdui/sdui_network_image_cache.dart';
import 'json_http.dart';

/// Loads schemas on demand and warms a small set after login for offline use.
///
/// Device schemas stay on-demand (opening every device at login exhausted
/// memory). Home, Grid, and IoT list schemas are queued in the background
/// after login so airplane mode still paints those shells.
class SchemaLoadQueue {
  SchemaLoadQueue._();

  static final SchemaLoadQueue instance = SchemaLoadQueue._();

  final List<_PrefetchTask> _queue = <_PrefetchTask>[];
  final Set<String> _done = <String>{};
  final Map<String, Future<Map<String, dynamic>>> _joined =
      <String, Future<Map<String, dynamic>>>{};

  String _token = '';
  int? _userId;
  bool _pumping = false;
  String? _runningKey;

  /// Remembers the session and background-prefetches Home, Grid, and IoT.
  Future<void> startAfterLogin({
    required String accessToken,
    int? userId,
  }) {
    final token = accessToken.trim();
    if (token.isEmpty) return Future<void>.value();
    _token = token;
    _userId = userId;
    // Front-queue in reverse so Home runs first, then Grid, then IoT.
    _enqueueFront(_PrefetchTask('iot', _runIot));
    _enqueueFront(_PrefetchTask('grid:${userId ?? 0}', _runGrid));
    _enqueueFront(_PrefetchTask('home:${userId ?? 0}', _runHome));
    unawaited(_kick());
    return Future<void>.value();
  }

  /// Clears in-flight tasks, cached keys, and session token on logout.
  void reset() {
    _queue.clear();
    _done.clear();
    _joined.clear();
    _token = '';
    _userId = null;
    _pumping = false;
    _runningKey = null;
  }

  /// The user opened IoT. Save that IoT screen schema only.
  /// Device schemas stay unloaded until the user taps a device.
  void prioritizeIot({required String accessToken}) {
    final token = accessToken.trim();
    if (token.isEmpty) return;
    _token = token;
    unawaited(loadIot(accessToken: token));
  }

  /// The user opened Grid. It is not in the login sequence; a tap saves it
  /// ahead of whatever background schema is still waiting.
  void prioritizeGrid({required String accessToken, int? userId}) {
    final token = accessToken.trim();
    if (token.isEmpty) return;
    _token = token;
    if (userId != null && userId > 0) _userId = userId;
    final key = 'grid:${_userId ?? 0}';
    unawaited(loadGrid(accessToken: token, userId: _userId));
    _enqueueFront(_PrefetchTask(key, _runGrid));
    unawaited(_kick());
  }

  /// The user opened one device. Save that device schema ahead of the others.
  void prioritizeDevice({required String modelId, required String nodeId}) {
    final model = modelId.trim();
    final node = nodeId.trim();
    if (model.isEmpty || node.isEmpty) return;
    final key = 'device:$model:$node';
    unawaited(loadDevice(modelId: model, nodeId: node));
    _enqueueFront(
      _PrefetchTask(key, () => loadDevice(modelId: model, nodeId: node)),
    );
    unawaited(_kick());
  }

  /// Device schemas are not queued from a list. Opening IoT used to download
  /// every device document and the process was killed for lack of memory.
  void enqueueDevices(Iterable<Object> identities) {
    logDebug(
      '[SchemaPrefetch] skipped ${identities.length} device schema(s); '
      'a device schema loads when that device is opened',
    );
  }

  Future<Map<String, dynamic>> loadAuth({bool forceRefresh = false}) {
    if (forceRefresh) return _fetchAuth(forceRefresh: true);
    return _join('auth', () => _fetchAuth(forceRefresh: false));
  }

  Future<Map<String, dynamic>> loadHome({
    required String accessToken,
    required int? userId,
    bool forceRefresh = false,
  }) {
    final key = 'home:${userId ?? 0}';
    if (forceRefresh) {
      return _fetchHome(
        accessToken: accessToken,
        userId: userId,
        forceRefresh: true,
      );
    }
    return _join(
      key,
      () => _fetchHome(
        accessToken: accessToken,
        userId: userId,
        forceRefresh: false,
      ),
    );
  }

  Future<Map<String, dynamic>> loadIot({
    required String accessToken,
    bool forceRefresh = false,
  }) {
    if (forceRefresh) {
      return _fetchIot(accessToken: accessToken, forceRefresh: true);
    }
    return _join(
      'iot',
      () => _fetchIot(accessToken: accessToken, forceRefresh: false),
    );
  }

  Future<Map<String, dynamic>> loadGrid({
    required String accessToken,
    int? userId,
    bool forceRefresh = false,
  }) {
    final key = 'grid:${userId ?? 0}';
    if (forceRefresh) {
      return _fetchGrid(
        accessToken: accessToken,
        userId: userId,
        forceRefresh: true,
      );
    }
    return _join(
      key,
      () => _fetchGrid(
        accessToken: accessToken,
        userId: userId,
        forceRefresh: false,
      ),
    );
  }

  Future<Map<String, dynamic>> loadDevice({
    required String modelId,
    required String nodeId,
    bool forceRefresh = false,
  }) {
    final key = 'device:${modelId.trim()}:${nodeId.trim()}';
    if (forceRefresh) {
      return _fetchDevice(
        modelId: modelId,
        nodeId: nodeId,
        forceRefresh: true,
      );
    }
    return _join(
      key,
      () => _fetchDevice(
        modelId: modelId,
        nodeId: nodeId,
        forceRefresh: false,
      ),
    );
  }

  Future<Map<String, dynamic>> _join(
    String key,
    Future<Map<String, dynamic>> Function() start,
  ) {
    final existing = _joined[key];
    if (existing != null) return existing;
    final future = start();
    _joined[key] = future;
    future.whenComplete(() {
      if (identical(_joined[key], future)) _joined.remove(key);
    });
    return future;
  }

  void _enqueueFront(_PrefetchTask task) {
    if (_done.contains(task.key) || _runningKey == task.key) return;
    _queue.removeWhere((item) => item.key == task.key);
    _queue.insert(0, task);
  }

  Future<void> _kick() {
    if (_pumping) return Future<void>.value();
    return _run();
  }

  Future<void> _run() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final task = _queue.removeAt(0);
        if (_done.contains(task.key)) continue;
        _runningKey = task.key;
        try {
          await task.run();
          _done.add(task.key);
          logDebug('[SchemaPrefetch] SAVED ${task.key}');
        } catch (error) {
          logDebug('[SchemaPrefetch] SKIP ${task.key}: $error');
        } finally {
          _runningKey = null;
        }
      }
    } finally {
      _pumping = false;
      if (_queue.isNotEmpty) unawaited(_run());
    }
  }

  Future<void> _runHome() async {
    if (_token.isEmpty) return;
    final schema = await loadHome(accessToken: _token, userId: _userId);
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }

  Future<void> _runIot() async {
    if (_token.isEmpty) return;
    final schema = await loadIot(accessToken: _token);
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }

  Future<void> _runGrid() async {
    if (_token.isEmpty) return;
    final schema = await loadGrid(accessToken: _token, userId: _userId);
    unawaited(SduiNetworkImageCache.prefetchSchemaImages(schema));
  }
}

class _PrefetchTask {
  const _PrefetchTask(this.key, this.run);

  final String key;
  final Future<void> Function() run;
}

Future<Map<String, dynamic>> _fetchAuth({required bool forceRefresh}) async {
  final repo = AuthSchemaRepository();
  try {
    return await repo.load(forceRefresh: forceRefresh);
  } finally {
    repo.dispose();
  }
}

Future<Map<String, dynamic>> _fetchHome({
  required String accessToken,
  required int? userId,
  required bool forceRefresh,
}) async {
  final repo = HomeSchemaRepository();
  try {
    return await repo.load(
      forceRefresh: forceRefresh,
      accessToken: accessToken,
      userId: userId,
    );
  } finally {
    repo.dispose();
  }
}

Future<Map<String, dynamic>> _fetchIot({
  required String accessToken,
  required bool forceRefresh,
}) async {
  final repo = IotSchemaRepository(
    source: IotSchemaSource.fromEnvironment(),
    accessToken: accessToken,
  );
  try {
    return await repo.load(forceRefresh: forceRefresh);
  } finally {
    repo.dispose();
  }
}

Future<Map<String, dynamic>> _fetchGrid({
  required String accessToken,
  required int? userId,
  required bool forceRefresh,
}) async {
  final repo = GridSchemaRepository(
    accessToken: accessToken,
    userId: userId,
  );
  try {
    return await repo.load(forceRefresh: forceRefresh);
  } finally {
    repo.dispose();
  }
}

Future<Map<String, dynamic>> _fetchDevice({
  required String modelId,
  required String nodeId,
  required bool forceRefresh,
}) async {
  final repo = SchemaRepository();
  try {
    return await repo.load(
      modelId: modelId,
      nodeId: nodeId,
      forceRefresh: forceRefresh,
    );
  } finally {
    repo.dispose();
  }
}

/// Stores the session and warms Home / Grid / IoT schemas in the background.
Future<void> prefetchAuthenticatedSchemas({
  required String accessToken,
  int? userId,
}) {
  return SchemaLoadQueue.instance.startAfterLogin(
    accessToken: accessToken,
    userId: userId,
  );
}

/// Kept so older call sites compile. It does not download device schemas.
Future<void> prefetchDeviceSchemas(Iterable<Object> identities) async {}
