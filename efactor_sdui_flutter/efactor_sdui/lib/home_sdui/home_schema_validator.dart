typedef HomeSchemaSignatureVerifier =
    Future<bool> Function(Map<String, dynamic> schema);

class HomeSchemaValidator {
  const HomeSchemaValidator({this.signatureVerifier});

  final HomeSchemaSignatureVerifier? signatureVerifier;

  Future<void> validate(
    Map<String, dynamic> schema, {
    required bool productionSecurity,
    required int rawByteLength,
  }) async {
    if (schema['schemaType']?.toString() != 'server-driven-mobile-app') {
      throw FormatException(
        'Expected schemaType=server-driven-mobile-app; '
        'got ${schema['schemaType']}.',
      );
    }

    // Schema version is metadata. It is required, but it never selects a
    // different renderer implementation.
    if (schema['schemaVersion'] == null) {
      throw const FormatException('schemaVersion is required.');
    }

    final requirements = _map(schema['rendererRequirements']);
    if (requirements != null) {
      final engine = requirements['engine']?.toString();
      if (engine != null && engine.isNotEmpty && engine != 'efactor-sdui') {
        throw FormatException('Unsupported renderer engine "$engine".');
      }
    }

    final security = _map(schema['security']) ?? const <String, dynamic>{};
    final maximumSizeKb = (security['maximumSchemaSizeKb'] as num?)?.toInt();

    if (maximumSizeKb != null && rawByteLength > maximumSizeKb * 1024) {
      throw FormatException(
        'Schema is ${rawByteLength ~/ 1024} KiB but maximumSchemaSizeKb='
        '$maximumSizeKb.',
      );
    }

    final components = _requiredMap(schema, 'components');
    final pages = _requiredMap(schema, 'pages');
    final routes = _requiredMap(schema, 'routes');
    final actions = _requiredMap(schema, 'actionRegistry');

    if (components.isEmpty) {
      throw const FormatException('components{} must not be empty.');
    }
    if (pages.isEmpty) {
      throw const FormatException('pages{} must not be empty.');
    }
    if (routes.isEmpty) {
      throw const FormatException('routes{} must not be empty.');
    }

    final maximumComponents = (security['maximumComponents'] as num?)?.toInt();
    if (maximumComponents != null && components.length > maximumComponents) {
      throw FormatException(
        'components count ${components.length} exceeds maximumComponents='
        '$maximumComponents.',
      );
    }

    final allowedComponentTypes = (security['allowedComponentTypes'] as List?)
        ?.map((e) => e.toString())
        .toSet();

    if (allowedComponentTypes != null) {
      for (final entry in components.entries) {
        final component = _map(entry.value);
        if (component == null) {
          throw FormatException('components.${entry.key} must be an object.');
        }

        final type = _effectiveComponentType(schema, component);
        if (type == null || type.isEmpty) {
          throw FormatException(
            'components.${entry.key} has no type and its preset does not '
            'declare a type.',
          );
        }

        if (!allowedComponentTypes.contains(type)) {
          throw FormatException(
            'Component ${entry.key} uses disallowed type "$type".',
          );
        }
      }
    }

    final allowedActionTypes = (security['allowedActionTypes'] as List?)
        ?.map((e) => e.toString())
        .toSet();

    if (allowedActionTypes != null) {
      for (final entry in actions.entries) {
        _validateActionTree(
          entry.value,
          path: 'actionRegistry.${entry.key}',
          allowedTypes: allowedActionTypes,
        );
      }
    }

    _validateReferences(schema);

    if (!productionSecurity) return;

    if (security['rejectExpiredSchema'] == true) {
      final expiresAt = DateTime.tryParse(
        security['expiresAt']?.toString() ?? '',
      );
      if (expiresAt == null) {
        throw const FormatException(
          'security.expiresAt is required when rejectExpiredSchema=true.',
        );
      }
      if (DateTime.now().toUtc().isAfter(expiresAt.toUtc())) {
        throw StateError(
          'Home schema expired at ${expiresAt.toUtc().toIso8601String()}.',
        );
      }
    }

    if (security['requireSchemaSignature'] == true) {
      final signature = _map(schema['signature']);
      final value = signature?['value']?.toString().trim();

      if (value == null ||
          value.isEmpty ||
          value == '__ATTACHED_BY_SERVER_AT_PUBLISH_TIME__') {
        throw StateError('Production schema signature is missing.');
      }

      final verifier = signatureVerifier;
      if (verifier == null) {
        throw StateError(
          'Schema requests signature verification, but no '
          'HomeSchemaSignatureVerifier was configured.',
        );
      }

      if (!await verifier(schema)) {
        throw StateError('Home schema signature verification failed.');
      }
    }
  }

  void _validateActionTree(
    dynamic raw, {
    required String path,
    required Set<String> allowedTypes,
  }) {
    final action = _map(raw);
    if (action == null) {
      throw FormatException('$path must be an object.');
    }

    final type = action['type']?.toString();
    if (type == null || type.isEmpty) {
      throw FormatException('$path.type is required.');
    }

    if (!allowedTypes.contains(type)) {
      throw FormatException('$path uses disallowed action type "$type".');
    }

    if (type == 'sequence') {
      final children = action['actions'];
      if (children is! List) {
        throw FormatException('$path.actions[] is required.');
      }
      for (var i = 0; i < children.length; i++) {
        _validateActionTree(
          children[i],
          path: '$path.actions[$i]',
          allowedTypes: allowedTypes,
        );
      }
    }

    final onSuccess = action['onSuccess'];
    if (onSuccess is Map) {
      _validateActionTree(
        onSuccess,
        path: '$path.onSuccess',
        allowedTypes: allowedTypes,
      );
    }
  }

  void _validateReferences(Map<String, dynamic> schema) {
    final components = _requiredMap(schema, 'components');
    final pages = _requiredMap(schema, 'pages');
    final routes = _requiredMap(schema, 'routes');
    final actions = _requiredMap(schema, 'actionRegistry');

    void requireComponent(String? id, String source) {
      if (id == null || id.isEmpty) return;
      if (!components.containsKey(id)) {
        throw FormatException('$source references missing component "$id".');
      }
    }

    void requireAction(String? id, String source) {
      if (id == null || id.isEmpty) return;
      if (!actions.containsKey(id)) {
        throw FormatException('$source references missing action "$id".');
      }
    }

    for (final entry in pages.entries) {
      final page = _map(entry.value);
      if (page == null) {
        throw FormatException('pages.${entry.key} must be an object.');
      }
      requireComponent(
        page['rootComponentId']?.toString(),
        'pages.${entry.key}.rootComponentId',
      );
    }

    for (final entry in routes.entries) {
      final route = _map(entry.value);
      if (route == null) {
        throw FormatException('routes.${entry.key} must be an object.');
      }

      final path = route['path']?.toString().trim() ?? '';

      // External destinations are not Flutter page routes.
      //
      // Some backend-generated Home schemas retain an external URL in routes{}
      // for Studio/deep-link metadata while the actual tap is correctly
      // executed by an `external-navigate` action. An absolute HTTPS route
      // therefore must not be forced to reference pages{}.
      //
      // This is capability based; no host, route id, schema version or app
      // name is hardcoded.
      final externalUri = Uri.tryParse(path);
      final isAbsoluteExternalRoute =
          externalUri != null &&
          externalUri.hasScheme &&
          externalUri.host.isNotEmpty &&
          (externalUri.scheme.toLowerCase() == 'https' ||
              externalUri.scheme.toLowerCase() == 'http');

      if (isAbsoluteExternalRoute) {
        if (externalUri.scheme.toLowerCase() != 'https') {
          throw FormatException(
            'routes.${entry.key}.path must use HTTPS for an external route; '
            'got "$path".',
          );
        }
        continue;
      }

      final pageId = route['pageId']?.toString();
      if (pageId == null || pageId.isEmpty || !pages.containsKey(pageId)) {
        throw FormatException(
          'routes.${entry.key}.pageId references missing page "$pageId".',
        );
      }
    }

    for (final entry in components.entries) {
      final component = _map(entry.value);
      if (component == null) {
        throw FormatException('components.${entry.key} must be an object.');
      }

      final children = component['children'];
      if (children is List) {
        for (final child in children) {
          if (child is String) {
            requireComponent(child, 'components.${entry.key}.children');
          }
        }
      }

      for (final key in const <String>[
        'emptyStateComponentId',
        'bottomNavigationComponentId',
        'floatingActionComponentId',
      ]) {
        requireComponent(
          component[key]?.toString(),
          'components.${entry.key}.$key',
        );
      }

      for (final key in const <String>[
        'primaryActionId',
        'retryActionId',
        'submitActionId',
        'actionId',
      ]) {
        requireAction(
          component[key]?.toString(),
          'components.${entry.key}.$key',
        );
      }

      final events = _map(component['events']);
      if (events != null) {
        for (final event in events.entries) {
          final config = _map(event.value);
          requireAction(
            config?['actionId']?.toString(),
            'components.${entry.key}.events.${event.key}',
          );
        }
      }

      final faces = component['faces'];
      if (faces is List) {
        for (var i = 0; i < faces.length; i++) {
          final face = _map(faces[i]);
          final events = _map(face?['events']);
          if (events != null) {
            for (final event in events.entries) {
              final config = _map(event.value);
              requireAction(
                config?['actionId']?.toString(),
                'components.${entry.key}.faces[$i].events.${event.key}',
              );
            }
          }
        }
      }
    }

    final shell = _map(schema['appShell']);
    if (shell != null) {
      requireComponent(
        shell['bottomNavigationComponentId']?.toString(),
        'appShell.bottomNavigationComponentId',
      );
      requireComponent(
        shell['floatingActionComponentId']?.toString(),
        'appShell.floatingActionComponentId',
      );
    }

    final navigation = _map(schema['navigation']);
    final items = navigation?['items'];
    if (items is List) {
      for (var i = 0; i < items.length; i++) {
        final item = _map(items[i]);
        requireAction(
          item?['actionId']?.toString(),
          'navigation.items[$i].actionId',
        );
      }
    }
  }

  String? _effectiveComponentType(
    Map<String, dynamic> schema,
    Map<String, dynamic> component,
  ) {
    final direct = component['type']?.toString();
    if (direct != null && direct.isNotEmpty) return direct;

    final presetId = component['presetId']?.toString();
    final presets = _map(schema['componentPresets']);
    final preset = presetId == null ? null : _map(presets?[presetId]);
    return preset?['type']?.toString();
  }

  Map<String, dynamic> _requiredMap(Map<String, dynamic> schema, String key) {
    final value = _map(schema[key]);
    if (value == null) {
      throw FormatException('$key{} is required.');
    }
    return value;
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }
}
