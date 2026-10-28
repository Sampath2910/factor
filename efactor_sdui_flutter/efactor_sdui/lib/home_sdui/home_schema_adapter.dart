import 'dart:convert';

/// Converts supported server Home-schema shapes into the single internal
/// contract consumed by the Home SDUI state and renderer.
///
/// Important design rules:
/// - no user id, account, model, card id, route id, text, color or URL is
///   hardcoded here;
/// - already-canonical `server-driven-mobile-app` schemas pass through;
/// - flat/composer schemas are detected by capabilities, not by account;
/// - the raw server map is copied and never mutated by the adapter;
/// - unsupported/ambiguous schemas are returned unchanged so the normal
///   validator can reject them instead of silently inventing UI.
class HomeSchemaAdapter {
  const HomeSchemaAdapter();

  static const Set<String> _rendererComponentTypes = <String>{
    'scrollPage',
    'pageHeader',
    'homeHeader',
    'banner',
    'summaryBanner',
    'statusSummary',
    'responsiveGrid',
    'rotatingFaceCard',
    'rotatingDeviceCard',
    'bottomNavigation',
    'floatingActionButton',
    'list',
    'skeleton',
    'emptyState',
    'errorState',
    'faceSelector',
    'deviceControlPanel',
    'deviceDetailsHeader',
    'profileHeader',
    'profileMenu',
    'themeModeSelector',
    'actionButton',
    'loginForm',
    'staticHomeUi',
  };

  /// True when the input can be normalized without knowing a specific user,
  /// route name or schema-generator version.
  bool supports(Map<String, dynamic> schema) {
    if (_hasCanonicalShape(schema)) return true;

    final components = _map(schema['components']);
    if (components == null || components.isEmpty) return false;

    // Flat/composer schemas expose components plus either a singular page,
    // a pages map, app-level initial-page metadata, or navigation metadata.
    // This is intentionally capability based; `kind` is only diagnostic.
    return _map(schema['page']) != null ||
        _map(schema['pages']) != null ||
        _map(schema['app']) != null ||
        _map(schema['navigation']) != null;
  }

  Map<String, dynamic> normalize(Map<String, dynamic> rawSchema) {
    final source = _deepCopy(rawSchema);

    if (_hasCanonicalShape(source)) {
      source['_clientHomeSchemaAdapter'] = 'canonical-pass-through';
      return source;
    }

    if (!supports(source)) {
      return source;
    }

    // A schema that already has the canonical route/page/component shape but
    // only lacks the marker can be normalized without rewriting its content.
    if (_hasCanonicalStructure(source)) {
      source['schemaType'] = 'server-driven-mobile-app';
      source['_clientHomeSchemaAdapter'] = 'canonical-structure-marker';
      return source;
    }

    return _normalizeFlatComposerSchema(source);
  }

  bool _hasCanonicalShape(Map<String, dynamic> schema) {
    return schema['schemaType']?.toString().trim() ==
            'server-driven-mobile-app' &&
        _hasCanonicalStructure(schema);
  }

  bool _hasCanonicalStructure(Map<String, dynamic> schema) {
    return _map(schema['components']) != null &&
        _map(schema['pages']) != null &&
        _map(schema['routes']) != null &&
        _map(schema['actionRegistry']) != null;
  }

  Map<String, dynamic> _normalizeFlatComposerSchema(
    Map<String, dynamic> source,
  ) {
    final rawComponents = _map(source['components']) ?? <String, dynamic>{};
    final components = <String, dynamic>{};
    final componentAliases = <String, String>{};
    final actions = _copyMap(source['actionRegistry']);

    for (final entry in rawComponents.entries) {
      final raw = _map(entry.value);
      if (raw == null) continue;
      final id = _nonEmpty(raw['id']) ?? entry.key;
      componentAliases[entry.key] = id;
      componentAliases[id] = id;
      components[id] = _normalizeComponent(
        id,
        raw,
        components: components,
        actions: actions,
      );
    }

    final pages = <String, dynamic>{};
    final rawPages = _map(source['pages']);
    if (rawPages != null) {
      for (final entry in rawPages.entries) {
        final page = _map(entry.value);
        if (page == null) continue;
        _materializePage(
          _nonEmpty(page['id']) ?? entry.key,
          page,
          components: components,
          componentAliases: componentAliases,
          pages: pages,
        );
      }
    }

    final flatPage = _map(source['page']);
    if (flatPage != null) {
      final flatPageId =
          _nonEmpty(flatPage['id']) ??
          _nonEmpty(_map(source['app'])?['initialPageId']) ??
          _nonEmpty(_map(source['navigation'])?['activePage']) ??
          '__compat_page_1';
      _materializePage(
        flatPageId,
        flatPage,
        components: components,
        componentAliases: componentAliases,
        pages: pages,
      );
    }

    final routes = _copyMap(source['routes']);
    _repairRoutes(routes, pages);

    final sourceNavigation = _map(source['navigation']) ?? <String, dynamic>{};
    final sourceApp = _map(source['app']) ?? <String, dynamic>{};

    String? initialRouteId =
        _nonEmpty(sourceNavigation['initialRouteId']) ??
        _nonEmpty(sourceNavigation['activeRouteId']) ??
        _nonEmpty(sourceNavigation['activePage']) ??
        _nonEmpty(sourceApp['initialPageId']) ??
        (pages.isEmpty ? null : pages.keys.first);

    final navigationItems = _normalizeNavigationItems(
      source,
      sourceNavigation,
      components: components,
      componentAliases: componentAliases,
      pages: pages,
      routes: routes,
      actions: actions,
    );

    // Any composer component may declare a navigate action independently of
    // bottom navigation. Materialize those destinations generically so taps
    // never depend on a hardcoded route-name table.
    _materializeActionDestinations(
      source,
      actions,
      components: components,
      componentAliases: componentAliases,
      pages: pages,
      routes: routes,
    );

    if (initialRouteId != null && initialRouteId.isNotEmpty) {
      _ensureRouteAndPage(
        initialRouteId,
        label: initialRouteId,
        source: source,
        components: components,
        componentAliases: componentAliases,
        pages: pages,
        routes: routes,
      );
    }

    if (initialRouteId == null ||
        initialRouteId.isEmpty ||
        !routes.containsKey(initialRouteId)) {
      initialRouteId = routes.isEmpty ? null : routes.keys.first;
    }

    final canonicalNavigation = <String, dynamic>{
      ...sourceNavigation,
      if (initialRouteId != null) 'initialRouteId': initialRouteId,
      'items': navigationItems,
      if (!sourceNavigation.containsKey('maximumHistoryEntries'))
        'maximumHistoryEntries': _historyLimitFromSchema(source),
    };

    final appShell = _normalizeAppShell(
      source,
      components,
      componentAliases,
    );

    final output = <String, dynamic>{
      ...source,
      'schemaType': 'server-driven-mobile-app',
      'components': components,
      'pages': pages,
      'routes': routes,
      'actionRegistry': actions,
      'navigation': canonicalNavigation,
      'appShell': appShell,
      'designTokens': _normalizeDesignTokens(source, components),
      'state': _normalizeState(source, initialRouteId),
      '_clientHomeSchemaAdapter': 'flat-composer-normalized',
      '_clientHomeSchemaOriginalKind': source['kind'],
    };

    return output;
  }

  Map<String, dynamic> _normalizeComponent(
    String id,
    Map<String, dynamic> raw, {
    required Map<String, dynamic> components,
    required Map<String, dynamic> actions,
  }) {
    final type = _nonEmpty(raw['type']) ?? '';

    if (type == 'pageHeader') {
      return _normalizePageHeader(id, raw, actions: actions);
    }

    if (_rendererComponentTypes.contains(type)) {
      final copy = _deepCopy(raw);
      copy['id'] = id;
      _normalizeComponentEvents(copy, actions);
      return copy;
    }

    if (_looksLikeGrid(raw)) {
      return _normalizeGrid(
        id,
        raw,
        components: components,
        actions: actions,
      );
    }

    if (_looksLikeRotatingCard(raw)) {
      return _normalizeCard(id, raw, actions: actions);
    }

    if (_looksLikeBottomNavigation(raw)) {
      return _normalizeBottomNavigation(id, raw);
    }

    final lowered = type.toLowerCase();

    if (lowered.contains('welcome') || lowered.contains('banner')) {
      return _normalizeBanner(id, raw, actions: actions);
    }

    if (lowered.contains('alert') || lowered.contains('summary')) {
      return _normalizeSummary(id, raw, actions: actions);
    }

    if (lowered.contains('iot') &&
        (raw.containsKey('label') || raw.containsKey('action'))) {
      return _normalizeBanner(id, raw, actions: actions);
    }

    if (lowered == 'pageheader' || lowered == 'header') {
      final copy = <String, dynamic>{
        ...raw,
        'id': id,
        'type': 'pageHeader',
        if (raw['iconToken'] == null && raw['icon'] != null)
          'iconToken': raw['icon'],
      };
      _normalizeComponentEvents(copy, actions);
      return copy;
    }

    // Unknown but text-capable components degrade to a schema-derived banner
    // instead of being translated using account-specific rules.
    return _normalizeBanner(id, raw, actions: actions);
  }

  bool _looksLikeGrid(Map<String, dynamic> raw) {
    return raw['cards'] is List ||
        raw['childrenBinding'] is Map ||
        (_nonEmpty(raw['type'])?.toLowerCase().contains('grid') ?? false);
  }

  bool _looksLikeRotatingCard(Map<String, dynamic> raw) {
    return raw['faces'] is List ||
        raw['flip'] is Map ||
        raw['rotation'] is Map;
  }

  bool _looksLikeBottomNavigation(Map<String, dynamic> raw) {
    final type = _nonEmpty(raw['type'])?.toLowerCase() ?? '';
    if (type.contains('bottomnav') || type.contains('bottom-navigation')) {
      return true;
    }
    final items = raw['items'];
    return items is List &&
        (raw.containsKey('activeColor') ||
            raw.containsKey('inactiveColor') ||
            raw.containsKey('height'));
  }

  Map<String, dynamic> _normalizePageHeader(
    String id,
    Map<String, dynamic> raw, {
    required Map<String, dynamic> actions,
  }) {
    final normalizedActions = <dynamic>[];
    final rawActions = raw['actions'];
    if (rawActions is List) {
      for (var index = 0; index < rawActions.length; index++) {
        final action = _map(rawActions[index]);
        if (action == null) continue;
        final actionId = _registerAction(
          action,
          ownerId: '$id-action-${index + 1}',
          eventName: 'tap',
          actions: actions,
        );
        if (actionId == null) continue;
        normalizedActions.add(<String, dynamic>{
          ...action,
          'actionId': actionId,
          if (action['iconToken'] == null && action['icon'] != null)
            'iconToken': action['icon'],
        });
      }
    }

    final copy = <String, dynamic>{
      ...raw,
      'id': id,
      'type': 'pageHeader',
      if (raw['iconToken'] == null && raw['icon'] != null)
        'iconToken': raw['icon'],
      if (normalizedActions.isNotEmpty) 'actions': normalizedActions,
    };
    _normalizeComponentEvents(copy, actions);
    return copy;
  }

  Map<String, dynamic> _normalizeBanner(
    String id,
    Map<String, dynamic> raw, {
    required Map<String, dynamic> actions,
  }) {
    final rawBackground = raw['background'];
    final background = _normalizeBackground(rawBackground);

    final content = <String, dynamic>{
      if (raw['greeting'] != null) 'greeting': raw['greeting'],
      if (raw['title'] != null || raw['label'] != null)
        'title': raw['title'] ?? raw['label'],
      if (raw['subtitle'] != null) 'subtitle': raw['subtitle'],
      if (raw['email'] != null) 'supportingText': raw['email'],
      if (raw['caption'] != null) 'caption': raw['caption'],
      if (raw['supportingText'] != null)
        'supportingText': raw['supportingText'],
    };

    final result = <String, dynamic>{
      'id': id,
      'type': 'banner',
      'content': content,
      'appearance': <String, dynamic>{
        if (background != null) 'background': background,
        if (background == null && rawBackground is String)
          'backgroundColor': rawBackground,
        if (raw['textColor'] != null) 'textColor': raw['textColor'],
        if (raw['borderRadius'] != null)
          'borderRadius': raw['borderRadius'],
        if (raw['padding'] != null) 'padding': raw['padding'],
      },
      if (raw['responsiveLayout'] != null)
        'responsiveLayout': raw['responsiveLayout'],
    };

    final avatar = _map(raw['avatar']) ?? _map(raw['avatarPlaceholder']);
    if (avatar != null) {
      final size = _number(avatar['size']);
      final sourceText =
          _nonEmpty(avatar['initials']) ??
          _nonEmpty(raw['email']) ??
          _nonEmpty(raw['title']) ??
          _nonEmpty(raw['greeting']);
      final initials = _initials(sourceText);
      if (size != null && size > 0 && initials.isNotEmpty) {
        result['avatar'] = <String, dynamic>{
          'initials': initials,
          if (avatar['imageUrl'] != null) 'imageUrl': avatar['imageUrl'],
          'appearance': <String, dynamic>{
            'width': size,
            'height': size,
            'borderRadius': _number(avatar['borderRadius']) ?? size / 2,
            'fontSize': size * 0.4,
            if (avatar['background'] != null)
              'backgroundColor': avatar['background'],
            if (raw['textColor'] != null) 'textColor': raw['textColor'],
          },
        };
      }
    }

    _attachActionFromRaw(result, raw, id, actions);
    return result;
  }

  Map<String, dynamic> _normalizeSummary(
    String id,
    Map<String, dynamic> raw, {
    required Map<String, dynamic> actions,
  }) {
    final result = <String, dynamic>{
      'id': id,
      'type': 'summaryBanner',
      'content': <String, dynamic>{
        'title':
            raw['title'] ?? raw['label'] ?? raw['message'] ?? raw['badgeText'],
        'value': raw['value'] ?? raw['count'] ?? raw['newUsers'],
        if (raw['showBadge'] != false && raw['badgeText'] != null)
          'badge': raw['badgeText'],
      },
      'appearance': <String, dynamic>{
        if (raw['background'] != null) 'backgroundColor': raw['background'],
        if (raw['textColor'] != null) 'textColor': raw['textColor'],
        if (raw['borderRadius'] != null)
          'borderRadius': raw['borderRadius'],
      },
    };
    _attachActionFromRaw(result, raw, id, actions);
    return result;
  }

  Map<String, dynamic> _normalizeGrid(
    String id,
    Map<String, dynamic> raw, {
    required Map<String, dynamic> components,
    required Map<String, dynamic> actions,
  }) {
    final children = <String>[];

    final existingChildren = raw['children'];
    if (existingChildren is List) {
      for (final child in existingChildren) {
        if (child is String && child.trim().isNotEmpty) {
          children.add(child.trim());
        }
      }
    }

    final cards = raw['cards'];
    if (cards is List) {
      for (var index = 0; index < cards.length; index++) {
        final card = _map(cards[index]);
        if (card == null) continue;
        final cardId =
            _nonEmpty(card['id']) ?? '${_safeId(id)}-item-${index + 1}';
        components[cardId] = _normalizeCard(
          cardId,
          card,
          actions: actions,
        );
        children.add(cardId);
      }
    }

    final baseGap = _number(raw['gap']);
    final baseRowHeight = _number(raw['rowHeight']) ??
        _number(raw['rowHeightDp']) ??
        _number(raw['minRowHeight']) ??
        _number(raw['minCardRowHeightDp']);
    final baseLayout = <String, dynamic>{
      if (_number(raw['columns']) != null) 'columns': _number(raw['columns']),
      if (baseGap != null) 'columnGap': baseGap,
      if (baseGap != null) 'rowGap': baseGap,
      if (baseRowHeight != null) 'rowHeight': baseRowHeight,
      if (_number(raw['minRowHeight']) != null)
        'minRowHeight': _number(raw['minRowHeight']),
      if (_number(raw['maxContentWidth']) != null)
        'maximumContentWidth': _number(raw['maxContentWidth']),
    };

    final layouts = <String, dynamic>{};
    final responsive = _map(raw['responsiveLayout']) ?? _map(raw['responsiveLayouts']);
    if (responsive != null) {
      for (final entry in responsive.entries) {
        final value = _map(entry.value);
        if (value == null) continue;
        final gap = _number(value['gap']) ?? baseGap;
        final rHeight = _number(value['rowHeight']) ??
            _number(value['rowHeightDp']) ??
            _number(value['minRowHeight']) ??
            _number(value['minCardRowHeightDp']) ??
            baseRowHeight;
        layouts[entry.key] = <String, dynamic>{
          ...baseLayout,
          if (_number(value['columns']) != null)
            'columns': _number(value['columns']),
          if (gap != null) 'columnGap': gap,
          if (gap != null) 'rowGap': gap,
          if (rHeight != null) 'rowHeight': rHeight,
          if (_number(value['minRowHeight']) != null)
            'minRowHeight': _number(value['minRowHeight']),
          if (_number(value['maxContentWidth']) != null)
            'maximumContentWidth': _number(value['maxContentWidth']),
        };
      }
    }

    return <String, dynamic>{
      'id': id,
      'type': 'responsiveGrid',
      'children': children,
      'layout': baseLayout,
      if (layouts.isNotEmpty) 'layouts': layouts,
      'clampChildColumnSpan': true,
    };
  }

  Map<String, dynamic> _normalizeCard(
    String id,
    Map<String, dynamic> raw, {
    required Map<String, dynamic> actions,
  }) {
    final faces = <dynamic>[];
    final rawFaces = raw['faces'];

    if (rawFaces is List) {
      for (var index = 0; index < rawFaces.length; index++) {
        final face = _map(rawFaces[index]);
        if (face == null) continue;
        faces.add(_normalizeFace(id, index, raw, face));
      }
    }

    // A one-face card remains valid when a composer publishes no `faces[]`.
    if (faces.isEmpty) {
      faces.add(_normalizeFace(id, 0, raw, raw));
    }

    final responsiveLayout = <String, dynamic>{};
    final rawResponsive = _map(raw['responsiveLayout']);
    if (rawResponsive != null) {
      for (final entry in rawResponsive.entries) {
        final value = _map(entry.value);
        if (value == null) continue;
        responsiveLayout[entry.key] = <String, dynamic>{
          if (_number(value['columnSpan'] ?? value['colSpan']) != null)
            'columnSpan': _number(value['columnSpan'] ?? value['colSpan']),
          if (_number(value['rowSpan']) != null)
            'rowSpan': _number(value['rowSpan']),
        };
      }
    }

    final flip = _map(raw['flip']);
    final rotation = _map(raw['rotation']) ?? <String, dynamic>{};

    final result = <String, dynamic>{
      ...raw,
      'id': id,
      'type': 'rotatingFaceCard',
      'faces': faces,
      'defaultFaceIndex':
          raw['defaultFaceIndex'] ?? raw['defaultFace'] ?? flip?['currentFace'] ?? 0,
      'layout': <String, dynamic>{
        'columnSpan': _number(raw['columnSpan'] ?? raw['colSpan']) ?? 1,
        'rowSpan': _number(raw['rowSpan']) ?? 1,
      },
      if (responsiveLayout.isNotEmpty)
        'responsiveLayout': responsiveLayout,
      'overflowPolicy': raw['overflowPolicy'] ?? 'clip',
      'appearance': <String, dynamic>{
        if (raw['color'] != null) 'backgroundColor': raw['color'],
        if (raw['textColor'] != null) 'titleTextColor': raw['textColor'],
        if (raw['textColor'] != null)
          'subtitleTextColor': raw['textColor'],
        if (raw['textColor'] != null) 'iconColor': raw['textColor'],
        if (raw['borderRadius'] != null)
          'borderRadius': raw['borderRadius'],
      },
      'rotation': <String, dynamic>{
        ...rotation,
        if (flip?['enabled'] != null && !rotation.containsKey('enabled'))
          'enabled': flip?['enabled'],
        if (raw['rotationDir'] != null &&
            !rotation.containsKey('rotationDir'))
          'rotationDir': raw['rotationDir'],
        if (flip?['axis'] != null && !rotation.containsKey('axis'))
          'axis': flip?['axis'],
        if (flip?['curve'] != null && !rotation.containsKey('curve'))
          'curve': flip?['curve'],
      },
    };

    _attachActionFromRaw(result, raw, id, actions);
    return result;
  }

  Map<String, dynamic> _normalizeFace(
    String cardId,
    int index,
    Map<String, dynamic> card,
    Map<String, dynamic> face,
  ) {
    final background = face['color'] ?? card['color'];
    final textColor = face['textColor'] ?? card['textColor'];
    final image = face['image'] ?? (index == 0 ? card['image'] : null);

    return <String, dynamic>{
      ...face,
      'id': _nonEmpty(face['id']) ?? '${_safeId(cardId)}-face-$index',
      'faceIndex': face['faceIndex'] ?? index,
      if (face['title'] == null && face['label'] != null)
        'title': face['label'],
      if (image != null) 'image': image,
      if (face['imageFit'] == null && card['imageFit'] != null)
        'imageFit': card['imageFit'],
      if (face['imageAlignment'] == null && card['imagePosition'] != null)
        'imageAlignment': card['imagePosition'],
      if (face['iconToken'] == null && face['icon'] != null)
        'iconToken': face['icon'],
      'appearance': <String, dynamic>{
        if (background != null) 'backgroundColor': background,
        if (textColor != null) 'titleTextColor': textColor,
        if (textColor != null) 'subtitleTextColor': textColor,
        if (textColor != null) 'iconColor': textColor,
        if (card['borderRadius'] != null)
          'borderRadius': card['borderRadius'],
      },
    };
  }

  Map<String, dynamic> _normalizeBottomNavigation(
    String id,
    Map<String, dynamic> raw,
  ) {
    return <String, dynamic>{
      'id': id,
      'type': 'bottomNavigation',
      'appearance': <String, dynamic>{
        'activeColorToken': 'colors.navActive',
        'inactiveColorToken': 'colors.textMuted',
        'backgroundColorToken': 'colors.navBackground',
        if (raw['height'] != null) 'height': raw['height'],
        if (raw['borderRadius'] != null)
          'borderRadius': raw['borderRadius'],
        if (raw['showLabels'] != null) 'showLabels': raw['showLabels'],
      },
      // items are resolved from normalized schema.navigation.items.
      'itemsSource': <String, dynamic>{r'$reference': 'navigation.items'},
    };
  }

  void _materializePage(
    String pageId,
    Map<String, dynamic> rawPage, {
    required Map<String, dynamic> components,
    required Map<String, String> componentAliases,
    required Map<String, dynamic> pages,
  }) {
    final existingRoot = _nonEmpty(rawPage['rootComponentId']);
    final resolvedExistingRoot = existingRoot == null
        ? null
        : (componentAliases[existingRoot] ?? existingRoot);
    if (resolvedExistingRoot != null &&
        components.containsKey(resolvedExistingRoot)) {
      pages[pageId] = <String, dynamic>{
        ...rawPage,
        'id': pageId,
        'rootComponentId': resolvedExistingRoot,
      };
      return;
    }

    final renderOrder = <String>[];
    final rawOrder = rawPage['renderOrder'] ?? rawPage['children'];
    if (rawOrder is List) {
      for (final rawChild in rawOrder) {
        final childId = rawChild?.toString().trim() ?? '';
        final resolvedId = componentAliases[childId] ?? childId;
        if (resolvedId.isNotEmpty && components.containsKey(resolvedId)) {
          renderOrder.add(resolvedId);
        }
      }
    }

    if (renderOrder.isEmpty) {
      _materializeGenericPageContent(
        pageId,
        rawPage,
        components: components,
        renderOrder: renderOrder,
      );
    }

    final rootId = '__compat_page_${_safeId(pageId)}_root';
    components[rootId] = <String, dynamic>{
      'id': rootId,
      'type': 'scrollPage',
      'layout': <String, dynamic>{
        if (rawPage['safeArea'] != null) 'safeArea': rawPage['safeArea'],
        if (rawPage['padding'] != null) 'padding': rawPage['padding'],
        if (rawPage['gap'] != null) 'gap': rawPage['gap'],
      },
      'children': renderOrder,
    };

    pages[pageId] = <String, dynamic>{
      ...rawPage,
      'id': pageId,
      'rootComponentId': rootId,
    };
  }

  void _materializeGenericPageContent(
    String pageId,
    Map<String, dynamic> rawPage, {
    required Map<String, dynamic> components,
    required List<String> renderOrder,
  }) {
    final header = _map(rawPage['header']);
    if (header != null) {
      final headerId = '__compat_${_safeId(pageId)}_header';
      components[headerId] = <String, dynamic>{
        ...header,
        'id': headerId,
        'type': 'pageHeader',
        if (header['iconToken'] == null && header['leftIcon'] != null)
          'iconToken': header['leftIcon'],
      };
      renderOrder.add(headerId);
    }

    final status = _map(rawPage['status']);
    if (status != null && status.isNotEmpty) {
      final statusId = '__compat_${_safeId(pageId)}_status';
      components[statusId] = <String, dynamic>{
        'id': statusId,
        'type': 'statusSummary',
        'items': <dynamic>[
          for (final entry in status.entries)
            <String, dynamic>{
              'label': entry.key,
              'value': entry.value,
              'colorToken': 'colors.accent',
            },
        ],
      };
      renderOrder.add(statusId);
    }

    for (final entry in rawPage.entries) {
      if (entry.key == 'header' ||
          entry.key == 'status' ||
          entry.key == 'id' ||
          entry.key == 'padding' ||
          entry.key == 'safeArea' ||
          entry.key == 'responsiveLayout') {
        continue;
      }

      final value = entry.value;
      if (value is List && value.isNotEmpty && value.every((e) => e is Map)) {
        final listId = '__compat_${_safeId(pageId)}_${_safeId(entry.key)}';
        components[listId] = <String, dynamic>{
          'id': listId,
          'type': 'list',
          'itemsBinding': value,
        };
        renderOrder.add(listId);
      }
    }

    if (renderOrder.isNotEmpty) return;

    final scalarItems = <dynamic>[];
    for (final entry in rawPage.entries) {
      final value = entry.value;
      if (value == null || value is Map || value is List) continue;
      scalarItems.add(<String, dynamic>{
        'title': entry.key,
        'subtitle': value.toString(),
      });
    }

    if (scalarItems.isNotEmpty) {
      final listId = '__compat_${_safeId(pageId)}_details';
      components[listId] = <String, dynamic>{
        'id': listId,
        'type': 'list',
        'itemsBinding': scalarItems,
      };
      renderOrder.add(listId);
    }
  }

  List<dynamic> _normalizeNavigationItems(
    Map<String, dynamic> source,
    Map<String, dynamic> sourceNavigation, {
    required Map<String, dynamic> components,
    required Map<String, String> componentAliases,
    required Map<String, dynamic> pages,
    required Map<String, dynamic> routes,
    required Map<String, dynamic> actions,
  }) {
    dynamic rawItems = sourceNavigation['items'];
    if (rawItems is! List) {
      final navBottom = _map(sourceNavigation['bottomNav']);
      rawItems = navBottom?['items'];
    }

    if (rawItems is! List) {
      final componentBottom = _firstBottomNavigationSource(source);
      rawItems = componentBottom?['items'];
    }

    if (rawItems is! List) return <dynamic>[];

    final items = <dynamic>[];

    for (var index = 0; index < rawItems.length; index++) {
      final raw = _map(rawItems[index]);
      if (raw == null) continue;

      final routeId =
          _nonEmpty(raw['routeId']) ??
          _nonEmpty(raw['target']) ??
          _nonEmpty(raw['id']) ??
          'route-${index + 1}';
      final label = raw['label'] ?? raw['title'] ?? routeId;

      _ensureRouteAndPage(
        routeId,
        label: label,
        source: source,
        components: components,
        componentAliases: componentAliases,
        pages: pages,
        routes: routes,
      );

      var actionId = _nonEmpty(raw['actionId']);
      if (actionId == null || !actions.containsKey(actionId)) {
        actionId = '__compat_nav_${_safeId(routeId)}';
        actions[actionId] = <String, dynamic>{
          'type': 'navigate',
          'destination': <String, dynamic>{'routeId': routeId},
        };
      }

      items.add(<String, dynamic>{
        ...raw,
        'id': _nonEmpty(raw['id']) ?? 'nav-${_safeId(routeId)}',
        'label': label,
        'routeId': routeId,
        'actionId': actionId,
        if (raw['iconToken'] == null && raw['icon'] != null)
          'iconToken': raw['icon'],
      });
    }

    return items;
  }

  void _ensureRouteAndPage(
    String routeId, {
    required dynamic label,
    required Map<String, dynamic> source,
    required Map<String, dynamic> components,
    required Map<String, String> componentAliases,
    required Map<String, dynamic> pages,
    required Map<String, dynamic> routes,
  }) {
    if (!pages.containsKey(routeId)) {
      final pageLike = _findPageLike(source, routeId);
      if (pageLike != null) {
        _materializePage(
          routeId,
          pageLike,
          components: components,
          componentAliases: componentAliases,
          pages: pages,
        );
      }
    }

    if (!pages.containsKey(routeId)) {
      final headerId = '__compat_${_safeId(routeId)}_header';
      final rootId = '__compat_page_${_safeId(routeId)}_root';

      components[headerId] = <String, dynamic>{
        'id': headerId,
        'type': 'pageHeader',
        'title': label,
      };

      components[rootId] = <String, dynamic>{
        'id': rootId,
        'type': 'scrollPage',
        'children': <String>[headerId],
      };

      pages[routeId] = <String, dynamic>{
        'id': routeId,
        'rootComponentId': rootId,
      };
    }

    final existing = _map(routes[routeId]);
    if (existing == null) {
      routes[routeId] = <String, dynamic>{
        'id': routeId,
        'path': '/${Uri.encodeComponent(routeId)}',
        'pageId': routeId,
      };
    } else if (_nonEmpty(existing['pageId']) == null ||
        !pages.containsKey(existing['pageId']?.toString())) {
      routes[routeId] = <String, dynamic>{...existing, 'pageId': routeId};
    }
  }

  Map<String, dynamic>? _findPageLike(
    Map<String, dynamic> source,
    String routeId,
  ) {
    final direct = _map(source['${routeId}Page']);
    if (direct != null) return direct;

    final lowerRoute = routeId.toLowerCase();
    for (final entry in source.entries) {
      final key = entry.key.toLowerCase();
      if (key == '${lowerRoute}page') {
        return _map(entry.value);
      }
    }
    return null;
  }

  void _repairRoutes(
    Map<String, dynamic> routes,
    Map<String, dynamic> pages,
  ) {
    for (final key in routes.keys.toList()) {
      final route = _map(routes[key]);
      if (route == null) {
        routes.remove(key);
        continue;
      }

      final path = _nonEmpty(route['path']);
      final uri = path == null ? null : Uri.tryParse(path);
      final external = uri != null && uri.hasScheme && uri.host.isNotEmpty;
      if (external) continue;

      final pageId = _nonEmpty(route['pageId']);
      if (pageId == null || !pages.containsKey(pageId)) {
        if (pages.containsKey(key)) {
          routes[key] = <String, dynamic>{...route, 'pageId': key};
        } else {
          routes.remove(key);
        }
      }
    }

    for (final pageId in pages.keys) {
      routes.putIfAbsent(
        pageId,
        () => <String, dynamic>{
          'id': pageId,
          'path': '/${Uri.encodeComponent(pageId)}',
          'pageId': pageId,
        },
      );
    }
  }

  void _materializeActionDestinations(
    Map<String, dynamic> source,
    Map<String, dynamic> actions, {
    required Map<String, dynamic> components,
    required Map<String, String> componentAliases,
    required Map<String, dynamic> pages,
    required Map<String, dynamic> routes,
  }) {
    for (final value in actions.values) {
      final action = _map(value);
      if (action == null || action['type']?.toString() != 'navigate') continue;
      final routeId = _nonEmpty(_map(action['destination'])?['routeId']);
      if (routeId == null) continue;
      _ensureRouteAndPage(
        routeId,
        label: routeId,
        source: source,
        components: components,
        componentAliases: componentAliases,
        pages: pages,
        routes: routes,
      );
    }
  }

  Map<String, dynamic> _normalizeAppShell(
    Map<String, dynamic> source,
    Map<String, dynamic> components,
    Map<String, String> componentAliases,
  ) {
    final existing = _map(source['appShell']);
    if (existing != null) {
      final bottom = _nonEmpty(existing['bottomNavigationComponentId']);
      final floating = _nonEmpty(existing['floatingActionComponentId']);
      return <String, dynamic>{
        ...existing,
        if (bottom != null)
          'bottomNavigationComponentId': componentAliases[bottom] ?? bottom,
        if (floating != null)
          'floatingActionComponentId': componentAliases[floating] ?? floating,
      };
    }

    String? bottomId;
    for (final entry in components.entries) {
      final component = _map(entry.value);
      if (component?['type']?.toString() == 'bottomNavigation') {
        bottomId = entry.key;
        break;
      }
    }

    return <String, dynamic>{
      'type': 'appShell',
      'bodySlot': 'active-page',
      if (bottomId != null) 'bottomNavigationComponentId': bottomId,
      'floatingActionComponentId': null,
    };
  }

  Map<String, dynamic> _normalizeState(
    Map<String, dynamic> source,
    String? initialRouteId,
  ) {
    final state = _copyMap(source['state']);
    final navigation = _copyMap(state['navigation']);
    if (_nonEmpty(navigation['activeRouteId']) == null &&
        initialRouteId != null) {
      navigation['activeRouteId'] = initialRouteId;
    }
    final history = navigation['history'];
    if (history is! List) navigation['history'] = <dynamic>[];
    state['navigation'] = navigation;

    final preferences = _copyMap(state['preferences']);
    preferences.putIfAbsent('showBottomNav', () => true);
    preferences.putIfAbsent('animationsEnabled', () => true);
    state['preferences'] = preferences;
    return state;
  }

  Map<String, dynamic> _normalizeDesignTokens(
    Map<String, dynamic> source,
    Map<String, dynamic> normalizedComponents,
  ) {
    final existing = _map(source['designTokens']);
    if (existing != null && existing.isNotEmpty) return existing;

    final theme = _map(source['theme']) ?? <String, dynamic>{};
    final app = _map(source['app']) ?? <String, dynamic>{};

    final rawComponents = _map(source['components']) ?? <String, dynamic>{};
    final welcome = _firstComponentByCapability(
      rawComponents,
      (component) =>
          component.containsKey('greeting') ||
          (_nonEmpty(component['type'])?.toLowerCase().contains('welcome') ??
              false),
    );
    final welcomeBackground = _map(welcome?['background']);

    final pageBackground =
        _firstNonEmpty(<dynamic>[
          app['background'],
          theme['phoneBg'],
          theme['background'],
          theme['backgroundColor'],
        ]) ??
        _firstColorFromComponents(normalizedComponents);

    final surface =
        _firstNonEmpty(<dynamic>[
          theme['surfaceColor'],
          theme['surface'],
          pageBackground,
        ]) ??
        pageBackground;

    final accent =
        _firstNonEmpty(<dynamic>[
          theme['accentColor'],
          theme['accentGreen'],
          theme['primaryColor'],
          _firstColorFromComponents(normalizedComponents),
        ]) ??
        surface;

    final textPrimary =
        _firstNonEmpty(<dynamic>[
          theme['textPrimary'],
          welcome?['textColor'],
          _firstTextColorFromComponents(normalizedComponents),
        ]) ??
        accent;

    final textSecondary =
        _firstNonEmpty(<dynamic>[
          theme['textSecondary'],
          theme['textMuted'],
          textPrimary,
        ]) ??
        textPrimary;

    final textMuted =
        _firstNonEmpty(<dynamic>[
          theme['textMuted'],
          theme['inactiveColor'],
          textSecondary,
        ]) ??
        textSecondary;

    final navActive =
        _firstNonEmpty(<dynamic>[
          theme['navActiveColor'],
          theme['activeColor'],
          accent,
        ]) ??
        accent;

    final navBackground =
        _firstNonEmpty(<dynamic>[
          theme['navBg'],
          theme['navBackground'],
          surface,
        ]) ??
        surface;

    final grid = _firstGrid(source);
    final rowHeight =
        _number(source['grid']?['rowHeightDp']) ??
        _number(source['grid']?['minCardRowHeightDp']) ??
        _number(source['grid']?['responsiveLayouts']?['compact']?['rowHeight']) ??
        _number(source['uiRenderContract']?['grid']?['rowHeightDp']) ??
        _number(source['meta']?['layoutSnapshot']?['grid']?['rowHeightDp']) ??
        _number(theme['gridRowHeight']) ??
        _number(grid?['rowHeightDp']) ??
        _number(grid?['minCardRowHeightDp']) ??
        _number(grid?['rowHeight']) ??
        _firstCardRowHeight(normalizedComponents) ??
        1;
    final gridGap =
        _number(grid?['gap']) ?? _number(theme['gridGap']) ?? rowHeight * 0.05;
    final responsive = _map(source['responsive']);
    final responsiveLayouts = _map(responsive?['layouts']);
    final compactLayout = _map(responsiveLayouts?['compact']);
    final pagePadding =
        _number(compactLayout?['pagePadding']) ?? gridGap * 2;

    final cardRadius =
        _number(theme['cardBorderRadius']) ??
        _firstCardRadius(normalizedComponents) ??
        gridGap;

    // Typography is derived from the schema's own row-height metric when the
    // composer format does not publish a typography table.
    final pageTitleSize = _positive(rowHeight * 0.20);
    final pageSubtitleSize = _positive(rowHeight * 0.13);
    final cardTitleSize = _positive(rowHeight * 0.15);
    final cardSubtitleSize = _positive(rowHeight * 0.115);
    final statSize = _positive(rowHeight * 0.20);

    return <String, dynamic>{
      'colors': <String, dynamic>{
        'pageBackground': pageBackground,
        'surface': surface,
        'surfaceElevated': surface,
        'textPrimary': textPrimary,
        'textSecondary': textSecondary,
        'textMuted': textMuted,
        'accent': accent,
        'navActive': navActive,
        'navBackground': navBackground,
        'welcomeText': _firstNonEmpty(<dynamic>[
          welcome?['textColor'],
          textPrimary,
        ]),
        'border': surface,
        'danger': accent,
        'avatarGradientStart':
            welcomeBackground?['start'] ??
            welcomeBackground?['startColor'] ??
            accent,
        'avatarGradientEnd':
            welcomeBackground?['end'] ??
            welcomeBackground?['endColor'] ??
            navActive,
      },
      'spacing': <String, dynamic>{
        'xxs': _positive(gridGap / 2),
        'xs': _positive(gridGap),
        'sm': _positive(gridGap * 2),
        'md': _positive(pagePadding),
        'lg': _positive(pagePadding * 1.5),
      },
      'radius': <String, dynamic>{
        'small': _nonNegative(cardRadius / 2),
        'card': _nonNegative(cardRadius),
        'pill': _positive(rowHeight),
      },
      'typography': <String, dynamic>{
        'pageTitle': <String, dynamic>{
          'fontSize': pageTitleSize,
          'fontWeight': 700,
          'maxLines': 2,
          'overflow': 'ellipsis',
        },
        'pageSubtitle': <String, dynamic>{
          'fontSize': pageSubtitleSize,
          'fontWeight': 400,
          'maxLines': 2,
          'overflow': 'ellipsis',
        },
        'cardTitle': <String, dynamic>{
          'fontSize': cardTitleSize,
          'fontWeight': 700,
          'maxLines': 2,
          'overflow': 'ellipsis',
        },
        'cardSubtitle': <String, dynamic>{
          'fontSize': cardSubtitleSize,
          'fontWeight': 400,
          'maxLines': 2,
          'overflow': 'ellipsis',
        },
        'statValue': <String, dynamic>{
          'fontSize': statSize,
          'fontWeight': 800,
        },
        'welcomeGreeting': <String, dynamic>{
          'fontSize': pageTitleSize,
          'fontWeight': 700,
        },
        'welcomeEmail': <String, dynamic>{
          'fontSize': pageSubtitleSize,
          'fontWeight': 400,
        },
        'welcomeCaption': <String, dynamic>{
          'fontSize': cardSubtitleSize,
          'fontWeight': 400,
        },
      },
    };
  }

  Map<String, dynamic>? _firstGrid(Map<String, dynamic> source) {
    final components = _map(source['components']);
    if (components == null) return null;
    for (final value in components.values) {
      final component = _map(value);
      if (component != null && _looksLikeGrid(component)) return component;
    }
    return null;
  }

  Map<String, dynamic>? _firstBottomNavigationSource(
    Map<String, dynamic> source,
  ) {
    final components = _map(source['components']);
    if (components == null) return null;
    for (final value in components.values) {
      final component = _map(value);
      if (component != null && _looksLikeBottomNavigation(component)) {
        return component;
      }
    }
    return null;
  }

  Map<String, dynamic>? _firstComponentByCapability(
    Map<String, dynamic> components,
    bool Function(Map<String, dynamic>) predicate,
  ) {
    for (final value in components.values) {
      final component = _map(value);
      if (component != null && predicate(component)) return component;
    }
    return null;
  }

  dynamic _firstColorFromComponents(Map<String, dynamic> components) {
    for (final value in components.values) {
      final component = _map(value);
      if (component == null) continue;
      final color =
          _firstNonEmpty(<dynamic>[
            component['color'],
            component['background'],
            _map(component['appearance'])?['backgroundColor'],
          ]);
      if (color is String && _looksLikeColor(color)) return color;
    }
    return null;
  }

  dynamic _firstTextColorFromComponents(Map<String, dynamic> components) {
    for (final value in components.values) {
      final component = _map(value);
      if (component == null) continue;
      final color =
          _firstNonEmpty(<dynamic>[
            component['textColor'],
            _map(component['appearance'])?['titleTextColor'],
          ]);
      if (color is String && _looksLikeColor(color)) return color;
    }
    return null;
  }

  double? _firstCardRowHeight(Map<String, dynamic> components) {
    for (final value in components.values) {
      final component = _map(value);
      if (component == null) continue;
      final height = _number(_map(component['layout'])?['rowHeight']);
      if (height != null && height > 0) return height;
    }
    return null;
  }

  double? _firstCardRadius(Map<String, dynamic> components) {
    for (final value in components.values) {
      final component = _map(value);
      if (component == null) continue;
      final radius =
          _number(component['borderRadius']) ??
          _number(_map(component['appearance'])?['borderRadius']);
      if (radius != null && radius >= 0) return radius;
    }
    return null;
  }

  int _historyLimitFromSchema(Map<String, dynamic> source) {
    final nav = _map(source['navigation']);
    final value = _number(nav?['maximumHistoryEntries']);
    if (value != null && value > 0) return value.toInt();

    final items = nav?['items'];
    if (items is List && items.isNotEmpty) {
      return items.length * 4;
    }

    final bottom = _map(nav?['bottomNav']);
    final bottomItems = bottom?['items'];
    if (bottomItems is List && bottomItems.isNotEmpty) {
      return bottomItems.length * 4;
    }
    return 20;
  }

  void _normalizeComponentEvents(
    Map<String, dynamic> component,
    Map<String, dynamic> actions,
  ) {
    final events = _map(component['events']);
    if (events == null) return;

    final cleaned = <String, dynamic>{};
    for (final entry in events.entries) {
      final config = _map(entry.value);
      if (config == null) continue;
      final actionId = _nonEmpty(config['actionId']);
      if (actionId != null && actions.containsKey(actionId)) {
        cleaned[entry.key] = config;
      }
    }
    if (cleaned.isEmpty) {
      component.remove('events');
    } else {
      component['events'] = cleaned;
    }
  }

  void _attachActionFromRaw(
    Map<String, dynamic> normalized,
    Map<String, dynamic> raw,
    String ownerId,
    Map<String, dynamic> actions,
  ) {
    final action = _map(raw['action']);
    if (action == null) return;

    final actionId = _registerAction(
      action,
      ownerId: ownerId,
      eventName: 'tap',
      actions: actions,
    );
    if (actionId == null) return;

    normalized['events'] = <String, dynamic>{
      'tap': <String, dynamic>{'actionId': actionId},
    };
  }

  String? _registerAction(
    Map<String, dynamic> raw, {
    required String ownerId,
    required String eventName,
    required Map<String, dynamic> actions,
  }) {
    final existingId = _nonEmpty(raw['actionId'] ?? raw['id']);
    if (existingId != null && actions.containsKey(existingId)) {
      return existingId;
    }

    final type =
        (_nonEmpty(raw['actionType']) ?? _nonEmpty(raw['type']) ?? '')
            .toLowerCase();
    final target =
        _nonEmpty(raw['target']) ??
        _nonEmpty(raw['routeId']) ??
        _nonEmpty(_map(raw['destination'])?['routeId']) ??
        _nonEmpty(raw['url']);

    if (target == null) return null;

    final id =
        existingId ?? '__compat_${_safeId(ownerId)}_${_safeId(eventName)}';
    final uri = Uri.tryParse(target);
    final isExternal = uri != null && uri.hasScheme && uri.host.isNotEmpty;

    if (isExternal || type.contains('external')) {
      actions[id] = <String, dynamic>{
        'type': 'external-navigate',
        'url': target,
      };
    } else {
      actions[id] = <String, dynamic>{
        'type': 'navigate',
        'destination': <String, dynamic>{'routeId': target},
      };
    }

    return id;
  }

  Map<String, dynamic>? _normalizeBackground(dynamic raw) {
    final map = _map(raw);
    if (map == null) return null;

    final start = map['startColor'] ?? map['start'];
    final end = map['endColor'] ?? map['end'];
    if (start == null || end == null) return null;

    return <String, dynamic>{
      'type': 'linear-gradient',
      'startColor': start,
      'endColor': end,
      if (map['direction'] != null) 'direction': map['direction'],
    };
  }

  String _initials(String? source) {
    final text = source?.trim() ?? '';
    if (text.isEmpty) return '';

    final emailPrefix = text.contains('@') ? text.split('@').first : text;
    final parts = emailPrefix
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);

    if (parts.isEmpty) return emailPrefix.substring(0, 1).toUpperCase();
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String _safeId(String value) {
    final safe = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    return safe.isEmpty ? 'generated' : safe;
  }

  bool _looksLikeColor(String value) {
    final text = value.trim().toLowerCase();
    return text.startsWith('#') ||
        text.startsWith('rgb(') ||
        text.startsWith('rgba(');
  }

  double _positive(double value) => value <= 0 ? 1 : value;
  double _nonNegative(double value) => value < 0 ? 0 : value;

  String? _nonEmpty(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  dynamic _firstNonEmpty(List<dynamic> candidates) {
    for (final value in candidates) {
      if (value == null) continue;
      if (value is String && value.trim().isEmpty) continue;
      return value;
    }
    return null;
  }

  double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '');
  }

  Map<String, dynamic> _copyMap(dynamic value) {
    final map = _map(value);
    return map == null ? <String, dynamic>{} : _deepCopy(map);
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  Map<String, dynamic> _deepCopy(Map<String, dynamic> source) {
    return jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  }
}
