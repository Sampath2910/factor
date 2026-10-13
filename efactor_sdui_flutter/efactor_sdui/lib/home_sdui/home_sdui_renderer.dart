import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../core/responsive_util.dart';
import '../sdui/schema_guard.dart';
import '../sdui/schema_runtime.dart';
import '../sdui/sdui_network_image_cache.dart';
import '../services/json_http.dart';
import 'home_cube_motion.dart';
import 'home_icon_resolver.dart';
import 'home_metro_grid.dart';
import 'home_static_template_renderer.dart';
import 'home_sdui_state.dart';

class HomeSduiRenderer {
  HomeSduiRenderer(this.state) : icons = HomeIconResolver(state.schema);

  final HomeSduiState state;
  final HomeIconResolver icons;
  Object? _imageHostSchema;
  Set<String>? _declaredImageHosts;
  static final Set<String> _loggedImageErrors = <String>{};

  Widget buildComponent(
    BuildContext context,
    String componentId, {
    Map<String, dynamic>? item,
    Map<String, dynamic>? event,
  }) {
    final component = state.component(componentId);
    if (component == null) {
      return _error('Missing component "$componentId".');
    }

    return buildNode(context, component, item: item, event: event);
  }

  Widget buildNode(
    BuildContext context,
    Map<String, dynamic> component, {
    Map<String, dynamic>? item,
    Map<String, dynamic>? event,
  }) {
    if (!_visible(component, item: item, event: event)) {
      return const SizedBox.shrink();
    }

    component = _componentForViewport(context, component);
    final type = _effectiveType(component);

    return switch (type) {
      'scrollPage' => _scrollPage(context, component, item: item),
      'pageHeader' => _pageHeader(context, component, item: item),
      'homeHeader' => _homeHeader(context, component),
      'banner' => _banner(context, component, item: item),
      'summaryBanner' => _summaryBanner(context, component, item: item),
      'statusSummary' => _statusSummary(context, component, item: item),
      'responsiveGrid' => _responsiveGrid(context, component),
      'rotatingFaceCard' => _rotatingFaceCard(context, component, item: item),
      'rotatingDeviceCard' => _rotatingDeviceCard(
        context,
        component,
        item: item,
      ),
      'bottomNavigation' => _bottomNavigation(context, component),
      'floatingActionButton' => _floatingAction(context, component),
      'list' => _list(context, component),
      'skeleton' => _skeleton(context, component),
      'emptyState' => _emptyState(context, component),
      'errorState' => _errorState(context, component),
      'faceSelector' => _faceSelector(context, component, item: item),
      'deviceControlPanel' => _deviceControlPanel(
        context,
        component,
        item: item,
      ),
      'deviceDetailsHeader' => _deviceDetailsHeader(
        context,
        component,
        item: item,
      ),
      'profileHeader' => _profileHeader(context, component),
      'profileMenu' => _profileMenu(context, component),
      'themeModeSelector' => _themeModeSelector(context, component),
      'actionButton' => _actionButton(context, component),
      'loginForm' => _loginForm(context, component),
      'staticHomeUi' => HomeStaticTemplateRenderer(
        state: state,
        icons: icons,
      ).build(context, component),
      _ => _error(
        'Unsupported home component type "$type" '
        'for ${component['id']}.',
      ),
    };
  }

  String? _effectiveType(Map<String, dynamic> component) {
    final direct = component['type']?.toString();
    if (direct != null && direct.isNotEmpty) return direct;

    final presetId = component['presetId']?.toString();
    final preset = presetId == null
        ? null
        : state.schema['componentPresets']?[presetId];

    if (preset is Map) {
      return preset['type']?.toString();
    }

    return null;
  }

  Widget _scrollPage(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final layout = _layoutForViewport(
      context,
      _map(c['layout']) ?? const <String, dynamic>{},
    );
    final padding = _padding(layout['padding']);
    final gap = _d(layout['gap']) ?? 0;
    final children = c['children'];

    final widgets = <Widget>[];
    if (children is List) {
      for (final child in children) {
        if (child is String) {
          widgets.add(buildComponent(context, child, item: item));
        } else if (child is Map) {
          widgets.add(
            buildNode(
              context,
              Map<String, dynamic>.from(child.cast<dynamic, dynamic>()),
              item: item,
            ),
          );
        }
      }
    }

    final list = ListView.separated(
      padding: padding,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: widgets.length,
      separatorBuilder: (_, __) => SizedBox(height: gap),
      itemBuilder: (_, index) => widgets[index],
    );

    final appearance = _map(c['appearance']);
    if (appearance == null) return list;

    final background = tokenColor(
      appearance['backgroundColorToken']?.toString(),
    );

    if (background == null) {
      return _error(
        'Schema token missing: components.${c['id']}.'
        'appearance.backgroundColorToken',
      );
    }

    return ColoredBox(color: background, child: list);
  }

  Widget _homeHeader(BuildContext context, Map<String, dynamic> c) {
    final greetingRaw = c['greeting'];
    final titleRaw = c['title'];
    final subtitleRaw = c['subtitle'];
    final avatar = _map(c['avatar']);
    final logo = _map(c['logo']);
    final layout = _layoutForViewport(
      context,
      _map(c['layout']) ?? const <String, dynamic>{},
    );
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final headerOverflow = _schemaOverflow('headerText');

    String textFrom(dynamic raw) {
      final map = _map(raw);
      if (map != null) {
        if (map.containsKey('text')) return _textValue(map['text']);
        if (map.containsKey(r'$i18n')) {
          return _textValue(<String, dynamic>{r'$i18n': map[r'$i18n']});
        }
      }
      return _textValue(raw);
    }

    TextStyle styleFrom(
      dynamic raw, {
      required String fallbackToken,
      required Color? fallbackColor,
    }) {
      final map = _map(raw);
      final inline = _map(map?['typography']);
      if (inline != null && inline.isNotEmpty) {
        return _inlineTypography(inline, fallbackColor: fallbackColor);
      }
      final token = map?['typographyToken']?.toString().trim();
      return _typography(
        token == null || token.isEmpty ? fallbackToken : token,
        fallbackColor: fallbackColor,
      );
    }

    final greetingText = textFrom(greetingRaw);
    final title = textFrom(titleRaw);
    final subtitle = textFrom(subtitleRaw);
    if (title.isEmpty) {
      return _error(
        'Schema value missing: components.${c['id']}.title is required.',
      );
    }

    int? maxLinesOf(dynamic raw, {int fallback = 2}) {
      return (_map(raw)?['maxLines'] as num?)?.toInt() ?? fallback;
    }

    TextOverflow overflowOf(dynamic raw) {
      return _textOverflow(_map(raw)?['overflow']) ?? headerOverflow;
    }

    final textColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (greetingText.isNotEmpty)
          Text(
            greetingText,
            maxLines: maxLinesOf(greetingRaw),
            overflow: overflowOf(greetingRaw),
            style: styleFrom(
              greetingRaw,
              fallbackToken: 'typography.homeGreeting',
              fallbackColor: tokenColor('colors.textMuted'),
            ),
          ),
        Text(
          title,
          maxLines: maxLinesOf(titleRaw),
          overflow: overflowOf(titleRaw),
          style: styleFrom(
            titleRaw,
            fallbackToken: 'typography.brandTitle',
            fallbackColor: tokenColor('colors.textPrimary'),
          ),
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: maxLinesOf(subtitleRaw),
            overflow: overflowOf(subtitleRaw),
            style: styleFrom(
              subtitleRaw,
              fallbackToken: 'typography.brandSubtitle',
              fallbackColor: tokenColor('colors.textMuted'),
            ),
          ),
      ],
    );

    final gap = _d(layout['gap']) ?? _d(appearance['layoutGap']) ?? 0;
    final marginBottom =
        _d(layout['marginBottom']) ?? _d(appearance['marginBottom']) ?? 0;
    final rowChildren = <Widget>[];
    final breakpoint = _responsiveBreakpointName(context);
    final useCompactLogo =
        breakpoint == 'narrow' || breakpoint == 'compact';

    if (logo != null) {
      final source = logo['imageUrl']?.toString().trim() ?? '';
      var width = _d(logo['width'] ?? logo['maxWidth']);
      var height = _d(logo['height'] ?? logo['maxHeight']);
      if (useCompactLogo) {
        width = _d(appearance['logoWidth']) ?? width;
        height = _d(appearance['logoHeight']) ?? height;
      }
      if (source.isEmpty || width == null || height == null) {
        return _error(
          'Schema visual contract missing: components.${c['id']}.logo requires imageUrl, width and height.',
        );
      }

      final image = _networkImageFromSchema(
        source: source,
        fit: logo['objectFit'],
        alignment: logo['objectPosition'],
        errorIconToken:
            state.schema['rendererRequirements']?['fallbacks']?['missingImage'],
      );
      if (image != null) {
        rowChildren.add(
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width, maxHeight: height),
            child: SizedBox(width: width, height: height, child: image),
          ),
        );
        rowChildren.add(SizedBox(width: gap));
      }
    }

    rowChildren.add(
      Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: textColumn,
        ),
      ),
    );

    if (avatar != null) {
      final avatarAppearance =
          _map(avatar['appearance']) ?? const <String, dynamic>{};
      final initials = _textValue(
        avatar['initialsBinding'] ?? avatar['initials'],
      );
      final rawWidth = _d(avatarAppearance['width']);
      final rawHeight = _d(avatarAppearance['height']);
      final rawRadius = _d(avatarAppearance['borderRadius']);
      final avatarStart =
          _color(avatarAppearance['gradientStart']) ??
          tokenColor('colors.avatarGradientStart');
      final avatarEnd =
          _color(avatarAppearance['gradientEnd']) ??
          tokenColor('colors.avatarGradientEnd');
      final avatarTextColor =
          _color(avatarAppearance['textColor']) ??
          tokenColor('colors.welcomeText');
      final rawFontSize = _d(avatarAppearance['fontSize']);

      final imageUrl = avatar['imageUrl']?.toString().trim() ?? '';
      final hasImage = imageUrl.isNotEmpty;
      if ((!hasImage && initials.isEmpty) ||
          rawWidth == null ||
          rawHeight == null ||
          rawRadius == null ||
          rawFontSize == null ||
          avatarTextColor == null ||
          (!hasImage && (avatarStart == null || avatarEnd == null))) {
        return _error(
          'Schema visual/value contract missing: components.${c['id']}.avatar.',
        );
      }

      final responsive = ResponsiveUtil.of(context);
      final avatarWidth = responsive.scale(rawWidth);
      final avatarHeight = responsive.scale(rawHeight);
      final avatarRadius = responsive.scale(rawRadius);
      final avatarFontSize = responsive.scaleText(rawFontSize);

      Widget avatarChild;
      if (hasImage) {
        avatarChild =
            _networkImageFromSchema(
              source: imageUrl,
              fit: avatarAppearance['objectFit'],
              alignment: avatarAppearance['objectPosition'],
              errorIconToken: state
                  .schema['rendererRequirements']?['fallbacks']?['missingImage'],
            ) ??
            Text(
              initials,
              style: TextStyle(
                color: avatarTextColor,
                fontSize: avatarFontSize,
                fontWeight: _fontWeight(avatarAppearance['fontWeight']),
              ),
            );
      } else {
        avatarChild = Text(
          initials,
          style: TextStyle(
            color: avatarTextColor,
            fontSize: avatarFontSize,
            fontWeight: _fontWeight(avatarAppearance['fontWeight']),
          ),
        );
      }

      Widget avatarWidget = Container(
        width: avatarWidth,
        height: avatarHeight,
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: avatarStart != null && avatarEnd != null
              ? LinearGradient(colors: <Color>[avatarStart, avatarEnd])
              : null,
          color: avatarStart == null ? avatarTextColor : null,
          borderRadius: BorderRadius.circular(avatarRadius),
          boxShadow: _boxShadowList(avatarAppearance['shadow']),
        ),
        child: avatarChild,
      );

      final tap = _map(_map(avatar['events'])?['tap']);
      final actionId = tap?['actionId']?.toString().trim();
      if (actionId != null && actionId.isNotEmpty) {
        avatarWidget = Semantics(
          button: true,
          label: avatar['accessibilityLabel']?.toString(),
          child: InkWell(
            borderRadius: BorderRadius.circular(avatarRadius),
            onTap: () => state.dispatchAction(actionId),
            child: avatarWidget,
          ),
        );
      }

      rowChildren.add(SizedBox(width: gap));
      rowChildren.add(avatarWidget);
    }

    return Padding(
      padding: EdgeInsets.only(bottom: marginBottom),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: rowChildren,
      ),
    );
  }

  Widget _profileHeaderFlat(
    BuildContext context,
    Map<String, dynamic> c,
    Map<String, dynamic> appearance,
  ) {
    final background = tokenColor('colors.surface');
    final border = _color(appearance['cardBorderColor']);
    final radius = _d(appearance['cardBorderRadius']);
    final padding = _d(appearance['cardPadding']);
    final avatarSize = _d(appearance['avatarSize']);
    final avatarStart = _color(appearance['avatarGradientStart']) ??
        tokenColor('colors.avatarGradientStart');
    final avatarEnd = _color(appearance['avatarGradientEnd']) ??
        tokenColor('colors.avatarGradientEnd');
    final name = _boundText(c, 'name');
    final email = _boundText(c, 'email');
    final phone = _boundText(c, 'phone');
    final memberId = _boundText(c, 'memberId');
    var avatarText = _boundText(c, 'avatarText');
    if (avatarText.isEmpty && name.isNotEmpty) {
      avatarText = name[0].toUpperCase();
    }

    if (background == null ||
        radius == null ||
        padding == null ||
        avatarSize == null ||
        avatarStart == null ||
        avatarEnd == null ||
        name.isEmpty ||
        email.isEmpty ||
        avatarText.isEmpty) {
      return _error(
        'Schema visual/value contract missing for components.${c['id']} profileHeader.',
      );
    }

    final nameSize = _d(appearance['nameFontSize']);
    final emailSize = _d(appearance['emailFontSize']);
    final metaSize = _d(appearance['metaFontSize']);
    final avatarFontSize = _d(appearance['avatarFontSize']);
    if (nameSize == null ||
        emailSize == null ||
        metaSize == null ||
        avatarFontSize == null) {
      return _error(
        'Schema typography missing for components.${c['id']} profileHeader.',
      );
    }

    return Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: border == null ? null : Border.all(color: border),
        boxShadow: _boxShadowFromToken(appearance['cardShadowToken']),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: avatarSize,
            height: avatarSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: <Color>[avatarStart, avatarEnd]),
            ),
            child: Text(
              avatarText,
              style: TextStyle(
                color: _color(appearance['avatarTextColor']) ??
                    tokenColor('colors.welcomeText') ??
                    tokenColor('colors.textPrimary'),
                fontSize: avatarFontSize,
                fontWeight: _fontWeight(appearance['avatarFontWeight']),
              ),
            ),
          ),
          SizedBox(height: _tokenNumber('spacing.md') ?? 0),
          Text(
            name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: tokenColor('colors.textPrimary'),
              fontSize: nameSize,
              fontWeight: _fontWeight(appearance['nameFontWeight']),
            ),
          ),
          SizedBox(height: _tokenNumber('spacing.xs') ?? 0),
          Text(
            email,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: tokenColor('colors.textSecondary'),
              fontSize: emailSize,
            ),
          ),
          if (phone.isNotEmpty || memberId.isNotEmpty) ...<Widget>[
            SizedBox(height: _tokenNumber('spacing.md') ?? 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (phone.isNotEmpty) _profileChip(phone, appearance),
                if (memberId.isNotEmpty) _profileChip(memberId, appearance),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _profileMenuFlat(
    BuildContext context,
    Map<String, dynamic> c,
    Map<String, dynamic> appearance,
  ) {
    final items = c['items'];
    if (items is! List) {
      return _error('Schema path missing: components.${c['id']}.items[]');
    }

    final surface = tokenColor('colors.surface');
    final textPrimary = tokenColor('colors.textPrimary');
    final textSecondary = tokenColor('colors.textSecondary');
    final accent = tokenColor('colors.accent');
    final muted = tokenColor('colors.textMuted');
    final border = _color(appearance['rowBorderColor']);
    final rowRadius = _d(appearance['rowBorderRadius']);
    final rowMinHeight = _d(appearance['rowMinHeight']);
    final py = _d(appearance['rowPaddingVertical']);
    final px = _d(appearance['rowPaddingHorizontal']);
    final iconBoxSize = _d(appearance['iconBoxSize']);
    final iconRadius = _d(appearance['iconBoxBorderRadius']);
    final iconSize = _d(appearance['iconSize']);
    final titleSize = _d(appearance['rowTitleFontSize']);
    final subtitleSize = _d(appearance['rowSubtitleFontSize']);
    final chevronSize = _d(appearance['chevronSize']);
    final listGap = _d(appearance['listGap']);

    if (surface == null ||
        textPrimary == null ||
        textSecondary == null ||
        accent == null ||
        muted == null ||
        rowRadius == null ||
        rowMinHeight == null ||
        py == null ||
        px == null ||
        iconBoxSize == null ||
        iconRadius == null ||
        iconSize == null ||
        titleSize == null ||
        subtitleSize == null ||
        chevronSize == null ||
        listGap == null) {
      return _error(
        'Schema visual contract missing for components.${c['id']} profileMenu.',
      );
    }

    final children = <Widget>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
      final actionId = entry['actionId']?.toString().trim();
      final trailing = entry['trailingIconToken']?.toString();
      final row = Container(
        constraints: BoxConstraints(minHeight: rowMinHeight),
        padding: EdgeInsets.symmetric(horizontal: px, vertical: py),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(rowRadius),
          border: border == null
              ? null
              : Border.all(
                  color: border,
                  width: _d(appearance['rowBorderWidth']) ?? 1,
                ),
          boxShadow: _boxShadowFromToken(appearance['rowShadowToken']),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: iconBoxSize,
              height: iconBoxSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tokenColor('colors.surfaceElevated') ?? surface,
                borderRadius: BorderRadius.circular(iconRadius),
              ),
              child: FaIconAdapter(
                icon: icons.resolve(entry['iconToken']?.toString()),
                color: accent,
                size: iconSize,
              ),
            ),
            SizedBox(width: _tokenNumber('spacing.md') ?? 0),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _textValue(entry['label']),
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: titleSize,
                      fontWeight: _fontWeight(appearance['rowTitleFontWeight']),
                    ),
                  ),
                  if (_profileMenuSubtitle(entry).isNotEmpty)
                    Text(
                      _profileMenuSubtitle(entry),
                      style: TextStyle(
                        color: textSecondary,
                        fontSize: subtitleSize,
                        fontWeight: _fontWeight(
                          appearance['rowSubtitleFontWeight'],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null && trailing.isNotEmpty)
              FaIconAdapter(
                icon: icons.resolve(trailing),
                color: muted,
                size: chevronSize,
              ),
          ],
        ),
      );

      children.add(
        actionId == null || actionId.isEmpty
            ? row
            : InkWell(
                borderRadius: BorderRadius.circular(rowRadius),
                onTap: () => state.dispatchAction(actionId),
                child: row,
              ),
      );
    }

    return Column(
      children: <Widget>[
        for (var i = 0; i < children.length; i++) ...<Widget>[
          children[i],
          if (i < children.length - 1) SizedBox(height: listGap),
        ],
      ],
    );
  }

  Widget _profileHeader(BuildContext context, Map<String, dynamic> c) {
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    if (appearance.containsKey('cardPadding') ||
        appearance.containsKey('avatarSize')) {
      return _profileHeaderFlat(context, c, appearance);
    }
    final avatar = _map(appearance['avatar']) ?? const <String, dynamic>{};
    final chip = _map(appearance['chip']) ?? const <String, dynamic>{};

    final background =
        tokenColor(appearance['backgroundColorToken']?.toString()) ??
        tokenColor('colors.surface');
    final border =
        tokenColor(appearance['borderColorToken']?.toString()) ??
        tokenColor('colors.border');
    final radius =
        _tokenNumber(appearance['radiusToken']?.toString()) ??
        _tokenNumber('radius.card');
    final padding =
        _paddingOrNull(appearance['padding']) ??
        EdgeInsets.all(_tokenNumber('spacing.lg') ?? 0);
    final gap = _d(appearance['gap']) ?? _tokenNumber('spacing.sm') ?? 0;

    final avatarSize =
        _d(avatar['size']) ??
        _d(state.schema['accessibility']?['minimumTapTargetDp']);
    final avatarBorder =
        tokenColor(avatar['borderColorToken']?.toString()) ??
        tokenColor('colors.surface');
    final avatarStart =
        tokenColor(avatar['startColorToken']?.toString()) ??
        tokenColor('colors.avatarGradientStart');
    final avatarEnd =
        tokenColor(avatar['endColorToken']?.toString()) ??
        tokenColor('colors.avatarGradientEnd');

    final chipBackground =
        tokenColor(chip['backgroundColorToken']?.toString()) ??
        tokenColor('colors.surfaceElevated');
    final chipRadius =
        _tokenNumber(chip['radiusToken']?.toString()) ??
        _tokenNumber('radius.pill');
    final chipGap = _d(chip['gap']) ?? _tokenNumber('spacing.xs') ?? 0;
    final chipPadding =
        _paddingOrNull(chip['padding']) ??
        EdgeInsets.symmetric(
          horizontal: _tokenNumber('spacing.sm') ?? 0,
          vertical: _tokenNumber('spacing.xs') ?? 0,
        );

    if (background == null ||
        border == null ||
        radius == null ||
        avatarSize == null ||
        avatarBorder == null ||
        avatarStart == null ||
        avatarEnd == null ||
        chipBackground == null ||
        chipRadius == null) {
      return _error(
        'Schema visual contract missing for components.${c['id']}: '
        'profileHeader requires surface/border/avatar/chip design tokens.',
      );
    }

    final name = _boundText(c, 'name');
    final email = _boundText(c, 'email');
    final phone = _boundText(c, 'phone');
    final memberId = _boundText(c, 'memberId');
    var avatarText = _boundText(c, 'avatarText');
    if (avatarText.isEmpty && name.isNotEmpty) {
      avatarText = name[0].toUpperCase();
    }

    if (name.isEmpty || email.isEmpty || avatarText.isEmpty) {
      return _error(
        'Schema value missing: components.${c['id']} '
        'requires name, email and avatarText.',
      );
    }

    Widget chipWidget(String value) => Container(
      padding: chipPadding,
      decoration: BoxDecoration(
        color: chipBackground,
        borderRadius: BorderRadius.circular(chipRadius),
      ),
      child: Text(
        value,
        style: _typography(
          chip['typographyToken']?.toString() ?? 'typography.cardSubtitle',
          fallbackColor:
              tokenColor(chip['textColorToken']?.toString()) ??
              tokenColor('colors.textSecondary'),
        ),
      ),
    );

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: border,
          width: _d(appearance['borderWidth']) ?? 1,
        ),
      ),
      child: Column(
        children: [
          Container(
            width: avatarSize,
            height: avatarSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: <Color>[avatarStart, avatarEnd]),
              border: Border.all(
                color: avatarBorder,
                width: _d(avatar['borderWidth']) ?? 1,
              ),
            ),
            child: Text(
              avatarText,
              style: _typography(
                avatar['typographyToken']?.toString() ?? 'typography.pageTitle',
                fallbackColor:
                    tokenColor(avatar['textColorToken']?.toString()) ??
                    tokenColor('colors.welcomeText'),
              ),
            ),
          ),
          SizedBox(height: gap),
          Text(
            name,
            textAlign: TextAlign.center,
            style: _typography(
              appearance['nameTypographyToken']?.toString() ??
                  'typography.pageTitle',
              fallbackColor:
                  tokenColor(appearance['nameColorToken']?.toString()) ??
                  tokenColor('colors.textPrimary'),
            ),
          ),
          SizedBox(
            height:
                _d(appearance['textGap']) ?? _tokenNumber('spacing.xs') ?? 0,
          ),
          Text(
            email,
            textAlign: TextAlign.center,
            style: _typography(
              appearance['emailTypographyToken']?.toString() ??
                  'typography.pageSubtitle',
              fallbackColor:
                  tokenColor(appearance['emailColorToken']?.toString()) ??
                  tokenColor('colors.textSecondary'),
            ),
          ),
          if (phone.isNotEmpty || memberId.isNotEmpty) ...[
            SizedBox(height: gap),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: chipGap,
              runSpacing: chipGap,
              children: [
                if (phone.isNotEmpty) chipWidget(phone),
                if (memberId.isNotEmpty) chipWidget(memberId),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _profileMenu(BuildContext context, Map<String, dynamic> c) {
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    if (appearance.containsKey('rowMinHeight') ||
        appearance.containsKey('iconBoxSize')) {
      return _profileMenuFlat(context, c, appearance);
    }
    final items = c['items'];
    if (items is! List) {
      return _error('Schema path missing: components.${c['id']}.items[]');
    }

    final gap = _d(appearance['gap']) ?? _tokenNumber('spacing.sm') ?? 0;
    final background =
        tokenColor(appearance['backgroundColorToken']?.toString()) ??
        tokenColor('colors.surface');
    final border =
        tokenColor(appearance['borderColorToken']?.toString()) ??
        tokenColor('colors.border');
    final radius =
        _tokenNumber(appearance['radiusToken']?.toString()) ??
        _tokenNumber('radius.card');
    final padding =
        _paddingOrNull(appearance['padding']) ??
        EdgeInsets.all(_tokenNumber('spacing.md') ?? 0);
    final iconSize =
        _d(appearance['iconContainerSize']) ??
        _d(state.schema['accessibility']?['minimumTapTargetDp']);
    final iconBackground =
        tokenColor(appearance['iconBackgroundColorToken']?.toString()) ??
        tokenColor('colors.surfaceElevated');
    final iconColor =
        tokenColor(appearance['iconColorToken']?.toString()) ??
        tokenColor('colors.accent');
    final trailingColor =
        tokenColor(appearance['trailingIconColorToken']?.toString()) ??
        tokenColor('colors.textMuted');

    if (background == null ||
        border == null ||
        radius == null ||
        iconSize == null ||
        iconBackground == null ||
        iconColor == null ||
        trailingColor == null) {
      return _error(
        'Schema visual contract missing for components.${c['id']}: '
        'profileMenu requires surface/border/icon design tokens.',
      );
    }

    return Column(
      children: [
        for (var index = 0; index < items.length; index++) ...[
          if (items[index] is Map)
            Builder(
              builder: (_) {
                final entry = Map<String, dynamic>.from(
                  (items[index] as Map).cast<dynamic, dynamic>(),
                );
                final actionId = entry['actionId']?.toString();
                final trailing = entry['trailingIconToken']?.toString();

                final content = Container(
                  padding: padding,
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color: border,
                      width: _d(appearance['borderWidth']) ?? 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: iconSize,
                        height: iconSize,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: iconBackground,
                          borderRadius: BorderRadius.circular(
                            _d(appearance['iconRadius']) ??
                                _tokenNumber('radius.small') ??
                                radius,
                          ),
                        ),
                        child: FaIconAdapter(
                          icon: icons.resolve(entry['iconToken']?.toString()),
                          color: iconColor,
                          size:
                              _d(appearance['iconSize']) ??
                              _tokenNumber('typography.pageSubtitle.fontSize'),
                        ),
                      ),
                      SizedBox(
                        width:
                            _d(appearance['contentGap']) ??
                            _tokenNumber('spacing.sm') ??
                            gap,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _textValue(entry['label']),
                              style: _typography(
                                appearance['labelTypographyToken']
                                        ?.toString() ??
                                    'typography.cardTitle',
                                fallbackColor:
                                    tokenColor(
                                      appearance['labelColorToken']?.toString(),
                                    ) ??
                                    tokenColor('colors.textPrimary'),
                              ),
                            ),
                            if (_textValue(entry['subtitle']).isNotEmpty) ...[
                              SizedBox(
                                height:
                                    _d(appearance['labelGap']) ??
                                    _tokenNumber('spacing.xs') ??
                                    gap,
                              ),
                              Text(
                                _textValue(entry['subtitle']),
                                style: _typography(
                                  appearance['subtitleTypographyToken']
                                          ?.toString() ??
                                      'typography.cardSubtitle',
                                  fallbackColor:
                                      tokenColor(
                                        appearance['subtitleColorToken']
                                            ?.toString(),
                                      ) ??
                                      tokenColor('colors.textSecondary'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (trailing != null)
                        FaIconAdapter(
                          icon: icons.resolve(trailing),
                          color: trailingColor,
                          size:
                              _d(appearance['trailingIconSize']) ??
                              _tokenNumber('typography.pageSubtitle.fontSize'),
                        ),
                    ],
                  ),
                );

                if (actionId == null || actionId.isEmpty) return content;

                return Semantics(
                  button: true,
                  label: _textValue(entry['label']),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(radius),
                    onTap: () => state.dispatchAction(actionId),
                    child: content,
                  ),
                );
              },
            ),
          if (index < items.length - 1) SizedBox(height: gap),
        ],
      ],
    );
  }

  Widget _themeModeSelector(BuildContext context, Map<String, dynamic> c) {
    final rawOptions = c['options'];
    if (rawOptions is! List || rawOptions.isEmpty) {
      return _error('Schema path missing: components.${c['id']}.options[]');
    }

    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};

    final selectedPreset =
        state.resolve(c['selectedPresetBinding'])?.toString() ??
        state.readState('global.themePreset')?.toString();

    final selectedMode =
        state.resolve(c['selectedModeBinding'])?.toString() ??
        state.readState('global.themeMode')?.toString();

    final rowMinHeight =
        _d(appearance['rowMinHeight']) ??
        _d(state.schema['accessibility']?['minimumTapTargetDp']) ??
        44;

    final px =
        _d(appearance['rowPaddingHorizontal']) ??
        _tokenNumber('spacing.md') ??
        0;

    final py =
        _d(appearance['rowPaddingVertical']) ?? _tokenNumber('spacing.md') ?? 0;

    final rowRadius =
        _d(appearance['rowBorderRadius']) ?? _tokenNumber('radius.card') ?? 0;

    final rowBorderWidth = _d(appearance['rowBorderWidth']) ?? 1;
    final listGap =
        _d(appearance['listGap']) ??
        _d(appearance['pageGap']) ??
        _tokenNumber('spacing.sm') ??
        0;

    final surface = tokenColor('colors.surface');
    final surfaceElevated = tokenColor('colors.surfaceElevated') ?? surface;
    final primary = tokenColor('colors.textPrimary');
    final secondary =
        tokenColor('colors.textSecondary') ?? tokenColor('colors.textMuted');
    final accent = tokenColor('colors.accent');
    final border =
        _color(appearance['rowBorderColor']) ?? tokenColor('colors.border');

    if (surface == null ||
        surfaceElevated == null ||
        primary == null ||
        secondary == null ||
        accent == null ||
        border == null) {
      return _error(
        'Schema visual contract missing for components.${c['id']}: '
        'theme selector requires surface/text/accent/border colors.',
      );
    }

    final widgets = <Widget>[];

    for (var index = 0; index < rawOptions.length; index++) {
      final raw = rawOptions[index];
      if (raw is! Map) continue;

      final option = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());

      final id = option['id']?.toString().trim() ?? '';
      final preset = option['preset']?.toString().trim() ?? '';
      final mode = option['mode']?.toString().trim() ?? '';
      final actionId = option['actionId']?.toString().trim() ?? '';
      final label = _textValue(option['label']);
      final subtitle = _textValue(option['subtitle']);

      if (id.isEmpty || actionId.isEmpty || label.isEmpty) {
        return _error(
          'Schema value missing: components.${c['id']}.options[$index] '
          'requires id, label and actionId.',
        );
      }

      final selectedExpression = option['selectedWhen'];
      final selected = selectedExpression != null
          ? state.evaluate(selectedExpression)
          : ((preset.isNotEmpty && preset == selectedPreset) ||
                (mode.isNotEmpty && mode == selectedMode));

      final row = Container(
        constraints: BoxConstraints(minHeight: rowMinHeight),
        padding: EdgeInsets.symmetric(horizontal: px, vertical: py),
        decoration: BoxDecoration(
          color: selected ? surfaceElevated : surface,
          borderRadius: BorderRadius.circular(rowRadius),
          border: Border.all(
            color: selected ? accent : border,
            width: rowBorderWidth,
          ),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      color: primary,
                      fontSize:
                          _d(appearance['rowTitleFontSize']) ??
                          _tokenNumber('typography.cardTitle.fontSize'),
                      fontWeight: _fontWeight(appearance['rowTitleFontWeight']),
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...<Widget>[
                    SizedBox(height: _tokenNumber('spacing.xs') ?? 0),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: secondary,
                        fontSize:
                            _d(appearance['rowSubtitleFontSize']) ??
                            _tokenNumber('typography.cardSubtitle.fontSize'),
                        fontWeight: _fontWeight(
                          appearance['rowSubtitleFontWeight'],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(width: _tokenNumber('spacing.sm') ?? 0),
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: selected ? accent : secondary,
            ),
          ],
        ),
      );

      widgets.add(
        Semantics(
          button: true,
          selected: selected,
          label: label,
          child: InkWell(
            borderRadius: BorderRadius.circular(rowRadius),
            onTap: () => state.dispatchAction(actionId),
            child: row,
          ),
        ),
      );
    }

    return Column(
      children: <Widget>[
        for (var i = 0; i < widgets.length; i++) ...<Widget>[
          widgets[i],
          if (i < widgets.length - 1) SizedBox(height: listGap),
        ],
      ],
    );
  }

  Widget _actionButton(BuildContext context, Map<String, dynamic> c) {
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final actionId = c['actionId']?.toString();
    final label = _textValue(c['label']);

    final destructive = appearance['destructive'] == true;
    final background =
        _color(appearance['backgroundColor']) ??
        tokenColor(appearance['backgroundColorToken']?.toString()) ??
        tokenColor(destructive ? 'colors.danger' : 'colors.accent');

    final foreground =
        _color(appearance['textColor']) ??
        tokenColor(appearance['textColorToken']?.toString()) ??
        tokenColor('colors.surface');

    final border =
        _color(appearance['borderColor']) ??
        tokenColor(appearance['borderColorToken']?.toString()) ??
        background;

    final height =
        _d(appearance['height']) ??
        _d(appearance['minHeight']) ??
        _d(appearance['logoutMinHeight']) ??
        _d(state.schema['accessibility']?['minimumTapTargetDp']);

    final radius =
        _d(appearance['borderRadius']) ??
        _d(appearance['logoutBorderRadius']) ??
        _tokenNumber(appearance['radiusToken']?.toString()) ??
        _tokenNumber('radius.card');

    final gap = _d(appearance['gap']) ?? _tokenNumber('spacing.sm') ?? 0;

    if (actionId == null ||
        actionId.isEmpty ||
        label.isEmpty ||
        background == null ||
        foreground == null ||
        border == null ||
        height == null ||
        radius == null) {
      return _error(
        'Schema value missing: components.${c['id']} requires label, '
        'actionId and button design tokens.',
      );
    }

    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => state.dispatchAction(actionId),
        child: Ink(
          height: height,
          decoration: BoxDecoration(
            color: background,
            gradient: _gradient(_map(appearance['background'])),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: border,
              width: _d(appearance['borderWidth']) ?? 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (c['iconToken'] != null) ...[
                FaIconAdapter(
                  icon: icons.resolve(c['iconToken']?.toString()),
                  color: foreground,
                  size:
                      _d(appearance['iconSize']) ??
                      _tokenNumber('typography.pageSubtitle.fontSize'),
                ),
                SizedBox(width: gap),
              ],
              Text(
                label,
                style: appearance['logoutFontSize'] != null
                    ? TextStyle(
                        color: foreground,
                        fontSize: _d(appearance['logoutFontSize']),
                        fontWeight: _fontWeight(appearance['logoutFontWeight']),
                      )
                    : _typography(
                        appearance['typographyToken']?.toString() ??
                            'typography.cardTitle',
                        fallbackColor: foreground,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageHeader(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final title = _textValue(c['title'], item: item);
    final subtitle = _textValue(c['subtitle'], item: item);
    final typography = _map(c['typography']) ?? const <String, dynamic>{};
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final actions = c['actions'];

    final titleStyle = _typography(
      typography['titleToken']?.toString() ?? 'typography.pageTitle',
      fallbackColor:
          tokenColor(appearance['titleColorToken']?.toString()) ??
          tokenColor('colors.textPrimary'),
    );
    final subtitleStyle = _typography(
      typography['subtitleToken']?.toString() ?? 'typography.pageSubtitle',
      fallbackColor:
          tokenColor(appearance['subtitleColorToken']?.toString()) ??
          tokenColor('colors.textSecondary'),
    );

    final iconToken = c['iconToken']?.toString();
    final iconSize =
        _d(appearance['iconSize']) ??
        _tokenNumber('typography.pageTitle.fontSize');
    final iconGap =
        _d(appearance['iconGap']) ?? _tokenNumber('spacing.sm') ?? 0;
    final textGap =
        _d(appearance['textGap']) ?? _tokenNumber('spacing.xs') ?? 0;
    final iconColor =
        tokenColor(appearance['iconColorToken']?.toString()) ??
        tokenColor('colors.accent');

    if (iconToken != null && iconSize == null) {
      return _error(
        'Schema visual contract missing for components.${c['id']}: '
        'pageHeader icon size must come from appearance.iconSize or '
        'designTokens.typography.pageTitle.fontSize.',
      );
    }

    Widget header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (iconToken != null) ...[
          FaIconAdapter(
            icon: icons.resolve(iconToken),
            color: iconColor,
            size: iconSize,
          ),
          SizedBox(width: iconGap),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: _schemaOverflow('headerText'),
                style: titleStyle,
              ),
              if (subtitle.isNotEmpty) ...[
                SizedBox(height: textGap),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: _schemaOverflow('headerText'),
                  style: subtitleStyle,
                ),
              ],
            ],
          ),
        ),
        if (actions is List)
          for (final rawAction in actions)
            if (rawAction is Map)
              Builder(
                builder: (_) {
                  final action = Map<String, dynamic>.from(
                    rawAction.cast<dynamic, dynamic>(),
                  );
                  final actionId = action['actionId']?.toString().trim();
                  final iconToken =
                      action['iconToken']?.toString() ??
                      action['icon']?.toString();
                  return IconButton(
                    tooltip:
                        action['accessibilityLabel']?.toString() ??
                        action['label']?.toString() ??
                        action['title']?.toString(),
                    onPressed: actionId == null || actionId.isEmpty
                        ? null
                        : () => state.dispatchAction(actionId),
                    icon: FaIconAdapter(
                      icon: icons.resolve(iconToken),
                      color: iconColor,
                      size: iconSize,
                    ),
                  );
                },
              ),
      ],
    );

    final padding = _paddingOrNull(appearance['padding']);
    final radius =
        _d(appearance['borderRadius']) ??
        _tokenNumber(appearance['radiusToken']?.toString());
    final background =
        _color(appearance['backgroundColor']) ??
        tokenColor(appearance['backgroundColorToken']?.toString());
    final border =
        _color(appearance['borderColor']) ??
        tokenColor(appearance['borderColorToken']?.toString());

    if (padding != null ||
        radius != null ||
        background != null ||
        border != null) {
      header = Container(
        padding: padding,
        decoration: BoxDecoration(
          color: background,
          borderRadius: radius == null ? null : BorderRadius.circular(radius),
          border: border == null
              ? null
              : Border.all(
                  color: border,
                  width: _d(appearance['borderWidth']) ?? 1,
                ),
        ),
        child: header,
      );
    }

    return header;
  }

  Widget _banner(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final content = _map(c['content']) ?? const <String, dynamic>{};
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final typography = _map(c['typography']) ?? const <String, dynamic>{};
    final layout = _map(c['layout']) ?? const <String, dynamic>{};
    final textColumn = _map(c['textColumn']) ?? const <String, dynamic>{};
    final avatar = _map(c['avatar']);

    final title = _textValue(content['title'], item: item);
    final subtitle = _textValue(content['subtitle'], item: item);
    final greeting = _textValue(content['greeting'], item: item);
    final supporting = _textValue(content['supportingText'], item: item);
    final caption = _textValue(content['caption'], item: item);

    final radius =
        _d(appearance['radius']) ??
        _tokenNumber(appearance['radiusToken']?.toString()) ??
        _d(appearance['borderRadius']) ??
        _tokenNumber('radius.card');

    final padding =
        _paddingOrNull(appearance['padding']) ??
        EdgeInsets.all(_tokenNumber('spacing.md') ?? 0);

    final textColor =
        _color(appearance['textColor']) ??
        tokenColor(appearance['textColorToken']?.toString()) ??
        tokenColor('colors.textPrimary');

    final directBackground = _color(appearance['backgroundColor']);
    final tokenBackground = tokenColor(
      appearance['backgroundColorToken']?.toString(),
    );
    final gradient =
        _gradient(_map(appearance['background'])) ??
        _gradientFromCss(appearance['backgroundColor']?.toString());

    if (radius == null || textColor == null) {
      return _error(
        'Schema visual contract missing for components.${c['id']}.',
      );
    }

    TextStyle bannerStyle(String key, String fallbackToken, double opacity) {
      final inline = _map(typography[key]);
      if (inline != null && inline.isNotEmpty) {
        return _inlineTypography(
          inline,
          fallbackColor: textColor.withValues(alpha: opacity.clamp(0.0, 1.0)),
        );
      }
      return _typography(
        fallbackToken,
        fallbackColor: textColor.withValues(alpha: opacity.clamp(0.0, 1.0)),
      );
    }

    final textWidgets = <Widget>[];
    final textGap = _d(textColumn['gap']) ?? _tokenNumber('spacing.xs') ?? 0;

    void addText(String value, TextStyle style, dynamic raw) {
      if (value.isEmpty) return;
      if (textWidgets.isNotEmpty && textGap > 0) {
        textWidgets.add(SizedBox(height: textGap));
      }
      final rawMap = _map(raw);
      textWidgets.add(
        Text(
          value,
          maxLines: (rawMap?['maxLines'] as num?)?.toInt() ?? 2,
          overflow: _textOverflow(rawMap?['overflow']) ?? _schemaOverflow('headerText'),
          softWrap: rawMap?['softWrap'] != false,
          style: style,
        ),
      );
    }

    if (greeting.isNotEmpty || caption.isNotEmpty) {
      addText(
        greeting,
        bannerStyle('greeting', 'typography.welcomeGreeting', 1),
        typography['greeting'],
      );
      addText(
        supporting,
        bannerStyle('supportingText', 'typography.welcomeEmail', 1),
        typography['supportingText'],
      );
      addText(
        caption,
        bannerStyle('caption', 'typography.welcomeCaption', 0.88),
        typography['caption'],
      );
    } else {
      addText(
        title,
        bannerStyle('title', 'typography.pageTitle', 1),
        typography['title'],
      );
      addText(
        subtitle,
        bannerStyle('subtitle', 'typography.pageSubtitle', 0.88),
        typography['subtitle'],
      );
      addText(
        supporting,
        bannerStyle('supportingText', 'typography.cardSubtitle', 0.76),
        typography['supportingText'],
      );
    }

    Widget contentWidget = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: textWidgets,
    );

    if (avatar != null) {
      final avatarAppearance =
          _map(avatar['appearance']) ?? const <String, dynamic>{};
      final width = _d(avatarAppearance['width']);
      final height = _d(avatarAppearance['height']);
      final avatarRadius = _d(avatarAppearance['borderRadius']);
      final initials = _textValue(avatar['initials']);
      final fontSize = _d(avatarAppearance['fontSize']);
      final text = _color(avatarAppearance['textColor']) ?? textColor;
      final borderColor = _color(avatarAppearance['borderColor']);
      final borderWidth = _d(avatarAppearance['borderWidth']) ?? 0;

      if (width == null ||
          height == null ||
          avatarRadius == null ||
          fontSize == null ||
          (initials.isEmpty &&
              (avatar['imageUrl']?.toString().trim().isEmpty ?? true))) {
        return _error(
          'Schema visual/value contract missing for components.${c['id']}.avatar.',
        );
      }

      Widget avatarChild;
      final imageUrl = avatar['imageUrl']?.toString().trim() ?? '';
      if (imageUrl.isNotEmpty) {
        avatarChild =
            _networkImageFromSchema(
              source: imageUrl,
              fit: avatarAppearance['objectFit'],
              alignment: avatarAppearance['objectPosition'],
              errorIconToken: state
                  .schema['rendererRequirements']?['fallbacks']?['missingImage'],
            ) ??
            Text(initials);
      } else {
        avatarChild = Text(
          initials,
          style: TextStyle(
            color: text,
            fontSize: fontSize,
            fontWeight: _fontWeight(avatarAppearance['fontWeight']),
          ),
        );
      }

      Widget avatarWidget = Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _color(avatarAppearance['backgroundColor']),
          gradient: _color(avatarAppearance['backgroundColor']) == null
              ? LinearGradient(
                  colors: <Color>[
                    tokenColor('colors.avatarGradientStart') ??
                        tokenColor('colors.welcomeGradientStart') ??
                        text,
                    tokenColor('colors.avatarGradientEnd') ??
                        tokenColor('colors.welcomeGradientEnd') ??
                        text,
                  ],
                )
              : null,
          borderRadius: BorderRadius.circular(avatarRadius),
          border: borderColor == null || borderWidth <= 0
              ? null
              : Border.all(color: borderColor, width: borderWidth),
        ),
        child: avatarChild,
      );

      final tap = _map(_map(avatar['events'])?['tap']);
      final actionId = tap?['actionId']?.toString().trim();
      if (actionId != null && actionId.isNotEmpty) {
        avatarWidget = Semantics(
          button: true,
          label: avatar['accessibilityLabel']?.toString(),
          child: InkWell(
            borderRadius: BorderRadius.circular(avatarRadius),
            onTap: () => state.dispatchAction(actionId),
            child: avatarWidget,
          ),
        );
      }

      final gap = _d(layout['gap']) ?? _tokenNumber('spacing.md') ?? 0;
      contentWidget = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(child: contentWidget),
          SizedBox(width: gap),
          avatarWidget,
        ],
      );
    }

    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null
            ? directBackground ??
                  tokenBackground ??
                  tokenColor('colors.surface')
            : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: _boxShadowList(appearance['shadow']),
      ),
      child: contentWidget,
    );

    final marginBottom = _d(layout['marginBottom']) ?? 0;
    final rendered = marginBottom > 0
        ? Padding(
            padding: EdgeInsets.only(bottom: marginBottom),
            child: box,
          )
        : box;
    return _tapSurface(c, rendered, item: item);
  }

  Widget _summaryBanner(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final content = _map(c['content']) ?? const <String, dynamic>{};
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};

    final radius =
        _d(appearance['borderRadius']) ??
        _d(appearance['radius']) ??
        _tokenNumber(appearance['radiusToken']?.toString()) ??
        _tokenNumber('radius.card') ??
        0;

    final bg =
        _color(appearance['backgroundColor']) ??
        tokenColor(appearance['backgroundColorToken']?.toString()) ??
        tokenColor('colors.surface');

    final fg =
        _color(appearance['textColor']) ??
        tokenColor(appearance['textColorToken']?.toString()) ??
        tokenColor('colors.textPrimary');

    final rendered = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (appearance['showIcon'] != false) ...[
                FaIconAdapter(
                  icon: icons.resolve(
                    (appearance['iconToken'] ?? c['iconToken'])?.toString(),
                  ),
                  color: tokenColor('colors.accent') ?? fg,
                  size: 16,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  _textValue(content['title'], item: item),
                  maxLines: 2,
                  overflow: _schemaOverflow('headerText'),
                  style: TextStyle(color: fg, fontWeight: FontWeight.w700),
                ),
              ),
              Flexible(
                child: Text(
                  _textValue(content['value'], item: item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
              ),
              if (_textValue(content['badge'], item: item).isNotEmpty) ...[
                const SizedBox(width: 10),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: tokenColor('colors.accent')?.withValues(
                        alpha: 0.15,
                      ),
                      borderRadius: BorderRadius.circular(
                        _tokenNumber('radius.pill') ?? 999,
                      ),
                    ),
                    child: Text(
                      _textValue(content['badge'], item: item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokenColor('colors.accent'),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
              if (appearance['showPill'] != false &&
                  _textValue(content['pill'], item: item).isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: tokenColor('colors.accent'),
                      borderRadius: BorderRadius.circular(
                        _tokenNumber('radius.pill') ?? 999,
                      ),
                    ),
                    child: Text(
                      _textValue(content['pill'], item: item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokenColor('colors.surface'),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (appearance['showMeta'] != false &&
              _textValue(content['meta'], item: item).isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _textValue(content['meta'], item: item),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tokenColor('colors.textMuted') ?? fg,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
    return _tapSurface(c, rendered, item: item);
  }

  Widget _statusSummary(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final items = c['items'];
    if (items is! List) return _error('${c['id']}.items[] is required.');

    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (items[i] is Map)
            Expanded(
              child: Builder(
                builder: (_) {
                  final entry = Map<String, dynamic>.from(
                    (items[i] as Map).cast<dynamic, dynamic>(),
                  );
                  final color = tokenColor(entry['colorToken']?.toString());
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: tokenColor('colors.surface'),
                      borderRadius: BorderRadius.circular(
                        _tokenNumber('radius.card') ?? 12,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          _textValue(entry['value'], item: item),
                          style: TextStyle(
                            color: color,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _textValue(entry['label'], item: item),
                          style: TextStyle(
                            color: tokenColor('colors.textSecondary'),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          if (i < items.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }

  double _responsiveViewportWidth(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final respectSafeArea =
        state.schema['layoutContract']?['respectSafeArea'] == true ||
        state.schema['responsive']?['safeArea'] == true;
    if (!respectSafeArea) return size.width;
    final padding = MediaQuery.viewPaddingOf(context);
    return (size.width - padding.left - padding.right)
        .clamp(0.0, double.infinity)
        .toDouble();
  }

  double _responsiveViewportHeight(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final respectSafeArea =
        state.schema['layoutContract']?['respectSafeArea'] == true ||
        state.schema['responsive']?['safeArea'] == true;
    if (!respectSafeArea) return size.height;
    final padding = MediaQuery.viewPaddingOf(context);
    return (size.height - padding.top - padding.bottom)
        .clamp(0.0, double.infinity)
        .toDouble();
  }

  String _responsiveBreakpointName(BuildContext context) {
    final width = _responsiveViewportWidth(context);
    final height = _responsiveViewportHeight(context);
    final orientation = width > height ? 'landscape' : 'portrait';
    var name =
        SchemaRuntime(state.schema).resolveBreakpointName(
          width,
          logicalHeight: height,
          orientation: orientation,
        ) ??
        state.schema['responsive']?['defaultBreakpoint']?.toString() ??
        'compact';

    if (orientation == 'landscape') {
      final landscape = _map(state.schema['responsive']?['orientation']?['landscape']);
      if (landscape?['preferMediumLayout'] == true &&
          (name == 'narrow' || name == 'compact')) {
        name = 'medium';
      }
    }
    return name;
  }

  Map<String, dynamic> _componentForViewport(
    BuildContext context,
    Map<String, dynamic> component,
  ) {
    return SchemaRuntime(state.schema).resolveResponsiveMap(
      component,
      _responsiveViewportWidth(context),
      logicalHeight: _responsiveViewportHeight(context),
      orientation: _responsiveViewportWidth(context) >
              _responsiveViewportHeight(context)
          ? 'landscape'
          : 'portrait',
    );
  }

  Map<String, dynamic> _layoutForViewport(
    BuildContext context,
    Map<String, dynamic> layout,
  ) {
    return SchemaRuntime(state.schema).resolveLayoutMap(
      layout,
      _responsiveViewportWidth(context),
      logicalHeight: _responsiveViewportHeight(context),
      orientation: _responsiveViewportWidth(context) >
              _responsiveViewportHeight(context)
          ? 'landscape'
          : 'portrait',
    );
  }

  TextOverflow _schemaOverflow(String policyKey) {
    final policy = _map(state.schema['responsive']?['overflowPolicy']);
    return _textOverflow(policy?[policyKey]) ??
        _textOverflow(policy?['default']) ??
        TextOverflow.ellipsis;
  }

  (double, double)? schemaTextScaleRange() {
    final raw = _map(state.schema['responsive']?['textScale']);
    if (raw == null) return null;
    final minimum = _d(raw['minimum']) ?? 0.9;
    final maximum = _d(raw['maximum']) ?? 1.3;
    if (maximum < minimum) return (minimum, minimum);
    return (minimum, maximum);
  }

  Widget _responsiveGrid(BuildContext context, Map<String, dynamic> c) {
    final items = <_GridItem>[];

    final children = c['children'];
    if (children is List) {
      for (final child in children) {
        if (child is String) {
          final node = state.component(child);
          if (node != null) {
            items.add(_GridItem(component: node));
          }
        }
      }
    }

    final binding = _map(c['childrenBinding']);
    if (binding != null) {
      final bindPath = binding[r'$bind']?.toString();

      if (bindPath == null || bindPath.isEmpty) {
        return _error(
          'Schema binding missing: '
          'components.${c['id']}.childrenBinding.\$bind',
        );
      }

      final sourceId = bindPath.split('.').first;

      final runtimeError = state.dataError(sourceId);

      final bound = state.resolve(<String, dynamic>{
        r'$bind': bindPath,
        'fallback': <dynamic>[],
      });

      if (runtimeError != null && (bound is! List || bound.isEmpty)) {
        return _error(
          'Runtime data error for '
          'components.${c['id']}: '
          '$runtimeError',
        );
      }

      final templateId = binding['itemTemplateId']?.toString();
      if (bound is List && templateId != null) {
        final template = state.component(templateId);
        if (template != null) {
          for (final raw in bound) {
            if (raw is Map) {
              items.add(
                _GridItem(
                  component: template,
                  item: Map<String, dynamic>.from(raw.cast<dynamic, dynamic>()),
                ),
              );
            }
          }
        }
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Breakpoint selection must use the actual logical viewport, not the
        // grid's already-padded/nested LayoutBuilder width. The latter can
        // incorrectly classify a 600dp tablet as compact after page padding.
        final layoutName = _responsiveBreakpointName(context);
        final layout = _gridLayoutForBreakpoint(c, layoutName);

        final columnGap = _d(layout['columnGap']);
        final rowGap = _d(layout['rowGap']);
        final rowHeight = _d(layout['rowHeight']);
        final minimumRowHeight =
            _d(layout['minRowHeight']) ??
            _d(_map(c['layout'])?['minRowHeight']);
        final columns = (layout['columns'] as num?)?.toInt();

        if (columns == null ||
            columnGap == null ||
            rowGap == null ||
            rowHeight == null) {
          return _error(
            'Schema path missing: components.${c['id']}.layouts.$layoutName '
            '(columns, columnGap, rowGap, rowHeight). '
            'Got columns=$columns columnGap=$columnGap rowGap=$rowGap '
            'rowHeight=$rowHeight',
          );
        }

        final gridPolicy =
            _map(state.schema['responsive']?['grid']) ??
            const <String, dynamic>{};
        final minCell =
            _d(layout['minimumCellWidthDp']) ??
            _d(gridPolicy['minimumCellWidthDp']) ??
            0;
        final narrowThreshold = _d(gridPolicy['narrowScreenThresholdDp']);
        final narrowMaxCols =
            (gridPolicy['narrowScreenMaxColumns'] as num?)?.toInt();
        final viewportWidth = _responsiveViewportWidth(context);

        var columnCount = columns;
        final preserveMetroColumns = _isMetroMosaic(c);
        // Schema may declare a preferred metro column count, but narrow phones
        // still honor responsive.grid.narrowScreen* so tiles do not overflow.
        if (preserveMetroColumns) {
          final declaredColumns =
              (_map(c['layout'])?['columns'] as num?)?.toInt() ??
              (_map(c['layouts'])?['compact']?['columns'] as num?)?.toInt() ??
              (state.schema['uiRenderContract']?['grid']?['columns'] as num?)
                  ?.toInt() ??
              (state.schema['layoutContract']?['gridCalculation']
                      ?['homeGridColumns'] as num?)
                  ?.toInt();
          if (declaredColumns != null && declaredColumns > 0) {
            columnCount = declaredColumns;
          }
        }

        final applyNarrowCollapse = narrowThreshold != null &&
            narrowMaxCols != null &&
            viewportWidth < narrowThreshold &&
            // Allow schema to keep full metro columns: set
            // responsive.grid.preserveMetroColumnsOnNarrow = true
            !(preserveMetroColumns &&
                state.schema['responsive']?['grid']
                        ?['preserveMetroColumnsOnNarrow'] ==
                    true);
        if (applyNarrowCollapse) {
          columnCount = math.min(columnCount, narrowMaxCols);
        }

        var availableWidth = constraints.maxWidth;
        if (!availableWidth.isFinite || availableWidth <= 0) {
          availableWidth = viewportWidth;
        }
        final maxWidth = _d(layout['maximumContentWidth']);
        if (maxWidth != null && !(preserveMetroColumns && !applyNarrowCollapse)) {
          availableWidth = math.min(maxWidth, availableWidth);
        }

        // Always shrink columns until cells fit minimumCellWidthDp from schema
        // (metro included) unless schema opts out on narrow.
        if (!(preserveMetroColumns &&
            state.schema['responsive']?['grid']
                    ?['preserveMetroColumnsOnNarrow'] ==
                true &&
            !applyNarrowCollapse)) {
          while (columnCount > 1) {
            final cell =
                (availableWidth - ((columnCount - 1) * columnGap)) /
                columnCount;
            if (cell.isFinite && cell > 0 && cell >= minCell) break;
            columnCount -= 1;
          }
        }

        final effectiveRowHeight = minimumRowHeight == null
            ? rowHeight
            : math.max(rowHeight, minimumRowHeight);

        if (columnCount <= 0 || effectiveRowHeight <= 0) {
          return _error(
            'Schema layout invalid: components.${c['id']}.layouts.'
            '$layoutName columns and rowHeight must be greater than zero.',
          );
        }

        var cellWidth =
            (availableWidth - ((columnCount - 1) * columnGap)) / columnCount;
        if (!cellWidth.isFinite || cellWidth <= 0) {
          columnCount = 1;
          cellWidth = availableWidth <= 0 ? viewportWidth : availableWidth;
        }

        final placements = _packGrid(
          items,
          columns: columnCount,
          layoutName: preserveMetroColumns ? 'compact' : layoutName,
          clampColumnSpan:
              c['clampChildColumnSpan'] != false &&
              (c['clampChildColumnSpan'] == true ||
                  state.schema['responsive']?['grid']?['clampColumnSpanToColumns'] != false ||
                  state.schema['layoutContract']?['responsiveGrid']?['clampColumnSpanToColumns'] != false),
          preferExplicitPlacement: preserveMetroColumns,
        );

        var maxRow = 0;
        for (final p in placements) {
          maxRow = math.max(maxRow, p.row + p.rowSpan);
        }

        final height =
            maxRow * effectiveRowHeight + math.max(0, maxRow - 1) * rowGap;

        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: availableWidth,
            height: height,
            child: Stack(
              children: [
                for (final p in placements)
                  Positioned(
                    left: p.column * (cellWidth + columnGap),
                    top: p.row * (effectiveRowHeight + rowGap),
                    width:
                        p.columnSpan * cellWidth +
                        (p.columnSpan - 1) * columnGap,
                    height:
                        p.rowSpan * effectiveRowHeight +
                        (p.rowSpan - 1) * rowGap,
                    child: Builder(
                      builder: (context) {
                        final child = buildNode(
                          context,
                          p.item.component,
                          item: p.item.item,
                          event: p.item.item == null
                              ? null
                              : <String, dynamic>{
                                  'componentId': p.item.item!['id'],
                                },
                        );

                        // Web `.ahp-card` always clips to the metro tile.
                        // Four-face boxes still rotate in 3D *inside* that clip.
                        return _clipToTileBounds(
                          p.item.component,
                          RepaintBoundary(child: SizedBox.expand(child: child)),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<_Placement> _packGrid(
    List<_GridItem> items, {
    required int columns,
    required String layoutName,
    required bool clampColumnSpan,
    bool preferExplicitPlacement = false,
  }) {
    final metroItems = <HomeMetroItem>[];
    for (final item in items) {
      final spans = _gridSpan(item.component, layoutName);
      metroItems.add(
        HomeMetroItem(
          id: item.component['id']?.toString() ?? '${metroItems.length}',
          columnSpan: spans.columnSpan,
          rowSpan: spans.rowSpan,
          columnStart: preferExplicitPlacement ? spans.columnStart : null,
          rowStart: preferExplicitPlacement ? spans.rowStart : null,
        ),
      );
    }

    final placed = placeHomeMetroGrid(
      items: metroItems,
      columns: columns,
      clampColumnSpan: clampColumnSpan,
    );
    final byId = <String, _GridItem>{
      for (final item in items)
        if (item.component['id'] != null)
          item.component['id'].toString(): item,
    };

    return <_Placement>[
      for (var i = 0; i < placed.length; i++)
        _Placement(
          item: byId[placed[i].id] ?? items[i],
          row: placed[i].row,
          column: placed[i].column,
          rowSpan: placed[i].rowSpan,
          columnSpan: placed[i].columnSpan,
        ),
    ];
  }

  ({int columnSpan, int rowSpan, int? columnStart, int? rowStart}) _gridSpan(
    Map<String, dynamic> component,
    String layoutName,
  ) {
    final responsive = _map(component['responsiveLayout']);
    final perLayout = responsive == null
        ? null
        : (_map(responsive[layoutName]) ??
            _map(responsive['compact']) ??
            _map(responsive['narrow']));
    final base = _map(component['layout']) ?? const <String, dynamic>{};
    final dimensions = _map(component['dimensions']);

    int asInt(dynamic raw, int fallback) {
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '') ?? fallback;
    }

    return (
      columnSpan: asInt(
        perLayout?['columnSpan'] ??
            base['columnSpan'] ??
            dimensions?['columnSpan'],
        1,
      ),
      rowSpan: asInt(
        perLayout?['rowSpan'] ?? base['rowSpan'] ?? dimensions?['rowSpan'],
        1,
      ),
      columnStart: () {
        final raw =
            perLayout?['columnStart'] ??
            base['columnStart'] ??
            base['col'];
        if (raw is num) return raw.toInt();
        return int.tryParse(raw?.toString() ?? '');
      }(),
      rowStart: () {
        final raw = perLayout?['rowStart'] ?? base['rowStart'] ?? base['row'];
        if (raw is num) return raw.toInt();
        return int.tryParse(raw?.toString() ?? '');
      }(),
    );
  }

  bool _isMetroMosaic(Map<String, dynamic> c) {
    final style = c['style']?.toString().trim().toLowerCase();
    final layoutType = _map(c['layout'])?['type']?.toString().trim().toLowerCase();
    return style == 'metromosaic' || layoutType == 'metrogrid';
  }

  Map<String, dynamic> _gridLayoutForBreakpoint(
    Map<String, dynamic> c,
    String name,
  ) {
    final componentLayouts = _map(c['layouts']);
    final schemaLayouts = _map(state.schema['responsive']?['grid']?['layouts']);
    final base = _map(c['layout']) ?? const <String, dynamic>{};

    Map<String, dynamic> pick(String key) {
      return <String, dynamic>{
        ...base,
        ...?_map(schemaLayouts?[key]),
        ...?_map(componentLayouts?[key]),
      };
    }

    bool hasMetrics(Map<String, dynamic> layout) {
      return layout['columns'] is num &&
          _d(layout['columnGap']) != null &&
          _d(layout['rowGap']) != null &&
          _d(layout['rowHeight']) != null;
    }

    var layout = pick(name);
    if (hasMetrics(layout)) return layout;

    final fallbacks = <String>[
      state.schema['responsive']?['defaultBreakpoint']?.toString() ?? 'compact',
      'narrow',
      'compact',
      'medium',
      'expanded',
      if (componentLayouts != null)
        ...componentLayouts.keys.map((key) => key.toString()),
      if (schemaLayouts != null)
        ...schemaLayouts.keys.map((key) => key.toString()),
    ];

    for (final key in fallbacks) {
      if (key.isEmpty || key == name) continue;
      layout = pick(key);
      if (hasMetrics(layout)) return layout;
    }

    return layout;
  }

  bool _isFourFaceBoxComponent(Map<String, dynamic> c) {
    final rotation = _map(c['rotation']);
    final model =
        '${rotation?['model'] ?? ''} ${rotation?['rendererKey'] ?? ''} '
        '${c['presetId'] ?? ''}';
    if (model.toLowerCase().contains('fourface')) return true;
    final geometry = _map(rotation?['geometry']);
    final style = geometry?['transformStyle']?.toString().trim().toLowerCase();
    return style == 'preserve-3d';
  }

  double? _metroTileRadius(Map<String, dynamic> c) {
    final appearance = _map(c['appearance']);
    return _d(appearance?['borderRadius']) ??
        _d(appearance?['cardBorderRadius']) ??
        _tokenNumber('radius.card');
  }

  /// Matches web `.ahp-card { overflow: hidden; border-radius }`.
  ///
  /// 3D side faces still render during a turn; they are clipped to the tile
  /// so the cube cannot paint over neighbours.
  Widget _clipToTileBounds(Map<String, dynamic> c, Widget child) {
    final overflow = c['overflowPolicy']?.toString().trim().toLowerCase();
    final fourFace = _isFourFaceBoxComponent(c);
    if (!fourFace && overflow != 'clip' && overflow != 'hidden') {
      return child;
    }
    final radius = _metroTileRadius(c);
    if (radius != null && radius > 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    }
    return ClipRect(clipBehavior: Clip.antiAlias, child: child);
  }

  ({int index, int count}) _cardStaggerSlot(Map<String, dynamic> c) {
    final id = c['id']?.toString();
    if (id == null || id.isEmpty) return (index: 0, count: 1);
    final components = state.schema['components'];
    if (components is Map) {
      for (final raw in components.values) {
        if (raw is! Map) continue;
        if (raw['type']?.toString() != 'responsiveGrid') continue;
        final children = raw['children'];
        if (children is! List) continue;
        final index = children.indexOf(id);
        if (index >= 0) {
          return (index: index, count: children.length);
        }
      }
    }
    return (index: 0, count: 1);
  }

  Widget _rotatingFaceCard(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final faces = c['faces'];
    if (faces is! List) return _error('${c['id']}.faces[] is required.');

    final slot = _cardStaggerSlot(c);
    final cube = _RotatingCard(
      schema: state.schema,
      component: c,
      faces: faces,
      item: item,
      staggerIndex: slot.index,
      staggerCount: slot.count,
      buildFace: (face, index) => _face(context, c, face, item: item),
      onTap: () => _event(c, 'tap', item: item),
      onLongPress: () => _event(c, 'longPress', item: item),
    );

    return _clipToTileBounds(c, cube);
  }

  Widget _rotatingDeviceCard(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final resolvedFaces = state.resolve(c['facesBinding'], item: item);
    final faces = resolvedFaces is List && resolvedFaces.isNotEmpty
        ? resolvedFaces
        : c['faces'];

    if (faces is! List || faces.isEmpty) {
      return _error('${c['id']} has no device faces.');
    }

    final online =
        state.resolve(_map(c['status'])?['online'], item: item) == true;

    final power =
        state.resolve(_map(c['powerControl'])?['powerBinding'], item: item) ==
        true;

    final powerControl = _map(c['powerControl']);
    final powerVisible = powerControl?['visible'] != false;

    final deviceCard = Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(
          child: _RotatingCard(
            schema: state.schema,
            component: c,
            faces: faces,
            item: item,
            staggerIndex: _cardStaggerSlot(c).index,
            staggerCount: _cardStaggerSlot(c).count,
            buildFace: (face, index) => _face(context, c, face, item: item),
            onTap: () => _event(c, 'tap', item: item),
            onLongPress: () => _event(c, 'longPress', item: item),
          ),
        ),
        if (_map(c['status'])?['showStatusDot'] != false)
          Positioned(
            top: _tokenNumber('spacing.sm') ?? 0,
            right: _tokenNumber('spacing.sm') ?? 0,
            child: Container(
              width: (_tokenNumber('spacing.xs') ?? 0) * 2,
              height: (_tokenNumber('spacing.xs') ?? 0) * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: online
                    ? tokenColor(
                        _map(c['status'])?['onlineColorToken']?.toString(),
                      )
                    : tokenColor(
                        _map(c['status'])?['offlineColorToken']?.toString(),
                      ),
              ),
            ),
          ),
        if (powerVisible)
          Positioned(
            right: _tokenNumber('spacing.sm') ?? 0,
            bottom: _tokenNumber('spacing.sm') ?? 0,
            child: GestureDetector(
              onTap: _enabled(powerControl?['enabledWhen'], item: item)
                  ? () => _event(c, 'powerTap', item: item)
                  : null,
              child: Container(
                width:
                    _d(state.schema['accessibility']?['minimumTapTargetDp']) ??
                    0,
                height:
                    _d(state.schema['accessibility']?['minimumTapTargetDp']) ??
                    0,
                decoration: BoxDecoration(
                  color: power
                      ? tokenColor('colors.accent')
                      : tokenColor('colors.surfaceElevated'),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.power_settings_new,
                  size: _tokenNumber('typography.cardTitle.fontSize'),
                  color: tokenColor('colors.surface'),
                ),
              ),
            ),
          ),
      ],
    );

    return _clipToTileBounds(c, deviceCard);
  }

  Widget _face(
    BuildContext context,
    Map<String, dynamic> parent,
    dynamic rawFace, {
    Map<String, dynamic>? item,
  }) {
    if (rawFace is! Map) {
      return _error(
        'Schema component error: components.${parent['id']}.faces[] '
        'must contain objects.',
      );
    }

    final face = Map<String, dynamic>.from(rawFace.cast<dynamic, dynamic>());

    final faceAppearance = _map(face['appearance']);
    final parentAppearance =
        _map(parent['appearance']) ?? const <String, dynamic>{};
    final appearance = faceAppearance ?? parentAppearance;

    // A face-level background is authoritative. Only fall back to the parent
    // card background when the face does not declare a background at all.
    // This preserves each schema face's own solid/gradient color instead of
    // applying the parent card gradient to every face.
    final faceDeclaresBackground =
        faceAppearance != null &&
        (faceAppearance.containsKey('background') ||
            faceAppearance.containsKey('backgroundColor'));
    final backgroundAppearance = faceDeclaresBackground
        ? faceAppearance
        : parentAppearance;
    final resolvedBackgroundColor = state.resolve(
      backgroundAppearance['backgroundColor'],
      item: item,
    );
    final backgroundGradient =
        _gradient(_map(backgroundAppearance['background'])) ??
        _gradientFromCss(resolvedBackgroundColor?.toString());
    final background = backgroundGradient == null
        ? (_color(resolvedBackgroundColor) ??
              (!faceDeclaresBackground &&
                      !parentAppearance.containsKey('background') &&
                      !parentAppearance.containsKey('backgroundColor')
                  ? tokenColor('colors.surface')
                  : null))
        : null;

    final titleColor =
        _color(appearance['titleTextColor']) ??
        tokenColor('colors.textPrimary');

    final subtitleColor =
        _color(appearance['subtitleTextColor']) ??
        tokenColor('colors.textSecondary');

    final iconColor =
        _color(appearance['iconColor']) ?? tokenColor('colors.textPrimary');

    final imageTextColor = tokenColor('colors.welcomeText');

    final radius =
        _d(appearance['borderRadius']) ?? _tokenNumber('radius.card');

    final titleSize =
        _d(appearance['titleFontSize']) ??
        _tokenNumber('typography.cardTitle.fontSize');

    final subtitleSize =
        _d(appearance['subtitleFontSize']) ??
        _tokenNumber('typography.cardSubtitle.fontSize');

    // The schema has no dedicated global icon-size token. Use the schema's
    // page-title size as the generic icon metric unless this face explicitly
    // supplies appearance.iconSize.
    final iconSize =
        _d(appearance['iconSize']) ??
        _tokenNumber('typography.pageTitle.fontSize');

    final statSize = _tokenNumber('typography.statValue.fontSize');

    final contentPadding = _tokenNumber('spacing.sm');

    final iconTitleGap = _tokenNumber('spacing.xs');

    final detailGap = _tokenNumber('spacing.xxs');

    final titleWeight = _tokenFontWeight('typography.cardTitle.fontWeight');

    final subtitleWeight = _tokenFontWeight(
      'typography.cardSubtitle.fontWeight',
    );

    final statWeight = _tokenFontWeight('typography.statValue.fontWeight');

    final titleMaxLines = _tokenInt('typography.cardTitle.maxLines');

    final subtitleMaxLines = _tokenInt('typography.cardSubtitle.maxLines');

    final titleOverflow = _tokenTextOverflow('typography.cardTitle.overflow');

    final subtitleOverflow = _tokenTextOverflow(
      'typography.cardSubtitle.overflow',
    );

    final requiredValues = <String, dynamic>{
      'designTokens.colors.surface/backgroundColor':
          backgroundGradient ?? background,
      'designTokens.colors.textPrimary/titleTextColor': titleColor,
      'designTokens.colors.textSecondary/subtitleTextColor': subtitleColor,
      'designTokens.colors.textPrimary/iconColor': iconColor,
      'designTokens.radius.card/borderRadius': radius,
      'designTokens.typography.cardTitle.fontSize/titleFontSize': titleSize,
      'designTokens.typography.cardSubtitle.fontSize/subtitleFontSize':
          subtitleSize,
      'designTokens.typography.pageTitle.fontSize/iconSize': iconSize,
      'designTokens.typography.statValue.fontSize': statSize,
      'designTokens.spacing.sm': contentPadding,
      'designTokens.spacing.xs': iconTitleGap,
      'designTokens.spacing.xxs': detailGap,
      'designTokens.typography.cardTitle.fontWeight': titleWeight,
      'designTokens.typography.cardSubtitle.fontWeight': subtitleWeight,
      'designTokens.typography.statValue.fontWeight': statWeight,
      'designTokens.typography.cardTitle.maxLines': titleMaxLines,
      'designTokens.typography.cardSubtitle.maxLines': subtitleMaxLines,
      'designTokens.typography.cardTitle.overflow': titleOverflow,
      'designTokens.typography.cardSubtitle.overflow': subtitleOverflow,
    };

    final missing = requiredValues.entries
        .where((entry) => entry.value == null)
        .map((entry) => entry.key)
        .toList(growable: false);

    if (missing.isNotEmpty) {
      return _error(
        'Schema visual contract missing for '
        'components.${parent['id']}.faces.${face['id'] ?? '?'}: '
        '${missing.join(', ')}',
      );
    }

    final title = _textValue(face['title'], item: item);
    final subtitle = _textValue(face['subtitle'], item: item);
    final value = _textValue(face['value'], item: item);
    final unit = _textValue(face['unit'], item: item);

    // Resolve the visual asset before validating textual content. Image-only
    // cube faces are valid schema content and are used by the web renderer.
    final assetId = face['assetId']?.toString().trim();
    final directImage = face['image']?.toString().trim();
    Widget? image;
    if (assetId != null && assetId.isNotEmpty) {
      image = _assetWidget(assetId);
    }
    // A schema may publish both an assetId and the resolved image URL. If the
    // asset entry is absent/unsupported, try the explicit face image without
    // weakening HTTPS/domain security checks.
    if (image == null && directImage != null && directImage.isNotEmpty) {
      image = _networkImageFromSchema(
        source: directImage,
        fit: face['imageFit'],
        alignment: face['imageAlignment'],
        errorIconToken: face['iconToken'],
      );
    }

    final contentLayout = _map(face['contentLayout']) ?? const <String, dynamic>{};
    final tileStyle = (appearance['style'] ??
            parentAppearance['style'] ??
            contentLayout['style'])
        ?.toString()
        .trim()
        .toLowerCase();
    final isMetroTile =
        tileStyle == 'metrotile' || tileStyle == 'starttile';

    final iconToken = face['iconToken']?.toString().trim();
    final imageFace = face['type']?.toString() == 'image' ||
        parent['cardType']?.toString() == 'image';
    final hasIcon = iconToken != null &&
        iconToken.isNotEmpty &&
        !(image != null && imageFace);
    final hasText = title.isNotEmpty || subtitle.isNotEmpty || value.isNotEmpty;

    if (!hasText && image == null && !hasIcon) {
      return _error(
        'Schema content missing: components.${parent['id']}.faces.'
        '${face['id'] ?? '?'} requires text, icon or image content.',
      );
    }

    final foregroundTitle = image == null
        ? titleColor!
        : (imageTextColor ?? titleColor!);

    final foregroundSubtitle = image == null
        ? subtitleColor!
        : (imageTextColor ?? subtitleColor!);

    final foregroundIcon = image == null
        ? iconColor!
        : (imageTextColor ?? iconColor!);

    final layoutPadding = _paddingOrNull(contentLayout['padding']);
    final metroPad = layoutPadding ??
        EdgeInsets.symmetric(
          horizontal: _d(_map(contentLayout['padding'])?['horizontal']) ?? 10,
          vertical: _d(_map(contentLayout['padding'])?['vertical']) ?? 8,
        );

    Widget titleBlock({required TextAlign align}) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: align == TextAlign.left
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          if (title.isNotEmpty)
            Text(
              title,
              textAlign: align,
              maxLines: titleMaxLines!,
              overflow: titleOverflow!,
              style: TextStyle(
                color: foregroundTitle,
                fontWeight: titleWeight!,
                fontSize: titleSize!,
                height: _d(appearance['titleLineHeight']),
              ),
            ),
          if (!isMetroTile && subtitle.isNotEmpty) ...[
            SizedBox(height: detailGap!),
            Text(
              subtitle,
              textAlign: align,
              maxLines: subtitleMaxLines!,
              overflow: subtitleOverflow!,
              style: TextStyle(
                color: foregroundSubtitle,
                fontWeight: subtitleWeight!,
                fontSize: subtitleSize!,
                height: _d(appearance['subtitleLineHeight']),
              ),
            ),
          ],
        ],
      );
    }

    final iconWidget = !hasIcon
        ? null
        : FaIconAdapter(
            icon: icons.resolve(iconToken),
            color: foregroundIcon,
            size: iconSize!,
          );

    late final Widget content;
    if (isMetroTile && image == null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Center(child: iconWidget ?? const SizedBox.shrink()),
          ),
          if (title.isNotEmpty) titleBlock(align: TextAlign.left),
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (iconWidget != null) ...[
            iconWidget,
            if (hasText) SizedBox(height: iconTitleGap!),
          ],
          if (title.isNotEmpty)
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: titleMaxLines!,
              overflow: titleOverflow!,
              style: TextStyle(
                color: foregroundTitle,
                fontWeight: titleWeight!,
                fontSize: titleSize!,
              ),
            ),
          if (value.isNotEmpty) ...[
            SizedBox(height: detailGap!),
            Text(
              '$value$unit',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foregroundTitle,
                fontSize: statSize!,
                fontWeight: statWeight!,
              ),
            ),
          ] else if (subtitle.isNotEmpty) ...[
            SizedBox(height: detailGap!),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              maxLines: subtitleMaxLines!,
              overflow: subtitleOverflow!,
              style: TextStyle(
                color: foregroundSubtitle,
                fontSize: subtitleSize!,
                fontWeight: subtitleWeight!,
              ),
            ),
          ],
        ],
      );
    }

    final faceEvents = _map(face['events']);
    final faceTapActionId = _map(faceEvents?['tap'])?['actionId']?.toString();
    final faceLongPressActionId = _map(
      faceEvents?['longPress'],
    )?['actionId']?.toString();

    return GestureDetector(
      onTap: () {
        if (faceTapActionId != null && faceTapActionId.isNotEmpty) {
          state.dispatchAction(
            faceTapActionId,
            item: item,
            event: <String, dynamic>{
              'componentId': item?['id'] ?? parent['id'],
              'faceId': face['id'],
              'eventName': 'tap',
            },
          );
        } else {
          _event(parent, 'tap', item: item);
        }
      },
      onLongPress: () {
        if (faceLongPressActionId != null && faceLongPressActionId.isNotEmpty) {
          state.dispatchAction(
            faceLongPressActionId,
            item: item,
            event: <String, dynamic>{
              'componentId': item?['id'] ?? parent['id'],
              'faceId': face['id'],
              'eventName': 'longPress',
            },
          );
        } else {
          _event(parent, 'longPress', item: item);
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius!),
        child: Container(
          decoration: BoxDecoration(
            color: backgroundGradient == null ? background : null,
            gradient: backgroundGradient,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (image != null) image,
              if (isMetroTile && image == null)
                Padding(padding: metroPad, child: content)
              else if (isMetroTile && image != null)
                Padding(
                  padding: metroPad,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: titleBlock(align: TextAlign.left),
                  ),
                )
              else
                Padding(
                  padding: EdgeInsets.all(contentPadding!),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: content,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  FontWeight? _tokenFontWeight(String token) {
    final raw = _tokenValue(token);
    return raw == null ? null : _fontWeight(raw);
  }

  int? _tokenInt(String token) {
    final raw = _tokenValue(token);
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  TextOverflow? _tokenTextOverflow(String token) {
    final raw = _tokenValue(token)?.toString();
    return switch (raw) {
      'ellipsis' => TextOverflow.ellipsis,
      'clip' => TextOverflow.clip,
      'fade' => TextOverflow.fade,
      'visible' => TextOverflow.visible,
      _ => null,
    };
  }

  dynamic _tokenValue(String token) {
    final themed = _activeThemeTokenValue(token);
    if (themed != null) return themed;

    dynamic current = state.schema['designTokens'];

    for (final part in token.split('.')) {
      if (current is! Map || !current.containsKey(part)) {
        return null;
      }
      current = current[part];
    }

    return current;
  }

  Widget? _networkImageFromSchema({
    required String source,
    dynamic fit,
    dynamic alignment,
    dynamic errorIconToken,
  }) {
    final uri = Uri.tryParse(source);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      logDebug('[HOME_SDUI][IMAGE] rejected invalid URL: $source');
      return null;
    }

    if (state.schema['security']?['requireHttps'] == true &&
        uri.scheme.toLowerCase() != 'https') {
      logDebug(
        '[HOME_SDUI][IMAGE] rejected non-HTTPS asset host=${uri.host}',
      );
      return null;
    }

    final allowedDomains =
        (state.schema['security']?['allowedAssetDomains'] as List?)
            ?.map((e) => e.toString().trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        <String>{};

    // The live schema only lists images.unsplash.com, but it also publishes
    // logo/GRID assets on efactor.tech. Web loads those schema-declared URLs;
    // blocking them here dropped the Home logo and GRID banner on the app.
    final permitted = <String>{
      ...allowedDomains,
      ..._schemaDeclaredImageHosts(),
    };

    if (permitted.isNotEmpty &&
        !permitted.contains(uri.host.toLowerCase())) {
      logDebug(
        '[HOME_SDUI][IMAGE] BLOCKED_BY_SCHEMA_DOMAIN '
        'host=${uri.host} allowed=${permitted.join(",")}',
      );
      return null;
    }

    return CachedNetworkImage(
      imageUrl: source,
      cacheManager: SduiNetworkImageCache.manager,
      fit: _fit(fit),
      alignment: _alignment(alignment),
      filterQuality: FilterQuality.medium,
      placeholder: (_, __) => const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      errorWidget: (_, error, __) {
        if (_loggedImageErrors.add(source)) {
          logDebug(
            '[HOME_SDUI][IMAGE] NETWORK_ERROR host=${uri.host} error=$error',
          );
        }
        return Center(
          child: FaIconAdapter(
            icon: icons.resolve(errorIconToken?.toString()),
            color: tokenColor('colors.textMuted'),
            size: _tokenNumber('typography.pageTitle.fontSize'),
          ),
        );
      },
    );
  }

  Set<String> _schemaDeclaredImageHosts() {
    if (identical(_imageHostSchema, state.schema) && _declaredImageHosts != null) {
      return _declaredImageHosts!;
    }

    final hosts = <String>{};
    const imageKeys = <String>{
      'imageUrl',
      'image',
      'avatarUrl',
      'source',
      'logoUrl',
    };

    void addHost(dynamic raw) {
      final text = raw?.toString().trim() ?? '';
      if (text.isEmpty) return;
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty) return;
      if (uri.scheme != 'http' && uri.scheme != 'https') return;
      hosts.add(uri.host.toLowerCase());
    }

    void walk(dynamic node) {
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString();
          if (imageKeys.contains(key)) {
            addHost(entry.value);
          }
          if (key == 'logo' && entry.value is Map) {
            addHost((entry.value as Map)['imageUrl']);
          }
          walk(entry.value);
        }
      } else if (node is List) {
        for (final child in node) {
          walk(child);
        }
      }
    }

    walk(state.schema['components']);
    walk(state.schema['assets']);
    _imageHostSchema = state.schema;
    _declaredImageHosts = hosts;
    return hosts;
  }

  Widget? _assetWidget(String assetId) {
    dynamic raw;
    final assets = state.schema['assets'];

    if (assets is Map) {
      raw = assets[assetId];
    } else if (assets is List) {
      for (final candidate in assets) {
        if (candidate is Map && candidate['id']?.toString() == assetId) {
          raw = candidate;
          break;
        }
      }
    }

    if (raw is! Map) return null;

    final asset = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
    final type = asset['type']?.toString();

    if (type != 'network-image') return null;

    final source = asset['source']?.toString();
    if (source == null || source.isEmpty) return null;
    return _networkImageFromSchema(
      source: source,
      fit: asset['fit'],
      alignment: asset['alignment'],
      errorIconToken: asset['errorIconToken'],
    );
  }

  Widget _bottomNavigation(BuildContext context, Map<String, dynamic> c) {
    final source = state.resolve(c['itemsSource']);
    final items = source is List
        ? source
        : state.schema['navigation']?['items'];
    if (items is! List) {
      return _error('${c['id']}.itemsSource did not resolve.');
    }

    final tokenNav =
        _map(state.schema['designTokens']?['bottomNavigation']) ??
        _map(state.schema['componentStyles']?['bottomNavigation']) ??
        const <String, dynamic>{};
    final appearance = <String, dynamic>{
      ...tokenNav,
      ...?_map(c['appearance']),
    };
    final activeColor =
        tokenColor(appearance['activeColorToken']?.toString()) ??
        tokenColor('colors.navActive');
    final inactiveColor =
        tokenColor(appearance['inactiveColorToken']?.toString()) ??
        tokenColor('colors.textMuted');
    final background =
        _color(appearance['backgroundColor']) ??
        tokenColor(appearance['backgroundColorToken']?.toString()) ??
        tokenColor('colors.navBackground');
    final showLabels = appearance['showLabels'] != false;
    final iconSize =
        _d(appearance['iconSize']) ??
        _tokenNumber('typography.pageSubtitle.fontSize');
    final selectedFontSize =
        _d(appearance['selectedLabelFontSize']) ??
        _d(appearance['labelFontSize']) ??
        _tokenNumber('typography.cardSubtitle.fontSize');
    final unselectedFontSize =
        _d(appearance['unselectedLabelFontSize']) ??
        _d(appearance['labelFontSize']) ??
        _tokenNumber('typography.cardSubtitle.fontSize');

    if (activeColor == null ||
        inactiveColor == null ||
        background == null ||
        iconSize == null ||
        selectedFontSize == null ||
        unselectedFontSize == null) {
      return _error(
        'Schema visual contract missing for components.${c['id']}: '
        'bottomNavigation requires colors plus icon/label typography tokens.',
      );
    }

    final navItems = <Map<String, dynamic>>[
      for (final raw in items)
        if (raw is Map)
          Map<String, dynamic>.from(raw.cast<dynamic, dynamic>()),
    ];
    if (navItems.isEmpty) {
      return _error('${c['id']}.itemsSource resolved to an empty list.');
    }

    final currentIndex = math.max(
      0,
      navItems.indexWhere(state.navigationItemMatchesRoute),
    );
    final labelWeight = appearance['labelFontWeight'] == null
        ? null
        : _fontWeight(appearance['labelFontWeight']);
    final padH = _d(appearance['paddingHorizontal']) ?? 0;
    final padV = _d(appearance['paddingVertical']) ?? 0;
    final height = _d(appearance['height']);
    final insetBottom = appearance['safeAreaInsetBottom'] != false;

    Widget destination(int index) {
      final raw = navItems[index];
      final selected = index == currentIndex;
      final color = selected ? activeColor : inactiveColor;
      final fontSize = selected ? selectedFontSize : unselectedFontSize;
      final label = _textValue(raw['label']);
      return Expanded(
        child: InkWell(
          onTap: () {
            final actionId = raw['actionId']?.toString();
            if (actionId != null && actionId.isNotEmpty) {
              state.dispatchAction(actionId);
            }
          },
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FaIconAdapter(
                    icon: icons.resolve(raw['iconToken']?.toString()),
                    size: iconSize,
                    color: color,
                  ),
                  if (showLabels && label.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: fontSize,
                        fontWeight: labelWeight,
                        height: 1.1,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget navigation = Material(
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < navItems.length; i++) destination(i),
          ],
        ),
      ),
    );

    if (height != null && height > 0) {
      navigation = SizedBox(height: height, child: navigation);
    }

    final marginH = _d(appearance['marginHorizontal']);
    final marginB = _d(appearance['marginBottom']);
    final margin =
        _paddingOrNull(appearance['margin']) ??
        EdgeInsets.fromLTRB(marginH ?? 0, 0, marginH ?? 0, marginB ?? 0);
    final radius =
        _d(appearance['borderRadius']) ??
        _tokenNumber(appearance['radiusToken']?.toString());
    final borderWidth = _d(appearance['borderWidth']);
    final borderColor = _color(appearance['borderColor']);
    final shadow = _boxShadowFromToken(appearance['shadowToken']);

    if (margin != EdgeInsets.zero ||
        radius != null ||
        borderWidth != null ||
        shadow != null) {
      navigation = Padding(
        padding: margin,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(radius ?? 0),
            border: borderWidth != null &&
                    borderWidth > 0 &&
                    borderColor != null
                ? Border.all(color: borderColor, width: borderWidth)
                : null,
            boxShadow: shadow,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius ?? 0),
            child: navigation,
          ),
        ),
      );
    } else {
      navigation = ColoredBox(color: background, child: navigation);
    }

    return SafeArea(
      top: false,
      left: false,
      right: false,
      bottom: insetBottom,
      child: MediaQuery.removeViewPadding(
        context: context,
        removeBottom: true,
        child: navigation,
      ),
    );
  }

  Widget _floatingAction(BuildContext context, Map<String, dynamic> c) {
    final appearance = _map(c['appearance']) ?? const <String, dynamic>{};
    final actionId =
        c['actionId']?.toString() ??
        _map(c['events'])?['tap']?['actionId']?.toString();

    return FloatingActionButton(
      backgroundColor:
          tokenColor(appearance['backgroundColorToken']?.toString()) ??
          tokenColor('colors.accent'),
      foregroundColor:
          tokenColor(appearance['foregroundColorToken']?.toString()) ??
          tokenColor('colors.textPrimary'),
      onPressed: actionId == null ? null : () => state.dispatchAction(actionId),
      child: FaIconAdapter(
        icon: icons.resolve(c['iconToken']?.toString()),
        size: 20,
      ),
    );
  }

  Widget _list(BuildContext context, Map<String, dynamic> c) {
    final items = state.resolve(c['itemsBinding']);
    if (items is! List || items.isEmpty) {
      final emptyId = c['emptyStateComponentId']?.toString();
      return emptyId == null
          ? const SizedBox.shrink()
          : buildComponent(context, emptyId);
    }

    final templateId = c['itemTemplateId']?.toString();
    if (templateId == null) {
      return Column(
        children: [
          for (final item in items)
            if (item is Map)
              ListTile(
                title: Text(
                  item['title']?.toString() ??
                      item['name']?.toString() ??
                      item['message']?.toString() ??
                      '',
                ),
                subtitle: item['subtitle'] == null
                    ? null
                    : Text(item['subtitle'].toString()),
              ),
        ],
      );
    }

    return Column(
      children: [
        for (final raw in items)
          if (raw is Map)
            buildComponent(
              context,
              templateId,
              item: Map<String, dynamic>.from(raw.cast<dynamic, dynamic>()),
            ),
      ],
    );
  }

  Widget _skeleton(BuildContext context, Map<String, dynamic> c) {
    return Column(
      children: List<Widget>.generate(
        5,
        (index) => Container(
          height: index == 0 ? 70 : 84,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: tokenColor('colors.surface'),
            borderRadius: BorderRadius.circular(
              _tokenNumber('radius.card') ?? 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context, Map<String, dynamic> c) {
    final actionId = c['primaryActionId']?.toString();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FaIconAdapter(
              icon: icons.resolve(c['iconToken']?.toString()),
              color: tokenColor('colors.textMuted'),
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(
              _textValue(c['title']),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: tokenColor('colors.textPrimary'),
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
            if (_textValue(c['subtitle']).isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _textValue(c['subtitle']),
                textAlign: TextAlign.center,
                style: TextStyle(color: tokenColor('colors.textSecondary')),
              ),
            ],
            if (actionId != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => state.dispatchAction(actionId),
                child: const Icon(Icons.add),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _errorState(BuildContext context, Map<String, dynamic> c) {
    final actionId = c['retryActionId']?.toString();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              color: tokenColor('colors.danger'),
              size: 38,
            ),
            const SizedBox(height: 12),
            Text(
              _textValue(c['title']),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: tokenColor('colors.textPrimary'),
                fontWeight: FontWeight.w800,
              ),
            ),
            if (actionId != null) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => state.dispatchAction(actionId),
                icon: const Icon(Icons.refresh),
                label: Text(state.i18n('errors.refreshFailed')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _faceSelector(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    dynamic faces = state.resolve(c['facesBinding'], item: item);

    if ((faces is! List || faces.isEmpty) && item != null) {
      final bound = item['faces'];
      if (bound is List) {
        faces = bound;
      }
    }

    if (faces is! List || faces.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: faces.length,
      itemBuilder: (context, index) {
        final face = faces[index];
        if (face is! Map) return const SizedBox.shrink();
        return ListTile(
          leading: FaIconAdapter(
            icon: icons.resolve(face['iconToken']?.toString()),
            size: 18,
          ),
          title: Text(_textValue(face['title'], item: item)),
          subtitle: Text(_textValue(face['subtitle'], item: item)),
        );
      },
    );
  }

  Widget _deviceControlPanel(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final deviceId = _textValue(c['deviceIdBinding'], item: item);
    final controls = state.readData('deviceDetails.controls');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (deviceId.isNotEmpty)
          Text(
            deviceId,
            style: TextStyle(
              color: tokenColor('colors.textMuted'),
              fontSize: 11,
            ),
          ),
        if (controls is List)
          for (final raw in controls)
            if (raw is Map)
              ListTile(
                title: Text(raw['name']?.toString() ?? ''),
                subtitle: raw['value'] == null
                    ? null
                    : Text(raw['value'].toString()),
              ),
      ],
    );
  }

  Widget _deviceDetailsHeader(
    BuildContext context,
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
  }) {
    final title = _textValue(c['titleBinding'], item: item);
    final online = state.resolve(c['statusBinding'], item: item) == true;

    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: tokenColor('colors.textPrimary'),
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: online
                ? tokenColor('colors.online')
                : tokenColor('colors.offline'),
          ),
        ),
      ],
    );
  }

  Widget _loginForm(BuildContext context, Map<String, dynamic> c) {
    final actionId = c['submitActionId']?.toString();
    if (c['emailBinding'] == null ||
        c['passwordBinding'] == null ||
        actionId == null ||
        actionId.isEmpty) {
      return _error(
        'Schema contract missing: components.${c['id']} loginForm requires '
        'emailBinding, passwordBinding and submitActionId.',
      );
    }

    return _SchemaLoginForm(state: state, component: c, renderer: this);
  }

  bool _visible(
    Map<String, dynamic> c, {
    Map<String, dynamic>? item,
    Map<String, dynamic>? event,
  }) {
    if (c['visible'] == false) return false;
    final expression = c['visibleWhen'];
    if (expression != null &&
        !state.evaluate(
          expression,
          item: item,
          event: event,
          parameters: state.parameters,
        )) {
      return false;
    }
    return true;
  }

  bool _enabled(dynamic expression, {Map<String, dynamic>? item}) {
    return expression == null ||
        state.evaluate(expression, item: item, parameters: state.parameters);
  }

  Widget _tapSurface(
    Map<String, dynamic> component,
    Widget child, {
    Map<String, dynamic>? item,
  }) {
    final events = _map(component['events']);
    final tap = events == null ? null : _map(events['tap']);
    final actionId = tap?['actionId']?.toString().trim();
    if (actionId == null || actionId.isEmpty) return child;

    return Semantics(
      button: true,
      child: InkWell(
        onTap: () => _event(component, 'tap', item: item),
        child: child,
      ),
    );
  }

  void _event(
    Map<String, dynamic> c,
    String eventName, {
    Map<String, dynamic>? item,
  }) {
    final events = _map(c['events']);
    final event = events == null ? null : _map(events[eventName]);
    final actionId = event?['actionId']?.toString();
    if (actionId == null) return;

    state.dispatchAction(
      actionId,
      item: item,
      event: <String, dynamic>{
        'componentId': item?['id'] ?? c['id'],
        'eventName': eventName,
      },
    );
  }

  String _boundText(Map<String, dynamic> c, String key) {
    final binding = c['${key}Binding'];
    if (binding != null) {
      final text = _textValue(binding).trim();
      if (text.isNotEmpty) return text;
    }
    return _textValue(c[key]).trim();
  }

  String _profileMenuSubtitle(Map<String, dynamic> entry) {
    final binding = _map(entry['subtitleBinding']);
    if (binding != null) {
      var text = _textValue(binding).trim();
      final transform = entry['subtitleTransform']?.toString();
      if (transform == 'capitalizeFirst' && text.isNotEmpty) {
        text = '${text[0].toUpperCase()}${text.substring(1)}';
      }
      final format = entry['subtitleFormat']?.toString();
      if (format != null && format.contains('{value}') && text.isNotEmpty) {
        text = format.replaceAll('{value}', text);
      }
      if (text.isNotEmpty) return text;
    }
    return _textValue(entry['subtitle']).trim();
  }

  Widget _profileChip(String value, Map<String, dynamic> appearance) {
    final accent = tokenColor(
          appearance['rowIconColorToken']?.toString(),
        ) ??
        tokenColor('colors.accent');
    final background = tokenColor('colors.surfaceElevated') ??
        accent?.withValues(alpha: 0.12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(
          _tokenNumber('radius.pill') ?? 999,
        ),
      ),
      child: Text(
        value,
        style: TextStyle(
          color: accent ?? tokenColor('colors.textSecondary'),
          fontSize: _d(appearance['metaFontSize']) ?? 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  String _textValue(dynamic raw, {Map<String, dynamic>? item}) {
    final resolved = state.resolve(
      raw,
      item: item,
      parameters: state.parameters,
    );
    return resolved?.toString() ?? '';
  }

  LinearGradient? _gradient(Map<String, dynamic>? background) {
    if (background == null ||
        background['type']?.toString() != 'linear-gradient') {
      return null;
    }

    final start = _color(background['startColor']);
    final end = _color(background['endColor']);
    if (start == null || end == null) return null;

    final direction = background['direction']?.toString();
    final (begin, finish) = switch (direction) {
      'left-to-right' => (Alignment.centerLeft, Alignment.centerRight),
      'right-to-left' => (Alignment.centerRight, Alignment.centerLeft),
      'top-to-bottom' => (Alignment.topCenter, Alignment.bottomCenter),
      'bottom-to-top' => (Alignment.bottomCenter, Alignment.topCenter),
      _ => (Alignment.topLeft, Alignment.bottomRight),
    };

    return LinearGradient(
      begin: begin,
      end: finish,
      colors: <Color>[start, end],
    );
  }

  LinearGradient? _gradientFromCss(String? raw) {
    final text = raw?.trim();
    if (text == null || !text.startsWith('linear-gradient(')) {
      return null;
    }

    final colors = RegExp(r'#[0-9a-fA-F]{6,8}')
        .allMatches(text)
        .map((m) => _color(m.group(0)))
        .whereType<Color>()
        .toList(growable: false);

    if (colors.length < 2) return null;

    final angleMatch = RegExp(r'(-?\d+(?:\.\d+)?)deg').firstMatch(text);
    final angle = double.tryParse(angleMatch?.group(1) ?? '');

    Alignment begin = Alignment.topLeft;
    Alignment end = Alignment.bottomRight;

    if (angle != null) {
      final radians = angle * math.pi / 180;
      final dx = math.sin(radians);
      final dy = -math.cos(radians);
      begin = Alignment(-dx, -dy);
      end = Alignment(dx, dy);
    }

    return LinearGradient(begin: begin, end: end, colors: colors);
  }

  dynamic _activeThemeTokenValue(String token) {
    final presetId =
        state.readState('global.themePreset')?.toString().trim() ??
        state.schema['themes']?['activePreset']?.toString().trim();

    if (presetId == null || presetId.isEmpty) return null;

    final presets = state.schema['themes']?['presets'];
    if (presets is! Map) return null;

    dynamic current = presets[presetId];
    if (current is! Map) return null;

    for (final part in token.split('.')) {
      if (current is! Map || !current.containsKey(part)) {
        return null;
      }
      current = current[part];
    }

    return current;
  }

  Color? tokenColor(String? token) {
    if (token == null || token.isEmpty) return null;
    return _color(_tokenValue(token));
  }

  double? _tokenNumber(String? token) {
    if (token == null || token.isEmpty) return null;
    return _d(_tokenValue(token));
  }

  TextStyle _typography(String token, {Color? fallbackColor}) {
    final current = _tokenValue(token);

    if (current is! Map) {
      return TextStyle(color: fallbackColor);
    }

    return TextStyle(
      color: fallbackColor,
      fontSize: _d(current['fontSize']),
      fontWeight: _fontWeight(current['fontWeight']),
      height: _d(current['lineHeight']),
    );
  }

  TextStyle _inlineTypography(
    Map<String, dynamic>? raw, {
    Color? fallbackColor,
  }) {
    final map = raw ?? const <String, dynamic>{};
    final color =
        _color(map['color']) ??
        tokenColor(map['colorToken']?.toString()) ??
        fallbackColor;
    return TextStyle(
      color: color,
      fontSize: _d(map['fontSize']),
      fontWeight: _fontWeight(map['fontWeight']),
      height: _d(map['lineHeight']),
      letterSpacing: _d(map['letterSpacing']),
    );
  }

  EdgeInsets _padding(dynamic raw) {
    if (raw is num) return EdgeInsets.all(raw.toDouble());
    if (raw is Map) {
      return EdgeInsets.fromLTRB(
        _d(raw['left']) ?? 0,
        _d(raw['top']) ?? 0,
        _d(raw['right']) ?? 0,
        _d(raw['bottom']) ?? 0,
      );
    }
    return EdgeInsets.zero;
  }

  EdgeInsets? _paddingOrNull(dynamic raw) {
    if (raw is num) return EdgeInsets.all(raw.toDouble());
    if (raw is Map) {
      final top = _d(raw['top']);
      final right = _d(raw['right']);
      final bottom = _d(raw['bottom']);
      final left = _d(raw['left']);
      if (top == null || right == null || bottom == null || left == null) {
        return null;
      }
      return EdgeInsets.fromLTRB(left, top, right, bottom);
    }
    return null;
  }

  List<BoxShadow>? _boxShadowFromToken(dynamic token) {
    final name = token?.toString().trim();
    if (name == null || name.isEmpty) return null;
    dynamic current = state.schema['designTokens'];
    for (final part in name.split('.')) {
      if (current is! Map) return null;
      current = current[part];
    }
    if (current is Map) {
      final css = current['css'];
      if (css != null) return _boxShadowList(css);
      final color = _color(current['color']);
      if (color == null) return null;
      return <BoxShadow>[
        BoxShadow(
          color: color,
          blurRadius: _d(current['blur']) ?? 0,
          spreadRadius: _d(current['spread']) ?? 0,
          offset: Offset(
            _d(current['offsetX']) ?? 0,
            _d(current['offsetY']) ?? 0,
          ),
        ),
      ];
    }
    return null;
  }

  List<BoxShadow>? _boxShadowList(dynamic raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty || text == 'none') return null;
    final colorMatch = RegExp(
      r'rgba?\([^)]*\)|#[0-9a-fA-F]{6,8}',
    ).firstMatch(text);
    final color = _color(colorMatch?.group(0));
    final numeric = RegExp(r'(-?\d+(?:\.\d+)?)px')
        .allMatches(text)
        .map((m) => double.tryParse(m.group(1) ?? ''))
        .whereType<double>()
        .toList(growable: false);
    if (color == null || numeric.length < 3) return null;
    final offsetX = numeric[0];
    final offsetY = numeric[1];
    final blur = numeric[2];
    final spread = numeric.length > 3 ? numeric[3] : 0.0;
    return <BoxShadow>[
      BoxShadow(
        color: color,
        offset: Offset(offsetX, offsetY),
        blurRadius: blur,
        spreadRadius: spread,
      ),
    ];
  }

  Color? _color(dynamic raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) return null;

    if (text.startsWith('#')) {
      var hex = text.substring(1);
      if (hex.length == 6) {
        hex = 'FF$hex';
      }
      if (hex.length != 8) return null;
      final parsed = int.tryParse(hex, radix: 16);
      return parsed == null ? null : Color(parsed);
    }

    final rgba = RegExp(
      r'^rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)'
      r'(?:\s*,\s*([0-9.]+))?\s*\)$',
      caseSensitive: false,
    ).firstMatch(text);

    if (rgba != null) {
      final r = double.tryParse(rgba.group(1) ?? '');
      final g = double.tryParse(rgba.group(2) ?? '');
      final b = double.tryParse(rgba.group(3) ?? '');
      final a = double.tryParse(rgba.group(4) ?? '1');

      if (r == null || g == null || b == null || a == null) {
        return null;
      }

      return Color.fromRGBO(
        r.round().clamp(0, 255).toInt(),
        g.round().clamp(0, 255).toInt(),
        b.round().clamp(0, 255).toInt(),
        a.clamp(0.0, 1.0).toDouble(),
      );
    }

    return null;
  }

  double? _d(dynamic raw) {
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw?.toString() ?? '');
  }

  FontWeight _fontWeight(dynamic raw) {
    final n = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
    if (n == null) return FontWeight.w400;
    if (n >= 800) return FontWeight.w800;
    if (n >= 700) return FontWeight.w700;
    if (n >= 600) return FontWeight.w600;
    if (n >= 500) return FontWeight.w500;
    return FontWeight.w400;
  }

  TextOverflow? _textOverflow(dynamic raw) {
    return switch (raw?.toString().trim()) {
      'ellipsis' => TextOverflow.ellipsis,
      'clip' => TextOverflow.clip,
      'fade' => TextOverflow.fade,
      'visible' => TextOverflow.visible,
      _ => null,
    };
  }

  BoxFit _fit(dynamic raw) {
    return switch (raw?.toString()) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      'fitWidth' => BoxFit.fitWidth,
      'fitHeight' => BoxFit.fitHeight,
      _ => BoxFit.contain,
    };
  }

  Alignment _alignment(dynamic raw) {
    return switch (raw?.toString().trim()) {
      'topCenter' || 'top center' => Alignment.topCenter,
      'bottomCenter' || 'bottom center' => Alignment.bottomCenter,
      'centerLeft' || 'center left' || 'left center' => Alignment.centerLeft,
      'centerRight' ||
      'center right' ||
      'right center' => Alignment.centerRight,
      _ => Alignment.center,
    };
  }

  Map<String, dynamic>? _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return null;
  }

  Widget _error(String message) {
    return SchemaIssueWidget(
      title: 'Schema issue',
      details: [message],
    );
  }
}

class _GridItem {
  const _GridItem({required this.component, this.item});

  final Map<String, dynamic> component;
  final Map<String, dynamic>? item;
}

class _Placement {
  const _Placement({
    required this.item,
    required this.row,
    required this.column,
    required this.rowSpan,
    required this.columnSpan,
  });

  final _GridItem item;
  final int row;
  final int column;
  final int rowSpan;
  final int columnSpan;
}

class _RotatingCard extends StatefulWidget {
  const _RotatingCard({
    required this.schema,
    required this.component,
    required this.faces,
    required this.buildFace,
    required this.onTap,
    required this.onLongPress,
    this.item,
    this.staggerIndex = 0,
    this.staggerCount = 1,
  });

  final Map<String, dynamic> schema;
  final Map<String, dynamic> component;
  final List faces;
  final Map<String, dynamic>? item;
  final int staggerIndex;
  final int staggerCount;
  final Widget Function(dynamic face, int index) buildFace;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_RotatingCard> createState() => _RotatingCardState();
}

class _RotatingCardState extends State<_RotatingCard>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _cycleController;
  bool _animationsAllowed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cycleController = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _RotatingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.faces.length != widget.faces.length ||
        oldWidget.component != widget.component ||
        oldWidget.schema != widget.schema) {
      _syncAnimation();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final pauseWhenInactive = _boolConfig(
      'pauseWhenAppInactive',
      fallback: true,
    );
    if (!pauseWhenInactive) return;

    if (state == AppLifecycleState.resumed) {
      _startRepeatingIfNeeded(preserveProgress: true);
    } else {
      _cycleController.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cycleController.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    final reducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    final appPreference =
        widget.schema['state']?['preferences']?['animationsEnabled'] != false;
    final config = _animationConfig();

    _animationsAllowed =
        !reducedMotion &&
        appPreference &&
        config['enabled'] != false &&
        widget.faces.length > 1 &&
        _cycleDurationMs() > 0;

    if (!_animationsAllowed) {
      _cycleController.stop(canceled: false);
      if (_cycleController.value != 0) {
        _cycleController.value = 0;
      }
      return;
    }

    _startRepeatingIfNeeded(preserveProgress: true);
  }

  void _startRepeatingIfNeeded({required bool preserveProgress}) {
    if (!_animationsAllowed || widget.faces.length <= 1) return;

    final durationMs = _cycleDurationMs();
    if (durationMs <= 0) return;

    final current = preserveProgress ? _cycleController.value : 0.0;
    _cycleController
      ..stop(canceled: false)
      ..duration = Duration(milliseconds: durationMs)
      ..value = current.clamp(0.0, 1.0);

    _cycleController.repeat(period: Duration(milliseconds: durationMs));
  }

  int _resolvedDefaultIndex() {
    final raw = widget.component['defaultFaceIndex'];
    dynamic value = raw;

    if (raw is Map) {
      final bindingPath = raw[r'$item']?.toString();
      final currentItem = widget.item;
      if (bindingPath != null &&
          bindingPath.isNotEmpty &&
          currentItem != null &&
          currentItem.containsKey(bindingPath)) {
        value = currentItem[bindingPath];
      } else {
        value = raw['fallback'];
      }
    }

    final index = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;

    if (widget.faces.isEmpty) return 0;
    return index.clamp(0, widget.faces.length - 1);
  }

  Map<String, dynamic> _animationConfig() {
    final componentRotation = widget.component['rotation'];
    final rotation = componentRotation is Map
        ? Map<String, dynamic>.from(componentRotation.cast<dynamic, dynamic>())
        : <String, dynamic>{};

    String? presetId = rotation['presetId']?.toString();

    Map<String, dynamic> presetRotation = const <String, dynamic>{};
    if (widget.component['presetId'] != null) {
      final componentPreset =
          widget.schema['componentPresets']?[widget.component['presetId']];
      if (componentPreset is Map && componentPreset['rotation'] is Map) {
        presetRotation = Map<String, dynamic>.from(
          (componentPreset['rotation'] as Map).cast<dynamic, dynamic>(),
        );
        if (presetId == null || presetId.isEmpty) {
          presetId = presetRotation['presetId']?.toString();
        }
      }
    }

    dynamic rawPreset;
    if (presetId != null && presetId.isNotEmpty) {
      rawPreset =
          widget.schema['motionPolicy']?['animationPresets']?[presetId] ??
          widget.schema['animationPresets']?[presetId];
    }
    final preset = rawPreset is Map
        ? Map<String, dynamic>.from(rawPreset.cast<dynamic, dynamic>())
        : <String, dynamic>{};

    return <String, dynamic>{...preset, ...presetRotation, ...rotation};
  }

  Map<String, dynamic> _geometryConfig() {
    final config = _animationConfig();
    final configGeometry = config['geometry'];
    if (configGeometry is Map) {
      return Map<String, dynamic>.from(configGeometry.cast<dynamic, dynamic>());
    }

    final dimensions = widget.component['dimensions'];
    if (dimensions is Map) {
      return Map<String, dynamic>.from(dimensions.cast<dynamic, dynamic>());
    }

    final renderGeometry = widget.schema['uiRenderContract']?['cubeGeometry'];
    if (renderGeometry is Map) {
      return Map<String, dynamic>.from(renderGeometry.cast<dynamic, dynamic>());
    }

    return const <String, dynamic>{};
  }

  Map<String, dynamic> _nestedAnimationConfig() {
    final raw = _animationConfig()['animation'];
    return raw is Map
        ? Map<String, dynamic>.from(raw.cast<dynamic, dynamic>())
        : const <String, dynamic>{};
  }

  int _cycleDurationMs() {
    final config = _animationConfig();
    final nested = _nestedAnimationConfig();
    final timing = widget.component['timing'];

    final candidates = <dynamic>[
      config['durationMs'],
      nested['durationMs'],
      timing is Map ? timing['cycleDurationMs'] : null,
      widget.schema['designTokens']?['animation']?['cardRotationDurationMs'],
      widget.schema['uiRenderContract']?['cubeAnimation']?['durationMs'],
    ];

    for (final raw in candidates) {
      final value = raw is num
          ? raw.toInt()
          : int.tryParse(raw?.toString() ?? '');
      if (value != null && value > 0) return value;
    }
    return 0;
  }

  double _phaseOffsetFraction() {
    final durationMs = _cycleDurationMs();
    if (durationMs <= 0) return 0;
    final durationSec = durationMs / 1000.0;

    final rotation = widget.component['rotation'];
    final rotMap = rotation is Map
        ? Map<String, dynamic>.from(rotation.cast<dynamic, dynamic>())
        : <String, dynamic>{};
    final config = _animationConfig();
    final nested = _nestedAnimationConfig();
    final semantics =
        (rotMap['phaseOffsetSemantics'] ??
                config['phaseOffsetSemantics'] ??
                nested['phaseOffsetSemantics'])
            ?.toString();

    double? fromSeconds(dynamic msRaw, dynamic secRaw) {
      final ms = msRaw is num
          ? msRaw.toDouble()
          : double.tryParse(msRaw?.toString() ?? '');
      final sec = secRaw is num
          ? secRaw.toDouble()
          : double.tryParse(secRaw?.toString() ?? '');
      final seconds = sec ?? ((ms == null) ? null : ms / 1000.0);
      if (seconds == null || seconds == 0) return null;
      var phase = (-seconds) / durationSec;
      phase %= 1;
      if (phase < 0) phase += 1;
      return phase;
    }

    if (semantics == 'css-animation-delay-stagger') {
      final delayed = fromSeconds(
        rotMap['phaseOffsetMs'],
        rotMap['phaseOffsetSec'],
      );
      if (delayed != null) return delayed;
    }

    dynamic raw = rotMap['phaseOffset'];
    if (raw is Map) {
      final itemPath = raw[r'$item']?.toString();
      if (itemPath != null &&
          itemPath.isNotEmpty &&
          widget.item != null &&
          widget.item!.containsKey(itemPath)) {
        raw = widget.item![itemPath];
      } else {
        raw = raw['fallback'];
      }
    }

    final normalized = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '');
    if (normalized != null && normalized > 0 && normalized < 1) {
      return normalized;
    }

    if (semantics != 'css-animation-delay-stagger') {
      final delayed = fromSeconds(
        rotMap['phaseOffsetMs'] ?? config['phaseOffsetMs'],
        rotMap['phaseOffsetSec'] ?? config['phaseOffsetSec'],
      );
      if (delayed != null) return delayed;
    }

    final stagger = nested['stagger'] ?? config['stagger'];
    final staggerEnabled = stagger is! Map || stagger['enabled'] != false;
    final staggerSource = stagger is Map
        ? stagger['source']?.toString()
        : null;
    final useHashStagger =
        staggerEnabled &&
        (staggerSource == 'card-index-hash-offset' ||
            staggerSource == null ||
            staggerSource.isEmpty) &&
        _isFourFaceBox();

    if (useHashStagger) {
      final delay = computeCubeAnimOffsetSeconds(
        id: widget.component['id']?.toString() ?? '',
        index: widget.staggerIndex,
        totalCount: widget.staggerCount,
        speedSec: durationSec,
        faceCount: widget.faces.isEmpty ? 4 : widget.faces.length,
      );
      var phase = (-delay) / durationSec;
      phase %= 1;
      if (phase < 0) phase += 1;
      return phase;
    }

    return 0;
  }

  double _geometryDegreesPerFace() {
    final geometry = _geometryConfig();
    final raw = geometry['degreesPerFace'];
    final degrees = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '');
    return degrees == null || degrees == 0 ? 90 : degrees.abs();
  }

  /// Signed amount the whole cube advances for one face.
  ///
  /// The web contract carries the real direction in
  /// rotation.animation.degreesPerFace (for example -90 for RTL and +90 for
  /// LTR). Prefer that exact schema value instead of reconstructing the sign
  /// from textual aliases such as rotationDir/direction.
  double _animationDegreesPerFace() {
    final nested = _nestedAnimationConfig();
    final config = _animationConfig();
    final rotation = widget.component['rotation'];

    final raw =
        nested['degreesPerFace'] ??
        config['degreesPerFace'] ??
        (rotation is Map ? rotation['degreesPerFace'] : null);

    final degrees = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '');

    if (degrees != null && degrees != 0) return degrees;

    // Backward-compatible fallback for older schemas which only declared
    // direction/rotationDir.
    return -_rotationSign() * _geometryDegreesPerFace();
  }

  String _axis() {
    final geometry = _geometryConfig();
    final config = _animationConfig();
    return (geometry['axis'] ?? config['axis'] ?? 'y')
        .toString()
        .trim()
        .toLowerCase();
  }

  double _perspectiveEntry() {
    final geometry = _geometryConfig();
    final cubeGeometry = widget.schema['uiRenderContract']?['cubeGeometry'];
    final raw =
        geometry['perspectivePx'] ??
        geometry['perspectiveDp'] ??
        (geometry['perspective'] is num ? geometry['perspective'] : null) ??
        widget.component['dimensions']?['perspectivePx'] ??
        widget.component['dimensions']?['perspectiveDp'] ??
        widget.schema['designTokens']?['animation']?['perspectiveDp'] ??
        (cubeGeometry is Map ? cubeGeometry['perspectivePx'] : null) ??
        (cubeGeometry is Map ? cubeGeometry['perspectiveDp'] : null);
    final perspective = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '');
    if (perspective == null || perspective <= 0) return 0;
    return 1 / perspective;
  }

  bool _isFourFaceBox() {
    final geometry = _geometryConfig();
    final config = _animationConfig();
    final model =
        '${geometry['model'] ?? ''} ${geometry['rendererKey'] ?? ''} '
        '${config['model'] ?? ''} ${config['rendererKey'] ?? ''}';
    final style = geometry['transformStyle']?.toString().trim().toLowerCase();
    if (style == 'flat') return false;
    if (model.toLowerCase().contains('fourface')) return true;
    if (style == 'preserve-3d') return true;
    final centering = geometry['parentCenteringTransform']?.toString().trim();
    return centering != null && centering.isNotEmpty && centering != 'none';
  }

  double _parentCenteringDepth(double halfDepth) {
    if (halfDepth == 0) return 0;
    final geometry = _geometryConfig();
    final raw = geometry['parentCenteringTransform']?.toString() ?? '';
    final compact = raw.replaceAll(' ', '').toLowerCase();
    if (compact == 'none' || compact == 'identity') return 0;
    if (compact.contains('-half') || compact.contains('translatez(-')) {
      return -halfDepth.abs();
    }
    if (compact.isEmpty) {
      return _isFourFaceBox() ? -halfDepth.abs() : 0;
    }
    return 0;
  }

  double _faceBaseDegrees(int faceIndex) {
    final placements = _geometryConfig()['facePlacement'];
    if (placements is List) {
      for (final raw in placements) {
        if (raw is! Map) continue;
        final index = raw['faceIndex'];
        final parsed = index is num
            ? index.toInt()
            : int.tryParse(index?.toString() ?? '');
        if (parsed != faceIndex) continue;
        final deg = raw['rotateYDeg'] ?? raw['rotateXDeg'];
        final value = deg is num
            ? deg.toDouble()
            : double.tryParse(deg?.toString() ?? '');
        if (value != null) return value;
      }
    }
    return faceIndex * _geometryDegreesPerFace();
  }

  double _depthForWidth(double width) {
    final geometry = _geometryConfig();
    final dimensions = widget.component['dimensions'];
    final raw =
        geometry['halfDepthFormula'] ??
        (dimensions is Map ? dimensions['halfDepthFormula'] : null) ??
        geometry['depthFormula'] ??
        (dimensions is Map ? dimensions['cubeDepthFormula'] : null) ??
        widget.schema['designTokens']?['animation']?['cubeDepthFormula'];

    if (raw is num) {
      final value = raw.toDouble().abs();
      if (geometry['halfDepthFormula'] == null &&
          geometry['depthFormula'] != null) {
        return value / 2;
      }
      return value;
    }

    final formula = raw?.toString().trim();
    if (formula == null || formula.isEmpty) {
      return _isFourFaceBox() ? width / 2 : 0;
    }

    final compact = formula.replaceAll(' ', '');
    if (RegExp(
      r'^(?:slotWidth|cellWidth|cardWidth|width)$',
      caseSensitive: false,
    ).hasMatch(compact)) {
      return width / 2;
    }

    final match = RegExp(
      r'^(?:slotWidth|cellWidth|cardWidth|width)([/*])([0-9]+(?:\.[0-9]+)?)$',
      caseSensitive: false,
    ).firstMatch(compact);
    if (match == null) {
      return _isFourFaceBox() ? width / 2 : 0;
    }

    final operand = double.tryParse(match.group(2) ?? '');
    if (operand == null || operand == 0) {
      return _isFourFaceBox() ? width / 2 : 0;
    }
    return match.group(1) == '*' ? width * operand : width / operand;
  }

  double _rotationSign() {
    final rotation = widget.component['rotation'];
    final config = _animationConfig();
    final explicit =
        (rotation is Map
            ? rotation['rotationDir'] ?? rotation['rotationDirection']
            : null) ??
        config['rotationDir'] ??
        config['rotationDirection'];
    final value = explicit?.toString().trim().toLowerCase();

    if (value == 'ltr' ||
        value == 'left-to-right' ||
        value == 'counter-clockwise' ||
        value == 'counterclockwise') {
      return -1;
    }
    if (value == 'rtl' || value == 'right-to-left' || value == 'clockwise') {
      return 1;
    }

    final geometryDirection = _geometryConfig()['direction']
        ?.toString()
        .trim()
        .toLowerCase();
    return geometryDirection == 'counter-clockwise' ||
            geometryDirection == 'counterclockwise'
        ? -1
        : 1;
  }

  Curve _transitionCurve() {
    final config = _animationConfig();
    final nested = _nestedAnimationConfig();
    final easingRaw = nested['easing'];
    final easing = easingRaw is Map ? easingRaw : null;
    final raw =
        config['curve']?.toString() ??
        easing?['name']?.toString() ??
        nested['curve']?.toString();

    return switch (raw?.trim().toLowerCase()) {
      'linear' => Curves.linear,
      'ease' => Curves.ease,
      'ease-in' || 'easein' => Curves.easeIn,
      'ease-out' || 'easeout' => Curves.easeOut,
      'ease-in-out' || 'easeinout' => Curves.easeInOut,
      'ease-in-cubic' || 'easeincubic' => Curves.easeInCubic,
      'ease-out-cubic' || 'easeoutcubic' => Curves.easeOutCubic,
      'ease-in-out-cubic' || 'easeinoutcubic' => Curves.easeInOutCubic,
      _ => Curves.easeInOutCubic,
    };
  }

  double _holdRatio() {
    final config = _animationConfig();
    final nested = _nestedAnimationConfig();
    final cycleMs = _cycleDurationMs();
    final faceCount = widget.faces.isEmpty ? 1 : widget.faces.length;
    final faceDuration = cycleMs > 0 ? cycleMs / faceCount : 0.0;

    final holdMsRaw =
        config['dwellMs'] ??
        config['holdMs'] ??
        nested['dwellMs'] ??
        nested['holdMs'];
    final holdMs = holdMsRaw is num
        ? holdMsRaw.toDouble()
        : double.tryParse(holdMsRaw?.toString() ?? '');
    if (holdMs != null && faceDuration > 0) {
      return (holdMs / faceDuration).clamp(0.0, 1.0);
    }

    final cubeGeometry = widget.schema['uiRenderContract']?['cubeGeometry'];
    final contractRatio = cubeGeometry is Map
        ? cubeGeometry['holdRatio'] ?? cubeGeometry['dwellRatio']
        : null;
    final ratioRaw =
        config['dwellRatio'] ??
        config['holdRatio'] ??
        nested['dwellRatio'] ??
        nested['holdRatio'] ??
        contractRatio;
    final ratio = ratioRaw is num
        ? ratioRaw.toDouble()
        : double.tryParse(ratioRaw?.toString() ?? '');
    return (ratio ?? 0.78).clamp(0.0, 1.0);
  }

  bool _boolConfig(String key, {required bool fallback}) {
    final config = _animationConfig();
    final nested = _nestedAnimationConfig();
    final raw = config[key] ?? nested[key];
    return raw is bool ? raw : fallback;
  }

  bool _hideBackFaces() {
    return _geometryConfig()['backfaceVisibility']
            ?.toString()
            .trim()
            .toLowerCase() !=
        'visible';
  }

  Matrix4 _cubeFaceTransform({
    required double parentAngle,
    required double faceAngle,
    required double depth,
    required String axis,
    required double perspective,
  }) {
    final matrix = Matrix4.identity();
    if (perspective > 0) matrix.setEntry(3, 2, perspective);

    // Web parent transform is translateZ(-halfDepth) rotateY(angle). Without
    // the centering translate the box orbits around the front face instead of
    // spinning in the slot.
    final centering = _parentCenteringDepth(depth);
    if (centering != 0) {
      matrix.translateByDouble(0.0, 0.0, centering, 1.0);
    }

    final angle = parentAngle + faceAngle;
    if (axis == 'x') {
      matrix
        ..rotateX(angle)
        ..translateByDouble(0.0, 0.0, depth, 1.0);
    } else {
      matrix
        ..rotateY(angle)
        ..translateByDouble(0.0, 0.0, depth, 1.0);
    }
    return matrix;
  }

  bool _faceVisible(double angle) {
    if (!_hideBackFaces()) return true;
    return math.cos(angle) > 0.0001;
  }

  double _webDelaySeconds() {
    final durationMs = _cycleDurationMs();
    if (durationMs <= 0) return 0;
    final durationSec = durationMs / 1000.0;
    final phase = _phaseOffsetFraction();
    return -phase * durationSec;
  }

  _CubeProgress _progressFor(double cycle) {
    final faceCount = widget.faces.isEmpty ? 1 : widget.faces.length;
    final scaled = (cycle % 1.0) * faceCount;
    final segment = scaled.floor().clamp(0, faceCount - 1);
    final segmentProgress = scaled - scaled.floor();
    final hold = _holdRatio();

    double flipProgress = 0;
    if (hold < 1 && segmentProgress > hold) {
      flipProgress = ((segmentProgress - hold) / (1 - hold)).clamp(0.0, 1.0);
    }
    final easedFlip = _transitionCurve().transform(flipProgress);
    return _CubeProgress(
      segmentIndex: segment,
      easedFlip: easedFlip,
      rawFlip: flipProgress,
    );
  }

  Widget _buildCube(BuildContext context, double controllerValue) {
    if (widget.faces.isEmpty) return const SizedBox.shrink();

    final defaultIndex = _resolvedDefaultIndex();
    final durationMs = _cycleDurationMs();
    final cycle = _animationsAllowed && durationMs > 0
        ? cubeElapsedCycle(
            speedSec: durationMs / 1000.0,
            delaySec: _webDelaySeconds(),
          )
        : 0.0;
    final progress = _animationsAllowed
        ? _progressFor(cycle)
        : _CubeProgress(segmentIndex: defaultIndex, easedFlip: 0, rawFlip: 0);

    final animationRadiansPerFace = _animationDegreesPerFace() * math.pi / 180;

    // Web dwell-then-rotateY: parent angle lerps for the whole turn. The
    // interactive/current face stays on the dwelling segment until the turn
    // completes. There is no mid-turn content swap.
    final parentAngle =
        (progress.segmentIndex + progress.easedFlip) * animationRadiansPerFace;
    final currentIndex = progress.segmentIndex;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : width;
        if (width <= 0 || height <= 0) {
          return widget.buildFace(widget.faces[currentIndex], currentIndex);
        }

        final depth = _depthForWidth(width);
        final perspective = _perspectiveEntry();
        final axis = _axis();

        Widget cube = RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              for (
                var faceIndex = 0;
                faceIndex < widget.faces.length;
                faceIndex++
              )
                Builder(
                  builder: (context) {
                    final baseAngle =
                        _faceBaseDegrees(faceIndex) * math.pi / 180;
                    final effectiveAngle = parentAngle + baseAngle;
                    final visible = _faceVisible(effectiveAngle);

                    return IgnorePointer(
                      ignoring: faceIndex != currentIndex,
                      child: Visibility(
                        visible: visible,
                        maintainState: true,
                        maintainAnimation: true,
                        maintainSize: true,
                        child: Transform(
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.low,
                          transform: _cubeFaceTransform(
                            parentAngle: parentAngle,
                            faceAngle: baseAngle,
                            depth: depth,
                            axis: axis,
                            perspective: perspective,
                          ),
                          child: SizedBox.expand(
                            child: widget.buildFace(
                              widget.faces[faceIndex],
                              faceIndex,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );

        final appearance = widget.component['appearance'];
        double? radius;
        if (appearance is Map) {
          final raw =
              appearance['borderRadius'] ?? appearance['cardBorderRadius'];
          radius = raw is num
              ? raw.toDouble()
              : double.tryParse(raw?.toString() ?? '');
        }
        if (radius == null || radius <= 0) {
          final tokens = widget.schema['designTokens'];
          if (tokens is Map) {
            final tokenRadius = tokens['radius'] is Map
                ? tokens['radius']['card']
                : null;
            radius = tokenRadius is num
                ? tokenRadius.toDouble()
                : double.tryParse(tokenRadius?.toString() ?? '');
          }
        }

        // Web `.ahp-card { overflow:hidden; border-radius }` clips the
        // projected cube to the metro tile. Side faces remain visible
        // inside that rounded rect during the turn.
        if (radius != null && radius > 0) {
          cube = ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: cube,
          );
        } else {
          cube = ClipRect(clipBehavior: Clip.antiAlias, child: cube);
        }
        return cube;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.faces.isEmpty) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _cycleController,
      builder: (context, _) => _buildCube(context, _cycleController.value),
    );
  }
}

class _CubeProgress {
  const _CubeProgress({
    required this.segmentIndex,
    required this.easedFlip,
    required this.rawFlip,
  });

  final int segmentIndex;
  final double easedFlip;
  final double rawFlip;
}

class _SchemaLoginForm extends StatefulWidget {
  const _SchemaLoginForm({
    required this.state,
    required this.component,
    required this.renderer,
  });

  final HomeSduiState state;
  final Map<String, dynamic> component;
  final HomeSduiRenderer renderer;

  @override
  State<_SchemaLoginForm> createState() => _SchemaLoginFormState();
}

class _SchemaLoginFormState extends State<_SchemaLoginForm> {
  late final TextEditingController _email;
  late final TextEditingController _password;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();

    final emailBinding = widget.component['emailBinding'];
    final passwordBinding = widget.component['passwordBinding'];

    _email = TextEditingController(
      text: widget.state.resolve(emailBinding)?.toString() ?? '',
    );
    _password = TextEditingController(
      text: widget.state.resolve(passwordBinding)?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String _labelFromBinding(dynamic binding) {
    if (binding is! Map) return '';
    final path =
        binding[r'$state']?.toString() ??
        binding[r'$secureState']?.toString() ??
        '';
    if (path.isEmpty) return '';
    final last = path.split('.').last;
    if (last.isEmpty) return '';
    return '${last[0].toUpperCase()}${last.substring(1)}';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.renderer._textValue(widget.component['title']);
    final subtitle = widget.renderer._textValue(widget.component['subtitle']);

    final verticalGap = widget.renderer._tokenNumber('spacing.md') ?? 0;
    final smallGap = widget.renderer._tokenNumber('spacing.xs') ?? 0;

    final emailBinding = widget.component['emailBinding'];
    final passwordBinding = widget.component['passwordBinding'];

    final emailLabel = widget.component['emailLabel'] == null
        ? _labelFromBinding(emailBinding)
        : widget.renderer._textValue(widget.component['emailLabel']);

    final passwordLabel = widget.component['passwordLabel'] == null
        ? _labelFromBinding(passwordBinding)
        : widget.renderer._textValue(widget.component['passwordLabel']);

    final submitLabel = widget.component['submitLabel'] == null
        ? title
        : widget.renderer._textValue(widget.component['submitLabel']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            style: widget.renderer._typography(
              'typography.pageTitle',
              fallbackColor: widget.renderer.tokenColor('colors.textPrimary'),
            ),
          ),
        if (subtitle.isNotEmpty) ...[
          SizedBox(height: smallGap),
          Text(
            subtitle,
            style: widget.renderer._typography(
              'typography.pageSubtitle',
              fallbackColor: widget.renderer.tokenColor('colors.textSecondary'),
            ),
          ),
        ],
        SizedBox(height: verticalGap),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          onChanged: (value) {
            if (emailBinding is Map && emailBinding[r'$state'] != null) {
              widget.state.writeState(
                emailBinding[r'$state'].toString(),
                value,
              );
            }
          },
          decoration: InputDecoration(
            labelText: emailLabel.isEmpty ? null : emailLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        SizedBox(height: verticalGap),
        TextField(
          controller: _password,
          obscureText: _obscure,
          onChanged: (value) {
            if (passwordBinding is Map &&
                passwordBinding[r'$secureState'] != null) {
              widget.state.writeSecureState(
                passwordBinding[r'$secureState'].toString(),
                value,
              );
            }
          },
          decoration: InputDecoration(
            labelText: passwordLabel.isEmpty ? null : passwordLabel,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
        ),
        SizedBox(height: verticalGap),
        FilledButton(
          onPressed: () {
            final actionId = widget.component['submitActionId']?.toString();
            if (actionId != null && actionId.isNotEmpty) {
              widget.state.dispatchAction(actionId);
            }
          },
          child: Text(submitLabel),
        ),
      ],
    );
  }
}

/// Keeps the renderer independent from the Font Awesome widget API.
class FaIconAdapter extends StatelessWidget {
  const FaIconAdapter({super.key, required this.icon, this.color, this.size});

  final FaIconData icon;
  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) {
    return FaIcon(icon, color: color, size: size);
  }
}
