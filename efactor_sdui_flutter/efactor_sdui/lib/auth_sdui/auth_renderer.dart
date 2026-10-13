import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth_icon.dart';
import 'auth_schema_issue.dart';
import 'auth_state.dart';
import '../sdui/schema_pull_to_refresh.dart';
import '../sdui/schema_runtime.dart';
import '../sdui/sdui_network_image_cache.dart';

class AuthRenderer {
  AuthRenderer(this.state, {this.onPullRefresh});

  final AuthState state;
  final Future<void> Function()? onPullRefresh;

  Map<String, dynamic> get schema => state.schema;

  AuthIconResolver get _icons => AuthIconResolver(schema);

  Map<String, dynamic>? _page;
  bool _keyboardVisible = false;

  Widget build(BuildContext context) {
    _keyboardVisible =
        (MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0) > 0 ||
        (View.of(context).viewInsets.bottom > 0);
    final rawPage = state.page(state.pageId);

    if (rawPage == null) {
      return const AuthSchemaIssue(
        title: 'Invalid auth page',
        details: ['Current page is missing from pages[].'],
      );
    }

    final page = _resolvePageResponsiveMap(context, rawPage);
    _page = page;

    final components = page['components'];

    if (components is! List) {
      return const AuthSchemaIssue(
        title: 'Invalid auth page',
        details: ['page.components[] is required.'],
      );
    }

    Widget body;

    // pageLayout is the explicit native layout contract. Some generated Auth
    // pages also retain a legacy/simple `layout` map for compatibility; when
    // both exist, prefer the declared auth-phone-preview engine instead of
    // silently bypassing its responsive phone/tablet rules.
    if (page['pageLayout'] is Map) {
      body = _phonePreview(
        context,
        page,
        _resolveResponsiveMap(
          context,
          Map<String, dynamic>.from(
            (page['pageLayout'] as Map).cast<dynamic, dynamic>(),
          ),
        ),
        components,
      );
    } else if (page['layout'] is Map) {
      body = _simpleLayout(
        context,
        page,
        _resolveResponsiveMap(
          context,
          Map<String, dynamic>.from(
            (page['layout'] as Map).cast<dynamic, dynamic>(),
          ),
        ),
        components,
      );
    } else {
      return const AuthSchemaIssue(
        title: 'Auth layout missing',
        details: [
          'page.layout or page.pageLayout '
              'is required.',
        ],
      );
    }

    final background = _map(page['background']);

    if (background != null) {
      body = Stack(
        fit: StackFit.expand,
        children: [_background(context, background), body],
      );
    }

    final color =
        _color(page['backgroundColor']) ??
        _color(schema['theme']?['colors']?['background']) ??
        Colors.transparent;

    final safe =
        page['safeArea'] == true ||
        (page['safeArea'] == null && schema['app']?['safeArea'] == true);

    Widget pageBody = safe ? SafeArea(child: body) : body;
    final pullRefresh = onPullRefresh;
    if (pullRefresh != null) {
      pageBody = SchemaPullToRefresh(
        onRefresh: pullRefresh,
        fillViewport: true,
        child: pageBody,
      );
    }
    final feedback = _feedbackOverlay(context);

    return Scaffold(
      backgroundColor: color,
      resizeToAvoidBottomInset:
          page['keyboardAvoidance'] == true ||
          schema['app']?['keyboardAvoidance'] == true,
      body: Stack(
        fit: StackFit.expand,
        children: [pageBody, if (feedback != null) feedback],
      ),
    );
  }

  Widget? _feedbackOverlay(BuildContext context) {
    final error = state.authError.trim();
    final notice = state.authNotice.trim();

    final isError = error.isNotEmpty || state.fieldErrors.isNotEmpty;
    String message;

    if (isError) {
      // Validation actions also set a generic auth.error. Prefer the concrete
      // field message so a tap on Login/Create account immediately tells the
      // user what is missing. Server/API errors still use auth.error.
      final fieldMessage = state.fieldErrors.values.isEmpty
          ? null
          : state.fieldErrors.values.first.trim();
      message = (fieldMessage != null && fieldMessage.isNotEmpty)
          ? fieldMessage
          : error;
    } else {
      message = notice;
    }

    if (message.isEmpty) {
      return null;
    }

    final media = MediaQuery.of(context);
    final top = media.padding.top + 72;
    final scheme = Theme.of(context).colorScheme;
    final background = isError
        ? scheme.errorContainer
        : scheme.primaryContainer;
    final foreground = isError
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;
    final border = isError
        ? scheme.error.withValues(alpha: 0.45)
        : scheme.primary.withValues(alpha: 0.35);

    return Positioned(
      top: top,
      left: 18,
      right: 18,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Container(
              key: ValueKey<String>('${isError ? 'error' : 'notice'}:$message'),
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: border),
                boxShadow: [
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: 0.15),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isError ? Icons.error_outline : Icons.check_circle_outline,
                    size: 18,
                    color: foreground,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      message,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _simpleLayout(
    BuildContext context,
    Map<String, dynamic> page,
    Map<String, dynamic> layout,
    List components,
  ) {
    final type = layout['type']?.toString();

    if (type != 'stack') {
      return const AuthSchemaIssue(
        title: 'Unsupported simple auth layout',
        details: ['Only stack is used by schema v7 welcome.'],
      );
    }

    final padding = _insets(layout['padding']) ?? EdgeInsets.zero;

    return Padding(
      padding: padding,
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final raw in components)
            if (raw is Map)
              _position(
                context,
                Map<String, dynamic>.from(raw.cast<dynamic, dynamic>()),
              ),
        ],
      ),
    );
  }

  Widget _phonePreview(
    BuildContext context,
    Map<String, dynamic> page,
    Map<String, dynamic> pageLayout,
    List components,
  ) {
    if (pageLayout['layoutEngine'] != 'auth-phone-preview') {
      return AuthSchemaIssue(
        title: 'Unsupported auth layoutEngine',
        details: ['${pageLayout['layoutEngine']}'],
      );
    }

    final desktop = _map(pageLayout['desktopViewport']);
    final mobile = _map(pageLayout['mobileViewport']);

    if (desktop == null || mobile == null) {
      return const AuthSchemaIssue(
        title: 'Invalid auth phone preview',
        details: ['desktopViewport and mobileViewport are required.'],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = DeviceScreenMetrics.fromContext(context);
        final runtime = SchemaRuntime(schema);
        final logicalWidth = runtime.useSafeArea == true
            ? metrics.safeWidth
            : metrics.logicalWidth;
        final logicalHeight = runtime.useSafeArea == true
            ? metrics.safeHeight
            : metrics.logicalHeight;
        final breakpointName = runtime.resolveBreakpointName(
          logicalWidth,
          logicalHeight: logicalHeight,
          orientation: metrics.orientation,
        );
        final legacyBreakpoint = _n(mobile['breakpointMaxWidth']) ?? 430;
        final isMobile = breakpointName == null
            ? constraints.maxWidth <= legacyBreakpoint
            : breakpointName == 'narrow' || breakpointName == 'compact';

        final viewport = isMobile ? mobile : desktop;

        final pageSpec = _map(viewport['page']) ?? const <String, dynamic>{};

        final phoneSpec = _map(viewport['phone']) ?? const <String, dynamic>{};

        final screenSpec =
            _map(viewport['screen']) ?? const <String, dynamic>{};

        final basePagePadding = _length(context, pageSpec['padding']) ?? 0;
        final responsiveInsets = _responsiveContentInsets(
          pageLayout['contentPadding'],
        );

        // The mobileViewport contract explicitly owns the full-bleed phone
        // frame (width=100%, padding=0). Do not reinterpret breakpoint
        // contentPadding as an extra outer inset on narrow/compact phones;
        // responsive panel/component padding is handled by the page itself.
        final pageInsets = isMobile
            ? EdgeInsets.all(basePagePadding)
            : (responsiveInsets ?? EdgeInsets.all(basePagePadding));

        final phonePadding = _length(context, phoneSpec['padding']) ?? 0;

        final phoneRadius = _length(context, phoneSpec['borderRadius']) ?? 0;

        final screenRadius = _length(context, screenSpec['borderRadius']) ?? 0;

        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;

        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;

        final contentHeight = (availableHeight - pageInsets.vertical).clamp(
          0.0,
          double.infinity,
        );

        final contentWidth = (availableWidth - pageInsets.horizontal).clamp(
          0.0,
          double.infinity,
        );

        Widget screen = SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              for (final raw in components)
                if (raw is Map)
                  _position(
                    context,
                    _resolveResponsiveMap(
                      context,
                      Map<String, dynamic>.from(raw.cast<dynamic, dynamic>()),
                    ),
                  ),
            ],
          ),
        );

        screen = ClipRRect(
          borderRadius: BorderRadius.circular(screenRadius),
          child: screen,
        );

        final pageScrollable =
            page['scrollable'] == true ||
            page['verticalOverflow']?.toString().trim().toLowerCase() ==
                'scroll';
        final hasGlassPanel = components.any(
          (raw) => raw is Map && raw['type']?.toString() == 'glassPanel',
        );

        if (isMobile) {
          final desktopPhoneSpec =
              _map(desktop['phone']) ?? const <String, dynamic>{};
          final desktopMinimum =
              _length(context, desktopPhoneSpec['minHeight']) ?? contentHeight;
          final canvasHeight = pageScrollable && !hasGlassPanel
              ? (desktopMinimum > contentHeight
                    ? desktopMinimum
                    : contentHeight)
              : contentHeight;

          final mobileCanvas = SizedBox(
            width: contentWidth,
            height: canvasHeight,
            child: Padding(
              padding: EdgeInsets.all(phonePadding),
              child: screen,
            ),
          );

          if (pageScrollable &&
              !hasGlassPanel &&
              canvasHeight > contentHeight) {
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              padding: pageInsets,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: mobileCanvas,
            );
          }

          return Padding(padding: pageInsets, child: mobileCanvas);
        }

        final responsivePhoneWidth = _responsiveMaxWidth(
          pageLayout['phoneMaxWidth'],
          contentWidth,
        );
        final rootLayout = runtime.resolveResponsiveLayout(
          logicalWidth,
          logicalHeight: logicalHeight,
          orientation: metrics.orientation,
        );
        final rootMaxContentWidth = rootLayout?.maxContentWidth;
        final width =
            (responsivePhoneWidth ??
                    rootMaxContentWidth ??
                    _desktopPhoneWidth(phoneSpec['width']) ??
                    390)
                .clamp(0.0, contentWidth)
                .toDouble();

        final minHeight = _length(context, phoneSpec['minHeight']) ?? 620;

        final declaredHeight = _desktopPhoneHeight(
          context,
          phoneSpec['height'],
          fallback: contentHeight,
        );

        final shortViewportNeedsScroll =
            pageScrollable && !hasGlassPanel && contentHeight < minHeight;
        final height = shortViewportNeedsScroll
            ? (declaredHeight < minHeight ? minHeight : declaredHeight)
            : declaredHeight
                  .clamp(minHeight.clamp(0.0, contentHeight), contentHeight)
                  .toDouble();

        final phoneColor = _color(phoneSpec['backgroundColor']);
        if (phoneColor == null) {
          return const AuthSchemaIssue(
            title: 'Schema color missing',
            details: [
              'Provide desktop.phone.backgroundColor as a valid color.',
            ],
          );
        }

        final centered =
            pageSpec['placeItems']?.toString() == 'center' ||
            pageSpec['display']?.toString() == 'grid';

        final phone = Container(
          width: width,
          height: height,
          padding: EdgeInsets.all(phonePadding),
          decoration: BoxDecoration(
            color: phoneColor,
            borderRadius: BorderRadius.circular(phoneRadius),
          ),
          clipBehavior: Clip.antiAlias,
          child: screen,
        );

        if (shortViewportNeedsScroll) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            padding: pageInsets,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Align(alignment: Alignment.topCenter, child: phone),
          );
        }

        return Padding(
          padding: pageInsets,
          child: centered
              ? Center(child: phone)
              : Align(alignment: Alignment.topCenter, child: phone),
        );
      },
    );
  }

  double _desktopPhoneHeight(
    BuildContext context,
    dynamic raw, {
    required double fallback,
  }) {
    if (raw is num) {
      return raw.toDouble();
    }

    if (raw is Map &&
        raw['type']?.toString() == 'min' &&
        raw['values'] is List) {
      final values = <double>[];

      for (final candidate in raw['values'] as List) {
        final resolved = _viewportLength(context, candidate);

        if (resolved != null) {
          values.add(resolved);
        }
      }

      if (values.isNotEmpty) {
        return values.reduce((a, b) => a < b ? a : b);
      }
    }

    final resolved = _viewportLength(context, raw);
    return resolved ?? fallback;
  }

  double? _viewportLength(BuildContext context, dynamic raw) {
    if (raw is num) {
      return raw.toDouble();
    }

    final value = raw?.toString().trim();
    if (value == null || value.isEmpty) {
      return null;
    }

    final px = RegExp(r'^([0-9.]+)(?:px)?$').firstMatch(value);
    if (px != null) {
      return double.parse(px.group(1)!);
    }

    if (value == '100vh' || value == '100dvh') {
      return MediaQuery.sizeOf(context).height;
    }

    final calc = RegExp(
      r'^calc\(\s*100(?:d)?vh\s*-\s*([0-9.]+)px\s*\)$',
    ).firstMatch(value);

    if (calc != null) {
      return MediaQuery.sizeOf(context).height - double.parse(calc.group(1)!);
    }

    return null;
  }

  Widget _position(BuildContext context, Map<String, dynamic> component) {
    component = _resolveResponsiveMap(context, component);
    if (!_visible(component)) {
      return const SizedBox.shrink();
    }

    final position = _map(component['position']);
    final child = _component(context, component);

    if (position == null) {
      return child;
    }

    final top = _length(context, position['top']);
    final left = _length(context, position['left']);
    final right = _length(context, position['right']);
    final bottom = _length(context, position['bottom']);

    if (position['verticalCenter'] == true) {
      return Positioned(
        top: 0,
        bottom: 0,
        left: left ?? 0,
        right: right ?? 0,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pagePanel = _map(_page?['glassPanel']);
            final declaredMaxWidth =
                component['type']?.toString() == 'glassPanel'
                ? _responsiveMaxWidth(
                    pagePanel?['maxWidth'],
                    constraints.maxWidth,
                  )
                : null;
            final isKeyboardVisible =
                _keyboardVisible ||
                (View.of(context).viewInsets.bottom > 0) ||
                (MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0) > 0;
            return Align(
              alignment: isKeyboardVisible
                  ? Alignment.topCenter
                  : Alignment.center,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: declaredMaxWidth ?? constraints.maxWidth,
                  maxHeight: constraints.maxHeight,
                ),
                child: child,
              ),
            );
          },
        ),
      );
    }

    if (position['horizontalCenter'] == true) {
      return Positioned(
        top: top,
        bottom: bottom,
        left: 0,
        right: 0,
        child: Align(alignment: Alignment.center, child: child),
      );
    }

    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: child,
    );
  }

  Widget _component(BuildContext context, Map<String, dynamic> component) {
    component = _resolveResponsiveMap(context, component);
    if (!_visible(component)) {
      return const SizedBox.shrink();
    }

    return switch (component['type']?.toString()) {
      'text' => _text(component),
      'image' => _image(context, component),
      'button' => _button(context, component, textButton: false),
      'textButton' => _button(context, component, textButton: true),
      'iconButton' => _iconButton(context, component),
      'textInput' => _input(component, password: false),
      'passwordInput' => _input(component, password: true),
      'checkbox' => _checkbox(component),
      'checkboxWithInlineLink' => _checkboxWithLink(component),
      'row' => _row(context, component),
      'inlineText' => _inlineText(component),
      'linkRow' => _linkRow(component),
      'passwordStrength' => _passwordStrength(component),
      'dividerLabel' => _divider(component),
      'socialButton' => _socialButton(context, component),
      'glassPanel' => _glassPanel(context, component),
      'otpInput' => _otpInput(component),
      'authError' => _authError(component),
      'stateMessage' => _authError(component),
      _ => AuthSchemaIssue(
        title: 'Unsupported auth component',
        details: [
          'components.${component['id']}.'
              'type=${component['type']}',
        ],
      ),
    };
  }

  Widget _glassPanel(BuildContext context, Map<String, dynamic> component) {
    final baseStyle = _map(component['style']);
    final children = component['children'];

    if (baseStyle == null || children is! List) {
      return const AuthSchemaIssue(
        title: 'Invalid glassPanel',
        details: ['style and children[] are required.'],
      );
    }

    // Page-level responsiveLayout.glassPanel is the responsive geometry
    // override for the panel. maxWidth is consumed by _position(); responsive
    // inner padding belongs to the panel style and must not be ignored.
    final pagePanel = _map(_page?['glassPanel']);
    final style = Map<String, dynamic>.from(baseStyle);
    final responsivePadding = _map(pagePanel?['padding']);
    if (responsivePadding != null) {
      final basePadding = _map(baseStyle['padding']) ?? <String, dynamic>{};
      style['padding'] = _deepMergeMap(basePadding, responsivePadding);
    }

    final background = _color(style['backgroundColor']);
    final borderColor = _color(style['borderColor']);
    final borderWidth = _n(style['borderWidth']) ?? 0;
    final radius = _n(style['borderRadius']) ?? 0;
    final blur = _n(style['backdropBlur']) ?? 0;
    final padding = _insets(style['padding']) ?? EdgeInsets.zero;

    final gap =
        _n(_page?['pageLayout']?['regions']?['form']?['fieldGap']) ?? 10;

    final childWidgets = <Widget>[];

    for (final raw in children) {
      if (raw is Map) {
        final child = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());

        if (_visible(child)) {
          if (childWidgets.isNotEmpty) {
            childWidgets.add(SizedBox(height: gap));
          }

          childWidgets.add(_componentWithMargin(context, child));
        }
      }
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: childWidgets,
    );

    final wantsInternalScroll =
        component['scrollInside'] == true ||
        _page?['scrollable'] == true ||
        _page?['verticalOverflow']?.toString().toLowerCase() == 'scroll';

    Widget panel = LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;

        Widget body;

        if (wantsInternalScroll) {
          // shrinkWrap=true is essential here:
          // the panel remains content-sized while content fits, and becomes
          // scrollable only when it reaches the available vertical limit.
          body = CustomScrollView(
            shrinkWrap: true,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            slivers: [SliverToBoxAdapter(child: content)],
          );
        } else {
          body = content;
        }

        Widget decorated = Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          padding: padding,
          decoration: BoxDecoration(
            color: background ?? Colors.transparent,
            borderRadius: BorderRadius.circular(radius),
            border: borderColor == null
                ? null
                : Border.all(color: borderColor, width: borderWidth),
            boxShadow: _shadowList(style['shadow']),
          ),
          clipBehavior: Clip.antiAlias,
          child: body,
        );

        if (blur > 0) {
          decorated = ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: decorated,
            ),
          );
        }

        return decorated;
      },
    );

    return panel;
  }

  Widget _componentWithMargin(
    BuildContext context,
    Map<String, dynamic> component,
  ) {
    final child = _component(context, component);
    final margin = _insets(component['margin']);

    if (margin == null) {
      return child;
    }

    return Padding(padding: margin, child: child);
  }

  Widget _text(Map<String, dynamic> component) {
    final style = _map(component['style']);

    final text = component['text']?.toString();

    if (style == null || text == null) {
      return const AuthSchemaIssue(
        title: 'Invalid text',
        details: ['text/style are required.'],
      );
    }

    final color = _color(style['color']);
    if (color == null) {
      return AuthSchemaIssue(
        title: 'Schema color missing',
        details: [
          'Provide components.${component['id']}.style.color as a valid color.',
        ],
      );
    }

    return Text(
      text,
      textAlign: _textAlign(style['textAlign']),
      style: TextStyle(
        color: color,
        fontSize: _n(style['fontSize']),
        fontWeight: _weight(style['fontWeight']),
        height: _n(style['lineHeight']),
        letterSpacing: _n(style['letterSpacing']),
      ),
    );
  }

  Widget _image(BuildContext context, Map<String, dynamic> component) {
    final asset = component['asset']?.toString();

    final size = _map(component['size']);

    if (asset == null || size == null) {
      return const AuthSchemaIssue(
        title: 'Invalid image',
        details: ['asset and size are required.'],
      );
    }

    return SizedBox(
      width: _n(size['width']),
      height: _n(size['height']),
      child: _asset(context, asset),
    );
  }

  Widget _button(
    BuildContext context,
    Map<String, dynamic> component, {
    required bool textButton,
  }) {
    final text = component['text']?.toString();

    final action = component['actionRef']?.toString();

    final enabled = _enabled(component);

    final style = _map(component['style']) ?? const <String, dynamic>{};

    final loading = action != null && state.isActionLoading(action);

    final otpVisibleKey = component['id'] == 'signup_send_otp'
        ? 'signupForm.otpVisible'
        : (component['id'] == 'forgot_send_otp'
            ? 'forgotPasswordForm.otpVisible'
            : null);
    final isOtpSent = otpVisibleKey != null && state.read(otpVisibleKey) == true;
    final defaultText = (isOtpSent && component['resendText'] != null)
        ? component['resendText'].toString()
        : (text ?? '');

    final resolvedText = loading && component['loadingText'] != null
        ? component['loadingText'].toString()
        : defaultText;

    final rawLabelColor =
        _color(style[textButton ? 'color' : 'textColor']);
    if (rawLabelColor == null) {
      return AuthSchemaIssue(
        title: 'Schema color missing',
        details: [
          'Provide components.${component['id']}.style.'
              '${textButton ? 'color' : 'textColor'} as a valid color.',
        ],
      );
    }

    final isExplicitlyDisabled = component['enabled'] == false;
    final disabledLabelColor =
        _color(style['disabledColor'] ?? style['disabledTextColor']) ??
        rawLabelColor.withValues(alpha: 0.65);
    final labelColor = (!enabled && !loading)
        ? disabledLabelColor
        : rawLabelColor;

    final label = Text(
      resolvedText,
      style: TextStyle(
        color: labelColor,
        fontSize:
            _n(style['fontSize']) ??
            _n(schema['theme']?['typography']?['button']?['fontSize']),
        fontWeight: _weight(
          style['fontWeight'] ??
              schema['theme']?['typography']?['button']?['fontWeight'],
        ),
        letterSpacing: _n(style['letterSpacing']),
        decoration: style['textDecoration']?.toString() == 'underline'
            ? TextDecoration.underline
            : null,
        decorationColor: _color(style['decorationColor']),
        decorationThickness: _n(style['decorationThickness']),
      ),
    );

    void handleTap() {
      if (isExplicitlyDisabled || loading || action == null) return;
      if (!enabled) {
        final validationGroup =
            component['validationGroup']?.toString().trim() ??
            _map(component['enabledWhen'])?['validationGroup']?.toString().trim() ??
            _map(schema['actions']?[action])?['validationGroup']?.toString().trim();
        if (validationGroup != null && validationGroup.isNotEmpty) {
          final isValid = state.validate(validationGroup);
          if (!isValid) {
            final validationMessage =
                schema['errorHandling']?['messages']?['validation']?.toString() ??
                'Please correct the highlighted fields.';
            state.write('auth.error', validationMessage);
            return;
          }
        } else {
          return;
        }
      }
      state.dispatch(action);
    }

    if (textButton) {
      // A schema textButton is visually intrinsic-sized.
      //
      // Flutter's stock TextButton injects Material minimum size/padding.
      // On absolutely-positioned auth screens that extra geometry changes
      // the schema's bottom/top coordinates and can visually overlap nearby
      // components (for example welcome_create_account with welcome_signin).
      //
      // Keep the visual box exactly at the schema text size. Interaction is
      // still driven only by actionRef.
      return Semantics(
        button: true,
        enabled: !isExplicitlyDisabled && !loading,
        label: resolvedText,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: (!isExplicitlyDisabled && !loading && action != null)
              ? handleTap
              : null,
          child: Padding(
            padding: _insets(component['padding']) ?? EdgeInsets.zero,
            child: label,
          ),
        ),
      );
    }

    final radius =
        _n(style['borderRadius']) ??
        _n(schema['theme']?['radius']?['button']) ??
        0;

    final size = _map(component['size']);

    Widget button = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: (!isExplicitlyDisabled && !loading && action != null)
            ? handleTap
            : null,
        child: Ink(
          height: _n(size?['height']),
          decoration: _buttonDecoration(style, radius),
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : label,
          ),
        ),
      ),
    );

    if (size?['width'] == 'fill') {
      button = SizedBox(width: double.infinity, child: button);
    } else {
      final width = _n(size?['width']);

      if (width != null) {
        button = SizedBox(width: width, child: button);
      }
    }

    return button;
  }

  Decoration _buttonDecoration(Map<String, dynamic> style, double radius) {
    final raw = style['backgroundColor']?.toString();

    final gradient = _gradient(raw);

    return BoxDecoration(
      color: gradient == null ? _color(raw) : null,
      gradient: gradient,
      borderRadius: BorderRadius.circular(radius),
      border: _color(style['borderColor']) == null
          ? null
          : Border.all(
              color: _color(style['borderColor'])!,
              width: _n(style['borderWidth']) ?? 1,
            ),
      boxShadow: _shadowList(style['shadow']),
    );
  }

  Widget _iconButton(BuildContext context, Map<String, dynamic> component) {
    final style = _map(component['style']) ?? const <String, dynamic>{};

    final action = component['actionRef']?.toString();

    final size = _map(component['size']);

    final width = _n(size?['width']) ?? 44;

    final height = _n(size?['height']) ?? 44;

    final iconName =
        component['iconRef']?.toString() ?? component['icon']?.toString() ?? '';

    final iconColor = _color(style['iconColor']);
    if (iconColor == null) {
      return AuthSchemaIssue(
        title: 'Schema color missing',
        details: [
          'Provide components.${component['id']}.style.iconColor '
              'as a valid color.',
        ],
      );
    }

    final iconSize = _n(style['iconSize']) ?? 18;

    final radius = style['shape'] == 'circle'
        ? width / 2
        : _n(style['borderRadius']) ?? 0;

    Widget child = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _color(style['backgroundColor']),
        borderRadius: BorderRadius.circular(radius),
        border: _color(style['borderColor']) == null
            ? null
            : Border.all(
                color: _color(style['borderColor'])!,
                width: _n(style['borderWidth']) ?? 1,
              ),
        boxShadow: _shadowList(style['shadow']),
      ),
      alignment: Alignment.center,
      child: _icons.build(name: iconName, size: iconSize, color: iconColor),
    );

    final blur = _n(style['backdropBlur']);

    if (blur != null && blur > 0) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: child,
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: action == null ? null : () => state.dispatch(action),
      child: child,
    );
  }

  Widget _input(Map<String, dynamic> component, {required bool password}) {
    final stateKey = component['stateKey']?.toString();

    final style = _map(component['style']);

    if (stateKey == null || style == null) {
      return const AuthSchemaIssue(
        title: 'Invalid auth input',
        details: ['stateKey/style are required.'],
      );
    }

    final inputTypography = _map(schema['theme']?['typography']?['input']);

    final requiredNumbers = <String, double?>{
      'height': _n(style['height']),
      'borderRadius': _n(style['borderRadius']),
      'borderWidth': _n(style['borderWidth']),
      'horizontalPadding': _n(style['horizontalPadding']),
      'leadingIconSize': _n(style['leadingIconSize']),
      if (password) 'trailingIconSize': _n(style['trailingIconSize']),
      'fontSize': _n(style['fontSize'] ?? inputTypography?['fontSize']),
    };

    final requiredColors = <String, Color?>{
      'backgroundColor': _color(style['backgroundColor']),
      'borderColor': _color(style['borderColor']),
      'focusBorderColor': _color(style['focusBorderColor']),
      'textColor': _color(style['textColor']),
      'placeholderColor': _color(style['placeholderColor']),
      'iconColor': _color(style['iconColor']),
    };

    final fontWeight = _weight(
      style['fontWeight'] ?? inputTypography?['fontWeight'],
    );

    final missing = <String>[
      ...requiredNumbers.entries
          .where((entry) => entry.value == null)
          .map((entry) => entry.key),
      ...requiredColors.entries
          .where((entry) => entry.value == null)
          .map((entry) => entry.key),
      if (fontWeight == null) 'fontWeight',
    ];

    if (missing.isNotEmpty) {
      return AuthSchemaIssue(
        title: 'Auth input schema incomplete',
        details: [
          'components.${component['id']} '
              'is missing/invalid: '
              '${missing.join(', ')}.',
        ],
      );
    }

    final leadingName =
        component['leadingIconRef']?.toString() ??
        component['leadingIcon']?.toString();

    Widget? leading;

    if (leadingName != null && leadingName.isNotEmpty) {
      leading = _icons.build(
        name: leadingName,
        inlineAsset: _map(component['leadingIconAsset']),
        size: requiredNumbers['leadingIconSize'],
        color: requiredColors['iconColor'],
      );

      if (leading == null) {
        return AuthSchemaIssue(
          title: 'Auth icon missing',
          details: [
            'components.${component['id']} '
                'cannot resolve leading icon '
                '"$leadingName".',
          ],
        );
      }
    }

    Widget? trailingHidden;
    Widget? trailingVisible;
    Widget? trailingAction;

    if (password) {
      final refs = component['trailingIconRefs'];

      final assets = _map(component['trailingIconAssets']);

      if (refs is! List || refs.length < 2) {
        return AuthSchemaIssue(
          title: 'Password icon schema incomplete',
          details: [
            'components.${component['id']}.'
                'trailingIconRefs must contain '
                'two schema icon names.',
          ],
        );
      }

      final hiddenName = refs[0]?.toString();
      final visibleName = refs[1]?.toString();

      if (hiddenName == null ||
          hiddenName.isEmpty ||
          visibleName == null ||
          visibleName.isEmpty) {
        return AuthSchemaIssue(
          title: 'Password icon schema invalid',
          details: [
            'components.${component['id']}.'
                'trailingIconRefs contains '
                'an empty icon name.',
          ],
        );
      }

      trailingHidden = _icons.build(
        name: hiddenName,
        inlineAsset: _map(assets?[hiddenName]),
        size: requiredNumbers['trailingIconSize'],
        color: requiredColors['iconColor'],
      );

      trailingVisible = _icons.build(
        name: visibleName,
        inlineAsset: _map(assets?[visibleName]),
        size: requiredNumbers['trailingIconSize'],
        color: requiredColors['iconColor'],
      );

      if (trailingHidden == null || trailingVisible == null) {
        return AuthSchemaIssue(
          title: 'Password icon missing',
          details: [
            'components.${component['id']} '
                'could not resolve both '
                'schema trailing icons.',
          ],
        );
      }
    } else {
      final trailingActionSchema = _map(component['trailingAction']);

      if (trailingActionSchema != null) {
        trailingAction = _inputTrailingAction(component, trailingActionSchema);
      }
    }

    final minTouch = _n(schema['accessibility']?['minTouchTarget']?['width']);

    if (minTouch == null) {
      return const AuthSchemaIssue(
        title: 'Auth accessibility schema incomplete',
        details: [
          'accessibility.minTouchTarget.width '
              'is required.',
        ],
      );
    }

    final effectiveStyle = <String, dynamic>{
      ...style,
      'fontSize': requiredNumbers['fontSize'],
      'fontWeight': fontWeight,
      '_resolvedHeight': requiredNumbers['height'],
      '_resolvedBorderRadius': requiredNumbers['borderRadius'],
      '_resolvedBorderWidth': requiredNumbers['borderWidth'],
      '_resolvedHorizontalPadding': requiredNumbers['horizontalPadding'],
      '_resolvedBackgroundColor': requiredColors['backgroundColor'],
      '_resolvedBorderColor': requiredColors['borderColor'],
      '_resolvedFocusBorderColor': requiredColors['focusBorderColor'],
      '_resolvedTextColor': requiredColors['textColor'],
      '_resolvedPlaceholderColor': requiredColors['placeholderColor'],
      '_resolvedIconColor': requiredColors['iconColor'],
      '_resolvedTouchTarget': minTouch,
    };

    return _AuthBoundField(
      state: state,
      stateKey: stateKey,
      password: password,
      placeholder: component['placeholder']?.toString() ?? '',
      maxLength: (component['maxLength'] as num?)?.toInt(),
      keyboardType: _keyboardType(component),
      leading: leading,
      trailingHidden: trailingHidden,
      trailingVisible: trailingVisible,
      trailingAction: trailingAction,
      style: effectiveStyle,
      lengthEvent: _map(_map(component['events'])?['onLengthReached']),
    );
  }

  Widget _inputTrailingAction(
    Map<String, dynamic> component,
    Map<String, dynamic> actionSchema,
  ) {
    final actionRef = actionSchema['actionRef']?.toString();
    final text = actionSchema['text']?.toString();
    final activeText = actionSchema['activeText']?.toString();
    final activeStateKey = actionSchema['activeStateKey']?.toString();
    final activeValue = actionSchema.containsKey('activeValue')
        ? actionSchema['activeValue']
        : true;
    final style = _map(actionSchema['style']);

    if (actionRef == null ||
        actionRef.isEmpty ||
        text == null ||
        text.isEmpty ||
        style == null) {
      return AuthSchemaIssue(
        title: 'Invalid input trailing action',
        details: [
          'components.${component['id']}.'
              'trailingAction requires actionRef, text and style.',
        ],
      );
    }

    final enabledWhen = _map(actionSchema['enabledWhen']);
    final enabled =
        actionSchema['enabled'] != false &&
        (enabledWhen == null ||
            _condition(
              enabledWhen['stateKey'],
              enabledWhen['condition'],
              enabledWhen['value'],
            ));
    final active =
        activeStateKey != null &&
        activeStateKey.isNotEmpty &&
        state.read(activeStateKey) == activeValue;
    final loading = state.isActionLoading(actionRef);
    final resolvedText = loading
        ? actionSchema['loadingText']?.toString() ?? text
        : active && activeText != null && activeText.isNotEmpty
        ? activeText
        : text;
    final width = _n(style['width']) ?? 72;
    final height = _n(style['height']) ?? 30;
    final radius = _n(style['borderRadius']) ?? height / 2;
    final background = _color(style['backgroundColor']);
    final disabledBackground =
        _color(style['disabledBackgroundColor']) ?? background;
    final border = _color(style['borderColor']);
    final textColor = _color(style['textColor']);
    if (textColor == null) {
      return AuthSchemaIssue(
        title: 'Schema color missing',
        details: [
          'Provide components.${component['id']}.trailingAction.style.textColor '
              'as a valid color.',
        ],
      );
    }
    final disabledTextColor =
        _color(style['disabledTextColor']) ?? textColor.withValues(alpha: 0.65);

    return Padding(
      padding:
          _insets(actionSchema['padding']) ?? const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        enabled: enabled && !loading,
        label: resolvedText,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled && !loading ? () => state.dispatch(actionRef) : null,
          child: Container(
            width: width,
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled ? background : disabledBackground,
              borderRadius: BorderRadius.circular(radius),
              border: border == null
                  ? null
                  : Border.all(
                      color: border,
                      width: _n(style['borderWidth']) ?? 1,
                    ),
            ),
            child: loading
                ? SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: textColor,
                    ),
                  )
                : Text(
                    resolvedText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled ? textColor : disabledTextColor,
                      fontSize: _n(style['fontSize']) ?? 10,
                      fontWeight:
                          _weight(style['fontWeight']) ?? FontWeight.w700,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _authError(Map<String, dynamic> component) {
    final stateKey = component['stateKey']?.toString();
    final style = _map(component['style']);

    if (stateKey == null || stateKey.isEmpty || style == null) {
      return const AuthSchemaIssue(
        title: 'Invalid authError',
        details: ['stateKey and style are required.'],
      );
    }

    final message = state.read(stateKey)?.toString().trim() ?? '';

    if (message.isEmpty) {
      return const SizedBox.shrink();
    }

    final padding = _insets(style['padding']);
    final radius = _n(style['borderRadius']);
    final background = _color(style['backgroundColor']);
    final border = _color(style['borderColor']);
    final textColor = _color(style['textColor']);
    final fontSize = _n(style['fontSize']);

    if (padding == null ||
        radius == null ||
        background == null ||
        border == null ||
        textColor == null ||
        fontSize == null) {
      return AuthSchemaIssue(
        title: 'Invalid authError style',
        details: [
          'components.${component['id']}.style requires padding, '
              'borderRadius, backgroundColor, borderColor, textColor '
              'and fontSize.',
        ],
      );
    }

    final messageBox = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border, width: _n(style['borderWidth']) ?? 1),
      ),
      child: Text(
        message,
        maxLines: (component['maxLines'] as num?)?.toInt() ?? 2,
        overflow: TextOverflow.ellipsis,
        textAlign: _textAlign(style['textAlign']),
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: _weight(style['fontWeight']),
        ),
      ),
    );

    return switch (style['alignment']?.toString()) {
      'right' || 'centerRight' => Align(
        alignment: Alignment.centerRight,
        child: messageBox,
      ),
      'center' => Align(alignment: Alignment.center, child: messageBox),
      'left' ||
      'centerLeft' => Align(alignment: Alignment.centerLeft, child: messageBox),
      _ => messageBox,
    };
  }

  Widget _checkbox(Map<String, dynamic> component) {
    final stateKey = component['stateKey']?.toString();

    final style = _map(component['style']) ?? const <String, dynamic>{};

    if (stateKey == null) {
      return const AuthSchemaIssue(
        title: 'Invalid checkbox',
        details: ['stateKey is required.'],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: state.read(stateKey) == true,
          activeColor: _color(style['activeColor']),
          onChanged: (value) {
            state.write(stateKey, value == true);
          },
        ),
        Flexible(
          child: Text(
            component['text']?.toString() ?? '',
            style: TextStyle(
              color: _color(style['textColor']),
              fontSize: _n(style['fontSize']),
            ),
          ),
        ),
      ],
    );
  }

  Widget _checkboxWithLink(Map<String, dynamic> component) {
    final stateKey = component['stateKey']?.toString();

    final action = component['linkActionRef']?.toString();

    final style = _map(component['style']) ?? const <String, dynamic>{};

    if (stateKey == null) {
      return const AuthSchemaIssue(
        title: 'Invalid terms checkbox',
        details: ['stateKey is required.'],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(
          value: state.read(stateKey) == true,
          activeColor: _color(style['activeColor']),
          onChanged: (value) {
            state.write(stateKey, value == true);
          },
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  color: _color(style['textColor']),
                  fontSize: _n(style['fontSize']),
                ),
                children: [
                  TextSpan(text: component['text']?.toString() ?? ''),
                  TextSpan(
                    text: component['linkText']?.toString() ?? '',
                    style: TextStyle(
                      color: _color(style['linkColor']),
                      fontWeight: FontWeight.w800,
                    ),
                    recognizer: action == null
                        ? null
                        : (TapGestureRecognizer()
                            ..onTap = () => state.dispatch(action)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> component) {
    final children = component['children'];

    if (children is! List) {
      return const AuthSchemaIssue(
        title: 'Invalid row',
        details: ['children[] is required.'],
      );
    }

    final gap = _n(component['gap']) ?? 0;

    final widgets = <Widget>[];

    for (var i = 0; i < children.length; i++) {
      final raw = children[i];

      if (raw is Map) {
        widgets.add(
          Flexible(
            fit: FlexFit.loose,
            child: _component(
              context,
              Map<String, dynamic>.from(raw.cast<dynamic, dynamic>()),
            ),
          ),
        );

        if (i < children.length - 1) {
          widgets.add(SizedBox(width: gap));
        }
      }
    }

    return Row(
      mainAxisAlignment: _mainAxis(component['mainAxisAlignment']),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: widgets,
    );
  }

  Widget _inlineText(Map<String, dynamic> component) {
    final spans = component['spans'];

    if (spans is! List) {
      return const AuthSchemaIssue(
        title: 'Invalid inlineText',
        details: ['spans[] is required.'],
      );
    }

    return RichText(
      textAlign: _textAlign(component['alignment']),
      text: TextSpan(
        children: [
          for (final raw in spans)
            if (raw is Map)
              _span(Map<String, dynamic>.from(raw.cast<dynamic, dynamic>())),
        ],
      ),
    );
  }

  TextSpan _span(Map<String, dynamic> span) {
    final style = _map(span['style']) ?? const <String, dynamic>{};

    final action = span['actionRef']?.toString();

    return TextSpan(
      text: span['text']?.toString() ?? '',
      style: TextStyle(
        color: _color(style['color']),
        fontSize: _n(style['fontSize']),
        fontWeight: _weight(style['fontWeight']),
        letterSpacing: _n(style['letterSpacing']),
      ),
      recognizer: action == null
          ? null
          : (TapGestureRecognizer()..onTap = () => state.dispatch(action)),
    );
  }

  Widget _linkRow(Map<String, dynamic> component) {
    final links = component['links'];

    final style = _map(component['style']) ?? const <String, dynamic>{};

    if (links is! List) {
      return const AuthSchemaIssue(
        title: 'Invalid linkRow',
        details: ['links[] is required.'],
      );
    }

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: _n(style['gap']) ?? 12,
      runSpacing: _n(style['runSpacing']) ?? 0,
      children: [
        for (final raw in links)
          if (raw is Map)
            Semantics(
              button: raw['actionRef'] != null,
              label: raw['text']?.toString() ?? '',
              child: GestureDetector(
                behavior: HitTestBehavior.deferToChild,
                onTap: raw['actionRef'] == null
                    ? null
                    : () => state.dispatch(raw['actionRef'].toString()),
                child: Padding(
                  padding: _insets(raw['padding']) ?? EdgeInsets.zero,
                  child: Text(
                    raw['text']?.toString() ?? '',
                    style: TextStyle(
                      color: _color(style['color']),
                      fontSize: _n(style['fontSize']),
                      fontWeight: _weight(style['fontWeight']),
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }

  Widget _otpInput(Map<String, dynamic> component) {
    final stateKey = component['stateKey']?.toString();

    final style = _map(component['style']);

    final count = (component['digitCount'] as num?)?.toInt();

    if (stateKey == null || style == null || count == null) {
      return const AuthSchemaIssue(
        title: 'Invalid otpInput',
        details: [
          'stateKey, digitCount and style '
              'are required.',
        ],
      );
    }

    final requiredColors = <String, Color?>{
      'borderColor': _color(style['borderColor']),
      'focusBorderColor': _color(style['focusBorderColor']),
      'textColor': _color(style['textColor']),
    };
    final missing = requiredColors.entries
        .where((entry) => entry.value == null)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (missing.isNotEmpty) {
      return AuthSchemaIssue(
        title: 'Schema color missing',
        details: [
          'Provide components.${component['id']}.style.'
              '${missing.join(', style.')} as valid color(s).',
        ],
      );
    }

    return _SchemaOtpInput(
      state: state,
      stateKey: stateKey,
      digitCount: count,
      style: style,
      lengthEvent: _map(_map(component['events'])?['onLengthReached']),
    );
  }

  Widget _passwordStrength(Map<String, dynamic> component) {
    final stateKey = component['sourceStateKey']?.toString();

    final levels = component['levels'];

    final style = _map(component['style']);

    if (stateKey == null || levels is! List || style == null) {
      return const AuthSchemaIssue(
        title: 'Invalid passwordStrength',
        details: [
          'sourceStateKey, levels[] and style '
              'are required.',
        ],
      );
    }

    final password = state.read(stateKey)?.toString() ?? '';

    var passed = 0;

    if (password.length >= 8) {
      passed++;
    }
    if (RegExp(r'[A-Z]').hasMatch(password)) {
      passed++;
    }
    if (RegExp(r'[a-z]').hasMatch(password)) {
      passed++;
    }
    if (RegExp(r'[0-9]').hasMatch(password)) {
      passed++;
    }
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(password)) {
      passed++;
    }

    Map<String, dynamic>? selected;

    for (final raw in levels) {
      if (raw is! Map) {
        continue;
      }

      final current = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());

      final min = (current['minPassedRules'] as num?)?.toInt() ?? 0;

      if (passed >= min) {
        selected = current;
      }
    }

    final color = _color(selected?['color']);
    if (color == null) {
      return AuthSchemaIssue(
        title: 'Schema color missing',
        details: [
          'Provide components.${component['id']}.levels[].color '
              'for the active strength level.',
        ],
      );
    }

    final label = selected?['label']?.toString() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(_n(style['borderRadius']) ?? 999),
          child: LinearProgressIndicator(
            minHeight: _n(style['height']) ?? 4,
            value: passed / 5,
            color: color,
            backgroundColor: _color(style['trackColor']),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: _color(style['labelColor']),
            fontSize: _n(style['labelFontSize']),
          ),
        ),
      ],
    );
  }

  Widget _divider(Map<String, dynamic> component) {
    final style = _map(component['style']) ?? const <String, dynamic>{};

    return Row(
      children: [
        Expanded(child: Divider(color: _color(style['lineColor']))),
        SizedBox(width: _n(style['gap']) ?? 10),
        Text(
          component['text']?.toString() ?? '',
          style: TextStyle(
            color: _color(style['textColor']),
            fontSize: _n(style['fontSize']),
          ),
        ),
        SizedBox(width: _n(style['gap']) ?? 10),
        Expanded(child: Divider(color: _color(style['lineColor']))),
      ],
    );
  }

  Widget _socialButton(BuildContext context, Map<String, dynamic> component) {
    final size = _map(component['size']) ?? const <String, dynamic>{};

    final style = _map(component['style']) ?? const <String, dynamic>{};

    final icon =
        component['iconRef']?.toString() ??
        component['provider']?.toString() ??
        '';

    final width = _n(size['width']) ?? 40;

    final height = _n(size['height']) ?? 40;

    final inlineAsset = _map(component['iconAsset']);
    final isMultiColor = inlineAsset?['fill'] == 'multiColor' ||
        inlineAsset?['style'] == 'brand-multicolor' ||
        icon.toLowerCase() == 'google';

    final iconColor = _color(style['iconColor']);
    if (iconColor == null && !isMultiColor) {
      return AuthSchemaIssue(
        title: 'Schema color missing',
        details: [
          'Provide components.${component['id']}.style.iconColor '
              'as a valid color.',
        ],
      );
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _color(style['backgroundColor']),
        borderRadius: BorderRadius.circular(width / 2),
        border: _color(style['borderColor']) == null
            ? null
            : Border.all(color: _color(style['borderColor'])!),
      ),
      alignment: Alignment.center,
      child: _icons.build(
        name: icon,
        inlineAsset: inlineAsset,
        size: _n(component['iconSize']) ?? 18,
        color: isMultiColor ? null : iconColor,
      ),
    );
  }

  bool _enabled(Map<String, dynamic> component) {
    if (component['enabled'] == false) {
      return false;
    }

    final enabledWhen = _map(component['enabledWhen']);
    if (enabledWhen == null) {
      return true;
    }

    final validationGroup = enabledWhen['validationGroup']?.toString().trim();
    if (validationGroup != null && validationGroup.isNotEmpty) {
      return state.validationGroupSatisfied(validationGroup);
    }

    return _condition(
      enabledWhen['stateKey'],
      enabledWhen['condition'],
      enabledWhen['value'],
    );
  }

  bool _visible(Map<String, dynamic> component) {
    if (component['visibility'] == false) {
      return false;
    }

    final visibleStateKey = component['visibleStateKey']?.toString();

    if (visibleStateKey != null &&
        visibleStateKey.isNotEmpty &&
        state.read(visibleStateKey) != true) {
      return false;
    }

    final visibility = _map(component['visibility']);

    if (visibility != null &&
        !_condition(
          visibility['dependsOn'],
          visibility['condition'],
          visibility['value'],
        )) {
      return false;
    }

    final visibleWhen = _map(component['visibleWhen']);

    if (visibleWhen != null &&
        !_condition(
          visibleWhen['stateKey'],
          visibleWhen['condition'],
          visibleWhen['value'],
        )) {
      return false;
    }

    return true;
  }

  bool _condition(dynamic rawStateKey, dynamic rawCondition, dynamic expected) {
    final key = rawStateKey?.toString();

    if (key == null || key.isEmpty) {
      return true;
    }

    final value = state.read(key);

    return switch (rawCondition?.toString()) {
      'lengthEquals' =>
        (value?.toString().length ?? 0) == (expected as num?)?.toInt(),
      'equals' => value == expected,
      'notEquals' => value != expected,
      'truthy' => value == true,
      'notEmpty' => value != null && value.toString().trim().isNotEmpty,
      _ => true,
    };
  }

  Widget _background(BuildContext context, Map<String, dynamic> background) {
    final asset = background['asset']?.toString();

    final overlay = _map(background['overlay']);

    return Stack(
      fit: StackFit.expand,
      children: [
        if (asset != null) _asset(context, asset),
        if (overlay != null)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: _overlayGradient(overlay),
              color: _overlayGradient(overlay) == null
                  ? _color(overlay['color'])
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _asset(BuildContext context, String name) {
    final assets = schema['assets'];

    final raw = assets is Map ? assets[name] : null;

    if (raw is! Map) {
      return AuthSchemaIssue(
        title: 'Missing auth asset',
        details: ['assets.$name is required.'],
      );
    }

    final type = raw['type']?.toString();

    final url = raw['url']?.toString();

    if (type != 'networkImage' || url == null) {
      return AuthSchemaIssue(
        title: 'Invalid auth asset',
        details: [
          'assets.$name must be a '
              'networkImage with url.',
        ],
      );
    }

    final resolved = state.resolveUri(url).toString();

    return CachedNetworkImage(
      imageUrl: resolved,
      cacheManager: SduiAuthImageCache.manager,
      fit: _boxFit(raw['fit']),
      alignment: _alignment(raw['alignment']),
      placeholder: (_, __) => const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      errorWidget: (context, error, stack) => Image.asset(
        'assets/branding/efactor_app_logo.jpg',
        fit: _boxFit(raw['fit']),
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.flash_on, size: 36, color: Colors.blueAccent),
        ),
      ),
    );
  }

  LinearGradient? _gradient(String? raw) {
    if (raw == null || !raw.startsWith('linear-gradient')) {
      return null;
    }

    final matches = RegExp(r'(#[0-9A-Fa-f]{6,8}|rgba?\([^)]+\))')
        .allMatches(raw)
        .map((match) => _color(match.group(0)))
        .whereType<Color>()
        .toList();

    if (matches.length < 2) {
      return null;
    }

    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: matches,
    );
  }

  LinearGradient? _overlayGradient(Map<String, dynamic> overlay) {
    final colors = overlay['colors'];

    if (colors is! List) {
      return null;
    }

    final parsed = colors.map(_color).whereType<Color>().toList();

    if (parsed.length < 2) {
      return null;
    }

    final stops = overlay['stops'];

    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: parsed,
      stops: stops is List && stops.length == parsed.length
          ? stops.map((value) => (value as num).toDouble()).toList()
          : null,
    );
  }

  List<BoxShadow>? _shadowList(dynamic raw) {
    final shadow = _map(raw);

    if (shadow == null) {
      return null;
    }

    final color = _color(shadow['color']);

    if (color == null) {
      return null;
    }

    return <BoxShadow>[
      BoxShadow(
        color: color,
        offset: Offset(_n(shadow['offsetX']) ?? 0, _n(shadow['offsetY']) ?? 0),
        blurRadius: _n(shadow['blur']) ?? 0,
      ),
    ];
  }

  Color? _color(dynamic raw) {
    if (raw is Color) {
      return raw;
    }

    final text = raw?.toString().trim();

    if (text == null || text.isEmpty) {
      return null;
    }

    if (text.startsWith('#')) {
      var hex = text.substring(1);

      if (hex.length == 6) {
        hex = 'FF$hex';
      }

      if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }

    final rgba = RegExp(
      r'rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)(?:\s*,\s*([0-9.]+))?\s*\)',
    ).firstMatch(text);

    if (rgba != null) {
      final r = double.parse(rgba.group(1)!);

      final g = double.parse(rgba.group(2)!);

      final b = double.parse(rgba.group(3)!);

      final a = rgba.group(4) == null ? 1.0 : double.parse(rgba.group(4)!);

      return Color.fromRGBO(r.round(), g.round(), b.round(), a);
    }

    return null;
  }

  double? _n(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(value?.toString() ?? '');
  }

  double? _length(BuildContext context, dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    final text = value?.toString().trim();

    if (text == null || text.isEmpty) {
      return null;
    }

    final plain = RegExp(r'^(-?[0-9.]+)(?:px)?$').firstMatch(text);

    if (plain != null) {
      return double.parse(plain.group(1)!);
    }

    final calc = RegExp(
      r'calc\(\s*([0-9.]+)px\s*\+\s*(?:safeAreaBottom|env\(safe-area-inset-bottom\))\s*\)',
    ).firstMatch(text);

    if (calc != null) {
      return double.parse(calc.group(1)!) +
          MediaQuery.paddingOf(context).bottom;
    }

    return null;
  }

  EdgeInsets? _insets(dynamic raw) {
    if (raw is num) {
      return EdgeInsets.all(raw.toDouble());
    }

    if (raw is Map) {
      return EdgeInsets.fromLTRB(
        _n(raw['left']) ?? 0,
        _n(raw['top']) ?? 0,
        _n(raw['right']) ?? 0,
        _n(raw['bottom']) ?? 0,
      );
    }

    return null;
  }

  double? _desktopPhoneWidth(dynamic raw) {
    if (raw is num) {
      return raw.toDouble();
    }

    if (raw is Map && raw['type'] == 'min' && raw['values'] is List) {
      for (final value in raw['values'] as List) {
        final number = _n(value);

        if (number != null) {
          return number;
        }
      }
    }

    return null;
  }

  TextAlign _textAlign(dynamic raw) {
    return switch (raw?.toString()) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      _ => TextAlign.left,
    };
  }

  FontWeight? _weight(dynamic raw) {
    final value = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString() ?? '');

    if (value == null) {
      return null;
    }

    if (value >= 850) {
      return FontWeight.w900;
    }
    if (value >= 700) {
      return FontWeight.w700;
    }
    if (value >= 600) {
      return FontWeight.w600;
    }
    if (value >= 500) {
      return FontWeight.w500;
    }

    return FontWeight.w400;
  }

  MainAxisAlignment _mainAxis(dynamic raw) {
    return switch (raw?.toString()) {
      'spaceBetween' => MainAxisAlignment.spaceBetween,
      'center' => MainAxisAlignment.center,
      'end' => MainAxisAlignment.end,
      _ => MainAxisAlignment.start,
    };
  }

  TextInputType _keyboardType(Map<String, dynamic> component) {
    final raw =
        component['keyboardType']?.toString() ??
        component['inputMode']?.toString() ??
        component['inputType']?.toString();

    return switch (raw) {
      'number' || 'numeric' || 'phone' || 'tel' => TextInputType.phone,
      'email' => TextInputType.emailAddress,
      _ => TextInputType.text,
    };
  }

  BoxFit _boxFit(dynamic raw) {
    return switch (raw?.toString()) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      _ => BoxFit.contain,
    };
  }

  Alignment _alignment(dynamic raw) {
    return switch (raw?.toString()) {
      'topCenter' => Alignment.topCenter,
      'bottomCenter' => Alignment.bottomCenter,
      'centerLeft' => Alignment.centerLeft,
      'centerRight' => Alignment.centerRight,
      _ => Alignment.center,
    };
  }

  Map<String, dynamic> _resolvePageResponsiveMap(
    BuildContext context,
    Map<String, dynamic> source,
  ) {
    final runtime = SchemaRuntime(schema);
    if (runtime.responsive == null) {
      return Map<String, dynamic>.from(source);
    }

    final metrics = DeviceScreenMetrics.fromContext(context);
    final width = runtime.useSafeArea == true
        ? metrics.safeWidth
        : metrics.logicalWidth;
    final height = runtime.useSafeArea == true
        ? metrics.safeHeight
        : metrics.logicalHeight;
    final breakpoint = runtime.resolveBreakpointName(
      width,
      logicalHeight: height,
      orientation: metrics.orientation,
    );

    var effective = Map<String, dynamic>.from(source);

    // app.responsiveLayout contains global page behavior (for example the v8
    // landscape scroll/keyboard policy). Apply only the responsive override
    // payload here; base app fields are not copied into pages.
    final app = _map(schema['app']);
    if (app != null && breakpoint != null) {
      final appOverride = _responsiveOverridePayload(
        app,
        breakpoint,
        metrics.orientation,
      );
      effective = _deepMergeMap(effective, appOverride);
    }

    // Page-local responsiveLayout is more specific and therefore wins over
    // global app responsive defaults.
    return runtime.resolveResponsiveMap(
      effective,
      width,
      logicalHeight: height,
      orientation: metrics.orientation,
    );
  }

  Map<String, dynamic> _responsiveOverridePayload(
    Map<String, dynamic> source,
    String breakpoint,
    String orientation,
  ) {
    var result = <String, dynamic>{};

    for (final key in const <String>[
      'responsiveLayout',
      'responsiveOverrides',
    ]) {
      final raw = source[key];
      if (raw is! Map) continue;

      final all = _map(raw['all']);
      if (all != null) {
        result = _deepMergeMap(result, _withoutOrientationMaps(all));
        final oriented = _map(all[orientation.toLowerCase()]);
        if (oriented != null) {
          result = _deepMergeMap(result, oriented);
        }
      }

      final selected = _map(raw[breakpoint]);
      if (selected != null) {
        result = _deepMergeMap(result, _withoutOrientationMaps(selected));
        final oriented = _map(selected[orientation.toLowerCase()]);
        if (oriented != null) {
          result = _deepMergeMap(result, oriented);
        }
      }
    }

    return result;
  }

  Map<String, dynamic> _withoutOrientationMaps(Map<String, dynamic> source) {
    final result = Map<String, dynamic>.from(source);
    result.remove('portrait');
    result.remove('landscape');
    return result;
  }

  Map<String, dynamic> _deepMergeMap(
    Map<String, dynamic> base,
    Map<String, dynamic> override,
  ) {
    final result = Map<String, dynamic>.from(base);
    for (final entry in override.entries) {
      final current = result[entry.key];
      final incoming = entry.value;
      if (current is Map && incoming is Map) {
        result[entry.key] = _deepMergeMap(
          Map<String, dynamic>.from(current.cast<dynamic, dynamic>()),
          Map<String, dynamic>.from(incoming.cast<dynamic, dynamic>()),
        );
      } else {
        result[entry.key] = incoming;
      }
    }
    return result;
  }

  Map<String, dynamic> _resolveResponsiveMap(
    BuildContext context,
    Map<String, dynamic> source,
  ) {
    final runtime = SchemaRuntime(schema);
    if (runtime.responsive == null) {
      return Map<String, dynamic>.from(source);
    }

    final metrics = DeviceScreenMetrics.fromContext(context);
    final width = runtime.useSafeArea == true
        ? metrics.safeWidth
        : metrics.logicalWidth;
    final height = runtime.useSafeArea == true
        ? metrics.safeHeight
        : metrics.logicalHeight;

    return runtime.resolveResponsiveMap(
      source,
      width,
      logicalHeight: height,
      orientation: metrics.orientation,
    );
  }

  EdgeInsets? _responsiveContentInsets(dynamic raw) {
    if (raw is num) return EdgeInsets.all(raw.toDouble());
    if (raw is! Map) return null;

    final horizontal = _n(raw['horizontal']);
    final vertical = _n(raw['vertical']);
    if (horizontal != null || vertical != null) {
      return EdgeInsets.symmetric(
        horizontal: horizontal ?? 0,
        vertical: vertical ?? 0,
      );
    }

    return _insets(raw);
  }

  double? _responsiveMaxWidth(dynamic raw, double availableWidth) {
    if (raw is num) {
      return raw.toDouble().clamp(0.0, availableWidth).toDouble();
    }

    final text = raw?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) return null;
    if (text == 'fill' ||
        text == 'expanded' ||
        text == 'matchparent' ||
        text == '100%') {
      return availableWidth;
    }

    final parsed = double.tryParse(text.replaceAll('px', ''));
    return parsed?.clamp(0.0, availableWidth).toDouble();
  }

  Map<String, dynamic>? _map(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
    }

    return null;
  }
}

class _PhoneNumberFormatter extends TextInputFormatter {
  const _PhoneNumberFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    final digits = raw.replaceAll(RegExp(r'\D'), '');

    if (raw == digits && digits.length <= 10) {
      return newValue;
    }

    var normalized = digits;
    if (normalized.length == 12 && normalized.startsWith('91')) {
      normalized = normalized.substring(2);
    } else if (normalized.length == 11 && normalized.startsWith('0')) {
      normalized = normalized.substring(1);
    }
    if (normalized.length > 10) {
      normalized = normalized.substring(0, 10);
    }

    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }
}

class _AuthBoundField extends StatefulWidget {
  const _AuthBoundField({
    required this.state,
    required this.stateKey,
    required this.password,
    required this.placeholder,
    required this.keyboardType,
    required this.style,
    this.maxLength,
    this.leading,
    this.trailingHidden,
    this.trailingVisible,
    this.trailingAction,
    this.lengthEvent,
  });

  final AuthState state;
  final String stateKey;
  final bool password;
  final String placeholder;
  final TextInputType keyboardType;
  final Map<String, dynamic> style;
  final int? maxLength;
  final Widget? leading;
  final Widget? trailingHidden;
  final Widget? trailingVisible;
  final Widget? trailingAction;
  final Map<String, dynamic>? lengthEvent;

  @override
  State<_AuthBoundField> createState() => _AuthBoundFieldState();
}

class _AuthBoundFieldState extends State<_AuthBoundField> {
  late final TextEditingController _controller;

  String? _lastLengthEventValue;
  bool _lengthEventConsumed = false;

  void _dispatchLengthEvent(String value) {
    final event = widget.lengthEvent;
    final length = (event?['length'] as num?)?.toInt();
    final actionRef = event?['actionRef']?.toString();
    final once = event?['once'] == true;
    final skipIfStateKey = event?['skipIfStateKey']?.toString().trim();

    if (length == null ||
        length <= 0 ||
        actionRef == null ||
        actionRef.isEmpty) {
      return;
    }

    if (skipIfStateKey != null &&
        skipIfStateKey.isNotEmpty &&
        widget.state.read(skipIfStateKey) == true) {
      return;
    }

    if (value.length != length) {
      if (!once) {
        _lastLengthEventValue = null;
      }
      return;
    }

    if ((once && _lengthEventConsumed) ||
        _lastLengthEventValue == value ||
        widget.state.isActionLoading(actionRef)) {
      return;
    }

    _lastLengthEventValue = value;
    if (once) {
      _lengthEventConsumed = true;
    }
    unawaited(widget.state.dispatch(actionRef));
  }

  @override
  void initState() {
    super.initState();

    _controller = TextEditingController(
      text: widget.state.read(widget.stateKey)?.toString() ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _AuthBoundField oldWidget) {
    super.didUpdateWidget(oldWidget);

    final value = widget.state.read(widget.stateKey)?.toString() ?? '';

    if (_controller.text != value && !_controller.selection.isValid) {
      _controller.text = value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;

    final radius = style['_resolvedBorderRadius'] as double;

    final height = style['_resolvedHeight'] as double;

    final borderWidth = style['_resolvedBorderWidth'] as double;

    final horizontalPadding = style['_resolvedHorizontalPadding'] as double;

    final touchTarget = style['_resolvedTouchTarget'] as double;

    final fill = style['_resolvedBackgroundColor'] as Color;

    final border = style['_resolvedBorderColor'] as Color;

    final focus = style['_resolvedFocusBorderColor'] as Color;

    final textColor = style['_resolvedTextColor'] as Color;

    final placeholder = style['_resolvedPlaceholderColor'] as Color;

    final fontSize = style['fontSize'] as double;

    final fontWeight = style['fontWeight'] as FontWeight;

    final error = widget.state.fieldErrors[widget.stateKey];

    Widget? trailing;

    if (widget.password) {
      final visible = widget.state.passwordVisible(widget.stateKey);

      final icon = visible ? widget.trailingVisible : widget.trailingHidden;

      if (icon != null) {
        trailing = Semantics(
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              widget.state.togglePassword(widget.stateKey);

              setState(() {});
            },
            child: SizedBox(
              width: touchTarget,
              height: touchTarget,
              child: Center(child: icon),
            ),
          ),
        );
      }
    } else {
      trailing = widget.trailingAction;
    }

    return SizedBox(
      height: error == null ? height : null,
      child: TextField(
        controller: _controller,
        keyboardType: widget.keyboardType,
        obscureText:
            widget.password && !widget.state.passwordVisible(widget.stateKey),
        maxLength: widget.maxLength,
        inputFormatters: widget.keyboardType == TextInputType.phone
            ? const <TextInputFormatter>[_PhoneNumberFormatter()]
            : (widget.keyboardType == TextInputType.number
                ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly]
                : null),
        onChanged: (value) {
          widget.state.write(widget.stateKey, value);
          _dispatchLengthEvent(value);
        },
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: fontWeight,
        ),
        decoration: InputDecoration(
          counterText: '',
          hintText: widget.placeholder,
          hintStyle: TextStyle(
            color: placeholder,
            fontSize: fontSize,
            fontWeight: fontWeight,
          ),
          prefixIcon: widget.leading == null
              ? null
              : SizedBox(
                  width: touchTarget,
                  height: touchTarget,
                  child: Center(child: widget.leading!),
                ),
          prefixIconConstraints: BoxConstraints(
            minWidth: touchTarget,
            minHeight: touchTarget,
          ),
          suffixIcon: trailing,
          suffixIconConstraints: trailing == null
              ? null
              : BoxConstraints(minWidth: touchTarget, minHeight: touchTarget),
          contentPadding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          filled: true,
          fillColor: fill,
          errorText: error,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: border, width: borderWidth),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: focus, width: borderWidth),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.error,
              width: borderWidth,
            ),
          ),
        ),
      ),
    );
  }
}

class _SchemaOtpInput extends StatefulWidget {
  const _SchemaOtpInput({
    required this.state,
    required this.stateKey,
    required this.digitCount,
    required this.style,
    this.lengthEvent,
  });

  final AuthState state;
  final String stateKey;
  final int digitCount;
  final Map<String, dynamic> style;
  final Map<String, dynamic>? lengthEvent;

  @override
  State<_SchemaOtpInput> createState() => _SchemaOtpInputState();
}

class _SchemaOtpInputState extends State<_SchemaOtpInput> {
  late final List<TextEditingController> _controllers;

  late final List<FocusNode> _focusNodes;

  String? _lastLengthEventValue;
  bool _lengthEventConsumed = false;

  @override
  void initState() {
    super.initState();

    final existing = widget.state.read(widget.stateKey)?.toString() ?? '';

    _controllers = List<TextEditingController>.generate(
      widget.digitCount,
      (index) => TextEditingController(
        text: index < existing.length ? existing[index] : '',
      ),
    );

    _focusNodes = List<FocusNode>.generate(
      widget.digitCount,
      (_) => FocusNode(),
    );
  }

  void _sync() {
    final value = _controllers.map((controller) => controller.text).join();

    widget.state.write(widget.stateKey, value);

    final event = widget.lengthEvent;
    final length = (event?['length'] as num?)?.toInt();
    final actionRef = event?['actionRef']?.toString();
    final once = event?['once'] == true;
    final skipIfStateKey = event?['skipIfStateKey']?.toString().trim();

    if (length == null ||
        length <= 0 ||
        actionRef == null ||
        actionRef.isEmpty) {
      return;
    }

    if (skipIfStateKey != null &&
        skipIfStateKey.isNotEmpty &&
        widget.state.read(skipIfStateKey) == true) {
      return;
    }

    if (value.length != length) {
      if (!once) {
        _lastLengthEventValue = null;
      }
      return;
    }

    if ((once && _lengthEventConsumed) ||
        _lastLengthEventValue == value ||
        widget.state.isActionLoading(actionRef)) {
      return;
    }

    _lastLengthEventValue = value;
    if (once) {
      _lengthEventConsumed = true;
    }
    unawaited(widget.state.dispatch(actionRef));
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }

    for (final node in _focusNodes) {
      node.dispose();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final boxSize = (widget.style['boxSize'] as num?)?.toDouble() ?? 42;

    final gap = (widget.style['gap'] as num?)?.toDouble() ?? 7;

    final radius = (widget.style['borderRadius'] as num?)?.toDouble() ?? 9;

    final borderColor = _color(widget.style['borderColor'])!;
    final focusBorderColor = _color(widget.style['focusBorderColor'])!;
    final textColor = _color(widget.style['textColor'])!;
    final fillColor =
        _color(widget.style['backgroundColor']) ?? Colors.transparent;

    final row = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widget.digitCount; i++) ...[
          SizedBox(
            width: boxSize,
            height: boxSize,
            child: TextField(
              controller: _controllers[i],
              focusNode: _focusNodes[i],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 1,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: InputDecoration(
                counterText: '',
                contentPadding: EdgeInsets.zero,
                filled: true,
                fillColor: fillColor,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(radius),
                  borderSide: BorderSide(color: borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(radius),
                  borderSide: BorderSide(
                    color: focusBorderColor,
                    width: 2,
                  ),
                ),
              ),
              style: TextStyle(
                color: textColor,
                fontSize: (widget.style['fontSize'] as num?)?.toDouble(),
                fontWeight: FontWeight.w800,
              ),
              onChanged: (value) {
                _sync();

                if (value.isNotEmpty && i < widget.digitCount - 1) {
                  _focusNodes[i + 1].requestFocus();
                }

                if (value.isEmpty && i > 0) {
                  _focusNodes[i - 1].requestFocus();
                }
              },
            ),
          ),
          if (i < widget.digitCount - 1) SizedBox(width: gap),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: row,
          ),
        );
      },
    );
  }

  Color? _color(dynamic raw) {
    final text = raw?.toString();

    if (text == null) {
      return null;
    }

    if (text.startsWith('#')) {
      var hex = text.substring(1);

      if (hex.length == 6) {
        hex = 'FF$hex';
      }

      if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }

    final match = RegExp(
      r'rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)(?:\s*,\s*([0-9.]+))?\s*\)',
    ).firstMatch(text);

    if (match == null) {
      return null;
    }

    return Color.fromRGBO(
      double.parse(match.group(1)!).round(),
      double.parse(match.group(2)!).round(),
      double.parse(match.group(3)!).round(),
      match.group(4) == null ? 1 : double.parse(match.group(4)!),
    );
  }
}
