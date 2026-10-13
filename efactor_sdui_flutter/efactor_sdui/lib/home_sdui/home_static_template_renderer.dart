import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../sdui/schema_runtime.dart';
import '../sdui/sdui_network_image_cache.dart';
import 'home_icon_resolver.dart';
import 'home_sdui_state.dart';

/// Generic renderer for schema-declared static Home templates.
///
/// This renderer NEVER branches on:
/// - user id
/// - account
/// - template id
/// - ui-grocery / ui-quick / ui-food / etc.
///
/// The rendered Home is derived from:
///
///   staticHomeUi.sections[]
///       ↓
///   section.type
///       OR
///   section.canonicalComponent
///       OR
///   rendererRequirements.canonicalComponents[]
///
/// Current supported semantic capabilities:
/// - pageHeader / brandBar
/// - banner / etaHeader / locationRow / promoStrip / bannerText
/// - search (including vegToggle)
/// - tabs / filterChips / lineCategories
/// - list / categoryRail / trendingRail / specialsRail
/// - list / buyAgainRail
/// - responsiveGrid / festiveGrid / lookbookGrid / productGrid / iconGrid
/// - dealGrid / restaurantGrid / exploreTiles
/// - offerGrid / promoHero
/// - exploreGrid
/// - viewMore / CTA
///
/// New templates using the same capabilities render without a Flutter update.
/// Unknown section types fall back to their canonical component or generic
/// schema rendering instead of becoming blank.
class HomeStaticTemplateRenderer {
  const HomeStaticTemplateRenderer({
    required this.state,
    required this.icons,
  });

  final HomeSduiState state;
  final HomeIconResolver icons;

  Widget build(
    BuildContext context,
    Map<String, dynamic> component,
  ) {
    final appearance =
        _map(component['appearance']) ?? const <String, dynamic>{};

    final semanticColors =
        _map(appearance['colors']) ?? const <String, dynamic>{};

    final theme =
        _map(state.schema['theme']) ??
        _map(state.schema['meta']?['layoutSnapshot']?['theme']) ??
        const <String, dynamic>{};

    final palette = _StaticHomePalette(
      pageBackground:
          _color(semanticColors['pageBackground']) ??
          _color(appearance['phoneBg']) ??
          _color(theme['phoneBg']) ??
          Theme.of(context).scaffoldBackgroundColor,
      surface:
          _color(semanticColors['surface']) ??
          _color(appearance['surfaceColor']) ??
          _color(theme['surfaceColor']) ??
          Theme.of(context).colorScheme.surface,
      surfaceAlt:
          _color(semanticColors['surfaceAlt']) ??
          _color(semanticColors['sectionBackground']) ??
          _color(appearance['surfaceColor']) ??
          Theme.of(context).colorScheme.surfaceContainerLowest,
      sectionBackground:
          _color(semanticColors['sectionBackground']) ??
          _color(semanticColors['surfaceAlt']) ??
          _color(appearance['surfaceColor']) ??
          Theme.of(context).colorScheme.surface,
      accent:
          _color(semanticColors['contentAccent']) ??
          _color(appearance['accentColor']) ??
          _color(theme['accentColor']) ??
          Theme.of(context).colorScheme.primary,
      secondaryAccent:
          _color(semanticColors['secondaryAccent']) ??
          _color(theme['accentGreen']) ??
          Theme.of(context).colorScheme.secondary,
      brandBackground:
          _color(semanticColors['secondaryAccent']),
      offer:
          _color(semanticColors['offer']) ??
          _color(semanticColors['contentAccent']) ??
          _color(appearance['accentColor']) ??
          Theme.of(context).colorScheme.primary,
      warning:
          _color(semanticColors['warning']) ??
          _color(theme['warning']) ??
          _color(appearance['warning']) ??
          _color(semanticColors['offer']) ??
          _color(appearance['accentColor']) ??
          Theme.of(context).colorScheme.tertiary,
      textPrimary:
          _color(semanticColors['textPrimary']) ??
          _color(appearance['textPrimary']) ??
          _color(theme['textPrimary']) ??
          Theme.of(context).colorScheme.onSurface,
      textSecondary:
          _color(semanticColors['textSecondary']) ??
          _color(appearance['textSecondary']) ??
          _color(theme['textSecondary']) ??
          Theme.of(context).colorScheme.onSurfaceVariant,
      textMuted:
          _color(semanticColors['textMuted']) ??
          _color(appearance['textMuted']) ??
          _color(theme['textMuted']) ??
          Theme.of(context).colorScheme.onSurfaceVariant,
    );

    final sections = _mapList(component['sections']);

    if (sections.isEmpty) {
      return ColoredBox(
        color: palette.pageBackground,
        child: const SizedBox.shrink(),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = MediaQuery.sizeOf(context);

        final width =
            constraints.hasBoundedWidth &&
                constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : viewport.width;

        final orientation = viewport.width > viewport.height
            ? 'landscape'
            : 'portrait';

        final runtime = SchemaRuntime(state.schema);

        final responsive = runtime.resolveResponsiveLayout(
          width,
          logicalHeight: viewport.height,
          orientation: orientation,
        );

        final responsiveConfig =
            responsive?.config ?? const <String, dynamic>{};

        final rawPadding =
            _number(responsiveConfig['pagePadding']) ??
            _number(responsiveConfig['horizontalPadding']) ??
            0;

        final maximumPadding = width > 0 ? width / 2 : 0;

        // Static templates match the web phone frame. Schema layouts often
        // leave pagePadding at 0; keep a small inset so brand bars and grids
        // do not sit on the screen edge.
        final resolvedPagePadding = rawPadding <= 0 ? 12.0 : rawPadding;

        final pagePadding = resolvedPagePadding
            .clamp(0.0, maximumPadding)
            .toDouble();

        final availableWidth =
            (width - pagePadding * 2).clamp(0.0, width).toDouble();

        final globalGap =
            _number(responsiveConfig['gridGap']) ??
            _number(responsiveConfig['cardGap']) ??
            _number(responsiveConfig['columnGap']) ??
            _number(theme['gridGap']) ??
            12;

        final maximumContentWidth = responsive?.maxContentWidth;

        Widget body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var index = 0; index < sections.length; index++) ...<Widget>[
              _buildSection(
                context,
                templateComponent: component,
                section: sections[index],
                availableWidth: availableWidth,
                globalColumns: responsive?.columns,
                globalGap: globalGap,
                palette: palette,
              ),
              if (index < sections.length - 1)
                SizedBox(
                  height:
                      _number(sections[index]['marginBottom']) ??
                      _number(sections[index]['sectionGap']) ??
                      globalGap,
                ),
            ],
          ],
        );

        body = Padding(
          padding: EdgeInsets.fromLTRB(
            pagePadding,
            8,
            pagePadding,
            0,
          ),
          child: body,
        );

        if (maximumContentWidth != null &&
            maximumContentWidth.isFinite &&
            maximumContentWidth > 0) {
          body = Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maximumContentWidth,
              ),
              child: body,
            ),
          );
        }

        return ColoredBox(
          color: palette.pageBackground,
          child: body,
        );
      },
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required Map<String, dynamic> templateComponent,
    required Map<String, dynamic> section,
    required double availableWidth,
    required int? globalColumns,
    required double globalGap,
    required _StaticHomePalette palette,
  }) {
    if (!_visible(section)) {
      return const SizedBox.shrink();
    }

    final type = _normalized(section['type']);

    final canonical = _canonicalComponent(
      templateComponent,
      section,
    );

    if (type == 'explore' 'tiles') {
      return _exploreTiles(
        section,
        columns: _sectionColumns(
          section,
          globalColumns,
          fallback: 3,
        ),
        gap: _sectionGap(section, globalGap),
        palette: palette,
      );
    }

    switch (type) {
      case 'brandbar':
        return _brandBar(
          section,
          templateComponent: templateComponent,
          palette: palette,
        );

      case 'etaheader':
        return _etaHeader(
          section,
          palette: palette,
        );

      case 'locationrow':
        return _locationRow(
          section,
          palette: palette,
        );

      case 'search':
        return _search(
          section,
          templateComponent: templateComponent,
          palette: palette,
        );

      case 'icongrid':
        return _iconGrid(
          section,
          columns: _sectionColumns(
            section,
            globalColumns,
            fallback: 4,
          ),
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'specialsrail':
        return _specialsRail(
          section,
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'dealgrid':
        return _dealGrid(
          section,
          availableWidth: availableWidth,
          columns: _sectionColumns(
            section,
            globalColumns,
            fallback: 2,
          ),
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'viewmore':
        return _viewMore(
          section,
          palette: palette,
        );

      case 'filterchips':
        return _filterChips(
          section,
          palette: palette,
        );

      case 'restaurantgrid':
        return _restaurantGrid(
          section,
          columns: _sectionColumns(
            section,
            globalColumns,
            fallback: 2,
          ),
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'tabs':
        return _tabs(
          section,
          palette: palette,
        );

      case 'categoryrail':
        return _circularCategoryRail(
          section,
          palette: palette,
        );

      case 'linecategories':
        return _categoryRail(
          section,
          palette: palette,
        );

      case 'promostrip':
        return _promoStrip(
          section,
          palette: palette,
        );

      case 'lookbookgrid':
        return _lookbookGrid(
          section,
          availableWidth: availableWidth,
          columns: _sectionColumns(
            section,
            globalColumns,
            fallback: 2,
          ),
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'bannertext':
        return _bannerText(
          section,
          palette: palette,
        );

      case 'productgrid':
        return _sectionShell(
          section,
          palette: palette,
          child: _captionBelowGrid(
            section,
            availableWidth: availableWidth,
            columns: _sectionColumns(
              section,
              globalColumns,
              fallback: 2,
            ),
            gap: _sectionGap(section, globalGap),
            palette: palette,
          ),
        );

      case 'trendingrail':
        return _trendingRail(
          section,
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'festivegrid':
        return _responsiveItemGrid(
          section,
          availableWidth: availableWidth,
          columns: _sectionColumns(
            section,
            globalColumns,
            fallback: 2,
          ),
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'offergrid':
        return _offerCatalogGrid(
          section,
          availableWidth: availableWidth,
          columns: _sectionColumns(
            section,
            globalColumns,
            fallback: 3,
          ),
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'promohero':
        return _promoHero(
          section,
          palette: palette,
        );

      case 'exploregrid':
        return _exploreGrid(
          section,
          availableWidth: availableWidth,
          columns: _sectionColumns(
            section,
            globalColumns,
            fallback: 2,
          ),
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'buyagainrail':
        return _productRail(
          section,
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'cta':
        return _cta(
          section,
          palette: palette,
        );
    }

    switch (canonical) {
      case 'pageheader':
        return _brandBar(
          section,
          templateComponent: templateComponent,
          palette: palette,
        );

      case 'banner':
        if (_resolvedText(section['eta']) != null ||
            _resolvedText(section['location']) != null) {
          return _etaHeader(
            section,
            palette: palette,
          );
        }

        return _infoSection(
          section,
          palette: palette,
        );

      case 'list':
        return _renderListCapability(
          section,
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );

      case 'actionbutton':
        return _viewMore(
          section,
          palette: palette,
        );

      case 'responsivegrid':
        return _responsiveItemGrid(
          section,
          availableWidth: availableWidth,
          columns: _sectionColumns(
            section,
            globalColumns,
          ),
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );
    }

    final items = _mapList(section['items']);

    if (items.isNotEmpty) {
      if (_itemsLookLikeProducts(items)) {
        return _productRail(
          section,
          gap: _sectionGap(section, globalGap),
          palette: palette,
        );
      }

      return _genericItems(
        section,
        items: items,
        availableWidth: availableWidth,
        columns: _sectionColumns(
          section,
          globalColumns,
        ),
        gap: _sectionGap(section, globalGap),
        palette: palette,
      );
    }

    return _infoSection(
      section,
      palette: palette,
    );
  }

  String _canonicalComponent(
    Map<String, dynamic> template,
    Map<String, dynamic> section,
  ) {
    final direct = _normalized(section['canonicalComponent']);

    if (direct.isNotEmpty) {
      return direct;
    }

    final requirements = _map(template['rendererRequirements']);

    final mappings = requirements?['canonicalComponents'];

    if (mappings is List) {
      final sectionType = _normalized(section['type']);

      for (final raw in mappings) {
        final mapping = _map(raw);
        if (mapping == null) continue;

        if (_normalized(mapping['sectionType']) == sectionType) {
          return _normalized(mapping['component']);
        }
      }
    }

    return '';
  }

  Widget _brandBar(
    Map<String, dynamic> section, {
    required Map<String, dynamic> templateComponent,
    required _StaticHomePalette palette,
  }) {
    final brand = _map(templateComponent['brand']);

    final title =
        _resolvedText(section['title']) ??
        _resolvedText(brand?['name']);

    final subtitle = _resolvedText(section['subtitle']);

    final logoUrl =
        _resolvedText(section['logoUrl']) ??
        _resolvedText(brand?['logoUrl']);

    final padding =
        _edgeInsets(section['padding']) ??
        const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        );

    final background =
        _resolvedColor(section['backgroundColor']) ??
        palette.textPrimary;

    final onBackground = _onBackground(
      background,
      palette.surface,
      palette.textPrimary,
    );

    final radius = _number(section['borderRadius']) ?? 14;

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: _border(section),
      ),
      child: Row(
        children: <Widget>[
          if (logoUrl != null) ...<Widget>[
            _image(
              logoUrl,
              width: _number(section['logoWidth']) ?? 42,
              height: _number(section['logoHeight']) ?? 26,
              fit: _boxFit(section['logoFit']) ?? BoxFit.contain,
            ),
            SizedBox(
              width: _number(section['gap']) ?? 10,
            ),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(section['titleColor']) ??
                          onBackground,
                      fontSize:
                          _number(section['titleFontSize']) ?? 18,
                      fontWeight: _fontWeight(
                        section['titleFontWeight'],
                        fallback: FontWeight.w800,
                      ),
                    ),
                  ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(section['subtitleColor']) ??
                          onBackground.withValues(alpha: 0.78),
                      fontSize:
                          _number(section['subtitleFontSize']) ?? 12,
                      fontWeight: _fontWeight(
                        section['subtitleFontWeight'],
                        fallback: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return _tapSurface(
      section,
      content,
      item: section,
    );
  }

  Widget _etaHeader(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final eta =
        _resolvedText(section['eta']) ??
        _resolvedText(section['title']);

    final location =
        _resolvedText(section['location']) ??
        _resolvedText(section['subtitle']);

    final padding =
        _edgeInsets(section['padding']) ??
        const EdgeInsets.fromLTRB(2, 2, 2, 8);

    Widget result = Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (eta != null)
            Text(
              eta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    _resolvedColor(section['etaColor']) ??
                    palette.textPrimary,
                fontSize: _number(section['etaFontSize']) ?? 22,
                fontWeight: _fontWeight(
                  section['etaFontWeight'],
                  fallback: FontWeight.w800,
                ),
              ),
            ),
          if (location != null) ...<Widget>[
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                Icon(
                  Icons.location_on,
                  size: 16,
                  color:
                      _resolvedColor(section['locationColor']) ??
                      palette.accent,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(section['locationColor']) ??
                          palette.textSecondary,
                      fontSize:
                          _number(section['locationFontSize']) ?? 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color:
                      _resolvedColor(section['locationColor']) ??
                      palette.textSecondary,
                ),
              ],
            ),
          ],
        ],
      ),
    );

    return _tapSurface(
      section,
      result,
      item: section,
    );
  }

  Widget _locationRow(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final title =
        _resolvedText(section['title']) ??
        _resolvedText(section['location']);

    final subtitle = _resolvedText(section['subtitle']);

    final wallet = _resolvedText(section['wallet']);

    final padding =
        _edgeInsets(section['padding']) ??
        const EdgeInsets.symmetric(
          horizontal: 4,
          vertical: 6,
        );

    Widget result = Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Icon(
            Icons.location_on,
            size: _number(section['iconSize']) ?? 22,
            color:
                _resolvedColor(section['iconColor']) ??
                palette.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null)
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                _resolvedColor(
                                  section['titleColor'],
                                ) ??
                                palette.textPrimary,
                            fontSize:
                                _number(
                                  section['titleFontSize'],
                                ) ??
                                14,
                            fontWeight: _fontWeight(
                              section['titleFontWeight'],
                              fallback: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: palette.textMuted,
                      ),
                    ],
                  ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(
                            section['subtitleColor'],
                          ) ??
                          palette.textMuted,
                      fontSize:
                          _number(
                            section['subtitleFontSize'],
                          ) ??
                          11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (wallet != null) ...<Widget>[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: palette.textMuted.withValues(
                    alpha: 0.18,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FaIcon(
                    icons.resolve('wallet'),
                    size: 13,
                    color: palette.textPrimary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    wallet,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return _tapSurface(
      section,
      result,
      item: section,
    );
  }

  Widget _search(
    Map<String, dynamic> section, {
    required Map<String, dynamic> templateComponent,
    required _StaticHomePalette palette,
  }) {
    final placeholder =
        _resolvedText(section['placeholder']) ?? '';

    final brand = _map(templateComponent['brand']);

    final brandLogo =
        _resolvedText(section['logoUrl']) ??
        _resolvedText(brand?['logoUrl']);

    final showLogo = section['showLogo'] == true;

    final actions = _stringList(section['actions']);

    final inlineActions = actions
        .where(_isInlineSearchAction)
        .toList(growable: false);

    final trailingActions = actions
        .where((token) => !_isInlineSearchAction(token))
        .toList(growable: false);

    Widget search = Container(
      height: _number(section['height']) ?? 48,
      padding:
          _edgeInsets(section['padding']) ??
          const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color:
            _resolvedColor(section['backgroundColor']) ??
            palette.surface,
        borderRadius: BorderRadius.circular(
          _number(section['borderRadius']) ?? 14,
        ),
        border:
            _border(section) ??
            Border.all(
              color: palette.textMuted.withValues(alpha: 0.16),
            ),
      ),
      child: Row(
        children: <Widget>[
          if (showLogo && brandLogo != null) ...<Widget>[
            _image(
              brandLogo,
              width: _number(section['logoWidth']) ?? 26,
              height: _number(section['logoHeight']) ?? 20,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 9),
          ] else ...<Widget>[
            Icon(
              Icons.search_rounded,
              size: _number(section['iconSize']) ?? 20,
              color:
                  _resolvedColor(section['iconColor']) ??
                  palette.textMuted,
            ),
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Text(
              placeholder,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    _resolvedColor(section['placeholderColor']) ??
                    palette.textMuted,
                fontSize:
                    _number(section['fontSize']) ?? 14,
                fontWeight: _fontWeight(
                  section['fontWeight'],
                  fallback: FontWeight.w500,
                ),
              ),
            ),
          ),
          for (final token in inlineActions) ...<Widget>[
            const SizedBox(width: 8),
            FaIcon(
              icons.resolve(token),
              size: _number(section['actionIconSize']) ?? 16,
              color:
                  _resolvedColor(section['actionIconColor']) ??
                  palette.textMuted,
            ),
          ],
          if (section['trailingIcon'] != null)
            FaIcon(
              icons.resolve(
                _resolvedText(section['trailingIcon']),
              ),
              size: _number(section['trailingIconSize']) ?? 17,
              color:
                  _resolvedColor(section['trailingIconColor']) ??
                  palette.textMuted,
            ),
        ],
      ),
    );

    Widget result = _tapSurface(
      section,
      search,
      item: section,
    );

    final trailingAction =
        _map(section['trailingAction']) ??
        const <String, dynamic>{};

    final trailingLabel =
        _resolvedText(section['trailingLabel']) ??
        _resolvedText(trailingAction['label']);

    final trailingImage =
        _resolvedText(section['trailingImage']) ??
        _resolvedText(section['storeImage']) ??
        _resolvedText(trailingAction['image']);

    final hasStoreChip =
        trailingLabel != null ||
        trailingImage != null ||
        _actionId(trailingAction) != null;

    final showVegToggle = section['vegToggle'] == true;

    if (trailingActions.isEmpty && !hasStoreChip && !showVegToggle) {
      return result;
    }

    return Row(
      children: <Widget>[
        Expanded(child: result),
        if (hasStoreChip) ...<Widget>[
          const SizedBox(width: 8),
          _searchTrailingChip(
            actionSource: trailingAction.isEmpty
                ? section
                : trailingAction,
            label: trailingLabel,
            image: trailingImage,
            palette: palette,
          ),
        ],
        for (final token in trailingActions) ...<Widget>[
          const SizedBox(width: 8),
          _circleAction(
            token,
            palette: palette,
            size: _number(section['circleActionSize']) ?? 40,
          ),
        ],
        if (showVegToggle) ...<Widget>[
          const SizedBox(width: 8),
          _vegToggleChip(section, palette),
        ],
      ],
    );
  }

  Widget _vegToggleChip(
    Map<String, dynamic> section,
    _StaticHomePalette palette,
  ) {
    final label = _resolvedText(section['vegLabel']) ?? 'VEG';
    final color =
        _resolvedColor(section['vegColor']) ?? palette.secondaryAccent;

    return Container(
      height: _number(section['height']) ?? 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _searchTrailingChip({
    required Map<String, dynamic> actionSource,
    required String? label,
    required String? image,
    required _StaticHomePalette palette,
  }) {
    Widget chip = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: palette.textMuted.withValues(alpha: 0.16),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: image != null
              ? _image(image, fit: BoxFit.cover)
              : Center(
                  child: FaIcon(
                    icons.resolve('store'),
                    size: 16,
                    color: palette.textPrimary,
                  ),
                ),
        ),
        if (label != null) ...<Widget>[
          const SizedBox(height: 3),
          SizedBox(
            width: 58,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );

    return _tapSurface(
      actionSource,
      chip,
      item: actionSource,
    );
  }

  Widget _tabs(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: _number(section['height']) ?? 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding:
            _edgeInsets(section['padding']) ??
            EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, __) => SizedBox(
          width: _number(section['gap']) ?? 16,
        ),
        itemBuilder: (_, index) {
          final item = items[index];

          final label =
              _resolvedText(
                item['label'] ?? item['title'],
                item: item,
              ) ??
              '';

          final selected = _itemIsActive(
            section,
            item,
            label: label,
          );

          Widget chip = Container(
            alignment: Alignment.center,
            padding:
                _edgeInsets(item['padding']) ??
                const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
            decoration: BoxDecoration(
              color:
                  _resolvedColor(
                    item['backgroundColor'],
                    item: item,
                  ) ??
                  Colors.transparent,
              borderRadius: BorderRadius.circular(
                _number(item['borderRadius']) ??
                    _number(section['borderRadius']) ??
                    999,
              ),
              border:
                  _border(item) ??
                  (selected
                      ? Border.all(
                          color: palette.accent,
                          width: 1.4,
                        )
                      : null),
            ),
            child: Text(
              label,
              style: TextStyle(
                color:
                    _resolvedColor(
                      item['textColor'],
                      item: item,
                    ) ??
                    (selected
                        ? palette.accent
                        : palette.textMuted),
                fontSize:
                    _number(item['fontSize']) ??
                    _number(section['fontSize']) ??
                    13,
                fontWeight: selected
                    ? FontWeight.w800
                    : FontWeight.w600,
              ),
            ),
          );

          return _tapSurface(
            item,
            chip,
            item: item,
          );
        },
      ),
    );
  }

  Widget _circularCategoryRail(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final imageSize =
        _number(section['imageSize']) ?? 64;

    return SizedBox(
      height: _number(section['height']) ?? imageSize + 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding:
            _edgeInsets(section['padding']) ??
            EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, __) => SizedBox(
          width: _number(section['gap']) ?? 14,
        ),
        itemBuilder: (_, index) {
          final item = items[index];

          final label =
              _resolvedText(
                item['label'] ?? item['title'],
                item: item,
              ) ??
              '';

          final image = _resolvedText(
            item['image'],
            item: item,
          );

          final selected = _itemIsActive(
            section,
            item,
            label: label,
          );

          Widget tile = Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: imageSize,
                height: imageSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? palette.accent
                        : palette.textMuted.withValues(
                            alpha: 0.12,
                          ),
                    width: selected ? 2.4 : 1,
                  ),
                ),
                padding: EdgeInsets.all(
                  selected ? 2 : 1,
                ),
                child: ClipOval(
                  child: image == null
                      ? ColoredBox(
                          color: palette.surfaceAlt,
                          child: Icon(
                            Icons.image_outlined,
                            color: palette.textMuted,
                          ),
                        )
                      : _image(
                          image,
                          width: imageSize,
                          height: imageSize,
                          fit:
                              _boxFit(item['imageFit']) ??
                              BoxFit.cover,
                        ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: imageSize + 8,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color:
                        _resolvedColor(
                          item['textColor'],
                          item: item,
                        ) ??
                        palette.textPrimary,
                    fontSize:
                        _number(item['fontSize']) ??
                        _number(section['fontSize']) ??
                        11,
                    fontWeight: selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
            ],
          );

          return _tapSurface(
            item,
            tile,
            item: item,
          );
        },
      ),
    );
  }

  Widget _promoStrip(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: _number(section['height']) ?? 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) => SizedBox(
          width: _number(section['gap']) ?? 8,
        ),
        itemBuilder: (_, index) {
          final item = items[index];

          final label =
              _resolvedText(
                item['label'] ?? item['title'] ?? item['text'],
                item: item,
              ) ??
              '';

          Widget chip = Container(
            alignment: Alignment.center,
            padding:
                _edgeInsets(item['padding']) ??
                const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
            decoration: BoxDecoration(
              color:
                  _resolvedColor(
                    item['backgroundColor'],
                    item: item,
                  ) ??
                  palette.surfaceAlt,
              borderRadius: BorderRadius.circular(
                _number(item['borderRadius']) ??
                    _number(section['borderRadius']) ??
                    999,
              ),
              border: _border(item),
            ),
            child: Text(
              label,
              style: TextStyle(
                color:
                    _resolvedColor(
                      item['textColor'],
                      item: item,
                    ) ??
                    palette.accent,
                fontSize:
                    _number(item['fontSize']) ??
                    _number(section['fontSize']) ??
                    12,
                fontWeight: FontWeight.w600,
              ),
            ),
          );

          return _tapSurface(
            item,
            chip,
            item: item,
          );
        },
      ),
    );
  }

  Widget _lookbookGrid(
    Map<String, dynamic> section, {
    required double availableWidth,
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final aspect =
        _number(section['itemAspectRatio']) ??
        _number(section['aspectRatio']) ??
        0.72;

    final cards = <Widget>[
      for (final item in items)
        _lookbookCard(
          item,
          aspectRatio: aspect,
          palette: palette,
        ),
    ];

    return _columnGrid(
      children: cards,
      columns: columns,
      gap: gap,
    );
  }

  Widget _lookbookCard(
    Map<String, dynamic> item, {
    required double aspectRatio,
    required _StaticHomePalette palette,
  }) {
    final image = _resolvedText(
      item['image'],
      item: item,
    );

    final title = _resolvedText(
      item['title'] ?? item['label'],
      item: item,
    );

    final subtitle = _resolvedText(
      item['subtitle'] ?? item['offer'] ?? item['caption'],
      item: item,
    );

    final radius =
        _number(item['borderRadius']) ?? 14;

    Widget card = AspectRatio(
      aspectRatio: aspectRatio,
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(radius),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (image != null)
              _image(
                image,
                fit: _boxFit(item['imageFit']) ?? BoxFit.cover,
              )
            else
              ColoredBox(color: palette.surfaceAlt),
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  10,
                  10,
                  10,
                  10,
                ),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(
                    10,
                    8,
                    10,
                    8,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: <Widget>[
                      if (title != null)
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                _resolvedColor(
                                  item['titleColor'],
                                  item: item,
                                ) ??
                                palette.textPrimary,
                            fontSize:
                                _number(
                                  item['titleFontSize'],
                                ) ??
                                13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      if (subtitle != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Container(
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color:
                                _resolvedColor(
                                  item['badgeColor'],
                                  item: item,
                                ) ??
                                palette.secondaryAccent,
                            borderRadius:
                                BorderRadius.circular(5),
                          ),
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  _resolvedColor(
                                    item['subtitleColor'],
                                    item: item,
                                  ) ??
                                  palette.surface,
                              fontSize:
                                  _number(
                                    item['subtitleFontSize'],
                                  ) ??
                                  10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return _tapSurface(
      item,
      card,
      item: item,
    );
  }

  Widget _bannerText(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final text =
        _resolvedText(section['text']) ??
        _resolvedText(section['title']);

    if (text == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding:
          _edgeInsets(section['padding']) ??
          const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color:
              _resolvedColor(section['color']) ??
              _resolvedColor(section['textColor']) ??
              _resolvedColor(section['titleColor']) ??
              palette.warning,
          fontSize: _number(section['fontSize']) ?? 18,
          fontWeight: _fontWeight(
            section['fontWeight'] ?? section['titleFontWeight'],
            fallback: FontWeight.w800,
          ),
          letterSpacing:
              _number(section['letterSpacing']) ?? 0.4,
        ),
      ),
    );
  }

  Widget _iconGrid(
    Map<String, dynamic> section, {
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);
    if (items.isEmpty) return const SizedBox.shrink();

    return _columnGrid(
      columns: columns,
      gap: gap,
      children: <Widget>[
        for (final item in items)
          _tapSurface(
            item,
            Column(
              children: <Widget>[
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      _number(item['borderRadius']) ?? 16,
                    ),
                    child: _itemImage(item, palette),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _resolvedText(item['label'] ?? item['title'], item: item) ??
                      '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            item: item,
          ),
      ],
    );
  }

  Widget _specialsRail(
    Map<String, dynamic> section, {
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);
    if (items.isEmpty) {
      return _infoSection(section, palette: palette);
    }

    final itemWidth = _number(section['itemWidth']) ?? 132;
    final rail = SizedBox(
      height: _number(section['railHeight']) ?? itemWidth + 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) => SizedBox(width: gap),
        itemBuilder: (_, index) {
          final item = items[index];
          return SizedBox(
            width: itemWidth,
            child: _tapSurface(
              item,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: _itemImage(item, palette),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _resolvedText(item['title'] ?? item['label'], item: item) ??
                        '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              item: item,
            ),
          );
        },
      ),
    );

    return _sectionShell(section, palette: palette, child: rail);
  }

  Widget _dealGrid(
    Map<String, dynamic> section, {
    required double availableWidth,
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    return _responsiveItemGrid(
      section,
      availableWidth: availableWidth,
      columns: columns,
      gap: gap,
      palette: palette,
    );
  }

  Widget _viewMore(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final label =
        _resolvedText(section['label']) ??
        _resolvedText(section['title']) ??
        _resolvedText(section['text']);
    if (label == null) return const SizedBox.shrink();

    return _tapSurface(
      section,
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                color:
                    _resolvedColor(section['color']) ?? palette.textPrimary,
                fontSize: _number(section['fontSize']) ?? 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: _resolvedColor(section['color']) ?? palette.textPrimary,
            ),
          ],
        ),
      ),
      item: section,
    );
  }

  Widget _filterChips(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);
    if (items.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: _number(section['height']) ?? 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) =>
            SizedBox(width: _number(section['gap']) ?? 8),
        itemBuilder: (_, index) {
          final item = items[index];
          final label =
              _resolvedText(item['label'] ?? item['title'], item: item) ?? '';
          final accent = item['accent'] == true ||
              _chipSelected(section, item, index, items);
          final icon = _resolvedText(item['icon'], item: item);

          return _tapSurface(
            item,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent
                    ? palette.secondaryAccent.withValues(alpha: 0.10)
                    : palette.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: accent
                      ? palette.secondaryAccent.withValues(alpha: 0.45)
                      : palette.textMuted.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    FaIcon(
                      icons.resolve(icon),
                      size: 12,
                      color: accent
                          ? palette.secondaryAccent
                          : palette.textSecondary,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: accent
                          ? palette.secondaryAccent
                          : palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            item: item,
          );
        },
      ),
    );
  }

  Widget _restaurantGrid(
    Map<String, dynamic> section, {
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);
    if (items.isEmpty) return const SizedBox.shrink();

    final grid = _columnGrid(
      columns: columns,
      gap: gap,
      children: <Widget>[
        for (final item in items) _restaurantCard(item, palette),
      ],
    );

    return _sectionShell(section, palette: palette, child: grid);
  }

  Widget _restaurantCard(
    Map<String, dynamic> item,
    _StaticHomePalette palette,
  ) {
    final offer = _resolvedText(item['offer'], item: item);
    final rating = _resolvedText(item['rating'], item: item);
    final title = _resolvedText(item['title'] ?? item['label'], item: item);
    final subtitle = _resolvedText(item['subtitle'], item: item);
    final badge = _resolvedText(item['badge'], item: item);

    return _tapSurface(
      item,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 1.15,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _itemImage(item, palette),
                  if (offer != null)
                    Positioned(
                      left: 8,
                      top: 8,
                      right: 36,
                      child: Text(
                        offer,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.secondaryAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          shadows: <Shadow>[
                            Shadow(color: palette.surface, blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                  if (rating != null)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: palette.secondaryAccent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          rating,
                          style: TextStyle(
                            color: palette.surface,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (title != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
          ],
          if (badge != null) ...<Widget>[
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                FaIcon(icons.resolve('bolt'), size: 11, color: palette.secondaryAccent),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    badge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.secondaryAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      item: item,
    );
  }

  Widget _exploreTiles(
    Map<String, dynamic> section, {
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);
    if (items.isEmpty) return const SizedBox.shrink();

    final grid = _columnGrid(
      columns: columns,
      gap: gap,
      children: <Widget>[
        for (final item in items)
          _tapSurface(
            item,
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: palette.textMuted.withValues(alpha: 0.10),
                ),
              ),
              child: Column(
                children: <Widget>[
                  FaIcon(
                    icons.resolve(_resolvedText(item['icon'], item: item)),
                    size: 22,
                    color: palette.accent,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _resolvedText(item['title'] ?? item['label'], item: item) ??
                        '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            item: item,
          ),
      ],
    );

    return _sectionShell(section, palette: palette, child: grid);
  }

  Widget _itemImage(Map<String, dynamic> item, _StaticHomePalette palette) {
    final image = _resolvedText(item['image'], item: item);
    if (image == null) {
      return ColoredBox(
        color: palette.surfaceAlt,
        child: Icon(Icons.image_outlined, color: palette.textMuted),
      );
    }
    return _image(image, fit: _boxFit(item['imageFit']) ?? BoxFit.cover);
  }

  bool _chipSelected(
    Map<String, dynamic> section,
    Map<String, dynamic> item,
    int index,
    List<Map<String, dynamic>> items,
  ) {
    final label = _resolvedText(item['label'] ?? item['title'], item: item) ?? '';
    if (_itemIsActive(section, item, label: label) || item['accent'] == true) {
      return true;
    }
    final anyMarked = items.any((candidate) {
      final candidateLabel =
          _resolvedText(candidate['label'] ?? candidate['title'], item: candidate) ??
          '';
      return _itemIsActive(section, candidate, label: candidateLabel) ||
          candidate['accent'] == true ||
          candidate['selected'] == true;
    });
    return !anyMarked && index == 0;
  }

  Widget _captionBelowGrid(
    Map<String, dynamic> section, {
    required double availableWidth,
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final aspect =
        _number(section['imageAspectRatio']) ??
        _number(section['itemAspectRatio']) ??
        1.0;

    final cards = <Widget>[
      for (final item in items)
        _captionBelowCard(
          item,
          imageAspectRatio: aspect,
          palette: palette,
        ),
    ];

    return _columnGrid(
      children: cards,
      columns: columns,
      gap: gap,
    );
  }

  Widget _captionBelowCard(
    Map<String, dynamic> item, {
    required double imageAspectRatio,
    required _StaticHomePalette palette,
  }) {
    final image = _resolvedText(
      item['image'],
      item: item,
    );

    final title = _resolvedText(
      item['title'] ?? item['label'],
      item: item,
    );

    final subtitle = _resolvedText(
      item['subtitle'] ?? item['price'] ?? item['caption'],
      item: item,
    );

    final radius =
        _number(item['borderRadius']) ?? 14;

    Widget card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AspectRatio(
          aspectRatio: imageAspectRatio,
          child: Container(
            decoration: BoxDecoration(
              color: palette.surfaceAlt,
              borderRadius: BorderRadius.circular(radius),
            ),
            clipBehavior: Clip.antiAlias,
            child: image == null
                ? Icon(
                    Icons.image_outlined,
                    color: palette.textMuted,
                  )
                : _image(
                    image,
                    fit:
                        _boxFit(item['imageFit']) ??
                        BoxFit.cover,
                  ),
          ),
        ),
        if (title != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color:
                  _resolvedColor(
                    item['titleColor'],
                    item: item,
                  ) ??
                  palette.textPrimary,
              fontSize:
                  _number(item['titleFontSize']) ?? 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color:
                  _resolvedColor(
                    item['subtitleColor'],
                    item: item,
                  ) ??
                  palette.textMuted,
              fontSize:
                  _number(item['subtitleFontSize']) ?? 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );

    return _tapSurface(
      item,
      card,
      item: item,
    );
  }

  Widget _trendingRail(
    Map<String, dynamic> section, {
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final itemWidth =
        _number(section['itemWidth']) ?? 148;

    final imageAspect =
        _number(section['imageAspectRatio']) ?? 1.05;

    final rail = SizedBox(
      height:
          _number(section['railHeight']) ??
          itemWidth / imageAspect + 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) =>
            SizedBox(width: gap),
        itemBuilder: (_, index) {
          return SizedBox(
            width: itemWidth,
            child: _captionBelowCard(
              items[index],
              imageAspectRatio: imageAspect,
              palette: palette,
            ),
          );
        },
      ),
    );

    return _sectionShell(
      section,
      palette: palette,
      child: rail,
    );
  }

  Widget _circleAction(
    String token, {
    required _StaticHomePalette palette,
    required double size,
  }) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.surface,
        shape: BoxShape.circle,
        border: Border.all(
          color: palette.textMuted.withValues(alpha: 0.16),
        ),
      ),
      child: FaIcon(
        icons.resolve(token),
        size: size * 0.42,
        color: palette.textPrimary,
      ),
    );
  }

  Widget _offerCatalogGrid(
    Map<String, dynamic> section, {
    required double availableWidth,
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final cards = <Widget>[
      for (final item in items)
        _offerCatalogCard(
          item,
          palette: palette,
        ),
    ];

    final grid = _columnGrid(
      children: cards,
      columns: columns,
      gap: gap,
    );

    final title = _resolvedText(section['title']);
    final poweredBy = _resolvedText(section['poweredBy']);

    Widget content = grid;

    if (title != null || poweredBy != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (title != null)
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    _resolvedColor(section['titleColor']) ??
                    palette.offer,
                fontSize:
                    _number(section['titleFontSize']) ?? 15,
                fontWeight: _fontWeight(
                  section['titleFontWeight'],
                  fallback: FontWeight.w800,
                ),
              ),
            ),
          if (poweredBy != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              poweredBy,
              style: TextStyle(
                color:
                    _resolvedColor(section['poweredByColor']) ??
                    palette.offer,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          SizedBox(height: _number(section['titleGap']) ?? 10),
          grid,
        ],
      );
    }

    return Container(
      padding:
          _edgeInsets(section['padding']) ??
          const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color:
            _resolvedColor(section['backgroundColor']) ??
            palette.sectionBackground,
        borderRadius: BorderRadius.circular(
          _number(section['borderRadius']) ?? 18,
        ),
        border: _border(section),
      ),
      child: content,
    );
  }

  Widget _offerCatalogCard(
    Map<String, dynamic> item, {
    required _StaticHomePalette palette,
  }) {
    final image = _resolvedText(item['image'], item: item);
    final title = _resolvedText(
      item['title'] ?? item['label'],
      item: item,
    );
    final offer = _resolvedText(item['offer'], item: item);
    final radius = _number(item['borderRadius']) ?? 14;

    Widget card = Container(
      padding:
          _edgeInsets(item['padding']) ??
          const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color:
            _resolvedColor(item['backgroundColor'], item: item) ??
            palette.surface,
        borderRadius: BorderRadius.circular(radius),
        border: _border(item),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (title != null)
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    _resolvedColor(item['titleColor'], item: item) ??
                    palette.textPrimary,
                fontSize: _number(item['titleFontSize']) ?? 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          if (offer != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              offer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    _resolvedColor(item['offerColor'], item: item) ??
                    palette.offer,
                fontSize: _number(item['offerFontSize']) ?? 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio:
                _number(item['imageAspectRatio']) ?? 1.05,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                _number(item['imageBorderRadius']) ?? 10,
              ),
              child: image == null
                  ? ColoredBox(
                      color: palette.surfaceAlt,
                      child: Icon(
                        Icons.image_outlined,
                        color: palette.textMuted,
                      ),
                    )
                  : _image(
                      image,
                      fit: _boxFit(item['imageFit']) ?? BoxFit.cover,
                    ),
            ),
          ),
        ],
      ),
    );

    return _tapSurface(item, card, item: item);
  }

  Widget _promoHero(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final title = _resolvedText(section['title']);
    final subtitle = _resolvedText(section['subtitle']);
    final image = _resolvedText(section['image']);
    final logo = _resolvedText(section['logoUrl']);
    final cta = _resolvedText(section['cta']);

    Widget result = Container(
      padding:
          _edgeInsets(section['padding']) ??
          const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color:
            _resolvedColor(section['backgroundColor']) ??
            palette.surface,
        borderRadius: BorderRadius.circular(
          _number(section['borderRadius']) ?? 18,
        ),
        border:
            _border(section) ??
            Border.all(
              color: palette.textMuted.withValues(alpha: 0.08),
            ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (logo != null) ...<Widget>[
                  _image(
                    logo,
                    width: _number(section['logoWidth']) ?? 54,
                    height: _number(section['logoHeight']) ?? 22,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 8),
                ],
                if (title != null)
                  Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(section['titleColor']) ??
                          palette.textPrimary,
                      fontSize:
                          _number(section['titleFontSize']) ?? 18,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(section['subtitleColor']) ??
                          palette.textMuted,
                      fontSize:
                          _number(section['subtitleFontSize']) ?? 12,
                    ),
                  ),
                ],
                if (cta != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color:
                          _resolvedColor(section['ctaBackgroundColor']) ??
                          palette.secondaryAccent,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      cta,
                      style: TextStyle(
                        color:
                            _resolvedColor(section['ctaColor']) ??
                            palette.surface,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (image != null) ...<Widget>[
            const SizedBox(width: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _image(
                image,
                width: _number(section['imageWidth']) ?? 118,
                height: _number(section['imageHeight']) ?? 118,
                fit: _boxFit(section['imageFit']) ?? BoxFit.cover,
              ),
            ),
          ],
        ],
      ),
    );

    return Semantics(
      button: true,
      label: cta,
      child: _tapSurface(section, result, item: section),
    );
  }

  Widget _exploreGrid(
    Map<String, dynamic> section, {
    required double availableWidth,
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final hasExplicitSpan = items.any((item) {
      return item['columnSpan'] != null ||
          item['colSpan'] != null;
    });

    if (hasExplicitSpan) {
      return _responsiveItemGrid(
        section,
        availableWidth: availableWidth,
        columns: columns,
        gap: gap,
        palette: palette,
      );
    }

    final rows = _exploreRows(items);
    final aspect =
        _number(section['itemAspectRatio']) ?? 1.05;

    final grid = Column(
      children: <Widget>[
        for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) ...<Widget>[
          if (rowIndex > 0) SizedBox(height: gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = 0; i < rows[rowIndex].length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: gap),
                Expanded(
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: _gridItem(
                      rows[rowIndex][i],
                      palette: palette,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );

    return _sectionShell(
      section,
      palette: palette,
      child: grid,
    );
  }

  List<List<Map<String, dynamic>>> _exploreRows(
    List<Map<String, dynamic>> items,
  ) {
    if (items.length <= 2) {
      return <List<Map<String, dynamic>>>[items];
    }

    final rows = <List<Map<String, dynamic>>>[
      items.sublist(0, 2),
    ];
    final rest = items.sublist(2);
    final chunk = rest.length % 3 == 0 ? 3 : 2;

    for (var index = 0; index < rest.length; index += chunk) {
      final end = (index + chunk).clamp(0, rest.length).toInt();
      rows.add(rest.sublist(index, end));
    }

    return rows;
  }

  Widget _categoryRail(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final height = _number(section['height']) ?? 42;

    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding:
            _edgeInsets(section['padding']) ??
            EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, __) => SizedBox(
          width: _number(section['gap']) ?? 8,
        ),
        itemBuilder: (_, index) {
          final item = items[index];

          final label =
              _resolvedText(
                item['label'] ?? item['title'],
                item: item,
              ) ??
              '';

          final selected = _chipSelected(
            section,
            item,
            index,
            items,
          );

          final background =
              _resolvedColor(
                item['backgroundColor'],
                item: item,
              ) ??
              (selected == true
                  ? palette.accent
                  : palette.surface);

          final foreground =
              _resolvedColor(
                item['textColor'],
                item: item,
              ) ??
              (selected == true
                  ? palette.surface
                  : palette.textPrimary);

          Widget chip = Container(
            alignment: Alignment.center,
            padding:
                _edgeInsets(item['padding']) ??
                const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(
                _number(item['borderRadius']) ??
                    _number(section['borderRadius']) ??
                    999,
              ),
              border:
                  _border(item) ??
                  (selected == true
                      ? null
                      : Border.all(
                          color: palette.textMuted.withValues(
                            alpha: 0.18,
                          ),
                        )),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize:
                    _number(item['fontSize']) ??
                    _number(section['fontSize']) ??
                    13,
                fontWeight: _fontWeight(
                  item['fontWeight'] ??
                      section['fontWeight'],
                  fallback: selected == true
                      ? FontWeight.w700
                      : FontWeight.w600,
                ),
              ),
            ),
          );

          return _tapSurface(
            item,
            chip,
            item: item,
          );
        },
      ),
    );
  }

  Widget _renderListCapability(
    Map<String, dynamic> section, {
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return _infoSection(
        section,
        palette: palette,
      );
    }

    if (_itemsLookLikeProducts(items)) {
      return _productRail(
        section,
        gap: gap,
        palette: palette,
      );
    }

    return _categoryRail(
      section,
      palette: palette,
    );
  }

  bool _itemsLookLikeProducts(
    List<Map<String, dynamic>> items,
  ) {
    for (final item in items) {
      if (item['image'] != null ||
          item['price'] != null ||
          item['was'] != null ||
          item['offer'] != null) {
        return true;
      }
    }

    return false;
  }

  Widget _responsiveItemGrid(
    Map<String, dynamic> section, {
    required double availableWidth,
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty || availableWidth <= 0) {
      return _infoSection(
        section,
        palette: palette,
      );
    }

    final safeColumns = columns.clamp(1, 12).toInt();

    final usableWidth =
        availableWidth - gap * (safeColumns - 1);

    final cellWidth = usableWidth > 0
        ? usableWidth / safeColumns
        : availableWidth;

    final rowHeight =
        _number(section['rowHeight']) ??
        (cellWidth /
            (_number(section['itemAspectRatio']) ?? 0.92));

    final placements = _placeGridItems(
      items,
      columns: safeColumns,
    );

    final rowCount = placements.fold<int>(
      0,
      (maximum, placement) {
        final end =
            placement.row + placement.rowSpan;

        return end > maximum ? end : maximum;
      },
    );

    final contentHeight = rowCount == 0
        ? 0.0
        : rowCount * rowHeight +
            (rowCount - 1) * gap;

    final grid = SizedBox(
      width: availableWidth,
      height: contentHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (final placement in placements)
            Positioned(
              left:
                  placement.column *
                  (cellWidth + gap),
              top:
                  placement.row *
                  (rowHeight + gap),
              width:
                  cellWidth * placement.columnSpan +
                  gap * (placement.columnSpan - 1),
              height:
                  rowHeight * placement.rowSpan +
                  gap * (placement.rowSpan - 1),
              child: _gridItem(
                placement.item,
                palette: palette,
              ),
            ),
        ],
      ),
    );

    return _sectionShell(
      section,
      palette: palette,
      child: grid,
    );
  }

  List<_StaticGridPlacement> _placeGridItems(
    List<Map<String, dynamic>> items, {
    required int columns,
  }) {
    final occupied = <List<bool>>[];
    final placements = <_StaticGridPlacement>[];

    void ensureRows(int count) {
      while (occupied.length < count) {
        occupied.add(
          List<bool>.filled(
            columns,
            false,
          ),
        );
      }
    }

    bool canPlace(
      int row,
      int column,
      int columnSpan,
      int rowSpan,
    ) {
      ensureRows(row + rowSpan);

      for (var r = row; r < row + rowSpan; r++) {
        for (
          var c = column;
          c < column + columnSpan;
          c++
        ) {
          if (occupied[r][c]) {
            return false;
          }
        }
      }

      return true;
    }

    void occupy(
      int row,
      int column,
      int columnSpan,
      int rowSpan,
    ) {
      ensureRows(row + rowSpan);

      for (var r = row; r < row + rowSpan; r++) {
        for (
          var c = column;
          c < column + columnSpan;
          c++
        ) {
          occupied[r][c] = true;
        }
      }
    }

    for (final item in items) {
      var columnSpan =
          (_number(
                    item['columnSpan'] ??
                        item['colSpan'],
                  ) ??
                  (item['wide'] == true ? 2 : 1))
              .round();

      var rowSpan =
          (_number(item['rowSpan']) ??
                  (item['tall'] == true ? 2 : 1))
              .round();

      columnSpan = columnSpan
          .clamp(1, columns)
          .toInt();

      rowSpan = rowSpan.clamp(1, 12).toInt();

      var found = false;
      var row = 0;
      var column = 0;

      while (!found) {
        ensureRows(row + rowSpan);

        for (
          var candidate = 0;
          candidate <= columns - columnSpan;
          candidate++
        ) {
          if (canPlace(
            row,
            candidate,
            columnSpan,
            rowSpan,
          )) {
            column = candidate;
            found = true;
            break;
          }
        }

        if (!found) {
          row++;
        }
      }

      occupy(
        row,
        column,
        columnSpan,
        rowSpan,
      );

      placements.add(
        _StaticGridPlacement(
          item: item,
          row: row,
          column: column,
          columnSpan: columnSpan,
          rowSpan: rowSpan,
        ),
      );
    }

    return placements;
  }

  Widget _gridItem(
    Map<String, dynamic> item, {
    required _StaticHomePalette palette,
  }) {
    final imageUrl =
        _resolvedText(
          item['image'],
          item: item,
        );

    final title =
        _resolvedText(
          item['title'] ?? item['label'],
          item: item,
        );

    final subtitle =
        _resolvedText(
          item['subtitle'],
          item: item,
        );

    final tag =
        _resolvedText(
          item['tag'],
          item: item,
        );

    final offer =
        _resolvedText(
          item['offer'],
          item: item,
        );

    final price =
        _resolvedText(
          item['price'],
          item: item,
        );

    final previousPrice =
        _resolvedText(
          item['was'],
          item: item,
        );

    final radius =
        _number(item['borderRadius']) ?? 13;

    Widget content = Container(
      decoration: BoxDecoration(
        color:
            _resolvedColor(
              item['backgroundColor'],
              item: item,
            ) ??
            palette.surface,
        borderRadius:
            BorderRadius.circular(radius),
        border: _border(item),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (imageUrl != null)
            _image(
              imageUrl,
              fit:
                  _boxFit(item['imageFit']) ??
                  BoxFit.cover,
            ),

          // Image scrim only when schema provides imageOverlayColor — no invented black.
          if (imageUrl != null &&
              _resolvedColor(
                    item['imageOverlayColor'],
                    item: item,
                  ) !=
                  null)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.transparent,
                    _resolvedColor(
                      item['imageOverlayColor'],
                      item: item,
                    )!,
                  ],
                  stops: const <double>[
                    0.40,
                    1.0,
                  ],
                ),
              ),
            ),

          if (imageUrl == null &&
              item['icon'] != null)
            Center(
              child: FaIcon(
                icons.resolve(
                  _resolvedText(
                    item['icon'],
                    item: item,
                  ),
                ),
                size: _number(item['iconSize']) ?? 30,
                color:
                    _resolvedColor(
                      item['iconColor'],
                      item: item,
                    ) ??
                    palette.accent,
              ),
            ),

          if (tag != null)
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: palette.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),

          Positioned(
            left: 9,
            right: 9,
            bottom: 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: <Widget>[
                if (offer != null)
                  Text(
                    offer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(
                            item['offerColor'],
                            item: item,
                          ) ??
                          (imageUrl != null
                              ? palette.surface
                              : palette.offer),
                      fontSize:
                          _number(item['offerFontSize']) ??
                          10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),

                if (title != null)
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(
                            item['titleColor'],
                            item: item,
                          ) ??
                          (imageUrl != null
                              ? palette.surface
                              : palette.textPrimary),
                      fontSize:
                          _number(item['titleFontSize']) ??
                          12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),

                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(
                            item['subtitleColor'],
                            item: item,
                          ) ??
                          (imageUrl != null
                              ? palette.surface
                                  .withValues(alpha: 0.88)
                              : palette.textSecondary),
                      fontSize:
                          _number(
                            item['subtitleFontSize'],
                          ) ??
                          10,
                    ),
                  ),

                if (price != null ||
                    previousPrice != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 5,
                    crossAxisAlignment:
                        WrapCrossAlignment.center,
                    children: <Widget>[
                      if (price != null)
                        Text(
                          price,
                          style: TextStyle(
                            color:
                                _resolvedColor(
                                  item['priceColor'],
                                  item: item,
                                ) ??
                                (imageUrl != null
                                    ? palette.surface
                                    : palette.accent),
                            fontSize:
                                _number(
                                  item['priceFontSize'],
                                ) ??
                                12,
                            fontWeight:
                                FontWeight.w800,
                          ),
                        ),
                      if (previousPrice != null)
                        Text(
                          previousPrice,
                          style: TextStyle(
                            color: imageUrl != null
                                ? palette.surface
                                    .withValues(alpha: 0.75)
                                : palette.textMuted,
                            fontSize:
                                _number(
                                  item['wasFontSize'],
                                ) ??
                                10,
                            decoration:
                                TextDecoration.lineThrough,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return _tapSurface(
      item,
      content,
      item: item,
    );
  }

  Widget _productRail(
    Map<String, dynamic> section, {
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final items = _mapList(section['items']);

    if (items.isEmpty) {
      return _infoSection(
        section,
        palette: palette,
      );
    }

    final rail = SizedBox(
      height: _number(section['railHeight']) ??
          (items.any(
                (item) =>
                    _resolvedText(
                      item['addLabel'],
                      item: item,
                    ) !=
                    null,
              ) ||
              _map(section['itemAction']) != null
              ? 248
              : 210),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) =>
            SizedBox(width: gap),
        itemBuilder: (_, index) {
          final item = items[index];

          final image =
              _resolvedText(
                item['image'],
                item: item,
              );

          final title =
              _resolvedText(
                item['title'] ?? item['label'],
                item: item,
              ) ??
              '';

          final price =
              _resolvedText(
                item['price'],
                item: item,
              );

          final previous =
              _resolvedText(
                item['was'],
                item: item,
              );

          final addLabel =
              _resolvedText(
                item['addLabel'],
                item: item,
              ) ??
              _resolvedText(
                _map(section['itemAction'])?['label'],
              );

          final enabled =
              _resolvedBool(
                item['enabled'],
                item: item,
              ) ??
              true;

          Widget card = SizedBox(
            width:
                _number(item['width']) ??
                _number(section['itemWidth']) ??
                132,
            child: Container(
              decoration: BoxDecoration(
                color:
                    _resolvedColor(
                      item['backgroundColor'],
                      item: item,
                    ) ??
                    palette.surface,
                borderRadius: BorderRadius.circular(
                  _number(item['borderRadius']) ??
                      _number(
                        section['itemBorderRadius'],
                      ) ??
                      13,
                ),
                border:
                    _border(item) ??
                    Border.all(
                      color: palette.textMuted
                          .withValues(alpha: 0.10),
                    ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: image == null
                        ? Center(
                            child: Icon(
                              Icons.image_outlined,
                              color: palette.textMuted,
                            ),
                          )
                        : _image(
                            image,
                            fit:
                                _boxFit(
                                  item['imageFit'],
                                ) ??
                                BoxFit.cover,
                          ),
                  ),
                  Padding(
                    padding:
                        _edgeInsets(
                          item['contentPadding'],
                        ) ??
                        const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: <Widget>[
                        if (price != null ||
                            previous != null)
                          Wrap(
                            spacing: 5,
                            crossAxisAlignment:
                                WrapCrossAlignment.center,
                            children: <Widget>[
                              if (price != null)
                                Text(
                                  price,
                                  style: TextStyle(
                                    color:
                                        _resolvedColor(
                                          item[
                                              'priceColor'],
                                          item: item,
                                        ) ??
                                        palette.textPrimary,
                                    fontSize:
                                        _number(
                                          item[
                                              'priceFontSize'],
                                        ) ??
                                        13,
                                    fontWeight:
                                        FontWeight.w800,
                                  ),
                                ),
                              if (previous != null)
                                Text(
                                  previous,
                                  style: TextStyle(
                                    color:
                                        palette.textMuted,
                                    fontSize: 10,
                                    decoration:
                                        TextDecoration
                                            .lineThrough,
                                  ),
                                ),
                            ],
                          ),
                        const SizedBox(height: 3),
                        Text(
                          title,
                          maxLines: 2,
                          overflow:
                              TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                _resolvedColor(
                                  item['textColor'],
                                  item: item,
                                ) ??
                                palette.textPrimary,
                            fontSize:
                                _number(
                                  item['titleFontSize'],
                                ) ??
                                11,
                            fontWeight:
                                FontWeight.w600,
                          ),
                        ),
                        if (addLabel != null) ...<Widget>[
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            alignment: Alignment.center,
                            padding:
                                const EdgeInsets.symmetric(
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: palette.surface,
                              borderRadius:
                                  BorderRadius.circular(8),
                              border: Border.all(
                                color: enabled
                                    ? palette.offer
                                    : palette.textMuted
                                        .withValues(
                                          alpha: 0.35,
                                        ),
                              ),
                            ),
                            child: Text(
                              addLabel,
                              style: TextStyle(
                                color: enabled
                                    ? palette.offer
                                    : palette.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );

          return _tapSurface(
            item,
            card,
            item: item,
          );
        },
      ),
    );

    return _sectionShell(
      section,
      palette: palette,
      child: rail,
    );
  }

  Widget _cta(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final title = _resolvedText(section['title']);

    final subtitle =
        _resolvedText(section['subtitle']);

    final background =
        _resolvedColor(section['backgroundColor']) ??
        palette.brandBackground ??
        palette.secondaryAccent;

    final onBackground = _onBackground(
      background,
      palette.surface,
      palette.textPrimary,
    );

    Widget result = Container(
      padding:
          _edgeInsets(section['padding']) ??
          const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 13,
          ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(
          _number(section['borderRadius']) ?? 14,
        ),
        border: _border(section),
      ),
      child: Row(
        children: <Widget>[
          if (section['icon'] != null) ...<Widget>[
            FaIcon(
              icons.resolve(
                _resolvedText(section['icon']),
              ),
              color:
                  _resolvedColor(section['iconColor']) ??
                  onBackground,
              size: _number(section['iconSize']) ?? 18,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (title != null)
                  Text(
                    title,
                    style: TextStyle(
                      color:
                          _resolvedColor(
                            section['titleColor'],
                          ) ??
                          onBackground,
                      fontSize:
                          _number(
                            section['titleFontSize'],
                          ) ??
                          14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: TextStyle(
                      color:
                          _resolvedColor(
                            section['subtitleColor'],
                          ) ??
                          onBackground.withValues(alpha: 0.78),
                      fontSize:
                          _number(
                            section[
                                'subtitleFontSize'],
                          ) ??
                          12,
                    ),
                  ),
              ],
            ),
          ),
          if (section['trailingIcon'] != null)
            FaIcon(
              icons.resolve(
                _resolvedText(
                  section['trailingIcon'],
                ),
              ),
              size:
                  _number(
                    section['trailingIconSize'],
                  ) ??
                  16,
              color:
                  _resolvedColor(
                    section['trailingIconColor'],
                  ) ??
                  palette.textMuted,
            ),
        ],
      ),
    );

    return _tapSurface(
      section,
      result,
      item: section,
    );
  }

  Widget _genericItems(
    Map<String, dynamic> section, {
    required List<Map<String, dynamic>> items,
    required double availableWidth,
    required int columns,
    required double gap,
    required _StaticHomePalette palette,
  }) {
    final safeColumns = columns.clamp(1, 12).toInt();

    final unitWidth =
        (availableWidth -
            gap * (safeColumns - 1)) /
        safeColumns;

    final content = Wrap(
      spacing: gap,
      runSpacing: gap,
      children: <Widget>[
        for (final item in items)
          SizedBox(
            width: unitWidth > 0
                ? unitWidth
                : availableWidth,
            child: _genericItem(
              item,
              palette: palette,
            ),
          ),
      ],
    );

    return _sectionShell(
      section,
      palette: palette,
      child: content,
    );
  }

  Widget _genericItem(
    Map<String, dynamic> item, {
    required _StaticHomePalette palette,
  }) {
    final image =
        _resolvedText(
          item['image'],
          item: item,
        );

    final title =
        _resolvedText(
          item['title'] ?? item['label'],
          item: item,
        );

    final subtitle =
        _resolvedText(
          item['subtitle'] ??
              item['caption'] ??
              item['offer'] ??
              item['price'],
          item: item,
        );

    Widget result = Container(
      decoration: BoxDecoration(
        color:
            _resolvedColor(
              item['backgroundColor'],
              item: item,
            ) ??
            palette.surface,
        borderRadius: BorderRadius.circular(
          _number(item['borderRadius']) ?? 12,
        ),
        border: _border(item),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.stretch,
        children: <Widget>[
          if (image != null)
            AspectRatio(
              aspectRatio:
                  _number(item['imageAspectRatio']) ??
                  1,
              child: _image(
                image,
                fit:
                    _boxFit(item['imageFit']) ??
                    BoxFit.cover,
              ),
            ),
          Padding(
            padding:
                _edgeInsets(
                  item['contentPadding'],
                ) ??
                const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null)
                  Text(
                    title,
                    maxLines: 2,
                    overflow:
                        TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(
                            item['textColor'],
                            item: item,
                          ) ??
                          palette.textPrimary,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow:
                        TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          _resolvedColor(
                            item[
                                'secondaryTextColor'],
                            item: item,
                          ) ??
                          palette.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return _tapSurface(
      item,
      result,
      item: item,
    );
  }

  Widget _infoSection(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
  }) {
    final title =
        _resolvedText(
          section['title'] ??
              section['label'] ??
              section['eta'],
        );

    final subtitle =
        _resolvedText(
          section['subtitle'] ??
              section['caption'] ??
              section['message'] ??
              section['location'],
        );

    if (title == null && subtitle == null) {
      return const SizedBox.shrink();
    }

    Widget result = Container(
      padding:
          _edgeInsets(section['padding']) ??
          const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            _resolvedColor(section['backgroundColor']) ??
            palette.surface,
        borderRadius: BorderRadius.circular(
          _number(section['borderRadius']) ?? 12,
        ),
        border: _border(section),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (title != null)
            Text(
              title,
              style: TextStyle(
                color:
                    _resolvedColor(
                      section['titleColor'],
                    ) ??
                    palette.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          if (subtitle != null)
            Text(
              subtitle,
              style: TextStyle(
                color:
                    _resolvedColor(
                      section['subtitleColor'],
                    ) ??
                    palette.textSecondary,
              ),
            ),
        ],
      ),
    );

    return _tapSurface(
      section,
      result,
      item: section,
    );
  }

  Widget _sectionShell(
    Map<String, dynamic> section, {
    required _StaticHomePalette palette,
    required Widget child,
  }) {
    final title = _resolvedText(section['title']);

    final poweredBy =
        _resolvedText(section['poweredBy']);

    if (title == null && poweredBy == null) {
      return child;
    }

    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment:
              CrossAxisAlignment.center,
          children: <Widget>[
            if (title != null)
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        _resolvedColor(
                          section['titleColor'],
                        ) ??
                        palette.textPrimary,
                    fontSize:
                        _number(
                          section['titleFontSize'],
                        ) ??
                        16,
                    fontWeight: _fontWeight(
                      section['titleFontWeight'],
                      fallback:
                          FontWeight.w800,
                    ),
                  ),
                ),
              ),
            if (poweredBy != null)
              Text(
                poweredBy.toLowerCase().contains('powered')
                    ? poweredBy
                    : 'POWERED BY $poweredBy',
                maxLines: 1,
                overflow:
                    TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      _resolvedColor(
                        section['poweredByColor'],
                      ) ??
                      palette.accent,
                  fontSize:
                      _number(
                        section[
                            'poweredByFontSize'],
                      ) ??
                      11,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        SizedBox(
          height: _number(section['titleGap']) ?? 8,
        ),
        child,
      ],
    );
  }

  Widget _tapSurface(
    Map<String, dynamic> source,
    Widget child, {
    Map<String, dynamic>? item,
  }) {
    final actionId = _actionId(source);

    if (actionId == null) {
      return child;
    }

    final radius =
        _number(source['borderRadius']) ?? 12;

    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () async {
          await state.dispatchAction(
            actionId,
            item: item,
            event: <String, dynamic>{
              'componentId':
                  source['id'] ??
                  source['type'] ??
                  'staticHomeUi',
              'eventName': 'tap',
            },
          );
        },
        child: child,
      ),
    );
  }

  String? _actionId(
    Map<String, dynamic> source,
  ) {
    final direct =
        source['actionId']?.toString().trim();

    if (direct != null && direct.isNotEmpty) {
      return direct;
    }

    final events = _map(source['events']);

    final tap = _map(events?['tap']);

    final eventAction =
        tap?['actionId']?.toString().trim();

    if (eventAction != null &&
        eventAction.isNotEmpty) {
      return eventAction;
    }

    final action = source['action'];

    if (action is String) {
      final value = action.trim();

      if (value.isNotEmpty &&
          state.schema['actionRegistry']?[value] !=
              null) {
        return value;
      }
    }

    if (action is Map) {
      final actionMap =
          Map<String, dynamic>.from(
        action.cast<dynamic, dynamic>(),
      );

      final value =
          actionMap['actionId']
              ?.toString()
              .trim();

      if (value != null &&
          value.isNotEmpty) {
        return value;
      }
    }

    return null;
  }

  bool _visible(
    Map<String, dynamic> section,
  ) {
    if (section['visible'] == false) {
      return false;
    }

    final when = section['visibleWhen'];

    if (when != null &&
        !state.evaluate(
          when,
          item: section,
          parameters: state.parameters,
        )) {
      return false;
    }

    return true;
  }

  int _sectionColumns(
    Map<String, dynamic> section,
    int? globalColumns, {
    int? fallback,
  }) {
    final explicit =
        _number(section['columns'])?.round();

    if (explicit != null && explicit > 0) {
      return explicit.clamp(1, 12).toInt();
    }

    final layout =
        _map(section['layout']);

    final layoutColumns =
        _number(layout?['columns'])?.round();

    if (layoutColumns != null &&
        layoutColumns > 0) {
      return layoutColumns
          .clamp(1, 12)
          .toInt();
    }

    if (fallback != null && fallback > 0) {
      return fallback.clamp(1, 12).toInt();
    }

    if (globalColumns != null &&
        globalColumns > 0) {
      return globalColumns
          .clamp(1, 12)
          .toInt();
    }

    return 1;
  }

  double _sectionGap(
    Map<String, dynamic> section,
    double fallback,
  ) {
    return _number(section['gap']) ??
        _number(section['gridGap']) ??
        _number(
          _map(section['layout'])?['gap'],
        ) ??
        fallback;
  }

  Widget _image(
    String source, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
  }) {
    final value = source.trim();

    if (value.startsWith('asset://')) {
      final assetPath =
          value.substring('asset://'.length);

      return Image.asset(
        assetPath,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) =>
            const Center(
          child: Icon(
            Icons.broken_image_outlined,
          ),
        ),
      );
    }

    final uri = Uri.tryParse(value);

    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' &&
            uri.scheme != 'http')) {
      return SizedBox(
        width: width,
        height: height,
        child: const Center(
          child: Icon(
            Icons.broken_image_outlined,
          ),
        ),
      );
    }

    return CachedNetworkImage(
      imageUrl: value,
      cacheManager: SduiNetworkImageCache.manager,
      width: width,
      height: height,
      fit: fit,
      fadeInDuration:
          const Duration(milliseconds: 120),
      placeholder: (_, __) => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
          ),
        ),
      ),
      errorWidget: (_, __, ___) => Container(
        width: width,
        height: height,
        color: Colors.grey.withOpacity(0.06),
        child: Center(
          child: Icon(
            Icons.image_outlined,
            color: Colors.grey.withOpacity(0.35),
            size: math.min(width ?? 24.0, height ?? 24.0) * 0.5,
          ),
        ),
      ),
    );
  }

  Border? _border(
    Map<String, dynamic> source,
  ) {
    final color =
        _resolvedColor(source['borderColor']);

    if (color == null) {
      return null;
    }

    final width =
        _number(source['borderWidth']) ?? 1;

    if (width <= 0) {
      return null;
    }

    return Border.all(
      color: color,
      width: width,
    );
  }

  EdgeInsets? _edgeInsets(dynamic raw) {
    final resolved = state.resolve(
      raw,
      parameters: state.parameters,
    );

    if (resolved is num) {
      return EdgeInsets.all(
        resolved.toDouble(),
      );
    }

    if (resolved is! Map) {
      return null;
    }

    final map = Map<String, dynamic>.from(
      resolved.cast<dynamic, dynamic>(),
    );

    final horizontal =
        _number(map['horizontal']);

    final vertical =
        _number(map['vertical']);

    return EdgeInsets.only(
      left:
          _number(map['left']) ??
          horizontal ??
          0,
      top:
          _number(map['top']) ??
          vertical ??
          0,
      right:
          _number(map['right']) ??
          horizontal ??
          0,
      bottom:
          _number(map['bottom']) ??
          vertical ??
          0,
    );
  }

  BoxFit? _boxFit(dynamic raw) {
    switch (_normalized(raw)) {
      case 'fill':
        return BoxFit.fill;
      case 'contain':
        return BoxFit.contain;
      case 'fitwidth':
        return BoxFit.fitWidth;
      case 'fitheight':
        return BoxFit.fitHeight;
      case 'none':
        return BoxFit.none;
      case 'scaledown':
        return BoxFit.scaleDown;
      case 'cover':
        return BoxFit.cover;
    }

    return null;
  }

  Color _onBackground(
    Color background,
    Color light,
    Color dark,
  ) {
    return background.computeLuminance() < 0.45
        ? light
        : dark;
  }

  bool _isInlineSearchAction(String token) {
    final normalized = _normalized(token);

    return normalized == 'microphone' ||
        normalized == 'mic' ||
        normalized == 'camera';
  }

  bool _itemIsActive(
    Map<String, dynamic> section,
    Map<String, dynamic> item, {
    required String label,
  }) {
    if (_resolvedBool(item['active'], item: item) ==
        true) {
      return true;
    }

    if (_resolvedBool(item['selected'], item: item) ==
        true) {
      return true;
    }

    final active =
        _resolvedText(section['active']) ??
        _resolvedText(section['value']);

    if (active == null) {
      return false;
    }

    final itemId = _resolvedText(
      item['id'],
      item: item,
    );

    return active == label ||
        (itemId != null && active == itemId);
  }

  List<String> _stringList(dynamic raw) {
    final resolved = state.resolve(
      raw,
      parameters: state.parameters,
    );

    if (resolved is! List) {
      return const <String>[];
    }

    return resolved
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  Widget _columnGrid({
    required List<Widget> children,
    required int columns,
    required double gap,
  }) {
    final safeColumns = columns.clamp(1, 12).toInt();
    final rows = <Widget>[];

    for (var index = 0;
        index < children.length;
        index += safeColumns) {
      final end = (index + safeColumns)
          .clamp(0, children.length)
          .toInt();
      final rowItems = children.sublist(index, end);

      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (var i = 0; i < rowItems.length; i++) ...<Widget>[
              if (i > 0) SizedBox(width: gap),
              Expanded(child: rowItems[i]),
            ],
            for (var i = rowItems.length;
                i < safeColumns;
                i++) ...<Widget>[
              SizedBox(width: gap),
              const Expanded(child: SizedBox.shrink()),
            ],
          ],
        ),
      );

      if (end < children.length) {
        rows.add(SizedBox(height: gap));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  FontWeight _fontWeight(
    dynamic raw, {
    required FontWeight fallback,
  }) {
    final resolved = state.resolve(
      raw,
      parameters: state.parameters,
    );

    if (resolved is num) {
      final value =
          resolved.toInt().clamp(100, 900);

      return switch (value) {
        <= 150 => FontWeight.w100,
        <= 250 => FontWeight.w200,
        <= 350 => FontWeight.w300,
        <= 450 => FontWeight.w400,
        <= 550 => FontWeight.w500,
        <= 650 => FontWeight.w600,
        <= 750 => FontWeight.w700,
        <= 850 => FontWeight.w800,
        _ => FontWeight.w900,
      };
    }

    switch (
        resolved?.toString().trim().toLowerCase()) {
      case 'normal':
      case 'regular':
        return FontWeight.w400;
      case 'medium':
        return FontWeight.w500;
      case 'semibold':
      case 'semi-bold':
        return FontWeight.w600;
      case 'bold':
        return FontWeight.w700;
      case 'extrabold':
      case 'extra-bold':
        return FontWeight.w800;
      case 'black':
        return FontWeight.w900;
    }

    return fallback;
  }

  List<Map<String, dynamic>> _mapList(
    dynamic raw,
  ) {
    final resolved = state.resolve(
      raw,
      parameters: state.parameters,
    );

    if (resolved is! List) {
      return const <Map<String, dynamic>>[];
    }

    return resolved
        .whereType<Map>()
        .map(
          (value) =>
              Map<String, dynamic>.from(
            value.cast<dynamic, dynamic>(),
          ),
        )
        .toList(growable: false);
  }

  Map<String, dynamic>? _map(dynamic raw) {
    if (raw is! Map) {
      return null;
    }

    return Map<String, dynamic>.from(
      raw.cast<dynamic, dynamic>(),
    );
  }

  String _normalized(dynamic value) {
    return value
            ?.toString()
            .trim()
            .toLowerCase()
            .replaceAll(
              RegExp(r'[^a-z0-9]+'),
              '',
            ) ??
        '';
  }

  String? _resolvedText(
    dynamic raw, {
    Map<String, dynamic>? item,
  }) {
    final resolved = state.resolve(
      raw,
      item: item,
      parameters: state.parameters,
    );

    final text =
        resolved?.toString().trim();

    if (text == null || text.isEmpty) {
      return null;
    }

    return text;
  }

  bool? _resolvedBool(
    dynamic raw, {
    Map<String, dynamic>? item,
  }) {
    if (raw == null) {
      return null;
    }

    final resolved = state.resolve(
      raw,
      item: item,
      parameters: state.parameters,
    );

    if (resolved is bool) {
      return resolved;
    }

    final text =
        resolved?.toString().trim().toLowerCase();

    if (text == 'true' ||
        text == '1' ||
        text == 'yes') {
      return true;
    }

    if (text == 'false' ||
        text == '0' ||
        text == 'no') {
      return false;
    }

    return null;
  }

  double? _number(dynamic raw) {
    final resolved = state.resolve(
      raw,
      parameters: state.parameters,
    );

    if (resolved is num) {
      return resolved.toDouble();
    }

    return double.tryParse(
      resolved?.toString().trim() ?? '',
    );
  }

  Color? _resolvedColor(
    dynamic raw, {
    Map<String, dynamic>? item,
  }) {
    final resolved = state.resolve(
      raw,
      item: item,
      parameters: state.parameters,
    );

    return _color(resolved);
  }

  Color? _color(dynamic raw) {
    final text = raw?.toString().trim();

    if (text == null || text.isEmpty) {
      return null;
    }

    final rgb = RegExp(
      r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+))?\s*\)$',
      caseSensitive: false,
    ).firstMatch(text);

    if (rgb != null) {
      final r =
          int.tryParse(rgb.group(1) ?? '');

      final g =
          int.tryParse(rgb.group(2) ?? '');

      final b =
          int.tryParse(rgb.group(3) ?? '');

      final alpha =
          double.tryParse(
            rgb.group(4) ?? '1',
          );

      if (r == null ||
          g == null ||
          b == null ||
          alpha == null) {
        return null;
      }

      return Color.fromARGB(
        (alpha.clamp(0.0, 1.0) * 255)
            .round(),
        r.clamp(0, 255),
        g.clamp(0, 255),
        b.clamp(0, 255),
      );
    }

    var hex = text.startsWith('#')
        ? text.substring(1)
        : text;

    if (hex.length == 3) {
      hex =
          '${hex[0]}${hex[0]}'
          '${hex[1]}${hex[1]}'
          '${hex[2]}${hex[2]}';
    }

    if (hex.length == 6) {
      hex = 'FF$hex';
    }

    if (hex.length != 8) {
      return null;
    }

    final value =
        int.tryParse(hex, radix: 16);

    if (value == null) {
      return null;
    }

    return Color(value);
  }
}

class _StaticHomePalette {
  const _StaticHomePalette({
    required this.pageBackground,
    required this.surface,
    required this.surfaceAlt,
    required this.sectionBackground,
    required this.accent,
    required this.secondaryAccent,
    this.brandBackground,
    required this.offer,
    required this.warning,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
  });

  final Color pageBackground;
  final Color surface;
  final Color surfaceAlt;
  final Color sectionBackground;
  final Color accent;
  final Color secondaryAccent;
  final Color? brandBackground;
  final Color offer;
  final Color warning;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
}

class _StaticGridPlacement {
  const _StaticGridPlacement({
    required this.item,
    required this.row,
    required this.column,
    required this.columnSpan,
    required this.rowSpan,
  });

  final Map<String, dynamic> item;
  final int row;
  final int column;
  final int columnSpan;
  final int rowSpan;
}