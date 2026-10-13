import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/responsive_util.dart';
import '../services/json_http.dart';
import '../sdui/schema_guard.dart';
import '../sdui/schema_pull_to_refresh.dart';
import '../sdui/schema_runtime.dart';
import '../sdui/sdui_network_image_cache.dart';
import 'iot_schema_icon.dart';
import 'iot_sdui_state.dart';

class IotSduiRenderer {
  IotSduiRenderer(this.state) : _icons = IotSchemaIcon(state.schema);

  final IotSduiState state;
  final IotSchemaIcon _icons;

  Widget build(BuildContext context) {
    final theme = state.theme;
    final background =
        _cssColor(theme['background']) ?? Theme.of(context).colorScheme.surface;

    // This renderer is mounted directly inside the page SafeArea. Use this
    // root viewport to select the schema breakpoint before applying page
    // padding/max-content-width. Nested component widths are only used later
    // for actual layout math, never for breakpoint selection.
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaSize = MediaQuery.sizeOf(context);
        final viewportWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : mediaSize.width;
        final viewportHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : mediaSize.height;
        final orientation = viewportWidth > viewportHeight
            ? 'landscape'
            : 'portrait';
        final schemaRuntime = SchemaRuntime(state.schema);

        final basePage = Map<String, dynamic>.from(state.page);
        final page = schemaRuntime.resolveResponsiveMap(
          basePage,
          viewportWidth,
          logicalHeight: viewportHeight,
          orientation: orientation,
        );

        final baseLayout =
            _map(state.schema['layout']) ?? const <String, dynamic>{};
        final layout = schemaRuntime.resolveResponsiveMap(
          baseLayout,
          viewportWidth,
          logicalHeight: viewportHeight,
          orientation: orientation,
        );

        final pagePadding = _pagePadding(page, layout: layout);
        final maxContentWidth = _number(
          page['maxContentWidth'] ??
              page['maximumContentWidth'] ??
              layout['maxContentWidth'] ??
              layout['maximumContentWidth'],
        );

        final components = <Map<String, dynamic>>[
          for (final raw in state.components)
            if (_map(raw) case final component?)
              schemaRuntime.resolveResponsiveMap(
                component,
                viewportWidth,
                logicalHeight: viewportHeight,
                orientation: orientation,
              ),
        ];

        Widget content = SchemaPullToRefresh(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  pagePadding.left,
                  pagePadding.top,
                  pagePadding.right,
                  0,
                ),
                sliver: SliverToBoxAdapter(child: _buildHeader(context, page)),
              ),
              for (final component in components)
                SliverPadding(
                  padding: EdgeInsets.only(
                    left: pagePadding.left,
                    right: pagePadding.right,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _buildComponent(context, component),
                  ),
                ),
              if (state.lastError != null)
                SliverPadding(
                  padding: EdgeInsets.only(
                    left: pagePadding.left,
                    right: pagePadding.right,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _runtimeError(context, state.lastError!),
                  ),
                ),
              SliverToBoxAdapter(child: SizedBox(height: pagePadding.bottom)),
            ],
          ),
        );

        if (maxContentWidth != null &&
            maxContentWidth > 0 &&
            maxContentWidth.isFinite) {
          content = Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth),
              child: content,
            ),
          );
        }

        return ColoredBox(color: background, child: content);
      },
    );
  }

  Future<void> _refresh() async {
    // Pull-to-refresh must fetch live IoT schema (reloadHandler uses
    // forceRefresh: true), then refresh the device grid datasource.
    final reload = state.reloadHandler;
    if (reload != null) {
      await reload();
    } else {
      await state.refreshDeviceGrid();
      return;
    }
    if (state.deviceGrid != null) {
      await state.refreshDeviceGrid();
    }
  }

  Widget _buildHeader(BuildContext context, Map<String, dynamic> page) {
    final header = _map(page['header']);

    if (header == null) {
      logDebug(
        '[IOT_SDUI][CAPABILITY] page.header not declared; '
        'rendering page without a header. '
        'pageKeys=${state.page.keys.join(",")}',
      );
      return const SizedBox.shrink();
    }

    final style = _map(header['style']) ?? const <String, dynamic>{};
    final padding = _edgeInsets(style['padding']) ?? EdgeInsets.zero;
    final gap = _number(style['gap']) ?? 0.0;

    final orderedActions = _collectHeaderActions(header);
    final leading = <Widget>[];
    final trailing = <Widget>[];

    for (final action in orderedActions) {
      final isAvatar = action['_isAvatar'] == true;
      final widget = isAvatar
          ? _buildHeaderAvatar(context, action, header)
          : _buildHeaderAction(context, action, header);
      final placement = _map(action['placement']);
      final align = placement?['align']?.toString().toLowerCase();
      if (align == 'left') {
        leading.add(widget);
      } else {
        trailing.add(widget);
      }
    }

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (leading.isNotEmpty) ...[
                Wrap(spacing: gap, runSpacing: gap, children: leading),
                SizedBox(width: gap > 0 ? gap : 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (header['eyebrow']?.toString().isNotEmpty == true)
                      Text(
                        header['eyebrow'].toString(),
                        style: _textStyle(context, inline: _map(style['eyebrow'])),
                      ),
                    if (header['title']?.toString().isNotEmpty == true)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          header['title'].toString(),
                          maxLines: 1,
                          style: _textStyle(context, inline: _map(style['title'])),
                        ),
                      ),
                    if (_headerSubtitle(header).isNotEmpty)
                      Text(
                        _headerSubtitle(header),
                        style: _textStyle(context, inline: _map(style['subtitle'])),
                      ),
                  ],
                ),
              ),
              if (trailing.isNotEmpty)
                Wrap(spacing: gap, runSpacing: gap, children: trailing),
            ],
          ),
          if (state.isSearchVisible) ...[
            const SizedBox(height: 12),
            _buildSearchBar(context, header),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, Map<String, dynamic> header) {
    final searchConfig = _map(header['search']) ?? const <String, dynamic>{};
    return _IotSearchBarWidget(
      state: state,
      searchConfig: searchConfig,
      icons: _icons,
    );
  }

  Widget _buildEmptySearchState(BuildContext context, String query) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: _icons.buildNamed(
                  context,
                  name: 'search',
                  width: 26,
                  height: 26,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'No devices found',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'No devices match "$query"',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: () => state.clearSearchQuery(),
              icon: const Icon(Icons.clear, size: 16),
              label: const Text('Clear search'),
            ),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _collectHeaderActions(
    Map<String, dynamic> header,
  ) {
    final collected = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    void addCandidate(Map<String, dynamic>? candidate, {String? defaultId}) {
      if (candidate == null) return;
      final id = candidate['id']?.toString().trim() ?? defaultId ?? '';
      if (id.isNotEmpty && seenIds.contains(id)) return;
      if (id.isNotEmpty) seenIds.add(id);

      collected.add(Map<String, dynamic>.from(candidate));
    }

    // 1. Explicit actions array
    final actions = header['actions'];
    if (actions is List) {
      for (final raw in actions) {
        addCandidate(_map(raw));
      }
    }

    // 2. Primary action
    addCandidate(_map(header['action']));

    // 3. Dynamically scan all other sub-objects for button/action definitions
    // (e.g. search.button, filter.button, notifications.button, settings.button)
    for (final entry in header.entries) {
      final key = entry.key;
      if (key == 'style' ||
          key == 'eyebrow' ||
          key == 'title' ||
          key == 'subtitle' ||
          key == 'subtitleBind' ||
          key == 'actions' ||
          key == 'action' ||
          key == 'avatar') {
        continue;
      }
      final val = _map(entry.value);
      if (val == null) continue;
      if (val['enabled'] == false) continue;

      final btn = _map(val['button']) ?? _map(val['action']);
      if (btn != null) {
        addCandidate(btn, defaultId: key);
      } else if (val['type'] == 'iconButton' ||
          val['type'] == 'actionButton' ||
          val['onTap'] != null) {
        addCandidate(val, defaultId: key);
      }
    }

    // 4. Avatar (if not replaced by another action with placement.replacesAvatar)
    final avatar = _map(header['avatar']);
    final avatarAction = _map(avatar?['onTap']) ?? _map(avatar?['action']);
    final hasReplacesAvatar = collected.any(
      (a) => _map(a['placement'])?['replacesAvatar'] == true,
    );

    if (avatar != null && !hasReplacesAvatar) {
      final avatarId = avatar['id']?.toString().trim() ??
          avatarAction?['id']?.toString().trim() ??
          'headerAvatar';
      if (!seenIds.contains(avatarId)) {
        seenIds.add(avatarId);
        final avatarMap = Map<String, dynamic>.from(avatar);
        avatarMap['id'] = avatarId;
        avatarMap['_isAvatar'] = true;
        collected.add(avatarMap);
      }
    }

    return _orderHeaderActions(collected);
  }

  List<Map<String, dynamic>> _orderHeaderActions(
    List<Map<String, dynamic>> actions,
  ) {
    if (actions.length <= 1) return actions;

    final result = <Map<String, dynamic>>[];
    final pendingBefore = <String, List<Map<String, dynamic>>>{};
    final pendingAfter = <String, List<Map<String, dynamic>>>{};

    for (final action in actions) {
      final placement = _map(action['placement']);
      final beforeId = placement?['before']?.toString().trim();
      final afterId = placement?['after']?.toString().trim();

      if (beforeId != null && beforeId.isNotEmpty) {
        pendingBefore.putIfAbsent(beforeId, () => []).add(action);
      } else if (afterId != null && afterId.isNotEmpty) {
        pendingAfter.putIfAbsent(afterId, () => []).add(action);
      } else {
        result.add(action);
      }
    }

    var modified = true;
    var iterations = 0;
    while (modified && iterations < 10) {
      modified = false;
      iterations++;

      final beforeKeys = List<String>.from(pendingBefore.keys);
      for (final targetId in beforeKeys) {
        final idx = result.indexWhere((a) => a['id']?.toString() == targetId);
        if (idx != -1) {
          final items = pendingBefore.remove(targetId)!;
          result.insertAll(idx, items);
          modified = true;
        }
      }

      final afterKeys = List<String>.from(pendingAfter.keys);
      for (final targetId in afterKeys) {
        final idx = result.indexWhere((a) => a['id']?.toString() == targetId);
        if (idx != -1) {
          final items = pendingAfter.remove(targetId)!;
          result.insertAll(idx + 1, items);
          modified = true;
        }
      }
    }

    for (final items in pendingBefore.values) {
      result.addAll(items);
    }
    for (final items in pendingAfter.values) {
      result.addAll(items);
    }

    return result;
  }

  String _headerSubtitle(Map<String, dynamic> header) {
    final binding = _map(header['subtitleBind']);
    final template = binding?['template']?.toString();
    if (template == null || template.trim().isEmpty) {
      return header['subtitle']?.toString() ?? '';
    }

    return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (match) {
      final path = match.group(1)?.trim() ?? '';
      final value = state.readBinding(path);
      return value?.toString() ?? '';
    });
  }

  Widget _buildHeaderAvatar(
    BuildContext context,
    Map<String, dynamic> avatar,
    Map<String, dynamic> header,
  ) {
    final headerStyle = _map(header['style']) ?? const <String, dynamic>{};

    final size = _number(headerStyle['avatarSize']);
    final radius = _number(headerStyle['avatarRadius']);
    final iconSize = _number(headerStyle['avatarIconSize']);
    if (size == null || radius == null || iconSize == null) {
      return _schemaError(
        context,
        'page.header.style.avatarSize/avatarRadius/avatarIconSize',
      );
    }

    final iconName = avatar['icon']?.toString();
    final color =
        _cssColor(avatar['color']) ?? Theme.of(context).colorScheme.onPrimary;
    final action = _map(avatar['onTap']) ?? _map(avatar['action']);

    final box = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _cssColor(avatar['background']),
        gradient: _gradient(avatar['background']?.toString()),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: iconName == null
            ? const SizedBox.shrink()
            : _icons.buildNamed(
                context,
                name: iconName,
                width: iconSize,
                height: iconSize,
                color: color,
              ),
      ),
    );

    if (action == null || !state.canExecuteAction(action)) return box;

    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: () => state.executeAction(action),
      child: box,
    );
  }

  Widget _buildHeaderAction(
    BuildContext context,
    Map<String, dynamic> action,
    Map<String, dynamic> header,
  ) {
    final iconName = action['icon']?.toString() ??
        action['control']?.toString() ??
        action['id']?.toString();
    if (iconName == null || iconName.isEmpty) {
      return _schemaError(context, 'page.header.action/icon');
    }

    final style = _map(action['style']) ?? const <String, dynamic>{};
    final headerStyle = _map(header['style']) ?? const <String, dynamic>{};
    final tapAction =
        _map(action['onTap']) ??
        (state.canExecuteAction(action) ? action : null);

    final actionId = action['id']?.toString() ?? '';
    final isSearchButton = actionId == 'searchDevices' || iconName == 'search';
    final isActive = isSearchButton && state.isSearchVisible;

    final defaultIconColor = isActive
        ? (_cssColor(state.theme['accent']) ?? Theme.of(context).colorScheme.primary)
        : Theme.of(context).colorScheme.onSurface;

    final iconColor =
        _cssColor(style['color']) ??
        _cssColor(action['color']) ??
        defaultIconColor;

    final iconSize =
        _number(style['iconSize']) ??
        _number(headerStyle['avatarIconSize']) ??
        22.0;

    final Widget icon = _icons.buildNamed(
      context,
      name: iconName,
      width: iconSize,
      height: iconSize,
      color: iconColor,
    );

    final defaultSize = _number(headerStyle['avatarSize']) ?? 42.0;
    final defaultRadius = _number(headerStyle['avatarRadius']) ?? 14.0;
    final width = _number(style['width']) ?? defaultSize;
    final height = _number(style['height']) ?? defaultSize;
    final radius = _number(style['borderRadius']) ?? defaultRadius;
    final background = style['background']?.toString();

    Color? fallbackBg;
    BoxBorder? fallbackBorder;
    if (background == null) {
      if (isActive) {
        final accent =
            _cssColor(state.theme['accent']) ?? Theme.of(context).colorScheme.primary;
        fallbackBg = accent.withValues(alpha: 0.12);
        fallbackBorder = Border.all(
          color: accent.withValues(alpha: 0.4),
          width: 1.2,
        );
      } else {
        fallbackBg = Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.4);
        fallbackBorder = Border.all(
          color: Colors.grey.withValues(alpha: 0.18),
          width: 1.0,
        );
      }
    }

    final visual = Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _cssColor(background) ?? fallbackBg,
        gradient: _gradient(background),
        borderRadius: BorderRadius.circular(radius),
        border: fallbackBorder,
        boxShadow: _boxShadowList(style['boxShadow']),
      ),
      child: icon,
    );

    final enabled = tapAction != null && state.canExecuteAction(tapAction);
    if (!enabled) return visual;

    return Semantics(
      button: true,
      label:
          action['ariaLabel']?.toString() ??
          action['label']?.toString() ??
          action['title']?.toString(),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => state.executeAction(tapAction),
        child: visual,
      ),
    );
  }

  Widget _buildComponent(BuildContext context, Map<String, dynamic> component) {
    switch (component['type']?.toString()) {
      case 'summaryCard':
        return _buildSummaryCard(context, component);
      case 'deviceGrid':
        return _buildDeviceGrid(context, component);
      default:
        return _schemaError(
          context,
          'Unsupported IoT component type: ${component['type']}',
        );
    }
  }

  Widget _buildSummaryCard(
    BuildContext context,
    Map<String, dynamic> component,
  ) {
    final style = _map(component['style']) ?? const <String, dynamic>{};
    final layout = _map(component['layout']) ?? const <String, dynamic>{};
    final padding = _edgeInsets(style['padding']) ?? EdgeInsets.zero;
    final radius = _number(style['borderRadius']);
    final marginBottom = _number(style['marginBottom']) ?? 0.0;
    final gap = _number(style['gap']) ?? 0.0;

    final zones = component['zones'];
    if (zones is! List) {
      return _schemaError(context, 'summaryCard.zones[]');
    }

    final children = <Widget>[];
    for (final raw in zones) {
      final zone = _map(raw);
      if (zone != null) {
        children.add(Expanded(child: _buildSummaryZone(context, zone)));
      }
    }

    return Padding(
      padding: EdgeInsets.only(bottom: marginBottom),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: _cssColor(style['background']),
          borderRadius: radius == null ? null : BorderRadius.circular(radius),
          boxShadow: _boxShadowList(style['shadow']),
        ),
        child: Row(
          mainAxisAlignment: _mainAxis(layout['justify']),
          crossAxisAlignment: _crossAxis(layout['align']),
          children: _horizontalGap(children, gap),
        ),
      ),
    );
  }

  Widget _buildSummaryZone(BuildContext context, Map<String, dynamic> zone) {
    final fields = zone['fields'];
    if (fields is! List) {
      return _schemaError(context, 'summaryCard.zones[].fields[]');
    }

    final children = <Widget>[];
    for (final raw in fields) {
      final field = _map(raw);
      if (field != null) {
        children.add(_buildSummaryField(context, field));
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: zone['id']?.toString() == 'right'
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildSummaryField(BuildContext context, Map<String, dynamic> field) {
    switch (field['type']?.toString()) {
      case 'text':
        final value = field.containsKey('bind')
            ? state.readBinding(field['bind'].toString())
            : field['value'];
        return Text(
          _clean(value),
          style: _textStyle(
            context,
            typographyName: field['typography']?.toString(),
          ),
        );

      case 'metric':
        final value = field.containsKey('bind')
            ? state.readBinding(field['bind'].toString())
            : field['value'];
        final suffix = field['suffix']?.toString() ?? '';
        final fallback = field['fallback']?.toString() ?? '';
        return Text(
          value == null
              ? fallback
              : '${_clean(value)}${suffix.isEmpty ? '' : ' $suffix'}',
          style: _textStyle(
            context,
            typographyName: field['typography']?.toString(),
          ),
        );

      case 'icon':
        final iconName = field['icon']?.toString();
        final container = _map(field['container']) ?? const <String, dynamic>{};
        if (iconName == null || iconName.isEmpty) {
          return _schemaError(context, 'summaryCard icon field.icon');
        }

        final width = _number(container['width']);
        final height = _number(container['height']);
        final radius = _number(container['borderRadius']);
        final color =
            _cssColor(container['color']) ??
            Theme.of(context).colorScheme.onSurface;

        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: _cssColor(container['background']),
            gradient: _gradient(container['background']?.toString()),
            borderRadius: radius == null ? null : BorderRadius.circular(radius),
          ),
          child: Center(
            child: _icons.buildNamed(context, name: iconName, color: color),
          ),
        );

      default:
        return _schemaError(
          context,
          'Unsupported summary field type: ${field['type']}',
        );
    }
  }

  Widget _buildDeviceGrid(BuildContext context, Map<String, dynamic> grid) {
    final canonicalGrid = _findComponentByType(state.schema, 'deviceGrid');

    final rootLayout =
        _findMapByKey(state.schema, 'layout') ?? const <String, dynamic>{};

    final rootGrid =
        _map(rootLayout['grid']) ??
        _findNamedGridLayout(state.schema) ??
        const <String, dynamic>{};

    final devices = List<Map<String, dynamic>>.from(state.filteredDevices);
    final sort =
        grid['sort']?.toString() ?? state.theme['deviceSort']?.toString();

    if (sort == 'onlineFirst') {
      devices.sort((a, b) {
        final aa = a['online'] == true ? 1 : 0;
        final bb = b['online'] == true ? 1 : 0;
        return bb.compareTo(aa);
      });
    }

    final schemaRuntime = SchemaRuntime(state.schema);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Resolve responsiveLayout / responsiveOverrides dynamically against
        // the actual logical viewport width (screen width) rather than nested/padded
        // inner width, matching lib/sdui/renderer.dart line 431.
        final mediaWidth =
            MediaQuery.maybeSizeOf(context)?.width ?? constraints.maxWidth;
        final responsiveGrid = schemaRuntime.resolveResponsiveMap(
          grid,
          mediaWidth,
          logicalHeight:
              constraints.maxHeight.isFinite ? constraints.maxHeight : null,
        );

        int? columns =
            _int(responsiveGrid['columns']) ??
            _int(grid['columns']) ??
            _int(canonicalGrid?['columns']) ??
            _int(rootGrid['columns']);

        // Universal smartphone safeguard: On smartphone screens (mediaWidth < 600),
        // ensure the IoT device grid renders the 2-column dashboard layout if
        // the base or canonical schema specifies 2 columns.
        if (columns == 1 && mediaWidth >= 320.0 && mediaWidth < 600.0) {
          final baseCols = _int(grid['columns']) ??
              _int(canonicalGrid?['columns']) ??
              _int(rootGrid['columns']);
          if (baseCols != null && baseCols >= 2) {
            columns = baseCols;
          }
        }

        if (columns == null || columns <= 0) {
          return _schemaError(
            context,
            'deviceGrid.columns / layout.grid.columns',
          );
        }

        final declaredGap =
            _number(responsiveGrid['gap']) ??
            _number(grid['gap']) ??
            _number(canonicalGrid?['gap']) ??
            _number(rootGrid['gap']) ??
            _number(state.theme['gridGap']);
        final gap = declaredGap ?? 0.0;

        final deviceCount = devices.length;
        if (deviceCount == 0) {
          if (state.isSearchVisible && state.searchQuery.trim().isNotEmpty) {
            return _buildEmptySearchState(context, state.searchQuery.trim());
          }
          return const SizedBox.shrink();
        }

        // Render in symmetric rows with IntrinsicHeight so all cards in a row
        // share uniform vertical balance without jagged heights.
        final rows = <Widget>[];
        for (var i = 0; i < deviceCount; i += columns) {
          if (i > 0) {
            rows.add(SizedBox(height: gap));
          }

          final rowCards = <Widget>[];
          for (var j = 0; j < columns; j++) {
            if (j > 0) {
              rowCards.add(SizedBox(width: gap));
            }
            final index = i + j;
            if (index < deviceCount) {
              rowCards.add(
                Expanded(
                  child: _buildDeviceCard(
                    context,
                    responsiveGrid,
                    devices[index],
                  ),
                ),
              );
            } else {
              rowCards.add(const Expanded(child: SizedBox.shrink()));
            }
          }

          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rowCards,
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        );
      },
    );
  }

  Widget _buildDeviceCard(
    BuildContext context,
    Map<String, dynamic> grid,
    Map<String, dynamic> device,
  ) {
    final card = _map(grid['card']);
    if (card == null) {
      return _schemaError(context, 'deviceGrid.card');
    }

    final online = device['online'] == true;
    final states = _map(card['states']);
    final stateStyle =
        _map(states?[online ? 'online' : 'offline']) ??
        const <String, dynamic>{};

    final rootCard = _map(_map(state.schema['layout'])?['card']);

    final minHeight =
        _number(card['minHeight']) ?? _number(rootCard?['minHeight']);
    final radius =
        _number(card['borderRadius']) ?? _number(state.theme['cardRadius']);
    final padding =
        _edgeInsets(card['padding']) ??
        _edgeInsets(rootCard?['padding']) ??
        EdgeInsets.zero;

    final background =
        _cssColor(stateStyle['background']) ??
        _cssColor(state.theme[online ? 'surfaceOnline' : 'surfaceOffline']);

    final foreground =
        _cssColor(stateStyle['color']) ??
        _cssColor(state.theme[online ? 'textOnDark' : 'textPrimary']) ??
        Theme.of(context).colorScheme.onSurface;

    final zones = card['zones'];
    final fieldMap = _map(card['fields']);
    final declaredFieldList = card['fields'] is List
        ? List<dynamic>.from(card['fields'] as List)
        : null;

    final children = <Widget>[];

    if (zones is List && fieldMap != null) {
      // Rich presentation contract: render exactly the declared zones and
      // typed field definitions.
      for (final raw in zones) {
        final zone = _map(raw);
        if (zone != null) {
          children.add(
            _buildCardZone(
              context,
              zone: zone,
              fields: fieldMap,
              device: device,
              online: online,
              foreground: foreground,
              stateStyle: stateStyle,
            ),
          );
        }
      }
    } else if (declaredFieldList != null) {
      // Minimal declarative contract: the schema still explicitly tells us
      // which device properties belong on the card. Render those values with
      // neutral framework presentation; do not guess product-specific layout.
      children.add(
        _buildDeclaredFieldList(
          context,
          fieldIds: declaredFieldList,
          device: device,
          foreground: foreground,
        ),
      );

      logDebug(
        '[IOT_SDUI][CARD] minimal declared-fields contract '
        'fields=${declaredFieldList.join(",")}',
      );
    } else {
      return _schemaError(
        context,
        'deviceGrid.card.fields[] or card.zones[] + card.fields{}',
      );
    }

    Widget body = Container(
      constraints: minHeight == null
          ? null
          : BoxConstraints(minHeight: minHeight),
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius == null ? null : BorderRadius.circular(radius),
        border: _border(stateStyle['border']),
        boxShadow: _boxShadowList(stateStyle['shadow']),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );

    final onTap = _map(card['onTap']);
    if (card['clickable'] == true &&
        onTap != null &&
        state.canExecuteAction(onTap, device: device)) {
      body = InkWell(
        borderRadius: radius == null ? null : BorderRadius.circular(radius),
        onTap: () async {
          // If the schema explicitly owns navigation, execute its sequence as
          // published. Otherwise keep the legacy cardClick event, but do not
          // block Device SDUI navigation on that optional network request.
          if (state.actionRequestsOpenDevice(onTap)) {
            await state.executeAction(onTap, device: device);
            return;
          }

          unawaited(state.executeAction(onTap, device: device));
          if (state.canOpenDevice(device)) {
            await state.openDevice(device);
          }
        },
        child: body,
      );
    }

    return body;
  }

  Widget _buildDeclaredFieldList(
    BuildContext context, {
    required List<dynamic> fieldIds,
    required Map<String, dynamic> device,
    required Color foreground,
  }) {
    final widgets = <Widget>[];

    for (final rawId in fieldIds) {
      final id = rawId?.toString().trim() ?? '';
      if (id.isEmpty || !device.containsKey(id)) {
        continue;
      }

      final value = device[id];
      if (value == null) {
        continue;
      }

      // This is deliberately type-driven rather than name-driven. No device,
      // brand, field-name, or schema-version mapping is hardcoded.
      if (value is bool) {
        widgets.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  id,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: foreground),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                value
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
                size: 16,
                color: foreground,
              ),
            ],
          ),
        );
        continue;
      }

      final rawText = value.toString().trim();
      if (rawText.isEmpty || rawText.toUpperCase() == 'NULL') {
        continue;
      }

      final uri = Uri.tryParse(rawText);
      final looksLikeNetworkImage =
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          RegExp(
            r'\.(png|jpe?g|webp|gif|bmp|svg)(?:$|\?)',
            caseSensitive: false,
          ).hasMatch(uri.path);

      if (looksLikeNetworkImage) {
        widgets.add(
          CachedNetworkImage(
            imageUrl: rawText,
            cacheManager: SduiNetworkImageCache.manager,
            fit: BoxFit.contain,
            placeholder: (_, __) => const SizedBox(
              width: 40,
              height: 40,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            errorWidget: (_, __, ___) => const SizedBox.shrink(),
          ),
        );
        continue;
      }

      widgets.add(
        Text(
          rawText,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: foreground),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _verticalGap(widgets, 0.0),
    );
  }

  Widget _buildCardZone(
    BuildContext context, {
    required Map<String, dynamic> zone,
    required Map<String, dynamic> fields,
    required Map<String, dynamic> device,
    required bool online,
    required Color foreground,
    required Map<String, dynamic> stateStyle,
  }) {
    final ids = zone['fields'];
    if (ids is! List) {
      return _schemaError(context, 'card.zones[].fields[]');
    }

    final widgets = <Widget>[];
    for (final rawId in ids) {
      final id = rawId.toString();
      final field = _map(fields[id]);
      if (field == null) {
        widgets.add(_schemaError(context, 'card.fields.$id'));
        continue;
      }

      if (field.containsKey('showWhen') &&
          !state.resolveCondition(
            field['showWhen'],
            device: device,
            fallback: false,
          )) {
        continue;
      }

      widgets.add(
        _buildCardField(
          context,
          id: id,
          field: field,
          device: device,
          online: online,
          foreground: foreground,
          stateStyle: stateStyle,
        ),
      );
    }

    final layout = _map(zone['layout']) ?? const <String, dynamic>{};
    final layoutType = layout['type']?.toString().toLowerCase() ?? 'column';
    final gap = _number(zone['gap']) ?? 0.0;

    Widget content = layoutType == 'row'
        ? Row(
            mainAxisAlignment: _mainAxis(layout['justify']),
            crossAxisAlignment: _crossAxis(layout['align']),
            children: _horizontalGap(widgets, gap),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: _crossAxis(layout['align']),
            children: _verticalGap(widgets, gap),
          );

    final top = _number(zone['paddingTop']) ?? 0.0;
    final bottom =
        (_number(zone['paddingBottom']) ?? 0.0) +
        (_number(zone['marginBottom']) ?? 0.0);
    final minHeight = _number(zone['minHeight']);

    if (minHeight != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: content,
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: top, bottom: bottom),
      child: content,
    );
  }

  Widget _buildCardField(
    BuildContext context, {
    required String id,
    required Map<String, dynamic> field,
    required Map<String, dynamic> device,
    required bool online,
    required Color foreground,
    required Map<String, dynamic> stateStyle,
  }) {
    switch (field['type']?.toString()) {
      case 'image':
        return _buildImageField(
          context,
          id: id,
          field: field,
          device: device,
          online: online,
          foreground: foreground,
          stateStyle: stateStyle,
        );
      case 'svg':
        return _buildSvgField(context, field: field, online: online);
      case 'deviceIcon':
        return _buildDeviceIconField(
          context,
          id: id,
          field: field,
          device: device,
          online: online,
          foreground: foreground,
          stateStyle: stateStyle,
        );
      case 'icon':
        return _buildIconField(
          context,
          id: id,
          field: field,
          device: device,
          online: online,
          foreground: foreground,
        );
      case 'text':
        dynamic sourceValue;
        if (field.containsKey('bindPower')) {
          final powerValue =
              state.resolveTemplate(field['bindPower'], device: device) == true;
          sourceValue = powerValue
              ? field['valueOnline']
              : field['valueOffline'];
        } else if (online && field.containsKey('valueOnline')) {
          sourceValue = field['valueOnline'];
        } else if (!online && field.containsKey('valueOffline')) {
          sourceValue = field['valueOffline'];
        } else {
          sourceValue = field['value'];
        }

        final value = state.resolveTemplate(sourceValue, device: device);
        return Text(
          _clean(value),
          maxLines: _lineClamp(field),
          overflow: TextOverflow.ellipsis,
          style: _textStyle(
            context,
            typographyName: field['typography']?.toString(),
            online: online,
            fallbackColor: foreground,
          ),
        );
      case 'status':
        return _buildStatusField(
          context,
          field: field,
          device: device,
          online: online,
          foreground: foreground,
        );
      case 'toggle':
        return _buildToggleField(
          context,
          field: field,
          device: device,
          online: online,
        );
      default:
        return _schemaError(
          context,
          'Unsupported card field type for $id: ${field['type']}',
        );
    }
  }

  Widget _buildImageField(
    BuildContext context, {
    required String id,
    required Map<String, dynamic> field,
    required Map<String, dynamic> device,
    required bool online,
    required Color foreground,
    required Map<String, dynamic> stateStyle,
  }) {
    final src =
        state.resolveTemplate(field['src'], device: device)?.toString() ?? '';
    final width = _number(field['width']);
    final height = _number(field['height']);
    final radius = _number(field['borderRadius']);
    final fit = _boxFit(field['objectFit']?.toString());

    final container = _map(field['container']);
    final containerState = _map(container?[online ? 'online' : 'offline']);

    final containerWidth = _number(container?['width']) ?? width;
    final containerHeight = _number(container?['height']) ?? height;
    final containerRadius = _number(container?['borderRadius']) ?? radius;

    Widget renderFallbackDescriptor(Map<String, dynamic> fallback) {
      final type = fallback['type']?.toString().trim();

      if (type == 'deviceIcon') {
        final iconSize = _number(fallback['iconSize']);
        if (iconSize == null) {
          return _schemaError(context, 'card.fields.$id fallback iconSize');
        }

        final matchValue = _resolveDeviceFallbackValue(
          device,
          fallback['resolveFrom']?.toString(),
        );

        final declaredStroke = _cssColor(
          fallback[online ? 'strokeOnline' : 'strokeOffline'],
        );

        // Prefer an explicitly declared schema stroke. If omitted, use the
        // already-resolved card foreground (schema theme textOnDark/textPrimary).
        // Do not invent contrast whites/greys in the client.
        final resolvedIconColor = declaredStroke ?? foreground;

        return _icons.buildForDevice(
          context,
          device: device,
          matchValue: matchValue,
          size: iconSize,
          color: resolvedIconColor,
        );
      }

      if (type == 'initial') {
        final source = _resolveDeviceFallbackValue(
          device,
          fallback['resolveFrom']?.toString(),
        );

        final cleaned = _clean(source);
        final initial = cleaned.isEmpty
            ? ''
            : cleaned.characters.first.toUpperCase();

        return Center(
          child: Text(
            initial,
            style: _textStyle(
              context,
              inline: _map(fallback['typography']),
              fallbackColor: foreground,
            ),
          ),
        );
      }

      return const SizedBox.shrink();
    }

    Widget fallback() {
      // New schema contract supports an ordered fallback chain.
      final chain = field['fallbackChain'];
      if (chain is List) {
        for (final raw in chain) {
          final descriptor = _map(raw);
          if (descriptor == null) continue;

          final type = descriptor['type']?.toString().trim();
          if (type == 'deviceIcon') {
            return renderFallbackDescriptor(descriptor);
          }

          if (type == 'initial') {
            final value = _resolveDeviceFallbackValue(
              device,
              descriptor['resolveFrom']?.toString(),
            );
            if (_clean(value).isNotEmpty) {
              return renderFallbackDescriptor(descriptor);
            }
          }
        }
      }

      final rawFallback = field['fallback'];

      if (rawFallback == 'initial') {
        final brand = _resolveDeviceFallbackValue(
          device,
          'brand_name|brandName',
        );

        final cleaned = _clean(brand);
        final initial = cleaned.isEmpty
            ? ''
            : cleaned.characters.first.toUpperCase();

        return Center(
          child: Text(
            initial,
            style: _textStyle(
              context,
              inline: _map(field['fallbackTypography']),
              fallbackColor: foreground,
            ),
          ),
        );
      }

      final descriptor = _map(rawFallback);
      if (descriptor != null) {
        return renderFallbackDescriptor(descriptor);
      }

      // Device records in the 2.2.1 schema may already contain a completely
      // resolved SVG even when no explicit field fallback object is present.
      if (_map(device['resolvedIcon']) != null ||
          device['resolvedIconSvg']?.toString().trim().isNotEmpty == true) {
        final size =
            _number(field['height']) ?? _number(field['width']) ?? 24.0;

        final matchValue = _resolveDeviceFallbackValue(
          device,
          'device_type|product_name|brand_name',
        );

        return _icons.buildForDevice(
          context,
          device: device,
          matchValue: matchValue,
          size: size,
          color: foreground,
        );
      }

      return const SizedBox.shrink();
    }

    Widget image;
    if (src.isEmpty || src.toUpperCase() == 'NULL') {
      image = fallback();
    } else {
      final uri = state.resolveUrl(src);
      if (uri != null && (uri.host == 'localhost' || uri.host == '127.0.0.1')) {
        image = _schemaError(context, 'Image URL uses localhost');
      } else {
        // Current IoT schemas can explicitly declare logical dimensions.
        // In that mode numeric schema sizes are already Flutter logical pixels
        // and must not be multiplied by the legacy 375px screen scale.
        final schemaRuntime = SchemaRuntime(state.schema);
        final responsive = schemaRuntime.responsive;
        final scaleLegacyDimensions =
            responsive?['scaleLegacyDimensions'] != false &&
            !schemaRuntime.usesLogicalDimensions;
        final r = scaleLegacyDimensions ? ResponsiveUtil.of(context) : null;
        final scaledWidth = width == null
            ? null
            : (r == null ? width : r.scale(width));
        final scaledHeight = height == null
            ? null
            : (r == null ? height : r.scale(height));
        image = CachedNetworkImage(
          imageUrl: uri?.toString() ?? src,
          cacheManager: SduiNetworkImageCache.manager,
          width: scaledWidth,
          height: scaledHeight,
          fit: fit,
          placeholder: (_, __) => SizedBox(
            width: scaledWidth,
            height: scaledHeight,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          errorWidget: (_, __, ___) => fallback(),
        );
      }
    }

    final imageOpacity = (_number(stateStyle['imageOpacity']) ?? 1.0)
        .clamp(0.0, 1.0)
        .toDouble();
    final grayscale = _grayscale(stateStyle['imageFilter']?.toString());

    if (grayscale != null && grayscale > 0) {
      image = ColorFiltered(
        colorFilter: ColorFilter.matrix(_grayscaleMatrix(grayscale)),
        child: image,
      );
    }
    if (imageOpacity != 1.0) {
      image = Opacity(opacity: imageOpacity, child: image);
    }

    Widget result = Center(child: image);
    if (containerWidth != null || containerHeight != null) {
      result = SizedBox(
        width: containerWidth,
        height: containerHeight,
        child: result,
      );
    }
    if (radius != null) {
      result = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: result,
      );
    }
    if (container != null) {
      result = Container(
        width: containerWidth,
        height: containerHeight,
        decoration: BoxDecoration(
          color: _cssColor(containerState?['background']),
          borderRadius: containerRadius == null
              ? null
              : BorderRadius.circular(containerRadius),
          border: _border(containerState?['border']),
        ),
        child: result,
      );
    }

    return result;
  }

  String _resolveDeviceFallbackValue(
    Map<String, dynamic> device,
    String? expression,
  ) {
    final raw = expression?.trim() ?? '';
    if (raw.isEmpty) return '';

    // Schema uses pipe-separated candidate properties, e.g.
    // device_type|product_name|brand_name.
    for (final candidateRaw in raw.split('|')) {
      var candidate = candidateRaw.trim();
      if (candidate.startsWith('device.')) {
        candidate = candidate.substring('device.'.length);
      }

      if (candidate.isEmpty) continue;

      final value = device[candidate];
      final cleaned = _clean(value);

      if (cleaned.isNotEmpty) {
        return cleaned;
      }
    }

    return '';
  }

  Widget _buildSvgField(
    BuildContext context, {
    required Map<String, dynamic> field,
    required bool online,
  }) {
    final size = _number(field['containerSize']);
    final iconSize = _number(field['iconSize']);
    final color =
        _cssColor(field[online ? 'colorOnline' : 'colorOffline']) ??
        Theme.of(context).colorScheme.onSurface;
    final opacity = _number(field[online ? 'opacityOnline' : 'opacityOffline']);

    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: _icons.buildDefinition(
          context,
          definition: field,
          width: iconSize,
          height: iconSize,
          color: color,
          opacity: opacity,
        ),
      ),
    );
  }

  Widget _buildDeviceIconField(
    BuildContext context, {
    required String id,
    required Map<String, dynamic> field,
    required Map<String, dynamic> device,
    required bool online,
    required Color foreground,
    required Map<String, dynamic> stateStyle,
  }) {
    final iconSize = _number(field['iconSize']) ?? 24.0;
    final matchValue = _resolveDeviceFallbackValue(
      device,
      field['resolveFrom']?.toString(),
    );

    final declaredStroke = _cssColor(
      field[online ? 'strokeOnline' : 'strokeOffline'],
    ) ?? _cssColor(field['color']);

    final resolvedIconColor = declaredStroke ?? foreground;

    Widget icon = _icons.buildForDevice(
      context,
      device: device,
      matchValue: matchValue,
      size: iconSize,
      color: resolvedIconColor,
    );

    final container = _map(field['container']);
    if (container != null) {
      final containerWidth = _number(container['width']);
      final containerHeight = _number(container['height']);
      final containerRadius = _number(container['borderRadius']);
      final containerState = _map(container[online ? 'online' : 'offline']);
      final bg = containerState?['background'] ?? container['background'];
      final border = containerState?['border'] ?? container['border'];

      icon = Container(
        width: containerWidth,
        height: containerHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _cssColor(bg),
          borderRadius: containerRadius == null
              ? null
              : BorderRadius.circular(containerRadius),
          border: _border(border),
        ),
        child: icon,
      );
    }

    return Center(child: icon);
  }

  Widget _buildIconField(
    BuildContext context, {
    required String id,
    required Map<String, dynamic> field,
    required Map<String, dynamic> device,
    required bool online,
    required Color foreground,
  }) {
    final iconName =
        field['name']?.toString() ?? field['icon']?.toString() ?? '';
    final iconSize =
        _number(field['size']) ?? _number(field['iconSize']) ?? 24.0;
    final declaredColor = _cssColor(
      field[online ? 'strokeOnline' : 'strokeOffline'],
    ) ?? _cssColor(field['color']);
    final resolvedColor = declaredColor ?? foreground;

    Widget icon = _icons.buildNamed(
      context,
      name: iconName,
      width: iconSize,
      height: iconSize,
      color: resolvedColor,
    );

    final container = _map(field['container']);
    if (container != null) {
      final containerWidth = _number(container['width']);
      final containerHeight = _number(container['height']);
      final containerRadius = _number(container['borderRadius']);
      final containerState = _map(container[online ? 'online' : 'offline']);
      final bg = containerState?['background'] ?? container['background'];
      final border = containerState?['border'] ?? container['border'];

      icon = Container(
        width: containerWidth,
        height: containerHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _cssColor(bg),
          borderRadius: containerRadius == null
              ? null
              : BorderRadius.circular(containerRadius),
          border: _border(border),
        ),
        child: icon,
      );
    }

    return Center(child: icon);
  }

  Widget _buildStatusField(
    BuildContext context, {
    required Map<String, dynamic> field,
    required Map<String, dynamic> device,
    required bool online,
    required Color foreground,
  }) {
    final dot = _map(field['dot']);
    final dotState = _map(dot?[online ? 'online' : 'offline']);
    final diameter = _number(dot?['diameter']);
    final radius = _number(dot?['borderRadius']);

    if (diameter == null) {
      return _schemaError(context, 'statusPill.dot.diameter');
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            color: _cssColor(dotState?['color']),
            borderRadius: BorderRadius.circular(radius ?? diameter / 2),
            boxShadow: _boxShadowList(dotState?['glow']),
          ),
        ),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            _clean(state.resolveTemplate(field['value'], device: device)),
            style: _textStyle(
              context,
              typographyName: field['typography']?.toString(),
              online: online,
              fallbackColor: foreground,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToggleField(
    BuildContext context, {
    required Map<String, dynamic> field,
    required Map<String, dynamic> device,
    required bool online,
  }) {
    final width = _number(field['width']);
    final height = _number(field['height']);
    final radius = _number(field['borderRadius']);
    final thumb = _map(field['thumb']);
    final track = _map(field['track']);
    final thumbColors = _map(field['thumbColors']);

    // Prefer the action contract declared by the IoT UI schema. If the UI
    // field does not declare one, use the action contract returned with the
    // live device record at device.actions.onPowerToggle. This remains fully
    // server-driven: Flutter does not hardcode any URL, node id, command, or
    // model value.
    final schemaOnTap = _map(field['onTap']);
    final deviceActions = _map(device['actions']);
    final deviceOnPowerToggle = _map(deviceActions?['onPowerToggle']);
    final onTap = schemaOnTap ?? deviceOnPowerToggle;

    final thumbDiameter = _number(thumb?['diameter']);
    final offset = _number(thumb?['offset']);
    final translateXOn = _number(thumb?['translateXOn']);

    if (width == null ||
        height == null ||
        radius == null ||
        thumbDiameter == null ||
        offset == null ||
        translateXOn == null) {
      return _schemaError(
        context,
        'powerToggle width/height/borderRadius/thumb geometry',
      );
    }

    final power = state.resolveTemplate(field['bind'], device: device) == true;

    final enabledBySchema = state.resolveCondition(
      field['enabledWhen'],
      device: device,
      fallback: false,
    );

    final executable =
        onTap != null && state.canExecuteAction(onTap, device: device);
    final enabled = enabledBySchema && executable;

    logDebug(
      '[IOT_SDUI][POWER_TOGGLE] '
      'device=${device['node_id'] ?? device['id'] ?? '-'} '
      'online=$online power=$power '
      'enabledBySchema=$enabledBySchema '
      'actionSource=${schemaOnTap != null
          ? 'schema-field'
          : deviceOnPowerToggle != null
          ? 'device-action'
          : 'none'} '
      'executable=$executable enabled=$enabled',
    );

    Map<String, dynamic>? trackState;
    String thumbKey;

    if (!online) {
      trackState = _map(track?['offline']);
      thumbKey = power ? 'offlineOn' : 'offlineOff';
    } else if (power) {
      trackState = _map(track?['onlineOn']);
      thumbKey = 'onlineOn';
    } else {
      trackState = _map(track?['onlineOff']);
      thumbKey = 'onlineOff';
    }

    final toggle = SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _cssColor(trackState?['background']),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Stack(
          children: <Widget>[
            AnimatedPositioned(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              left: offset + (power ? translateXOn : 0.0),
              top: (height - thumbDiameter) / 2,
              child: Container(
                width: thumbDiameter,
                height: thumbDiameter,
                decoration: BoxDecoration(
                  color: _cssColor(thumbColors?[thumbKey]),
                  shape: BoxShape.circle,
                  boxShadow: _boxShadowList(thumb?['shadow']),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (!enabled) {
      return Opacity(opacity: 0.82, child: toggle);
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        logDebug(
          '[IOT_SDUI][POWER_TOGGLE][TAP] '
          'device=${device['node_id'] ?? device['id'] ?? '-'} '
          'from=$power to=${!power}',
        );

        final result = await state.executeAction(
          onTap,
          device: device,
          event: <String, dynamic>{
            'value': !power,
            'toggle_state': !power,
            'toggle_next': !power,
          },
        );

        logDebug(
          '[IOT_SDUI][POWER_TOGGLE][RESULT] '
          'device=${device['node_id'] ?? device['id'] ?? '-'} '
          'resultType=${result?.runtimeType ?? 'null'} '
          'error=${state.lastError ?? '-'}',
        );

        // Re-read the server state after a successful command instead of
        // inventing the new power state locally in Flutter.
        if (state.lastError == null) {
          await state.refreshDeviceGrid();
        }
      },
      child: toggle,
    );
  }

  TextStyle _textStyle(
    BuildContext context, {
    String? typographyName,
    Map<String, dynamic>? inline,
    bool? online,
    Color? fallbackColor,
  }) {
    final base =
        state.typographyStyle(typographyName) ?? const <String, dynamic>{};

    final merged = <String, dynamic>{...base, if (inline != null) ...inline};

    dynamic colorValue = merged['color'];
    if (online != null) {
      colorValue =
          merged[online ? 'colorOnline' : 'colorOffline'] ?? colorValue;
    }

    return TextStyle(
      color:
          _cssColor(colorValue) ??
          fallbackColor ??
          Theme.of(context).colorScheme.onSurface,
      fontSize: _number(merged['fontSize']),
      fontWeight: _fontWeight(merged['fontWeight']),
      height: _number(merged['lineHeight']),
      letterSpacing: _number(merged['letterSpacing']),
      fontFamily: _fontFamily(state.theme['fontFamily']),
    );
  }

  int? _lineClamp(Map<String, dynamic> field) {
    final direct = _int(field['lineClamp']);
    if (direct != null) return direct;
    return _int(
      state.typographyStyle(field['typography']?.toString())?['lineClamp'],
    );
  }

  EdgeInsets _pagePadding(
    Map<String, dynamic> page, {
    Map<String, dynamic>? layout,
  }) {
    final direct = _edgeInsets(page['padding']);
    if (direct != null) return direct;
    final resolvedLayout = layout ?? _map(state.schema['layout']);
    return _edgeInsets(resolvedLayout?['pagePadding']) ?? EdgeInsets.zero;
  }

  Widget _runtimeError(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        message,
        style: TextStyle(
          color:
              _cssColor(state.theme['danger']) ??
              Theme.of(context).colorScheme.error,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _schemaError(BuildContext context, String path) {
    return SchemaIssueWidget(
      title: 'IoT schema error',
      details: [path],
    );
  }

  String _clean(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.toUpperCase() == 'NULL' ? '' : text;
  }

  List<Widget> _horizontalGap(List<Widget> children, double gap) {
    if (children.length < 2 || gap <= 0) return children;
    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) result.add(SizedBox(width: gap));
      result.add(children[i]);
    }
    return result;
  }

  List<Widget> _verticalGap(List<Widget> children, double gap) {
    if (children.length < 2 || gap <= 0) return children;
    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) result.add(SizedBox(height: gap));
      result.add(children[i]);
    }
    return result;
  }

  MainAxisAlignment _mainAxis(dynamic raw) {
    switch (raw?.toString()) {
      case 'center':
        return MainAxisAlignment.center;
      case 'end':
        return MainAxisAlignment.end;
      case 'space-between':
      case 'spaceBetween':
        return MainAxisAlignment.spaceBetween;
      case 'space-around':
      case 'spaceAround':
        return MainAxisAlignment.spaceAround;
      case 'space-evenly':
      case 'spaceEvenly':
        return MainAxisAlignment.spaceEvenly;
      default:
        return MainAxisAlignment.start;
    }
  }

  CrossAxisAlignment _crossAxis(dynamic raw) {
    switch (raw?.toString()) {
      case 'center':
        return CrossAxisAlignment.center;
      case 'end':
        return CrossAxisAlignment.end;
      case 'stretch':
        return CrossAxisAlignment.stretch;
      default:
        return CrossAxisAlignment.start;
    }
  }

  EdgeInsets? _edgeInsets(dynamic raw) {
    if (raw is num) return EdgeInsets.all(raw.toDouble());
    final map = _map(raw);
    if (map == null) return null;

    final horizontal = _number(map['horizontal']);
    final vertical = _number(map['vertical']);

    return EdgeInsets.fromLTRB(
      _number(map['left']) ?? horizontal ?? 0.0,
      _number(map['top']) ?? vertical ?? 0.0,
      _number(map['right']) ?? horizontal ?? 0.0,
      _number(map['bottom']) ?? vertical ?? 0.0,
    );
  }

  Color? _cssColor(dynamic raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;

    if (text.startsWith('#')) {
      var hex = text.substring(1);
      if (hex.length == 3) {
        hex = '${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
      }
      if (hex.length == 6) hex = 'FF$hex';
      if (hex.length != 8) return null;
      final value = int.tryParse(hex, radix: 16);
      return value == null ? null : Color(value);
    }

    final match = RegExp(r'rgba?\(([^)]+)\)').firstMatch(text);
    if (match != null) {
      final parts = match.group(1)!.split(',').map((e) => e.trim()).toList();
      if (parts.length >= 3) {
        final r = int.tryParse(parts[0]);
        final g = int.tryParse(parts[1]);
        final b = int.tryParse(parts[2]);
        final a = parts.length >= 4 ? double.tryParse(parts[3]) ?? 1.0 : 1.0;
        if (r != null && g != null && b != null) {
          return Color.fromRGBO(r, g, b, a.clamp(0.0, 1.0).toDouble());
        }
      }
    }

    return null;
  }

  LinearGradient? _gradient(String? raw) {
    if (raw == null || !raw.startsWith('linear-gradient(')) return null;

    final inner = raw
        .substring('linear-gradient('.length, raw.length - 1)
        .split(',')
        .map((e) => e.trim())
        .toList();

    if (inner.length < 3) return null;

    final angle = double.tryParse(inner.first.replaceAll('deg', '')) ?? 180.0;
    final colors = inner
        .skip(1)
        .map(_cssColor)
        .whereType<Color>()
        .toList(growable: false);
    if (colors.length < 2) return null;

    final radians = angle * math.pi / 180.0;
    final dx = math.sin(radians);
    final dy = -math.cos(radians);

    return LinearGradient(
      begin: Alignment(-dx, -dy),
      end: Alignment(dx, dy),
      colors: colors,
    );
  }

  Border? _border(dynamic raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;

    final match = RegExp(
      r'(\d+(?:\.\d+)?)px\s+\w+\s+(#[0-9a-fA-F]{3,8})',
    ).firstMatch(text);
    if (match == null) return null;

    final width = double.tryParse(match.group(1)!) ?? 0.0;
    final color = _cssColor(match.group(2));
    if (color == null) return null;

    return Border.all(color: color, width: width);
  }

  List<BoxShadow> _boxShadowList(dynamic raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty || text == 'none') {
      return const <BoxShadow>[];
    }

    final match = RegExp(
      r'(-?\d+(?:\.\d+)?)px\s+'
      r'(-?\d+(?:\.\d+)?)px\s+'
      r'(\d+(?:\.\d+)?)px'
      r'(?:\s+(-?\d+(?:\.\d+)?)px)?\s+'
      r'(rgba?\([^)]+\)|#[0-9a-fA-F]{3,8})',
    ).firstMatch(text);
    if (match == null) return const <BoxShadow>[];

    final color = _cssColor(match.group(5));
    if (color == null) return const <BoxShadow>[];

    return <BoxShadow>[
      BoxShadow(
        offset: Offset(
          double.tryParse(match.group(1)!) ?? 0.0,
          double.tryParse(match.group(2)!) ?? 0.0,
        ),
        blurRadius: double.tryParse(match.group(3)!) ?? 0.0,
        spreadRadius: double.tryParse(match.group(4) ?? '') ?? 0.0,
        color: color,
      ),
    ];
  }

  double? _grayscale(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'grayscale\(([\d.]+)\)').firstMatch(raw);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  List<double> _grayscaleMatrix(double amount) {
    final a = amount.clamp(0.0, 1.0).toDouble();
    final inv = 1.0 - a;
    return <double>[
      0.2126 + 0.7874 * inv,
      0.7152 - 0.7152 * inv,
      0.0722 - 0.0722 * inv,
      0,
      0,
      0.2126 - 0.2126 * inv,
      0.7152 + 0.2848 * inv,
      0.0722 - 0.0722 * inv,
      0,
      0,
      0.2126 - 0.2126 * inv,
      0.7152 - 0.7152 * inv,
      0.0722 + 0.9278 * inv,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  BoxFit _boxFit(String? raw) {
    switch (raw) {
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      case 'scaleDown':
        return BoxFit.scaleDown;
      default:
        return BoxFit.contain;
    }
  }

  FontWeight? _fontWeight(dynamic raw) {
    final value = _int(raw);
    if (value == null) return null;
    if (value >= 900) return FontWeight.w900;
    if (value >= 800) return FontWeight.w800;
    if (value >= 700) return FontWeight.w700;
    if (value >= 600) return FontWeight.w600;
    if (value >= 500) return FontWeight.w500;
    if (value >= 400) return FontWeight.w400;
    if (value >= 300) return FontWeight.w300;
    if (value >= 200) return FontWeight.w200;
    return FontWeight.w100;
  }

  String? _fontFamily(dynamic raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text.split(',').first.trim().replaceAll('"', '').replaceAll("'", '');
  }

  Map<String, dynamic>? _findComponentByType(
    dynamic value,
    String type, {
    int depth = 0,
  }) {
    if (value == null || depth > 12) return null;

    if (value is List) {
      for (final item in value) {
        final found = _findComponentByType(item, type, depth: depth + 1);
        if (found != null) return found;
      }
      return null;
    }

    final map = _map(value);
    if (map == null) return null;

    if (map['type']?.toString() == type) {
      return map;
    }

    // Search wrapper/schema/component structures dynamically instead of
    // assuming a particular schema version or nesting level.
    for (final child in map.values) {
      if (child is Map || child is List) {
        final found = _findComponentByType(child, type, depth: depth + 1);
        if (found != null) return found;
      }
    }

    return null;
  }

  Map<String, dynamic>? _findMapByKey(
    dynamic value,
    String key, {
    int depth = 0,
  }) {
    if (value == null || depth > 12) return null;

    if (value is List) {
      for (final item in value) {
        final found = _findMapByKey(item, key, depth: depth + 1);
        if (found != null) return found;
      }
      return null;
    }

    final map = _map(value);
    if (map == null) return null;

    final direct = _map(map[key]);
    if (direct != null) return direct;

    for (final child in map.values) {
      if (child is Map || child is List) {
        final found = _findMapByKey(child, key, depth: depth + 1);
        if (found != null) return found;
      }
    }

    return null;
  }

  Map<String, dynamic>? _findNamedGridLayout(dynamic value, {int depth = 0}) {
    if (value == null || depth > 12) return null;

    if (value is List) {
      for (final item in value) {
        final found = _findNamedGridLayout(item, depth: depth + 1);
        if (found != null) return found;
      }
      return null;
    }

    final map = _map(value);
    if (map == null) return null;

    final candidate = _map(map['grid']);
    if (candidate != null &&
        (_int(candidate['columns']) != null ||
            _number(candidate['gap']) != null)) {
      return candidate;
    }

    for (final child in map.values) {
      if (child is Map || child is List) {
        final found = _findNamedGridLayout(child, depth: depth + 1);
        if (found != null) return found;
      }
    }

    return null;
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  int? _int(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

class _IotSearchBarWidget extends StatefulWidget {
  const _IotSearchBarWidget({
    required this.state,
    required this.searchConfig,
    required this.icons,
  });

  final IotSduiState state;
  final Map<String, dynamic> searchConfig;
  final IotSchemaIcon icons;

  @override
  State<_IotSearchBarWidget> createState() => _IotSearchBarWidgetState();
}

class _IotSearchBarWidgetState extends State<_IotSearchBarWidget> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.state.searchQuery);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _IotSearchBarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state.searchQuery != _controller.text) {
      _controller.text = widget.state.searchQuery;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder =
        widget.searchConfig['placeholder']?.toString() ?? 'Search devices';
    final hasText = widget.state.searchQuery.isNotEmpty;

    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          widget.icons.buildNamed(
            context,
            name: 'search',
            width: 18,
            height: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: placeholder,
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w400,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: (val) {
                widget.state.setSearchQuery(val);
              },
            ),
          ),
          if (hasText)
            IconButton(
              icon: Icon(
                Icons.cancel_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              splashRadius: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () {
                _controller.clear();
                widget.state.clearSearchQuery();
              },
            ),
        ],
      ),
    );
  }
}

