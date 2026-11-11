import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../home_sdui/home_icon_resolver.dart';
import '../sdui/schema_guard.dart';
import '../sdui/sdui_network_image_cache.dart';
import '../sdui/style.dart';
import 'grid_sdui_state.dart';

class GridSduiRenderer {
  GridSduiRenderer(this.state) : icons = HomeIconResolver(state.schema);

  final GridSduiState state;
  final HomeIconResolver icons;

  TextStyle _font(TextStyle base, {Map<String, dynamic>? component}) {
    final compTypography = _map(component?['typography']);
    final compDesignTypography =
        _map(_map(component?['designTokens'])?['typography']);
    final schemaTypography = _map(state.schema['typography']);
    final designTypography = _map(state.designTokens['typography']);
    final family = compTypography?['fontFamily'] ??
        compDesignTypography?['fontFamily'] ??
        schemaTypography?['fontFamily'] ??
        designTypography?['fontFamily'];
    return SduiStyle.withFontFamily(base, family);
  }

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
      'skeleton' => _skeletonState(context, component),
      'emptyState' => _messageState(component),
      'errorState' => _messageState(component),
      _ => _error('Unsupported Grid component type "$type".'),
    };
  }

  Widget _scrollPage(BuildContext context, Map<String, dynamic> c) {
    final appearance = state.resolvedAppearance(c);
    final pageBackground = state.parseColor(
          appearance['pageBackground'] ?? appearance['backgroundColor'],
        ) ??
        state.tokenColor('colors.pageBackground');
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
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
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
    if (pageBackground != null) {
      return ColoredBox(color: pageBackground, child: list);
    }
    return list;
  }

  Widget _pageHeader(BuildContext context, Map<String, dynamic> c) {
    final appearance = state.resolvedAppearance(c);
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final bp = _breakpoint(context);
    final responsiveLayout =
        _map(_map(layout['responsive'])?[bp]) ?? const <String, dynamic>{};

    final subtitle = c['subtitle']?.toString() ?? '';
    final lightLogo =
        (c['logoUrl'] ?? appearance['logoUrl'] ?? c['image'])?.toString().trim() ??
            '';
    final darkLogo = (appearance['logoUrlDark'] ??
            c['logoUrlDark'] ??
            appearance['logoUrl'] ??
            c['logoUrl'] ??
            c['image'])
        ?.toString()
        .trim() ??
        '';
    final logoUrl =
        state.isDarkMode && darkLogo.isNotEmpty ? darkLogo : lightLogo;

    final eyebrow = c['eyebrow']?.toString() ?? '';
    final title = c['title']?.toString() ?? 'Grid';
    final tagline = c['tagline']?.toString() ?? '';

    final lightGlobe =
        (c['orbitGlobeImageUrl'] ?? c['globeImageUrl'])?.toString().trim() ?? '';
    final darkGlobe = (appearance['orbitGlobeImageUrlDark'] ??
            c['orbitGlobeImageUrlDark'] ??
            lightGlobe)
        .toString()
        .trim();
    final orbitGlobeImageUrl =
        state.isDarkMode && darkGlobe.isNotEmpty ? darkGlobe : lightGlobe;
    final hasGlobe = orbitGlobeImageUrl.isNotEmpty;

    final orbitSizeMap =
        _map(appearance['orbitGlobeSize']) ?? _map(c['orbitGlobeSize']);
    final globeWidth = _d(responsiveLayout['heroGlobeWidth']) ??
        _d(responsiveLayout['orbitGlobeSize']) ??
        _d(layout['heroGlobeWidth']) ??
        _d(appearance['orbitGlobeSize']) ??
        _d(orbitSizeMap?['width']);
    final globeHeight = _d(responsiveLayout['heroGlobeHeight']) ??
        _d(responsiveLayout['orbitGlobeSize']) ??
        _d(layout['heroGlobeHeight']) ??
        _d(appearance['orbitGlobeSize']) ??
        _d(orbitSizeMap?['height']) ??
        globeWidth;

    if (hasGlobe &&
        (globeWidth == null ||
            globeHeight == null ||
            globeWidth <= 0 ||
            globeHeight <= 0)) {
      return SchemaIssueWidget(
        title: 'Schema globe size missing',
        details: const [
          'Provide layout.responsive.<bp>.heroGlobeWidth / heroGlobeHeight or orbitGlobeSize',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }

    final typography = _map(c['typography']) ?? const <String, dynamic>{};
    final titleTypMap = _map(typography['title']) ??
        _map(_map(state.schema['typography'])?['pageTitle']) ??
        _map(_map(state.designTokens['typography'])?['pageTitle']);
    final subtitleTypMap = _map(typography['subtitle']) ??
        _map(_map(state.schema['typography'])?['pageSubtitle']) ??
        _map(_map(state.designTokens['typography'])?['pageSubtitle']);
    final taglineTypMap = _map(typography['tagline']) ??
        _map(_map(state.schema['typography'])?['tagline']) ??
        subtitleTypMap;

    final titleColor = state.parseColor(appearance['titleColor']) ??
        state.tokenColor('colors.textPrimary');
    final subtitleColor = state.parseColor(appearance['subtitleColor']) ??
        state.tokenColor('colors.textSecondary');
    final eyebrowColor = state.parseColor(appearance['eyebrowColor']) ??
        state.tokenColor('colors.accent') ??
        titleColor;
    final taglineColor =
        state.parseColor(appearance['taglineColor']) ?? subtitleColor;

    final baseTitleStyle = _typographyOrNull(
      typography['titleToken']?.toString() ?? 'pageTitle',
      overrideMap: titleTypMap,
      responsiveFontSize: _d(responsiveLayout['titleFontSize']),
      overrideColor: titleColor,
      component: c,
    );
    final baseSubtitleStyle = _typographyOrNull(
      typography['subtitleToken']?.toString() ?? 'pageSubtitle',
      overrideMap: subtitleTypMap,
      responsiveFontSize: _d(responsiveLayout['subtitleFontSize']),
      overrideColor: subtitleColor,
      component: c,
    );
    if (baseTitleStyle == null || baseSubtitleStyle == null) {
      return SchemaIssueWidget(
        title: 'Schema typography missing',
        details: const [
          'Provide designTokens.typography.pageTitle / pageSubtitle (size + colors.textPrimary/textSecondary)',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }

    final titleMaxLines = (titleTypMap?['maxLines'] as num?)?.toInt();
    final titleOverflow = titleTypMap?['overflow']?.toString() == 'ellipsis'
        ? TextOverflow.ellipsis
        : null;
    final subtitleMaxLines = (subtitleTypMap?['maxLines'] as num?)?.toInt();
    final subtitleOverflow =
        subtitleTypMap?['overflow']?.toString() == 'ellipsis'
            ? TextOverflow.ellipsis
            : null;
    final taglineMaxLines = (taglineTypMap?['maxLines'] as num?)?.toInt();
    final taglineOverflow =
        taglineTypMap?['overflow']?.toString() == 'ellipsis'
            ? TextOverflow.ellipsis
            : null;

    final baseTaglineStyle = _typographyOrNull(
          'tagline',
          overrideMap: taglineTypMap,
          responsiveFontSize: _d(responsiveLayout['subtitleFontSize']),
          overrideColor: taglineColor,
          component: c,
        ) ??
        baseSubtitleStyle.copyWith(color: taglineColor);

    final actions = c['actions'];
    final logoHeight = _d(responsiveLayout['logoHeight'] ?? appearance['logoHeight']);
    final logoMaxWidth = _d(
      responsiveLayout['logoMaxWidth'] ??
          appearance['logoMaxWidth'] ??
          layout['logoMaxWidth'],
    );
    if (logoUrl.isNotEmpty && logoHeight == null) {
      return SchemaIssueWidget(
        title: 'Schema layout missing',
        details: const ['Provide appearance.logoHeight'],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }

    Widget brandWidget;
    if (logoUrl.isNotEmpty) {
      Widget logoImage = CachedNetworkImage(
        imageUrl: logoUrl,
        cacheManager: SduiNetworkImageCache.manager,
        height: logoHeight,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorWidget: (_, __, ___) => Text(
          title,
          style: baseTitleStyle,
          maxLines: titleMaxLines,
          overflow: titleOverflow,
        ),
      );
      if (logoMaxWidth != null && logoMaxWidth > 0) {
        logoImage = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: logoMaxWidth),
          child: logoImage,
        );
      }
      brandWidget = logoImage;
    } else {
      brandWidget = Text(
        title,
        style: baseTitleStyle,
        maxLines: titleMaxLines,
        overflow: titleOverflow,
      );
    }

    final topBar = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: brandWidget,
          ),
        ),
        if (actions is List)
          for (final raw in actions)
            if (raw is Map)
              _headerAction(
                Map<String, dynamic>.from(raw),
                component: c,
              ),
      ],
    );

    final hasHeroContent = eyebrow.isNotEmpty ||
        subtitle.isNotEmpty ||
        tagline.isNotEmpty ||
        hasGlobe;
    if (!hasHeroContent) {
      return topBar;
    }

    final orbitGlobeClip =
        (c['orbitGlobeClip'] ?? appearance['orbitGlobeClip']) == true;
    final heroGap = _d(responsiveLayout['gap'] ?? layout['gap']) ?? 10.0;

    final heroRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (eyebrow.isNotEmpty) ...<Widget>[
                Text(
                  eyebrow.toUpperCase(),
                  style: _font(
                    TextStyle(
                      color: eyebrowColor ?? baseTitleStyle.color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                    component: c,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              if (logoUrl.isNotEmpty && title.isNotEmpty) ...<Widget>[
                Text(
                  title,
                  style: baseTitleStyle,
                  maxLines: titleMaxLines,
                  overflow: titleOverflow,
                ),
                const SizedBox(height: 4),
              ],
              if (subtitle.isNotEmpty) ...<Widget>[
                Text(
                  subtitle,
                  style: baseSubtitleStyle,
                  maxLines: subtitleMaxLines,
                  overflow: subtitleOverflow,
                ),
              ],
              if (tagline.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  tagline,
                  style: baseTaglineStyle,
                  maxLines: taglineMaxLines,
                  overflow: taglineOverflow,
                ),
              ],
            ],
          ),
        ),
        if (hasGlobe) ...<Widget>[
          SizedBox(width: heroGap),
          _GridOrbitGlobe(
            orbitGlobeImageUrl: orbitGlobeImageUrl,
            width: globeWidth!,
            height: globeHeight!,
            clip: orbitGlobeClip,
          ),
        ],
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        topBar,
        const SizedBox(height: 16),
        heroRow,
      ],
    );
  }

  Widget _headerAction(
    Map<String, dynamic> action, {
    Map<String, dynamic>? component,
  }) {
    final type = action['type']?.toString();
    final appearance = state.resolvedAppearance(action);
    final layout = _map(action['layout']) ?? const <String, dynamic>{};
    final styleMap = _map(action['style']) ?? const <String, dynamic>{};

    final color = state.parseColor(
          appearance['backgroundColor'] ??
              styleMap['backgroundColor'] ??
              action['backgroundColor'] ??
              action['color'],
        ) ??
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
      final onAccent = state.parseColor(
            appearance['foregroundColor'] ??
                styleMap['color'] ??
                action['foregroundColor'],
          ) ??
          state.tokenColor('colors.onAccent') ??
          state.tokenColor('colors.surface');
      final fontSize = _d(
        appearance['fontSize'] ?? styleMap['fontSize'] ?? action['fontSize'],
      );
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
      final actionSize = _d(
            appearance['size'] ??
                appearance['width'] ??
                layout['width'] ??
                styleMap['width'],
          ) ??
          40.0;
      final weight = _fontWeight(
        appearance['fontWeight'] ?? styleMap['fontWeight'],
        fallback: FontWeight.w800,
      );
      final imageUrl = _firstNonEmptyString(<dynamic>[
        action['imageUrl'],
        action['avatarUrl'],
        action['previewImageUrl'],
        action['image'],
        appearance['imageUrl'],
      ]);
      final borderColor = state.parseColor(appearance['borderColor']);
      final borderWidth = _d(appearance['borderWidth']) ?? 1.0;

      return Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: borderColor != null
                ? Border.all(color: borderColor, width: borderWidth)
                : null,
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
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => state.dispatch(action['actionId']?.toString()),
              child: SizedBox(
                width: actionSize,
                height: actionSize,
                child: imageUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: imageUrl,
                        cacheManager: SduiNetworkImageCache.manager,
                        width: actionSize,
                        height: actionSize,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Center(
                          child: Text(
                            action['label']?.toString() ?? '',
                            style: _font(
                              TextStyle(
                                color: onAccent,
                                fontWeight: weight,
                                fontSize: fontSize,
                              ),
                              component: component,
                            ),
                          ),
                        ),
                      )
                    : Center(
                        child: Text(
                          action['label']?.toString() ?? '',
                          style: _font(
                            TextStyle(
                              color: onAccent,
                              fontWeight: weight,
                              fontSize: fontSize,
                            ),
                            component: component,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
    }

    final actionSize =
        _d(appearance['size'] ?? appearance['width'] ?? layout['width']) ?? 40.0;
    final iconSize = _d(appearance['iconSize']) ?? 20.0;
    final surface = state.parseColor(
          appearance['backgroundColor'] ?? action['backgroundColor'],
        ) ??
        Colors.transparent;
    final borderColor = state.parseColor(appearance['borderColor']);
    final borderWidth = _d(appearance['borderWidth']) ?? 1.0;
    final iconColor = state.parseColor(
          appearance['foregroundColor'] ?? appearance['color'] ?? action['color'],
        ) ??
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

    final iconToken = action['iconToken']?.toString().trim();
    final isScannerIcon = iconToken == 'scanner' ||
        iconToken == 'scan' ||
        iconToken == 'viewfinder' ||
        iconToken == 'cropFree';

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: surface,
        shape: CircleBorder(
          side: borderColor != null
              ? BorderSide(color: borderColor, width: borderWidth)
              : BorderSide.none,
        ),
        elevation: 0,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => state.dispatch(action['actionId']?.toString()),
          child: SizedBox(
            width: actionSize,
            height: actionSize,
            child: Center(
              child: isScannerIcon
                  ? Icon(
                      Icons.qr_code_scanner,
                      size: iconSize,
                      color: iconColor,
                    )
                  : FaIcon(
                      icons.resolve(iconToken),
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
    final responsive = _map(_map(layout['responsive'])?[bp]) ??
        _map(_map(c['layouts'])?[bp]) ??
        layout;
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

    final selectedFilter = state.selectedFilter('grid-explore-section');
    if (c['id'] == 'grid-explore-row' && selectedFilter != 'all') {
      ids.removeWhere((id) {
        final comp = state.component(id);
        if (comp == null) return false;
        final space = (comp['space'] ?? '').toString().toLowerCase();
        final badge = (comp['badge'] ?? '').toString().toLowerCase();
        final title = (comp['title'] ?? '').toString().toLowerCase();
        final subtitle = (comp['subtitle'] ?? '').toString().toLowerCase();
        final idLower = id.toLowerCase();

        if (selectedFilter == 'professional') {
          final isProf = space.contains('prof') ||
              badge.contains('prof') ||
              idLower.contains('prof') ||
              title.contains('prof') ||
              subtitle.contains('prof') ||
              idLower.contains('message');
          return !isProf;
        } else if (selectedFilter == 'circle') {
          final isCircle = space.contains('circle') ||
              badge.contains('circle') ||
              idLower.contains('circle') ||
              title.contains('circle') ||
              subtitle.contains('circle');
          return !isCircle;
        }
        return false;
      });
    }

    if (ids.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            'No activity found for this category.',
            style: _font(
              TextStyle(
                color: state.tokenColor('colors.textSecondary') ??
                    const Color(0xFF64748B),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              component: c,
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final itemWidth = (width - columnGap * (columns - 1)) / columns;
        final rows = <Widget>[];
        for (var i = 0; i < ids.length; i += columns) {
          final slice = ids.skip(i).take(columns).toList();
          final rowWidget = Row(
            crossAxisAlignment:
                columns > 1 ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
            children: <Widget>[
              for (var cIndex = 0; cIndex < slice.length; cIndex++) ...<Widget>[
                if (cIndex > 0) SizedBox(width: columnGap),
                SizedBox(
                  width: itemWidth,
                  child: buildComponent(context, slice[cIndex]),
                ),
              ],
            ],
          );
          rows.add(columns > 1 ? IntrinsicHeight(child: rowWidget) : rowWidget);
          if (i + columns < ids.length) {
            rows.add(SizedBox(height: rowGap));
          }
        }
        return Column(children: rows);
      },
    );
  }

  Widget _featureCard(BuildContext context, Map<String, dynamic> c) {
    final appearance = state.resolvedAppearance(c);
    final hasDarkAppearance =
        state.isDarkMode && (_map(c['appearanceDark'])?.isNotEmpty ?? false);
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final radius = _d(appearance['borderRadius']);
    final minHeight = _d(layout['minHeight'] ?? appearance['minHeight']);
    final textColor = state.parseColor(
          appearance['titleColor'] ??
              appearance['textColor'] ??
              (hasDarkAppearance ? null : c['textColor']),
        ) ??
        state.tokenColor('colors.textPrimary');
    final subtitleColor = state.parseColor(appearance['subtitleColor']) ??
        textColor?.withValues(alpha: 0.78);
    final start = state.parseColor(
          _map(appearance['backgroundGradient'])?['start'] ??
              (hasDarkAppearance ? null : c['gradientStart']) ??
              appearance['backgroundColor'],
        ) ??
        state.tokenColor('colors.surfaceElevated') ??
        state.tokenColor('colors.surface');
    final end = state.parseColor(
          _map(appearance['backgroundGradient'])?['end'] ??
              (hasDarkAppearance ? null : c['gradientEnd']),
        ) ??
        start;
    final borderColor = state.parseColor(appearance['borderColor']);
    final borderWidth = _d(appearance['borderWidth']) ?? 1.0;
    final iconSize = _d(appearance['iconSize']);
    final titleSize = _d(appearance['titleFontSize']);
    final subtitleSize =
        _d(appearance['subtitleFontSize']) ?? _tokenSize('pageSubtitle');
    final paddingRaw = _d(appearance['padding'] ?? appearance['titlePadding']);
    final cardPadding =
        (paddingRaw == null || paddingRaw <= 0.0) ? 12.0 : paddingRaw;
    final accent = state.parseColor(appearance['accentColor'] ?? c['color']) ??
        state.tokenColor('colors.accent') ??
        textColor;
    final onAccent =
        state.tokenColor('colors.onAccent') ?? state.tokenColor('colors.surface');
    final iconOverlay = state.tokenColor('colors.surface');
    final ctaColor = state.parseColor(appearance['ctaColor']) ?? accent;
    final actionArrowSize = _d(appearance['actionArrowSize']) ?? 34.0;

    if (radius == null ||
        minHeight == null ||
        textColor == null ||
        start == null ||
        end == null ||
        iconSize == null ||
        titleSize == null ||
        subtitleSize == null ||
        paddingRaw == null ||
        accent == null ||
        onAccent == null ||
        iconOverlay == null) {
      return SchemaIssueWidget(
        title: 'Schema tokens missing',
        details: const [
          'Provide appearance.borderRadius, layout.minHeight, textColor or colors.textPrimary,',
          'gradient/backgroundColor or colors.surface, appearance.iconSize/titleFontSize/subtitleFontSize/padding,',
          'component.color or colors.accent, and colors.surface (for overlays)',
        ],
        componentType: c['type']?.toString(),
        controlId: c['id']?.toString(),
      );
    }
    final iconBox = iconSize;
    final glyphSize = iconSize * 0.5;
    final direction =
        (layout['direction'] ?? 'vertical').toString().trim().toLowerCase();
    final isHorizontal = direction == 'horizontal' ||
        appearance['titlePosition'] == 'besideIcon' ||
        appearance['iconPosition'] == 'leading';

    final pageHeader = state.component('grid-page-header');
    final headerHasGlobe = pageHeader != null &&
        ((pageHeader['orbitGlobeUrl'] ?? pageHeader['globeUrl'])
                    ?.toString()
                    .trim()
                    .isNotEmpty ==
                true ||
            (pageHeader['orbitGlobeImageUrl'] ??
                        pageHeader['orbitGlobeImageUrlDark'] ??
                        pageHeader['globeImageUrl'])
                    ?.toString()
                    .trim()
                    .isNotEmpty ==
                true);
    String globeImageUrl =
        (c['orbitGlobeImageUrl'] ?? c['globeImageUrl'] ?? '').toString().trim();
    if (headerHasGlobe) {
      globeImageUrl = ''; // Suppress second globe in Circle Connect
    }

    Widget cardBody;
    if (isHorizontal) {
      final iconMap = _map(c['icon']) ?? _map(c['leading']);
      final avatarLabel = (iconMap?['label'] ??
              iconMap?['initial'] ??
              c['label'] ??
              c['initial'] ??
              c['initials'] ??
              '')
          .toString()
          .trim();
      final avatarColor = state.parseColor(iconMap?['backgroundColor'] ??
              iconMap?['color'] ??
              c['avatarColor']) ??
          accent;
      final avatarFg = state.parseColor(iconMap?['foregroundColor']) ?? onAccent;
      var avatarImageUrl = (iconMap?['imageUrl'] ??
              iconMap?['avatarUrl'] ??
              c['imageUrl'] ??
              c['image'])
          ?.toString()
          .trim();
      if ((avatarImageUrl == null || avatarImageUrl.isEmpty) &&
          globeImageUrl.isNotEmpty) {
        avatarImageUrl = globeImageUrl;
      }
      final iconBorderRadius =
          _d(appearance['iconBorderRadius']) ?? (iconBox / 2.0);
      final hasAvatar = iconMap != null ||
          avatarLabel.isNotEmpty ||
          (avatarImageUrl != null && avatarImageUrl.isNotEmpty);

      Widget leadingWidget;
      if (hasAvatar) {
        leadingWidget = Container(
          width: iconBox,
          height: iconBox,
          decoration: BoxDecoration(
            color: avatarColor,
            borderRadius: BorderRadius.circular(iconBorderRadius),
          ),
          clipBehavior: Clip.antiAlias,
          child: (avatarImageUrl != null && avatarImageUrl.isNotEmpty)
              ? CachedNetworkImage(
                  imageUrl: avatarImageUrl,
                  cacheManager: SduiNetworkImageCache.manager,
                  width: iconBox,
                  height: iconBox,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Center(
                    child: Text(
                      avatarLabel.isNotEmpty ? avatarLabel : 'M',
                      style: _font(
                        TextStyle(
                          color: avatarFg,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                        component: c,
                      ),
                    ),
                  ),
                )
              : Center(
                  child: Text(
                    avatarLabel.isNotEmpty ? avatarLabel : 'M',
                    style: _font(
                      TextStyle(
                        color: avatarFg,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                      component: c,
                    ),
                  ),
                ),
        );
      } else {
        leadingWidget = Container(
          width: iconBox,
          height: iconBox,
          decoration: BoxDecoration(
            color: iconOverlay.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(iconBorderRadius),
          ),
          alignment: Alignment.center,
          child: FaIcon(
            icons.resolve(c['iconToken']?.toString()),
            size: glyphSize,
            color: accent,
          ),
        );
      }

      final badgeText =
          (c['badge'] ?? _map(c['chip'])?['label'])?.toString().trim() ?? '';
      final showBadge =
          appearance['showBadge'] != false && badgeText.isNotEmpty;

      cardBody = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          leadingWidget,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  c['title']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _font(
                    TextStyle(
                      color: textColor,
                      fontSize: titleSize,
                      fontWeight: FontWeight.w700,
                    ),
                    component: c,
                  ),
                ),
                if (appearance['showSubtitle'] != false) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    c['subtitle']?.toString() ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _font(
                      TextStyle(
                        color: subtitleColor ?? textColor.withValues(alpha: 0.72),
                        fontSize: subtitleSize,
                        fontWeight: FontWeight.w500,
                      ),
                      component: c,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (showBadge) ...<Widget>[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                badgeText,
                style: _font(
                  TextStyle(
                    color: ctaColor ?? accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                  component: c,
                ),
              ),
            ),
          ],
          if (appearance['showActionArrow'] == true) ...<Widget>[
            const SizedBox(width: 8),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: accent,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: FaIcon(
                  icons.resolve(
                    c['actionArrowIconToken']?.toString() ?? 'chevron-right',
                  ),
                  size: 12,
                  color: onAccent,
                ),
              ),
            ),
          ],
        ],
      );
    } else {
      final arrowPosition =
          appearance['actionArrowPosition']?.toString() ?? 'bottomRight';
      final showArrow = appearance['showActionArrow'] != false;
      final ctaLabel =
          (appearance['ctaLabel'] ?? c['ctaLabel'])?.toString().trim() ?? '';
      final showCta = appearance['showCta'] == true && ctaLabel.isNotEmpty;
      final ctaSize = _d(appearance['ctaFontSize']) ?? 11.0;
      final ctaWeight = _fontWeight(
        appearance['ctaFontWeight'],
        fallback: FontWeight.w700,
      );

      final iconWidget = globeImageUrl.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: globeImageUrl,
              cacheManager: SduiNetworkImageCache.manager,
              width: iconBox,
              height: iconBox,
              fit: BoxFit.contain,
              errorWidget: (_, __, ___) => Container(
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
            )
          : Container(
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
            );

      final arrowWidget = Container(
        width: actionArrowSize,
        height: actionArrowSize,
        decoration: BoxDecoration(
          color: accent,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: FaIcon(
            icons.resolve(
              c['actionArrowIconToken']?.toString() ?? 'chevron-right',
            ),
            size: (actionArrowSize * 0.4).clamp(11.0, 16.0),
            color: onAccent,
          ),
        ),
      );

      final topSection = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (showArrow && arrowPosition == 'topRight')
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[iconWidget, arrowWidget],
            )
          else
            iconWidget,
          const SizedBox(height: 14),
          Text(
            c['title']?.toString() ?? '',
            maxLines: (appearance['titleMaxLines'] as num?)?.toInt(),
            overflow: appearance['titleOverflow']?.toString() == 'ellipsis'
                ? TextOverflow.ellipsis
                : null,
            style: _font(
              TextStyle(
                color: textColor,
                fontSize: titleSize,
                fontWeight: FontWeight.w800,
                height: 1.15,
              ),
              component: c,
            ),
          ),
          if (appearance['showSubtitle'] != false) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              c['subtitle']?.toString() ?? '',
              maxLines: (appearance['subtitleMaxLines'] as num?)?.toInt(),
              overflow: appearance['subtitleOverflow']?.toString() == 'ellipsis'
                  ? TextOverflow.ellipsis
                  : null,
              style: _font(
                TextStyle(
                  color: subtitleColor ?? textColor.withValues(alpha: 0.78),
                  fontSize: subtitleSize,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                ),
                component: c,
              ),
            ),
          ],
        ],
      );

      final Widget? footer = showCta
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: Text(
                    ctaLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _font(
                      TextStyle(
                        color: ctaColor ?? accent,
                        fontSize: ctaSize,
                        fontWeight: ctaWeight,
                      ),
                      component: c,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                FaIcon(
                  icons.resolve(
                    c['ctaIconToken']?.toString() ?? 'chevron-right',
                  ),
                  size: 10,
                  color: ctaColor ?? accent,
                ),
              ],
            )
          : (showArrow && arrowPosition != 'topRight')
              ? Align(
                  alignment: Alignment.bottomRight,
                  child: arrowWidget,
                )
              : null;

      cardBody = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          topSection,
          if (footer != null) ...<Widget>[
            const SizedBox(height: 12),
            footer,
          ],
        ],
      );
    }

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
          padding: EdgeInsets.all(cardPadding),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: borderColor != null
                ? Border.all(color: borderColor, width: borderWidth)
                : null,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[start, end],
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight - cardPadding * 2),
            child: cardBody,
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
        _d(_map(_map(layout['responsive'])?[bp])?['gap'] ?? layout['gap']) ??
            8.0;

    final appearance = state.resolvedAppearance(c);
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.surface') ??
        const Color(0xFFFFFFFF);
    final radius = _d(appearance['borderRadius']) ??
        _d(_map(state.designTokens['radius'])?['card']) ??
        16.0;
    final valueSize = _d(appearance['valueFontSize']) ?? 20.0;
    final labelSize = _d(appearance['labelFontSize']) ?? 12.0;
    final paddingVertical = _d(appearance['paddingVertical']) ?? 14.0;
    final paddingHorizontal = _d(appearance['paddingHorizontal']) ?? 16.0;
    final borderColor = state.parseColor(appearance['borderColor']) ??
        state.tokenColor('colors.border') ??
        const Color(0xFFE2E8F0);
    final textPrimary = state.parseColor(appearance['titleColor']) ??
        state.tokenColor('colors.textPrimary') ??
        const Color(0xFF1E293B);
    final textSecondary = state.parseColor(appearance['subtitleColor']) ??
        state.tokenColor('colors.textSecondary') ??
        const Color(0xFF64748B);

    return Container(
      padding: EdgeInsets.symmetric(
        vertical: paddingVertical,
        horizontal: paddingHorizontal,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: state.parseColor(appearance['borderColor']) != null
            ? Border.all(
                color: borderColor,
                width: _d(appearance['borderWidth']) ?? 1.0,
              )
            : null,
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
                        style: _font(
                          TextStyle(
                            color: color,
                            fontSize: valueSize,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                          component: c,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        entry['label']?.toString() ?? '',
                        textAlign: TextAlign.center,
                        style: _font(
                          TextStyle(
                            color: textSecondary,
                            fontSize: labelSize,
                            fontWeight: FontWeight.w500,
                          ),
                          component: c,
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
    final appearance = state.resolvedAppearance(c);
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
    final borderColor = state.parseColor(appearance['borderColor']) ??
        state.tokenColor('colors.border');
    final borderWidth = _d(appearance['borderWidth']) ?? 1.0;
    final cardPadding = _d(appearance['padding']) ?? 18.0;
    final titleColor = state.parseColor(appearance['titleColor']) ??
        state.tokenColor('colors.textPrimary');
    final muted = state.parseColor(appearance['subtitleColor']) ??
        state.tokenColor('colors.textSecondary');
    final captionColor = state.parseColor(appearance['captionColor']) ?? muted;
    final captionSize = _d(appearance['captionFontSize']) ?? 12.0;
    final titleSize = _d(appearance['titleFontSize']);
    final titleWeight = _fontWeight(
      appearance['titleFontWeight'],
      fallback: FontWeight.w800,
    );
    final subtitleSize = _d(appearance['subtitleFontSize']);
    final qrSize =
        _d(responsive['qrSize'] ?? layout['qrSize'] ?? appearance['qrSize']) ??
            112.0;
    final qrPadding = _d(appearance['qrPadding']) ?? 0.0;
    final qrBorderRadius = _d(appearance['qrBorderRadius']) ?? 12.0;
    final qrBgColor = state.parseColor(appearance['qrBackgroundColor']) ??
        state.tokenColor('colors.surface');
    final qrBorderColor = state.parseColor(appearance['qrBorderColor']);
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
                    cardAppearance: appearance,
                    component: c,
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
            color: accent.withValues(alpha: 0.14),
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
          style: _font(
            TextStyle(
              color: titleColor,
              fontSize: titleSize,
              fontWeight: titleWeight,
            ),
            component: c,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          c['subtitle']?.toString() ?? '',
          style: _font(
            TextStyle(
              color: muted,
              fontSize: subtitleSize,
              height: 1.35,
            ),
            component: c,
          ),
        ),
        const SizedBox(height: 16),
        chips,
      ],
    );

    final innerQrRadius = (qrBorderRadius - qrPadding).clamp(4.0, 16.0);
    final qrColumn = Column(
      children: <Widget>[
        Stack(
          children: <Widget>[
            Container(
              padding: EdgeInsets.all(qrPadding),
              decoration: BoxDecoration(
                color: qrBgColor ?? surface,
                borderRadius: BorderRadius.circular(qrBorderRadius),
                border: qrBorderColor != null
                    ? Border.all(color: qrBorderColor, width: 1)
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(innerQrRadius),
                child: qrUrl.isEmpty
                    ? SizedBox(width: qrSize, height: qrSize)
                    : CachedNetworkImage(
                        imageUrl: qrUrl,
                        cacheManager: SduiNetworkImageCache.manager,
                        width: qrSize,
                        height: qrSize,
                        fit: BoxFit.contain,
                        placeholder: (_, __) => SizedBox(
                          width: qrSize,
                          height: qrSize,
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        errorWidget: (_, __, ___) => SizedBox(
                          width: qrSize,
                          height: qrSize,
                          child: const Center(
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
                          icons.resolve(
                              c['shareIconToken']?.toString() ?? 'share'),
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
          style: _font(
            TextStyle(
              color: captionColor ?? muted,
              fontSize: captionSize,
            ),
            component: c,
          ),
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.all(cardPadding),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: borderColor != null
            ? Border.all(color: borderColor, width: borderWidth)
            : null,
      ),
      child: direction == 'vertical'
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                textColumn,
                SizedBox(height: gap),
                Align(alignment: Alignment.center, child: qrColumn),
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

  Widget _modeChip(
    Map<String, dynamic> mode, {
    required bool selected,
    Map<String, dynamic> cardAppearance = const <String, dynamic>{},
    Map<String, dynamic>? component,
  }) {
    final accent = state.tokenColor('colors.accent');
    final surface = state.tokenColor('colors.surface');
    final textSecondary = state.tokenColor('colors.textSecondary');
    final onAccent =
        state.tokenColor('colors.onAccent') ?? state.tokenColor('colors.surface');
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

    final selectedBg =
        state.parseColor(cardAppearance['modeChipSelectedBackground']) ??
            accent;
    final selectedFg =
        state.parseColor(cardAppearance['modeChipSelectedColor']) ?? onAccent;
    final idleBg =
        state.parseColor(cardAppearance['modeChipBackground']) ?? surface;
    final idleFg =
        state.parseColor(cardAppearance['modeChipColor']) ?? textSecondary;
    final radius = _d(cardAppearance['modeChipBorderRadius']) ?? 999.0;
    final padH = _d(cardAppearance['modeChipPaddingHorizontal']) ?? 16.0;
    final padV = _d(cardAppearance['modeChipPaddingVertical']) ?? 8.0;
    final fontSize = _d(cardAppearance['modeChipFontSize']) ?? 13.0;

    return Material(
      color: selected ? selectedBg : idleBg,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => state.dispatch(
          mode['actionId']?.toString() ?? 'grid-select-qr-mode',
          extra: <String, dynamic>{'mode': mode['id']},
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          child: Text(
            mode['label']?.toString() ?? '',
            style: _font(
              TextStyle(
                color: selected ? selectedFg : idleFg,
                fontWeight: FontWeight.w700,
                fontSize: fontSize,
              ),
              component: component,
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, Map<String, dynamic> c) {
    final appearance = state.resolvedAppearance(c);
    final trailing = _map(c['trailing']);
    final footer = _map(c['footer']);
    final children = c['children'];
    final sectionId = c['id']?.toString() ?? 'section';
    final bgColor = state.parseColor(appearance['backgroundColor']);
    final borderColor = state.parseColor(appearance['borderColor']);
    final borderWidth = _d(appearance['borderWidth']) ?? 1.0;
    final borderRadius = _d(appearance['borderRadius']) ?? 0.0;
    final sectionPadding = _d(appearance['padding']);
    final titleColor = state.parseColor(appearance['titleColor']) ??
        state.tokenColor('colors.textPrimary');
    final titleSize = _d(appearance['titleFontSize']) ?? 20.0;
    final titleWeight = _fontWeight(
      appearance['titleFontWeight'],
      fallback: FontWeight.w800,
    );
    final accent = state.tokenColor('colors.accent');
    final filterSelectedBg =
        state.parseColor(appearance['filterSelectedBackground']) ?? accent;
    final filterSelectedFg =
        state.parseColor(appearance['filterSelectedColor']) ??
            state.tokenColor('colors.onAccent') ??
            const Color(0xFFFFFFFF);
    final footerBg = state.parseColor(appearance['footerBackgroundColor']);
    final footerFg = state.parseColor(appearance['footerColor']) ?? accent;

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

    final rawFilters = c['filters'] ?? c['modes'];
    final filtersList = rawFilters is List
        ? rawFilters
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList()
        : <Map<String, dynamic>>[];

    final activeFilterId = state.selectedFilter(sectionId);

    final headerBadge = _map(c['headerBadge']);
    final badgeLabel = headerBadge?['label']?.toString().trim() ??
        c['badge']?.toString().trim() ??
        '';
    final badgeBg = state.parseColor(headerBadge?['backgroundColor']) ??
        const Color(0xFFDCFCE7);
    final badgeFg =
        state.parseColor(headerBadge?['color']) ?? const Color(0xFF16A34A);
    final idleBorderColor =
        state.tokenColor('colors.border') ?? const Color(0xFFE2E8F0);
    final idleTextColor =
        state.tokenColor('colors.textSecondary') ?? const Color(0xFF64748B);

    final sectionContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      c['title']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _font(
                        TextStyle(
                          color: titleColor,
                          fontSize: titleSize,
                          fontWeight: titleWeight,
                        ),
                        component: c,
                      ),
                    ),
                  ),
                  if (badgeLabel.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        badgeLabel,
                        style: _font(
                          TextStyle(
                            color: badgeFg,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                          component: c,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              TextButton(
                onPressed: () =>
                    state.dispatch(trailing['actionId']?.toString()),
                child: Text(
                  trailing['label']?.toString() ?? '',
                  style: _font(
                    TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w700,
                    ),
                    component: c,
                  ),
                ),
              ),
          ],
        ),
        if (filtersList.isNotEmpty) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final filter in filtersList) ...[
                  Builder(
                    builder: (context) {
                      final fId = filter['id']?.toString() ?? '';
                      final isSelected = fId == activeFilterId;
                      final label = filter['label']?.toString() ?? '';
                      final count = filter['count'];
                      final countStr =
                          (count != null && count is num && count > 0)
                              ? ' $count'
                              : '';
                      final selectedColor =
                          filterSelectedBg ?? const Color(0xFF7C3AED);
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Material(
                          color: isSelected ? selectedColor : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () =>
                                state.setSelectedFilter(sectionId, fId),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 7),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isSelected
                                      ? selectedColor
                                      : idleBorderColor,
                                  width: 1.2,
                                ),
                              ),
                              child: Text(
                                '$label$countStr',
                                style: _font(
                                  TextStyle(
                                    color: isSelected
                                        ? filterSelectedFg
                                        : idleTextColor,
                                    fontSize: 13,
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                  component: c,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        if (children is List)
          for (final child in children)
            if (child is String) buildComponent(context, child),
        if (footer != null &&
            (footer['label']?.toString().trim().isNotEmpty ?? false)) ...[
          const SizedBox(height: 12),
          Material(
            color: footerBg ?? accent?.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => state.dispatch(footer['actionId']?.toString()),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                alignment: Alignment.center,
                child: Text(
                  footer['label'].toString(),
                  style: _font(
                    TextStyle(
                      color: footerFg ?? accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    component: c,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );

    if (bgColor != null) {
      return Container(
        padding: EdgeInsets.all(sectionPadding ?? 14),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(borderRadius),
          border: borderColor != null
              ? Border.all(color: borderColor, width: borderWidth)
              : null,
        ),
        child: sectionContent,
      );
    }
    return sectionContent;
  }

  Widget _exploreCard(BuildContext context, Map<String, dynamic> c) {
    final appearance = state.resolvedAppearance(c);
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final radius = _d(appearance['borderRadius']);
    final minHeight = _d(layout['minHeight']);
    final color = state.parseColor(appearance['accentColor'] ?? c['color']) ??
        state.tokenColor('colors.accent');
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.surface');
    final borderColor = state.parseColor(appearance['borderColor']);
    final borderWidth = _d(appearance['borderWidth']) ?? 1.0;
    final textPrimary = state.parseColor(
          appearance['titleColor'] ?? appearance['textColor'],
        ) ??
        state.tokenColor('colors.textPrimary');
    final textSecondary = state.parseColor(appearance['subtitleColor']) ??
        state.tokenColor('colors.textSecondary');

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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: borderColor != null
            ? BorderSide(color: borderColor, width: borderWidth)
            : BorderSide.none,
      ),
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
                  style: _font(
                    TextStyle(
                      color: textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                    component: c,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  c['subtitle']?.toString() ?? '',
                  style: _font(
                    TextStyle(
                      color: textSecondary,
                      fontSize: 12,
                      height: 1.3,
                    ),
                    component: c,
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
    final appearance = state.resolvedAppearance(c);
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.surfaceElevated') ??
        state.tokenColor('colors.surface');
    final textColor = state.parseColor(
          appearance['textColor'] ?? appearance['titleColor'],
        ) ??
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
              style: _font(
                TextStyle(
                  color: textColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1.25,
                ),
                component: c,
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

  Widget _skeletonState(BuildContext context, Map<String, dynamic> c) {
    final appearance = state.resolvedAppearance(c);
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.pageBackground');
    final accent = state.tokenColor('colors.accent');
    Widget content = Center(
      child: CircularProgressIndicator(color: accent),
    );
    if (background != null) {
      content = ColoredBox(color: background, child: content);
    }
    return content;
  }

  Widget _messageState(Map<String, dynamic> c) {
    final appearance = state.resolvedAppearance(c);
    final background = state.parseColor(appearance['backgroundColor']) ??
        state.tokenColor('colors.pageBackground');
    final titleColor = state.parseColor(appearance['titleColor']) ??
        state.tokenColor('colors.textPrimary');
    final subtitleColor = state.parseColor(appearance['subtitleColor']) ??
        state.tokenColor('colors.textSecondary');
    final retryActionId = c['retryActionId']?.toString().trim() ?? '';

    Widget content = Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              c['title']?.toString() ?? '',
              textAlign: TextAlign.center,
              style: _font(
                TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: titleColor,
                ),
                component: c,
              ),
            ),
            if ((c['subtitle']?.toString() ?? '').isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                c['subtitle'].toString(),
                textAlign: TextAlign.center,
                style: _font(
                  TextStyle(color: subtitleColor, fontSize: 13),
                  component: c,
                ),
              ),
            ],
            if (retryActionId.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => state.dispatch(retryActionId),
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
    if (background != null) {
      content = ColoredBox(color: background, child: content);
    }
    return content;
  }

  String _breakpoint(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final layoutPolicy = _map(state.schema['layoutPolicy']);
    final points = _map(layoutPolicy?['responsiveBreakpoints']);
    final bpRanges = _map(_map(layoutPolicy?['responsive'])?['breakpoints']);

    final expanded =
        _d(points?['expanded']) ?? _d(_map(bpRanges?['expanded'])?['minWidth']);
    final medium =
        _d(points?['medium']) ?? _d(_map(bpRanges?['medium'])?['minWidth']);
    final regular =
        _d(points?['regular']) ?? _d(_map(bpRanges?['regular'])?['minWidth']);
    final compact =
        _d(points?['compact']) ?? _d(_map(bpRanges?['compact'])?['minWidth']);

    if (expanded != null && width >= expanded) return 'expanded';
    if (medium != null && width >= medium) return 'medium';
    if (regular != null && width >= regular) return 'regular';
    if (compact != null) {
      return width >= compact ? 'compact' : 'narrow';
    }
    return width < 320 ? 'narrow' : 'compact';
  }

  TextStyle? _typographyOrNull(
    String key, {
    Map<String, dynamic>? overrideMap,
    double? responsiveFontSize,
    Color? overrideColor,
    Map<String, dynamic>? component,
  }) {
    final tokenKey = key.contains('.') ? key.split('.').last : key;
    final tokens = overrideMap ??
        _map(_map(state.designTokens['typography'])?[tokenKey]) ??
        _map(_map(state.schema['typography'])?[tokenKey]);
    final size = responsiveFontSize ??
        _d(tokens?['size']) ??
        _d(tokens?['fontSize']);
    final color = overrideColor ??
        (tokenKey == 'pageTitle' || tokenKey == 'title'
            ? state.tokenColor('colors.textPrimary')
            : state.tokenColor('colors.textSecondary'));
    if (size == null || color == null) return null;
    final weight = _fontWeight(
      tokens?['weight'] ?? tokens?['fontWeight'],
      fallback: (tokenKey == 'pageTitle' || tokenKey == 'title')
          ? FontWeight.w800
          : FontWeight.w500,
    );
    return _font(
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        letterSpacing: _d(tokens?['letterSpacing']),
        height: _d(tokens?['lineHeight']),
        color: color,
      ),
      component: component,
    );
  }

  double? _tokenSize(String key) {
    final tokens = _map(_map(state.designTokens['typography'])?[key]);
    return _d(tokens?['size']) ?? _d(tokens?['fontSize']);
  }

  FontWeight _fontWeight(dynamic raw, {required FontWeight fallback}) {
    final value =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
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

  String _firstNonEmptyString(List<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
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

class GridGlobeMaskHelper {
  GridGlobeMaskHelper._();

  static final Map<String, bool> _maskNeededByUrl = <String, bool>{};

  @visibleForTesting
  static bool? cachedResult(String url) => _maskNeededByUrl[url];

  @visibleForTesting
  static void clearCache() => _maskNeededByUrl.clear();

  static void rememberResult(String url, bool needsMask) {
    if (_maskNeededByUrl.length >= 24 && !_maskNeededByUrl.containsKey(url)) {
      _maskNeededByUrl.remove(_maskNeededByUrl.keys.first);
    }
    _maskNeededByUrl[url] = needsMask;
  }

  /// Detects opaque neutral-light square mattes (e.g. a JPEG disguised as `.png`
  /// around a dark circular globe) so transparent PNGs pass through untouched.
  @visibleForTesting
  static bool shouldMaskOpaqueLightBackground(
    ByteData rgba,
    int width,
    int height,
  ) {
    if (width < 16 || height < 16) return false;
    final expectedBytes = width * height * 4;
    if (rgba.lengthInBytes < expectedBytes) return false;

    bool isOpaqueNeutralLight(int x, int y) {
      final offset = (y * width + x) * 4;
      final r = rgba.getUint8(offset);
      final g = rgba.getUint8(offset + 1);
      final b = rgba.getUint8(offset + 2);
      final a = rgba.getUint8(offset + 3);
      if (a < 240 || r < 220 || g < 220 || b < 220) return false;
      final spread = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      return spread <= 24;
    }

    final insetX = math.min(2, width - 1);
    final insetY = math.min(2, height - 1);
    final cornersMatch = isOpaqueNeutralLight(insetX, insetY) &&
        isOpaqueNeutralLight(width - 1 - insetX, insetY) &&
        isOpaqueNeutralLight(insetX, height - 1 - insetY) &&
        isOpaqueNeutralLight(width - 1 - insetX, height - 1 - insetY);
    if (!cornersMatch) return false;

    final centerOffset = ((height ~/ 2) * width + (width ~/ 2)) * 4;
    final cr = rgba.getUint8(centerOffset);
    final cg = rgba.getUint8(centerOffset + 1);
    final cb = rgba.getUint8(centerOffset + 2);
    final ca = rgba.getUint8(centerOffset + 3);
    if (ca < 200) return false;
    return (cr + cg + cb) / 3.0 < 170.0;
  }
}

class _GridOrbitGlobe extends StatefulWidget {
  const _GridOrbitGlobe({
    required this.orbitGlobeImageUrl,
    required this.width,
    required this.height,
    this.clip = false,
  });

  final String orbitGlobeImageUrl;
  final double width;
  final double height;
  final bool clip;

  @override
  State<_GridOrbitGlobe> createState() => _GridOrbitGlobeState();
}

class _GridOrbitGlobeState extends State<_GridOrbitGlobe> {
  ImageStream? _activeStream;
  ImageStreamListener? _activeListener;
  String? _probedUrl;

  void _clearStream() {
    if (_activeStream != null && _activeListener != null) {
      _activeStream!.removeListener(_activeListener!);
    }
    _activeStream = null;
    _activeListener = null;
  }

  void _ensureProbed(ImageProvider provider) {
    final url = widget.orbitGlobeImageUrl.trim();
    if (url.isEmpty ||
        GridGlobeMaskHelper.cachedResult(url) != null ||
        _probedUrl == url) {
      return;
    }
    _clearStream();
    _probedUrl = url;
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) async {
        final handle = info.image.clone();
        if (_activeListener == listener) {
          _clearStream();
        } else {
          stream.removeListener(listener);
        }
        try {
          final bytes = await handle.toByteData(format: ui.ImageByteFormat.rawRgba);
          if (bytes == null) return;
          final needsMask = GridGlobeMaskHelper.shouldMaskOpaqueLightBackground(
            bytes,
            handle.width,
            handle.height,
          );
          GridGlobeMaskHelper.rememberResult(url, needsMask);
          if (mounted) setState(() {});
        } finally {
          handle.dispose();
        }
      },
      onError: (_, __) {
        if (_activeListener == listener) _clearStream();
      },
    );
    _activeStream = stream;
    _activeListener = listener;
    stream.addListener(listener);
  }

  @override
  void didUpdateWidget(covariant _GridOrbitGlobe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orbitGlobeImageUrl != widget.orbitGlobeImageUrl) {
      _clearStream();
      _probedUrl = null;
    }
  }

  @override
  void dispose() {
    _clearStream();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.orbitGlobeImageUrl.trim();
    if (url.isEmpty) {
      return const SizedBox.shrink();
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: ClipRect(
        clipBehavior: widget.clip ? Clip.hardEdge : Clip.none,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: CachedNetworkImage(
            imageUrl: url,
            cacheManager: SduiNetworkImageCache.manager,
            width: widget.width,
            height: widget.height,
            fit: BoxFit.contain,
            imageBuilder: (context, imageProvider) {
              _ensureProbed(imageProvider);
              final applyMask =
                  GridGlobeMaskHelper.cachedResult(url) ?? isDark;
              Widget img = Image(
                image: imageProvider,
                width: widget.width,
                height: widget.height,
                fit: BoxFit.contain,
              );
              if (applyMask) {
                img = ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => const RadialGradient(
                    center: Alignment.center,
                    radius: 0.5,
                    colors: <Color>[
                      Colors.white,
                      Colors.white,
                      Color(0x00FFFFFF),
                    ],
                    stops: <double>[0.0, 0.795, 0.815],
                  ).createShader(bounds),
                  child: img,
                );
              }
              return img;
            },
            errorWidget: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
