import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../home_sdui/home_icon_resolver.dart';
import '../sdui/schema_guard.dart';
import '../sdui/sdui_network_image_cache.dart';
import 'grid_sdui_state.dart';

class GridSduiRenderer {
  GridSduiRenderer(this.state) : icons = HomeIconResolver(state.schema);

  final GridSduiState state;
  final HomeIconResolver icons;

  Widget buildRoot(BuildContext context) {
    final rootId = state.rootComponentId;
    if (rootId.isEmpty) {
      return const Center(
          child: Text('Grid schema rootComponentId is missing.'));
    }
    return buildComponent(context, rootId);
  }

  Widget buildComponent(BuildContext context, String id) {
    final component = state.component(id);
    if (component == null) {
      return _error('Missing Grid component "$id".');
    }
    return buildNode(context, component);
  }

  Widget buildNode(BuildContext context, Map<String, dynamic> component) {
    final type = component['type']?.toString();
    return switch (type) {
      'scrollPage' => _scrollPage(context, component),
      'pageHeader' => _pageHeader(context, component),
      'responsiveGrid' => _responsiveGrid(context, component),
      'featureCard' => _featureCard(context, component),
      'statusSummary' => _statusSummary(context, component),
      'shareQrCard' => _shareQrCard(context, component),
      'section' => _section(context, component),
      'exploreCard' => _exploreCard(context, component),
      'quoteBlock' => _quoteBlock(context, component),
      'skeleton' => const Center(child: CircularProgressIndicator()),
      'emptyState' => _messageState(component),
      'errorState' => _messageState(component),
      _ => _error('Unsupported Grid component type "$type".'),
    };
  }

  Widget _scrollPage(BuildContext context, Map<String, dynamic> c) {
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final bp = _breakpoint(context);
    final responsive = _map(_map(layout['responsive'])?[bp]) ?? layout;
    final padding = _paddingOrNull(responsive['padding'] ?? layout['padding']);
    final gap = _d(responsive['gap'] ?? layout['gap']);
    if (padding == null || gap == null) {
      return SchemaIssueWidget(
        title: 'Schema layout missing',
        details: const [
          'Provide layout.padding and layout.gap (or layout.responsive.<bp>.*)',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }
    final maxWidth = _d(responsive['maxWidth']);
    final children = c['children'];
    final widgets = <Widget>[];
    if (children is List) {
      for (final child in children) {
        if (child is String) widgets.add(buildComponent(context, child));
      }
    }

    Widget list = ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: padding,
      itemCount: widgets.length,
      separatorBuilder: (_, __) => SizedBox(height: gap),
      itemBuilder: (_, index) => widgets[index],
    );

    if (maxWidth != null && maxWidth > 0) {
      list = Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: list,
        ),
      );
    }
    return list;
  }

  Widget _pageHeader(BuildContext context, Map<String, dynamic> c) {
    final subtitle = c['subtitle']?.toString() ?? '';
    final logoUrl = c['logoUrl']?.toString() ?? c['image']?.toString() ?? '';
    final typography = _map(c['typography']) ?? const <String, dynamic>{};
    final titleStyle = _typographyOrNull(
      typography['titleToken']?.toString() ?? 'pageTitle',
    );
    final subtitleStyle = _typographyOrNull(
      typography['subtitleToken']?.toString() ?? 'pageSubtitle',
    );
    if (titleStyle == null || subtitleStyle == null) {
      return SchemaIssueWidget(
        title: 'Schema typography missing',
        details: const [
          'Provide designTokens.typography.pageTitle / pageSubtitle (size + colors.textPrimary/textSecondary)',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }
    final actions = c['actions'];
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final logoHeight = _d(appearance['logoHeight']);
    if (logoUrl.isNotEmpty && logoHeight == null) {
      return SchemaIssueWidget(
        title: 'Schema layout missing',
        details: const ['Provide appearance.logoHeight'],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (logoUrl.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: logoUrl,
                  cacheManager: SduiNetworkImageCache.manager,
                  height: logoHeight,
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                  errorWidget: (_, __, ___) => Text(
                    c['title']?.toString() ?? 'Grid',
                    style: titleStyle,
                  ),
                )
              else
                Text(c['title']?.toString() ?? '', style: titleStyle),
              if (subtitle.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(subtitle, style: subtitleStyle),
              ],
            ],
          ),
        ),
        if (actions is List)
          for (final raw in actions)
            if (raw is Map) _headerAction(Map<String, dynamic>.from(raw)),
      ],
    );
  }

  Widget _headerAction(Map<String, dynamic> action) {
    final type = action['type']?.toString();
    final color = state.parseColor(action['color']) ??
        state.tokenColor('colors.accent');
    if (color == null) {
      return SchemaIssueWidget(
        title: 'Schema color missing',
        details: const [
          'Provide action.color or designTokens.colors.accent',
        ],
        componentType: type,
        controlId: action['id']?.toString(),
      );
    }

    if (type == 'avatarButton') {
      final onAccent = state.tokenColor('colors.surface') ??
          state.tokenColor('colors.onAccent');
      final fontSize = _d(action['fontSize']);
      if (onAccent == null || fontSize == null) {
        return SchemaIssueWidget(
          title: 'Schema token missing',
          details: const [
            'Provide designTokens.colors.surface (or onAccent) and action.fontSize',
          ],
          componentType: type,
          controlId: action['id']?.toString(),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: color.withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => state.dispatch(action['actionId']?.toString()),
              child: SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: Text(
                    action['label']?.toString() ?? '',
                    style: TextStyle(
                      color: onAccent,
                      fontWeight: FontWeight.w800,
                      fontSize: fontSize,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final appearance = _map(action['appearance']) ?? const <String, dynamic>{};
    final layout = _map(action['layout']) ?? const <String, dynamic>{};
    final actionSize = _d(appearance['size'] ?? layout['width']) ?? 40.0;
    final iconSize = _d(appearance['iconSize']) ?? 20.0;
    final surface = state.parseColor(action['backgroundColor']) ??
        state.parseColor(appearance['backgroundColor']) ??
        Colors.transparent;
    final iconColor = state.parseColor(action['color']) ??
        state.tokenColor('colors.textSecondary');
    if (iconColor == null) {
      return SchemaIssueWidget(
        title: 'Schema color missing',
        details: const [
          'Provide designTokens.colors.textSecondary or action.color',
        ],
        componentType: type,
        controlId: action['id']?.toString(),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: surface,
        shape: const CircleBorder(),
        elevation: 0,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => state.dispatch(action['actionId']?.toString()),
          child: SizedBox(
            width: actionSize,
            height: actionSize,
            child: Center(
              child: FaIcon(
                icons.resolve(action['iconToken']?.toString()),
                size: iconSize,
                color: iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _responsiveGrid(BuildContext context, Map<String, dynamic> c) {
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final bp = _breakpoint(context);
    final responsive = _map(_map(layout['responsive'])?[bp]) ?? layout;
    final columnsRaw = _d(responsive['columns'] ?? layout['columns']);
    final columnGap = _d(responsive['columnGap'] ?? layout['columnGap']);
    final rowGap = _d(responsive['rowGap'] ?? layout['rowGap']);
    if (columnsRaw == null || columnGap == null || rowGap == null) {
      return SchemaIssueWidget(
        title: 'Schema layout missing',
        details: const [
          'Provide layout.columns, layout.columnGap, layout.rowGap (or layout.responsive.<bp>.*)',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }
    final columns = columnsRaw.round().clamp(1, 4);
    final ids = <String>[];
    final children = c['children'];
    if (children is List) {
      for (final child in children) {
        if (child is String) ids.add(child);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final itemWidth = (width - columnGap * (columns - 1)) / columns;
        final rows = <Widget>[];
        for (var i = 0; i < ids.length; i += columns) {
          final slice = ids.skip(i).take(columns).toList();
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var cIndex = 0;
                      cIndex < slice.length;
                      cIndex++) ...<Widget>[
                    if (cIndex > 0) SizedBox(width: columnGap),
                    SizedBox(
                      width: itemWidth,
                      child: buildComponent(context, slice[cIndex]),
                    ),
                  ],
                ],
              ),
            ),
          );
          if (i + columns < ids.length) {
            rows.add(SizedBox(height: rowGap));
          }
        }
        return Column(children: rows);
      },
    );
  }

  Widget _featureCard(BuildContext context, Map<String, dynamic> c) {
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final radius = _d(appearance['borderRadius']);
    final minHeight = _d(layout['minHeight']);
    final textColor = state.parseColor(c['textColor']) ??
        state.tokenColor('colors.textPrimary');
    final start = state.parseColor(
            c['gradientStart'] ?? appearance['backgroundGradient']?['start']) ??
        state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.surfaceElevated') ??
        state.tokenColor('colors.surface');
    final end = state.parseColor(
            c['gradientEnd'] ?? appearance['backgroundGradient']?['end']) ??
        start;
    final iconSize = _d(appearance['iconSize']);
    final titleSize = _d(appearance['titleFontSize']);
    final subtitleSize = _d(appearance['subtitleFontSize']) ??
        _tokenSize('pageSubtitle');
    final titlePadding = _d(appearance['titlePadding']);
    final accent = state.parseColor(c['color']) ??
        state.tokenColor('colors.accent') ??
        textColor;
    final onAccent = state.tokenColor('colors.surface') ??
        state.tokenColor('colors.onAccent');
    final iconOverlay = state.tokenColor('colors.surface');

    if (radius == null ||
        minHeight == null ||
        textColor == null ||
        start == null ||
        end == null ||
        iconSize == null ||
        titleSize == null ||
        subtitleSize == null ||
        titlePadding == null ||
        accent == null ||
        onAccent == null ||
        iconOverlay == null) {
      return SchemaIssueWidget(
        title: 'Schema tokens missing',
        details: const [
          'Provide appearance.borderRadius, layout.minHeight, textColor or colors.textPrimary,',
          'gradient/backgroundColor or colors.surface, appearance.iconSize/titleFontSize/subtitleFontSize/titlePadding,',
          'component.color or colors.accent, and colors.surface (for overlays)',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }
    final iconBox = iconSize;
    final glyphSize = iconSize * 0.5;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => state.dispatch(
          c['actionId']?.toString(),
          extra: <String, dynamic>{
            'url': c['url'],
            'route': c['route'],
            'title': c['title'],
            'openIn': c['openIn'] ?? _map(c['destination'])?['openIn'],
          },
        ),
        child: Ink(
          padding: EdgeInsets.all(titlePadding),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[start, end],
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight - titlePadding * 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: iconBox,
                  height: iconBox,
                  decoration: BoxDecoration(
                    color: iconOverlay.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: FaIcon(
                    icons.resolve(c['iconToken']?.toString()),
                    size: glyphSize,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  c['title']?.toString() ?? '',
                  style: TextStyle(
                    color: textColor,
                    fontSize: titleSize,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
                if (appearance['showSubtitle'] != false) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    c['subtitle']?.toString() ?? '',
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.78),
                      fontSize: subtitleSize,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const Spacer(),
                if (appearance['showActionArrow'] != false)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: FaIcon(
                          icons.resolve(
                            c['actionArrowIconToken']?.toString() ??
                                'chevron-right',
                          ),
                          size: 14,
                          color: onAccent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusSummary(BuildContext context, Map<String, dynamic> c) {
    final items = c['items'];
    if (items is! List) return _error('${c['id']}.items[] is required.');
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final bp = _breakpoint(context);
    final gap =
        _d(_map(_map(layout['responsive'])?[bp])?['gap'] ?? layout['gap']);

    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.surface');
    final radius = _d(appearance['borderRadius']) ??
        _d(_map(state.designTokens['radius'])?['card']);
    final valueSize = _d(appearance['valueFontSize']);
    final labelSize = _d(appearance['labelFontSize']);
    final paddingVertical = _d(appearance['paddingVertical']);
    final paddingHorizontal = _d(appearance['paddingHorizontal']);
    final borderColor = state.tokenColor('colors.border');
    final textPrimary = state.tokenColor('colors.textPrimary');
    final textSecondary = state.tokenColor('colors.textSecondary');

    if (gap == null ||
        background == null ||
        radius == null ||
        valueSize == null ||
        labelSize == null ||
        paddingVertical == null ||
        paddingHorizontal == null ||
        borderColor == null ||
        textPrimary == null ||
        textSecondary == null) {
      return SchemaIssueWidget(
        title: 'Schema tokens missing',
        details: const [
          'Provide layout.gap, appearance.backgroundColor or colors.surface,',
          'appearance.borderRadius or designTokens.radius.card,',
          'appearance.valueFontSize/labelFontSize/paddingVertical/paddingHorizontal,',
          'designTokens.colors.border, colors.textPrimary, colors.textSecondary',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        vertical: paddingVertical,
        horizontal: paddingHorizontal,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < items.length; i++) ...<Widget>[
            if (i > 0)
              Container(
                width: 1,
                height: 36,
                margin: EdgeInsets.symmetric(horizontal: gap),
                color: borderColor,
              ),
            Expanded(
              child: Builder(
                builder: (_) {
                  final entry = items[i] is Map
                      ? Map<String, dynamic>.from(
                          (items[i] as Map).cast<dynamic, dynamic>(),
                        )
                      : const <String, dynamic>{};
                  final color =
                      state.tokenColor(entry['colorToken']?.toString()) ??
                          textPrimary;
                  return Column(
                    children: <Widget>[
                      Text(
                        '${entry['value'] ?? ''}',
                        style: TextStyle(
                          color: color,
                          fontSize: valueSize,
                          fontWeight: FontWeight.w800,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        entry['label']?.toString() ?? '',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: textSecondary,
                          fontSize: labelSize,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _shareQrCard(BuildContext context, Map<String, dynamic> c) {
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final bp = _breakpoint(context);
    final responsive = _map(_map(layout['responsive'])?[bp]) ?? layout;
    final direction =
        (responsive['direction'] ?? layout['direction'] ?? 'horizontal')
            .toString()
            .trim()
            .toLowerCase();
    final radius = _d(appearance['borderRadius']);
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.surfaceElevated') ??
        state.tokenColor('colors.surface');
    final titleColor = state.tokenColor('colors.textPrimary');
    final muted = state.tokenColor('colors.textSecondary');
    final titleSize = _d(appearance['titleFontSize']);
    final subtitleSize = _d(appearance['subtitleFontSize']);
    final mode = state.selectedQrMode;
    final qrUrl = state.qrImageUrlForMode(mode);
    final modes = c['modes'];
    final gap = _d(responsive['gap'] ?? layout['gap']);
    final accent = state.tokenColor('colors.accent');
    final surface = state.tokenColor('colors.surface');

    if (radius == null ||
        background == null ||
        titleColor == null ||
        muted == null ||
        titleSize == null ||
        subtitleSize == null ||
        gap == null ||
        accent == null ||
        surface == null) {
      return SchemaIssueWidget(
        title: 'Schema tokens missing',
        details: const [
          'Provide appearance.borderRadius/backgroundColor (or colors.surface),',
          'appearance.titleFontSize/subtitleFontSize, layout.gap,',
          'designTokens.colors.textPrimary, textSecondary, accent, surface',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }

    final chips = modes is List
        ? Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final raw in modes)
                if (raw is Map)
                  _modeChip(
                    Map<String, dynamic>.from(raw.cast<dynamic, dynamic>()),
                    selected: raw['id']?.toString() == mode,
                  ),
            ],
          )
        : const SizedBox.shrink();

    final textColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: FaIcon(
            icons.resolve(c['iconToken']?.toString()),
            size: 16,
            color: accent,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          c['title']?.toString() ?? '',
          style: TextStyle(
            color: titleColor,
            fontSize: titleSize,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          c['subtitle']?.toString() ?? '',
          style: TextStyle(
            color: muted,
            fontSize: subtitleSize,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 16),
        chips,
      ],
    );

    final qrColumn = Column(
      children: <Widget>[
        Stack(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: surface,
                child: qrUrl.isEmpty
                    ? const SizedBox(width: 112, height: 112)
                    : CachedNetworkImage(
                        imageUrl: qrUrl,
                        cacheManager: SduiNetworkImageCache.manager,
                        width: 112,
                        height: 112,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => const SizedBox(
                          width: 112,
                          height: 112,
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        errorWidget: (_, __, ___) => const SizedBox(
                          width: 112,
                          height: 112,
                          child: Center(
                            child: Icon(Icons.qr_code_2_rounded, size: 48),
                          ),
                        ),
                      ),
              ),
            ),
            if (c['shareActionId'] != null &&
                c['shareActionId'].toString().trim().isNotEmpty)
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: surface,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => state.dispatch(c['shareActionId']?.toString()),
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: Center(
                        child: FaIcon(
                          icons.resolve(c['shareIconToken']?.toString() ?? 'share'),
                          size: 14,
                          color: muted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          c['qrCaption']?.toString() ?? '',
          style: TextStyle(
            color: muted,
            fontSize: 12,
          ),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: direction == 'vertical'
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                textColumn,
                SizedBox(height: gap),
                Align(alignment: Alignment.centerRight, child: qrColumn),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: textColumn),
                SizedBox(width: gap),
                qrColumn,
              ],
            ),
    );
  }

  Widget _modeChip(Map<String, dynamic> mode, {required bool selected}) {
    final accent = state.tokenColor('colors.accent');
    final surface = state.tokenColor('colors.surface');
    final textSecondary = state.tokenColor('colors.textSecondary');
    final onAccent = state.tokenColor('colors.surface') ??
        state.tokenColor('colors.onAccent');
    if (accent == null ||
        surface == null ||
        textSecondary == null ||
        onAccent == null) {
      return SchemaIssueWidget(
        title: 'Schema color missing',
        details: const [
          'Provide designTokens.colors.accent, surface, textSecondary',
        ],
        componentType: 'qrModeChip',
        controlId: mode['id']?.toString(),
      );
    }
    return Material(
      color: selected ? accent : surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => state.dispatch(
          mode['actionId']?.toString() ?? 'grid-select-qr-mode',
          extra: <String, dynamic>{'mode': mode['id']},
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            mode['label']?.toString() ?? '',
            style: TextStyle(
              color: selected ? onAccent : textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, Map<String, dynamic> c) {
    final trailing = _map(c['trailing']);
    final children = c['children'];
    final titleColor = state.tokenColor('colors.textPrimary');
    final accent = state.tokenColor('colors.accent');
    if (titleColor == null || (trailing != null && accent == null)) {
      return SchemaIssueWidget(
        title: 'Schema color missing',
        details: const [
          'Provide designTokens.colors.textPrimary and colors.accent',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                c['title']?.toString() ?? '',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (trailing != null)
              TextButton(
                onPressed: () =>
                    state.dispatch(trailing['actionId']?.toString()),
                child: Text(
                  trailing['label']?.toString() ?? '',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (children is List)
          for (final child in children)
            if (child is String) buildComponent(context, child),
      ],
    );
  }

  Widget _exploreCard(BuildContext context, Map<String, dynamic> c) {
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final radius = _d(appearance['borderRadius']);
    final minHeight = _d(layout['minHeight']);
    final color = state.parseColor(c['color']) ??
        state.tokenColor('colors.accent');
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.surface');
    final textPrimary = state.tokenColor('colors.textPrimary');
    final textSecondary = state.tokenColor('colors.textSecondary');

    if (radius == null ||
        minHeight == null ||
        color == null ||
        background == null ||
        textPrimary == null ||
        textSecondary == null) {
      return SchemaIssueWidget(
        title: 'Schema tokens missing',
        details: const [
          'Provide appearance.borderRadius, layout.minHeight,',
          'component.color or colors.accent, appearance.backgroundColor or colors.surface,',
          'designTokens.colors.textPrimary and textSecondary',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }

    final iconBorderRadius = _d(appearance['iconBorderRadius']) ?? 10.0;
    final showActionArrow = appearance['showActionArrow'] == true ||
        c['actionArrowIconToken'] != null;
    final actionArrowToken = c['actionArrowIconToken']?.toString();

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => state.dispatch(c['actionId']?.toString()),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(iconBorderRadius),
                  ),
                  alignment: Alignment.center,
                  child: FaIcon(
                    icons.resolve(c['iconToken']?.toString()),
                    size: 16,
                    color: color,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  c['title']?.toString() ?? '',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  c['subtitle']?.toString() ?? '',
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
                if (showActionArrow) ...<Widget>[
                  const Spacer(),
                  FaIcon(
                    icons.resolve(actionArrowToken ?? 'chevron-right'),
                    size: 14,
                    color: textSecondary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quoteBlock(BuildContext context, Map<String, dynamic> c) {
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.surfaceElevated') ??
        state.tokenColor('colors.surface');
    final textColor = state.parseColor(appearance['textColor']) ??
        state.tokenColor('colors.textPrimary');
    final radius = _d(appearance['borderRadius']);
    if (background == null || textColor == null || radius == null) {
      return SchemaIssueWidget(
        title: 'Schema tokens missing',
        details: const [
          'Provide appearance.backgroundColor (or colors.surface),',
          'appearance.textColor (or colors.textPrimary), appearance.borderRadius',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }
    final text = c['title']?.toString() ?? '';
    final parts = text.trim().split(RegExp(r'\s+'));
    final last = parts.isEmpty ? '' : parts.removeLast();
    final lead = parts.join(' ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FaIcon(
            icons.resolve(c['iconToken']?.toString() ?? 'quote'),
            size: 22,
            color: textColor.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 10),
          Text.rich(
            TextSpan(
              style: TextStyle(
                color: textColor,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
              children: <InlineSpan>[
                if (lead.isNotEmpty) TextSpan(text: '$lead '),
                TextSpan(
                  text: last,
                  style: const TextStyle(
                    decoration: TextDecoration.underline,
                    decorationThickness: 2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageState(Map<String, dynamic> c) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: <Widget>[
          Text(
            c['title']?.toString() ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          if ((c['subtitle']?.toString() ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(c['subtitle'].toString(), textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }

  String _breakpoint(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final points = _map(state.schema['layoutPolicy']?['responsiveBreakpoints']);
    final compact = _d(points?['compact']);
    final regular = _d(points?['regular']);
    final expanded = _d(points?['expanded']);
    // Clamp-safe defaults only after schema values exist; if missing, treat
    // as compact so callers still resolve layout.responsive.compact.
    if (expanded != null && width >= expanded) return 'expanded';
    if (regular != null && width >= regular) return 'regular';
    if (compact != null && width >= compact) return 'compact';
    return 'compact';
  }

  TextStyle? _typographyOrNull(String key) {
    final tokenKey = key.contains('.') ? key.split('.').last : key;
    final tokens = _map(_map(state.designTokens['typography'])?[tokenKey]);
    final size = _d(tokens?['size']) ?? _d(tokens?['fontSize']);
    final color = tokenKey == 'pageTitle'
        ? state.tokenColor('colors.textPrimary')
        : state.tokenColor('colors.textSecondary');
    if (size == null || color == null) return null;
    final weight = _fontWeight(
      tokens?['weight'] ?? tokens?['fontWeight'],
      fallback: tokenKey == 'pageTitle' ? FontWeight.w800 : FontWeight.w500,
    );
    return TextStyle(
      fontSize: size,
      fontWeight: weight,
      letterSpacing: _d(tokens?['letterSpacing']),
      height: _d(tokens?['lineHeight']),
      color: color,
    );
  }

  double? _tokenSize(String key) {
    final tokens = _map(_map(state.designTokens['typography'])?[key]);
    return _d(tokens?['size']) ?? _d(tokens?['fontSize']);
  }

  FontWeight _fontWeight(dynamic raw, {required FontWeight fallback}) {
    final value = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
    return switch (value) {
      800 || 900 => FontWeight.w800,
      700 => FontWeight.w700,
      600 => FontWeight.w600,
      500 => FontWeight.w500,
      400 => FontWeight.w400,
      300 => FontWeight.w300,
      _ => fallback,
    };
  }

  EdgeInsets? _paddingOrNull(dynamic raw) {
    final map = _map(raw);
    if (map == null) return null;
    return EdgeInsets.fromLTRB(
      _d(map['left']) ?? 0,
      _d(map['top']) ?? 0,
      _d(map['right']) ?? 0,
      _d(map['bottom']) ?? 0,
    );
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  double? _d(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  Widget _error(String message) {
    return SchemaIssueWidget(
      title: 'Schema issue',
      details: [message],
    );
  }
}
