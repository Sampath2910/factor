import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../state/app_state.dart';
import '../services/schema_patch.dart';
import 'action_registry.dart';
import 'component_registry.dart';
import 'parameter_card.dart';
import 'sdui_network_image_cache.dart';
import 'style.dart';
import 'schema_guard.dart';
import 'schema_runtime.dart';
import 'efactor_device_loader.dart';

/// Signature for custom component builders in the SDUI renderer.
typedef SduiComponentBuilderFunc =
    Widget Function(
      BuildContext context,
      Map<String, dynamic> node,
      Map<String, dynamic> props,
      SduiStyle style,
      List<Map<String, dynamic>> children,
      String? groupBinding,
    );

/// Generic server-driven recursive layout & component renderer.
class SduiRenderer {
  SduiRenderer(this.state);

  final AppState state;

  final Map<String, (String, Widget)> _parameterCardCache =
      <String, (String, Widget)>{};

  SchemaRuntime get runtime => state.schemaRuntime;

  double _responsiveViewportWidth(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (runtime.useSafeArea != true) return size.width;
    final padding = MediaQuery.viewPaddingOf(context);
    return (size.width - padding.left - padding.right)
        .clamp(0.0, double.infinity)
        .toDouble();
  }

  double _responsiveViewportHeight(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (runtime.useSafeArea != true) return size.height;
    final padding = MediaQuery.viewPaddingOf(context);
    return (size.height - padding.top - padding.bottom)
        .clamp(0.0, double.infinity)
        .toDouble();
  }

  String _responsiveOrientation(BuildContext context) {
    final width = _responsiveViewportWidth(context);
    final height = _responsiveViewportHeight(context);
    return width > height ? 'landscape' : 'portrait';
  }

  bool _isFillDimension(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'fill' ||
        normalized == 'expanded' ||
        normalized == 'matchparent' ||
        normalized == '100%';
  }

  /// Applies a schema-owned fractional width only when the current Flutter
  /// layout actually provides a finite horizontal extent.
  ///
  /// A horizontal SingleChildScrollView intentionally gives its child an
  /// unbounded maxWidth. Using `double.infinity` or a FractionallySizedBox
  /// against that unbounded width produces "BoxConstraints forces an infinite
  /// width". In that situation the child remains intrinsic until a finite
  /// ancestor constrains it.
  Widget _fractionalWidthWithinConstraints({
    required double fraction,
    required Widget child,
  }) {
    final safeFraction = fraction.clamp(0.0, 1.0).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.maxWidth.isFinite) {
          return child;
        }

        final availableWidth = constraints.maxWidth;
        return SizedBox(
          width: availableWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: availableWidth * safeFraction,
              child: child,
            ),
          ),
        );
      },
    );
  }

  Map<String, dynamic> _resolveResponsiveNode(
    BuildContext context,
    Map<String, dynamic> source,
  ) {
    final width = _responsiveViewportWidth(context);
    final height = _responsiveViewportHeight(context);
    final orientation = _responsiveOrientation(context);

    var result = runtime.resolveResponsiveMap(
      source,
      width,
      logicalHeight: height,
      orientation: orientation,
    );

    final rawProperties = result['properties'];
    if (rawProperties is Map) {
      var properties = runtime.resolveResponsiveMap(
        Map<String, dynamic>.from(rawProperties.cast<dynamic, dynamic>()),
        width,
        logicalHeight: height,
        orientation: orientation,
      );

      final rawNestedProps = properties['props'];
      if (rawNestedProps is Map) {
        properties = Map<String, dynamic>.from(properties);
        properties['props'] = runtime.resolveResponsiveMap(
          Map<String, dynamic>.from(rawNestedProps.cast<dynamic, dynamic>()),
          width,
          logicalHeight: height,
          orientation: orientation,
        );
      }

      result = Map<String, dynamic>.from(result);
      result['properties'] = properties;
    }

    return result;
  }

  Map<String, dynamic> _deepMergeMaps(
    Map<String, dynamic> base,
    Map<String, dynamic> override,
  ) {
    final result = Map<String, dynamic>.from(base);
    for (final entry in override.entries) {
      final current = result[entry.key];
      final incoming = entry.value;
      if (current is Map && incoming is Map) {
        result[entry.key] = _deepMergeMaps(
          Map<String, dynamic>.from(current),
          Map<String, dynamic>.from(incoming),
        );
      } else {
        result[entry.key] = incoming;
      }
    }
    return result;
  }

  Map<String, dynamic> _resolveNodeStyle({
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
  }) {
    final direct = node['style'] is Map
        ? Map<String, dynamic>.from(node['style'] as Map)
        : <String, dynamic>{};

    final styleRef =
        (node['styleRef'] ??
                props['styleRef'] ??
                (node['properties'] is Map
                    ? (node['properties'] as Map)['styleRef']
                    : null))
            ?.toString()
            .trim();

    Map<String, dynamic> referenced = <String, dynamic>{};
    if (styleRef != null && styleRef.isNotEmpty) {
      referenced = SchemaRuntime.resolveComponentStyle(state.schema, styleRef);
    }

    // The visual contract is: referenced design-system style first, then
    // concrete node style. Nested parts/gradients are recursively merged.
    //
    // Generic widget-tree responsiveLayout blocks are emitted under
    // properties and may override geometry such as padding/minHeight/maxWidth.
    // Those schema-owned layout values must participate in the final Flutter
    // style instead of being ignored in favour of the base node.style.
    final resolved = _deepMergeMaps(referenced, direct);
    for (final key in const <String>[
      'width',
      'height',
      'minWidth',
      'minHeight',
      'maxWidth',
      'maxHeight',
      'padding',
      'margin',
      'alignment',
      'spacing',
      'overflow',
    ]) {
      if (props.containsKey(key)) {
        resolved[key] = props[key];
      }
    }
    _applyLiveOnlineColors(resolved, node: node, props: props);
    return resolved;
  }

  bool? _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'online' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'offline' || text == 'off') {
      return false;
    }
    return null;
  }

  bool _isOnlineStateBinding(String? binding) {
    final normalized = binding?.trim().toLowerCase() ?? '';
    return normalized == 'state.online' ||
        normalized == 'state.online.value' ||
        normalized == 'state.islocal' ||
        normalized == 'state.islocalonline' ||
        normalized == 'state.localonline' ||
        normalized == 'state.deviceconnectivity.online';
  }

  bool _isOnlineLabelBinding(String? binding) {
    final normalized = binding?.trim().toLowerCase() ?? '';
    return normalized == 'state.onlinelabel' ||
        normalized == 'state.connectivitylabel' ||
        normalized == 'state.deviceconnectivity.label';
  }

  String? _themeConnectivityColor({required bool online}) {
    final colors = state.schema['theme']?['colors'];
    if (colors is! Map) return null;
    final keys = online
        ? const <String>['success', 'online', 'ok']
        : const <String>['error', 'danger', 'offline'];
    for (final key in keys) {
      final value = colors[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  void _applyLiveOnlineColors(
    Map<String, dynamic> style, {
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
  }) {
    final status = props['status'] is Map
        ? Map<String, dynamic>.from((props['status'] as Map).cast<dynamic, dynamic>())
        : const <String, dynamic>{};
    final binding =
        (props['stateBinding'] ?? node['stateBinding'] ?? status['stateBinding'])
            ?.toString();
    final labelBinding =
        (props['labelBinding'] ??
                props['textBinding'] ??
                status['labelBinding'])
            ?.toString();

    final usesOnlineState =
        _isOnlineStateBinding(binding) || _isOnlineLabelBinding(labelBinding);
    if (!usesOnlineState) return;

    final online = _asBool(state.resolveBinding('state.online'));
    if (online == null) return;

    final hex = _themeConnectivityColor(online: online);
    if (hex == null || hex.isEmpty) return;

    for (final key in const <String>['color', 'textColor', 'backgroundColor']) {
      if (style[key] != null) style[key] = hex;
    }
    final textStyle = style['textStyle'];
    if (textStyle is Map) {
      final next = Map<String, dynamic>.from(textStyle.cast<dynamic, dynamic>());
      if (next['color'] != null) next['color'] = hex;
      style['textStyle'] = next;
    }
  }

  Widget _applyRuntimeContracts({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required Widget child,
  }) {
    final enabled = runtime.isEnabled(node, props, state);
    final binding = (props['binding'] ?? node['binding'])?.toString().trim();
    final controlId = node['id']?.toString().trim();
    final label = runtime.semanticLabel(
      controlId: controlId,
      binding: binding,
      fallback:
          (props['semanticLabel'] ??
                  props['label'] ??
                  props['text'] ??
                  node['label'])
              ?.toString(),
    );
    final role = runtime.semanticRole(controlId: controlId, binding: binding);

    // Resolve the complete schema-owned style once.
    //
    // _resolveNodeStyle() already applies:
    // designSystem.componentStyles[styleRef] -> concrete node.style.
    //
    // Disabled rendering must use the same resolved style contract rather
    // than bypassing styleRef and inspecting only node['style'].
    //
    // No Flutter-owned opacity/default is introduced here.
    final resolvedStyle = _resolveNodeStyle(node: node, props: props);

    Widget result = child;
    if (!enabled) {
      final disabledStyle = resolvedStyle['disabled'];
      final opacity = disabledStyle is Map
          ? _schemaNumber(disabledStyle['opacity'])
          : _schemaNumber(props['disabledOpacity']);
      if (opacity == null) {
        return SchemaIssueWidget(
          title: 'Missing disabled-state schema',
          details: const [
            'style.disabled.opacity or properties.disabledOpacity â€” required when this node is disabled',
          ],
          componentType: node['type']?.toString(),
          binding: binding,
        );
      }
      result = IgnorePointer(
        child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: result),
      );
    }

    final minimumTouchTarget = runtime.minimumTouchTarget;
    if (minimumTouchTarget > 0 &&
        (role == 'button' ||
            role == 'switch' ||
            role == 'slider' ||
            props['interactive'] == true)) {
      // Explicit schema geometry is authoritative. Use the complete resolved
      // style so dimensions supplied by styleRef are not missed.
      final hasExplicitWidth =
          props['width'] != null ||
          props['minWidth'] != null ||
          props['maxWidth'] != null ||
          resolvedStyle['width'] != null ||
          resolvedStyle['minWidth'] != null ||
          resolvedStyle['maxWidth'] != null;
      final hasExplicitHeight =
          props['height'] != null ||
          props['minHeight'] != null ||
          props['maxHeight'] != null ||
          resolvedStyle['height'] != null ||
          resolvedStyle['minHeight'] != null ||
          resolvedStyle['maxHeight'] != null;

      if (!hasExplicitWidth || !hasExplicitHeight) {
        result = ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: hasExplicitWidth ? 0 : minimumTouchTarget,
            minHeight: hasExplicitHeight ? 0 : minimumTouchTarget,
          ),
          child: result,
        );
      }
    }

    if (label != null || role != null) {
      result = Semantics(
        label: label,
        enabled: enabled,
        button: role == 'button',
        toggled: role == 'switch'
            ? SchemaRuntime(
                state.schema,
              ).evaluateCondition(binding, state, defaultValue: false)
            : null,
        textField: role == 'textbox' || role == 'textfield',
        child: result,
      );
    }
    return result;
  }

  /// Register custom component builder dynamically into ComponentRegistry.
  void registerBuilder(String componentType, SduiComponentBuilderFunc builder) {
    ComponentRegistry.instance.register(
      componentType,
      ({
        required context,
        required node,
        required props,
        required style,
        required children,
        required state,
        required renderer,
        groupBinding,
      }) => builder(context, node, props, style, children, groupBinding),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ public entry point â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget build(
    BuildContext context,
    Map<String, dynamic>? node, [
    String? groupBinding,
  ]) {
    if (node == null) return const SizedBox.shrink();

    // Resolve responsiveLayout/responsiveOverrides from the actual logical
    // viewport before reading properties, style, children or component type.
    // This deliberately does not use a nested/padded LayoutBuilder width.
    final effectiveNode = _resolveResponsiveNode(context, node);

    final properties = Map<String, dynamic>.from(
      effectiveNode['properties'] as Map? ?? const {},
    );
    final rawNestedProps = properties['props'];
    final nestedProps = rawNestedProps is Map
        ? Map<String, dynamic>.from(rawNestedProps)
        : const <String, dynamic>{};

    // Schema widget nodes store visual/control values under
    // properties.props, while binding/events remain under properties.
    // Merge both levels before component resolution. This is schema-path
    // normalization, not a visual fallback.
    final props = <String, dynamic>{
      ...properties,
      ...nestedProps,
      if (!nestedProps.containsKey('binding') && properties['binding'] != null)
        'binding': properties['binding'],
      if (!nestedProps.containsKey('events') && properties['events'] != null)
        'events': properties['events'],
    };
    if (!runtime.isVisible(effectiveNode, props, state)) {
      return const SizedBox.shrink();
    }

    // â”€â”€ Suppress developer-only actions (ui.edit = CMS editor) â”€â”€
    if (_isDevOnlyNode(effectiveNode, props)) return const SizedBox.shrink();

    final style = SduiStyle(
      _resolveNodeStyle(node: effectiveNode, props: props),
    );
    final children = List<Map<String, dynamic>>.from(
      effectiveNode['children'] as List? ?? const [],
    );
    final rawNodeType = effectiveNode['type']?.toString() ?? '';
    final nodeType = rawNodeType.trim().toLowerCase();

    // 1. Reactive AnimatedBuilder wrappers for nodes with state bindings
    if (nodeType == 'button') {
      return AnimatedBuilder(
        animation: state,
        builder: (ctx, _) =>
            _button(ctx, effectiveNode, props, style, children, groupBinding),
      );
    }

    if (nodeType == 'text' && props['textBinding'] != null) {
      return AnimatedBuilder(
        animation: state,
        builder: (ctx, _) {
          final liveStyle = SduiStyle(
            _resolveNodeStyle(node: effectiveNode, props: props),
          );
          return _text(effectiveNode, props, liveStyle);
        },
      );
    }

    if ((nodeType == 'container' || nodeType == 'card') &&
        (props['widthBinding'] != null || props['stateBinding'] != null)) {
      return AnimatedBuilder(
        animation: state,
        builder: (ctx, _) {
          final liveStyle = SduiStyle(
            _resolveNodeStyle(node: effectiveNode, props: props),
          );
          return _container(
            ctx,
            effectiveNode,
            props,
            liveStyle,
            children,
            groupBinding,
          );
        },
      );
    }

    // 2. Recursive layout primitives
    Widget? layoutWidget;
    switch (nodeType) {
      case 'container':
      case 'card':
        layoutWidget = _container(
          context,
          effectiveNode,
          props,
          style,
          children,
          groupBinding,
        );
        break;
      case 'column':
        layoutWidget = _flex(
          context,
          Axis.vertical,
          props,
          style,
          children,
          groupBinding,
        );
        break;
      case 'row':
        layoutWidget = _flex(
          context,
          Axis.horizontal,
          props,
          style,
          children,
          groupBinding,
        );
        break;
      case 'stack':
        layoutWidget = _stack(context, props, style, children, groupBinding);
        break;
      case 'padding':
        layoutWidget = Padding(
          padding: style.padding,
          child: children.length == 1
              ? build(context, children.first, groupBinding)
              : Column(
                  children: _buildChildren(
                    context,
                    children,
                    0,
                    Axis.vertical,
                    groupBinding,
                  ),
                ),
        );
        break;
      case 'expanded':
        // Do not create Expanded here. The immediate parent Flex applies the
        // schema flex request only after it knows whether the main axis is
        // bounded. This keeps schema-driven layouts valid in scroll views and
        // shrink-wrapped rows.
        layoutWidget = children.length == 1
            ? build(context, children.first, groupBinding)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: _buildChildren(
                  context,
                  children,
                  0,
                  Axis.vertical,
                  groupBinding,
                ),
              );
        break;
      case 'align':
        layoutWidget = Align(
          alignment: style.alignment ?? Alignment.center,
          child: children.length == 1
              ? build(context, children.first, groupBinding)
              : Column(
                  children: _buildChildren(
                    context,
                    children,
                    0,
                    Axis.vertical,
                    groupBinding,
                  ),
                ),
        );
        break;
      case 'positioned':
        final pos =
            (effectiveNode['properties'] as Map?)?['position'] ??
            (effectiveNode['style'] as Map?)?['position'];
        if (pos is Map) {
          layoutWidget = Positioned(
            top: (pos['top'] as num?)?.toDouble(),
            right: (pos['right'] as num?)?.toDouble(),
            bottom: (pos['bottom'] as num?)?.toDouble(),
            left: (pos['left'] as num?)?.toDouble(),
            child: children.length == 1
                ? build(context, children.first, groupBinding)
                : Column(
                    children: _buildChildren(
                      context,
                      children,
                      0,
                      Axis.vertical,
                      groupBinding,
                    ),
                  ),
          );
        } else {
          layoutWidget = children.length == 1
              ? build(context, children.first, groupBinding)
              : Column(
                  children: _buildChildren(
                    context,
                    children,
                    0,
                    Axis.vertical,
                    groupBinding,
                  ),
                );
        }
        break;
      case 'sizedbox':
        layoutWidget = LayoutBuilder(
          builder: (context, constraints) {
            final width = _isFillDimension(props['width'] ?? style.s['width'])
                ? (constraints.hasBoundedWidth ? constraints.maxWidth : null)
                : style.dim('width') ?? (props['width'] as num?)?.toDouble();
            final height =
                _isFillDimension(props['height'] ?? style.s['height'])
                ? (constraints.hasBoundedHeight ? constraints.maxHeight : null)
                : style.dim('height') ?? (props['height'] as num?)?.toDouble();
            return SizedBox(
              width: width,
              height: height,
              child: children.isNotEmpty
                  ? build(context, children.first, groupBinding)
                  : null,
            );
          },
        );
        break;
      case 'listview':
        layoutWidget = _listView(context, props, style, children, groupBinding);
        break;
      case 'singlechildscrollview':
        layoutWidget = SingleChildScrollView(
          padding: style.padding,
          child: children.length == 1
              ? build(context, children.first, groupBinding)
              : Column(
                  children: _buildChildren(
                    context,
                    children,
                    0,
                    Axis.vertical,
                    groupBinding,
                  ),
                ),
        );
        break;
      case 'text':
        layoutWidget = _text(effectiveNode, props, style);
        break;
      case 'icon':
        layoutWidget = _icon(props, style);
        break;
      case 'image':
      case 'networkimage':
      case 'img':
        layoutWidget = _image(props, style);
        break;
      case 'schemacontrollist':
        layoutWidget = _controlList(context, props, style);
        break;
      case 'parametercard':
        // ParameterCard is the control shell painted by [parameterCard].
        // A copied widget-tree node of this type is only a wrapper. Render
        // its children. Do not ask the component registry for a type that
        // is not a leaf control.
        layoutWidget = children.isEmpty
            ? const SizedBox.shrink()
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final child in children)
                    build(context, child, groupBinding),
                ],
              );
        break;
      case 'progress':
        layoutWidget = _progressIndicator(effectiveNode, props, style);
        break;
    }

    if (layoutWidget != null) {
      // width/height/flex intentions are resolved by the parent Flex where
      // actual constraints are available.
      return _applyRuntimeContracts(
        context: context,
        node: effectiveNode,
        props: props,
        child: layoutWidget,
      );
    }

    // 3. Pure dynamic resolution from ComponentRegistry
    final w = ComponentRegistry.instance.build(
      context: context,
      node: effectiveNode,
      props: props,
      style: style,
      children: children,
      state: state,
      renderer: this,
      groupBinding: groupBinding,
    );

    // width/height/flex intentions are resolved by the parent Flex.
    return _applyRuntimeContracts(
      context: context,
      node: effectiveNode,
      props: props,
      child: w,
    );
  }

  // â”€â”€â”€â”€ Developer-only node detection â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //
  // Do not infer developer-only content from icon names, labels, node ids, or
  // action strings. The schema must explicitly declare that intent.
  static bool _isDevOnlyNode(
    Map<String, dynamic> node,
    Map<String, dynamic> props,
  ) {
    return node['developerOnly'] == true ||
        props['developerOnly'] == true ||
        node['visibility'] == 'developerOnly' ||
        props['visibility'] == 'developerOnly';
  }

  List<Widget> _buildChildren(
    BuildContext context,
    List<Map<String, dynamic>> children,
    double spacing,
    Axis axis, [
    String? groupBinding,
  ]) {
    final out = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      out.add(build(context, children[i], groupBinding));
      if (spacing > 0 && i < children.length - 1) {
        out.add(
          SizedBox(
            width: axis == Axis.horizontal ? spacing : 0,
            height: axis == Axis.vertical ? spacing : 0,
          ),
        );
      }
    }
    return out;
  }

  Gradient? _resolveGradient(Map<String, dynamic> node, SduiStyle style) {
    // The active widget-tree style is authoritative. Do not infer a design
    // style from node ids or substitute a renderer-owned gradient.
    return style.gradient;
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ container / card â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _container(
    BuildContext context,
    Map<String, dynamic> node,
    Map<String, dynamic> props,
    SduiStyle style,
    List<Map<String, dynamic>> children, [
    String? groupBinding,
  ]) {
    final resolvedGradient = _resolveGradient(node, style);
    final declaredLegacyGradient = style.s['gradient'] is Map;
    final declaredBackground = style.s['background'];
    final declaredBackgroundType = declaredBackground is Map
        ? declaredBackground['type']?.toString()
        : null;
    final declaresGradient =
        declaredLegacyGradient ||
        declaredBackgroundType == 'linearGradient' ||
        declaredBackgroundType == 'radialGradient' ||
        declaredBackgroundType == 'layered';
    if (declaresGradient && resolvedGradient == null) {
      return SchemaIssueWidget(
        title: 'Invalid gradient schema',
        details: const [
          'Declared gradient requires valid colors/stops and explicit begin/end, angle, or radial center/radius as applicable',
        ],
        componentType: node['type']?.toString(),
      );
    }

    Widget child = _buildContainerContent(
      context: context,
      props: props,
      style: style,
      children: children,
      groupBinding: groupBinding,
    );

    final rawHeight = props['height'] ?? style.s['height'];
    final fillHeight = _isFillDimension(rawHeight);

    // Preserve the existing working scroll/layout structure.
    // A vertical SingleChildScrollView gives its child an unbounded maximum
    // height. Converting schema `matchParent` to double.infinity here creates
    // an illegal BoxConstraints(h=Infinity) during layout. In that situation
    // the renderer must leave height unconstrained and let the existing parent
    // ConstrainedBox/Flex/PageView provide the finite viewport size.
    //
    // This changes only the `matchParent` height interpretation; explicit
    // numeric/schema heights continue to behave exactly as before.
    final height = fillHeight
        ? null
        : style.dim('height') ??
              (rawHeight is num ? rawHeight.toDouble() : null);

    final widthBindingKey = props['widthBinding'] as String?;
    if (widthBindingKey != null) {
      final resolved = state.resolveBinding(widthBindingKey);
      final raw = resolved is num
          ? resolved.toDouble()
          : double.tryParse(resolved?.toString() ?? '');

      // The schema contract names page progress explicitly. Its stored value
      // may be absent, a 0..1 fraction, or a 0..100 percentage. When the
      // binding is pageProgressPercent, activePageIndex/pages are the
      // authoritative schema state and keep the bar synchronized immediately.
      final isPageProgressBinding =
          widthBindingKey.split('.').last == 'pageProgressPercent';
      final double fraction;
      if (isPageProgressBinding && state.pages.isNotEmpty) {
        fraction = ((state.activePageIndex + 1) / state.pages.length).clamp(
          0.0,
          1.0,
        );
      } else if (raw == null) {
        fraction = 0.0;
      } else {
        fraction = (raw > 1 ? raw / 100.0 : raw).clamp(0.0, 1.0);
      }

      return _fractionalWidthWithinConstraints(
        fraction: fraction,
        child: Container(
          height: height,
          constraints: BoxConstraints(
            minWidth: style.dim('minWidth') ?? 0,
            minHeight:
                style.dim('minHeight') ??
                (props['minHeight'] as num?)?.toDouble() ??
                0,
          ),
          padding: style.padding,
          margin: style.margin,
          decoration: style.decoration,
          clipBehavior:
              props['clipBehavior'] == 'hardEdge' && style.decoration != null
              ? Clip.hardEdge
              : Clip.none,
          child: child,
        ),
      );
    }

    final widthPercent = (props['widthPercent'] as num?)?.toDouble();
    if (widthPercent != null) {
      final fraction = (widthPercent / 100.0).clamp(0.0, 1.0);
      return _fractionalWidthWithinConstraints(
        fraction: fraction,
        child: Container(
          height: height,
          constraints: BoxConstraints(
            minWidth: style.dim('minWidth') ?? 0,
            minHeight:
                style.dim('minHeight') ??
                (props['minHeight'] as num?)?.toDouble() ??
                0,
          ),
          padding: style.padding,
          margin: style.margin,
          decoration: style.decoration,
          clipBehavior:
              props['clipBehavior'] == 'hardEdge' && style.decoration != null
              ? Clip.hardEdge
              : Clip.none,
          child: child,
        ),
      );
    }

    final rawWidth = props['width'] ?? style.s['width'];
    final fillWidth = _isFillDimension(rawWidth);

    BoxDecoration? effectiveDecoration;
    if (resolvedGradient != null) {
      effectiveDecoration = (style.decoration ?? const BoxDecoration())
          .copyWith(gradient: resolvedGradient, color: null);
    } else {
      effectiveDecoration = style.decoration;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = fillWidth
            ? (constraints.hasBoundedWidth ? constraints.maxWidth : null)
            : style.dim('width') ??
                  (rawWidth is num ? rawWidth.toDouble() : null);
        final boundedHeight = fillHeight && constraints.hasBoundedHeight
            ? constraints.maxHeight
            : height;

        final minWidth =
            style.dim('minWidth') ??
            (props['minWidth'] is num
                ? (props['minWidth'] as num).toDouble()
                : 0.0);
        final minHeight =
            style.dim('minHeight') ??
            (props['minHeight'] is num
                ? (props['minHeight'] as num).toDouble()
                : 0.0);
        final maxWidth =
            style.dim('maxWidth') ??
            (props['maxWidth'] is num
                ? (props['maxWidth'] as num).toDouble()
                : double.infinity);
        final maxHeight =
            style.dim('maxHeight') ??
            (props['maxHeight'] is num
                ? (props['maxHeight'] as num).toDouble()
                : double.infinity);

        return Container(
          width: width,
          height: boundedHeight,
          constraints: BoxConstraints(
            minWidth: minWidth,
            minHeight: minHeight,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
          ),
          padding: style.padding,
          margin: style.margin,
          alignment: style.alignment,
          decoration: effectiveDecoration,
          clipBehavior:
              ((props['clipBehavior'] == 'hardEdge') ||
                  style.s['overflow']?.toString().toLowerCase() == 'clip' ||
                  style.s['overflow']?.toString().toLowerCase() == 'hidden')
              ? Clip.hardEdge
              : Clip.none,
          child: child,
        );
      },
    );
  }

  /// Builds the children of a schema Container/Card using the layout contract
  /// declared on that node. Web Studio emits container layouts such as
  /// `grid: auto / 1fr / auto` for the brand strip and `1fr / auto` for hero
  /// content. Treating every multi-child Container as a Column clips or hides
  /// the title/status portions of those compact cards.
  Widget _buildContainerContent({
    required BuildContext context,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    String? groupBinding,
  }) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) {
      return build(context, children.first, groupBinding);
    }

    final rawLayout = props['layout'] ?? style.s['layout'];
    final layout = rawLayout is Map
        ? Map<String, dynamic>.from(rawLayout)
        : const <String, dynamic>{};

    final layoutType = (layout['type'] ?? rawLayout)
        ?.toString()
        .trim()
        .toLowerCase();
    final flexDirection =
        (props['flexDirection'] ??
                style.s['flexDirection'] ??
                layout['direction'])
            ?.toString()
            .trim()
            .toLowerCase();

    final gap =
        _schemaNumber(
          props['gap'] ?? props['spacing'] ?? style.s['gap'] ?? layout['gap'],
        ) ??
        0;

    CrossAxisAlignment crossAxis() {
      final raw =
          (layout['alignItems'] ??
                  props['alignItems'] ??
                  props['crossAxisAlignment'])
              ?.toString()
              .trim()
              .toLowerCase();
      return switch (raw) {
        'start' || 'flex-start' => CrossAxisAlignment.start,
        'end' || 'flex-end' => CrossAxisAlignment.end,
        'stretch' => CrossAxisAlignment.stretch,
        _ => CrossAxisAlignment.center,
      };
    }

    MainAxisAlignment mainAxis() {
      final raw =
          (layout['justifyContent'] ??
                  props['justifyContent'] ??
                  props['mainAxisAlignment'])
              ?.toString()
              .trim()
              .toLowerCase();
      return switch (raw) {
        'center' => MainAxisAlignment.center,
        'end' || 'flex-end' => MainAxisAlignment.end,
        'space-between' || 'spacebetween' => MainAxisAlignment.spaceBetween,
        'space-around' || 'spacearound' => MainAxisAlignment.spaceAround,
        'space-evenly' || 'spaceevenly' => MainAxisAlignment.spaceEvenly,
        _ => MainAxisAlignment.start,
      };
    }

    final columns = layout['columns'];
    final isHorizontalGrid =
        layoutType == 'grid' && columns is List && columns.isNotEmpty;

    final isHorizontalFlex =
        flexDirection == 'row' ||
        layoutType == 'row' ||
        layoutType == 'horizontal';

    if (isHorizontalGrid || isHorizontalFlex) {
      final widgets = <Widget>[];
      for (var i = 0; i < children.length; i++) {
        Widget built = build(context, children[i], groupBinding);

        // CSS-grid's `1fr` column consumes remaining width; `auto` stays
        // intrinsic. This is fully schema driven and works for any future
        // brand/hero/header card using the same grid contract.
        if (isHorizontalGrid && i < columns.length) {
          final track = columns[i].toString().trim().toLowerCase();
          final fr = RegExp(r'^([0-9]*\\.?[0-9]+)?fr$').firstMatch(track);
          if (fr != null) {
            final weight = double.tryParse(fr.group(1) ?? '1') ?? 1;
            built = Expanded(
              flex: (weight * 100).round().clamp(1, 100000),
              child: built,
            );
          }
        }

        widgets.add(built);
        if (gap > 0 && i < children.length - 1) {
          widgets.add(SizedBox(width: gap));
        }
      }

      return Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: mainAxis(),
        crossAxisAlignment: crossAxis(),
        children: widgets,
      );
    }

    final widgets = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      widgets.add(build(context, children[i], groupBinding));
      if (gap > 0 && i < children.length - 1) {
        widgets.add(SizedBox(height: gap));
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: mainAxis(),
      crossAxisAlignment: crossAxis(),
      children: widgets,
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ flex â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _flex(
    BuildContext context,
    Axis axis,
    Map<String, dynamic> props,
    SduiStyle style,
    List<Map<String, dynamic>> children, [
    String? groupBinding,
  ]) {
    final spacing = (props['spacing'] as num?)?.toDouble() ?? 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final incomingMainAxisBounded = axis == Axis.horizontal
            ? constraints.hasBoundedWidth
            : constraints.hasBoundedHeight;

        final scrollableOnMainAxis = props['scrollable'] == true;

        // A page-mode horizontal ListView builds a PageView. PageView is
        // already the viewport for this region and each page owns its own
        // vertical scrolling. Wrapping that PageView in a same-axis parent
        // SingleChildScrollView removes its finite height and causes:
        // "Horizontal viewport was given unbounded height".
        // This decision is based only on schema type/properties.
        final containsPagedViewport = children.any((childNode) {
          final effectiveChildNode = _resolveResponsiveNode(context, childNode);
          final childType =
              effectiveChildNode['type']?.toString().trim().toLowerCase() ?? '';
          final rawChildProperties = effectiveChildNode['properties'];
          final childProperties = rawChildProperties is Map
              ? Map<String, dynamic>.from(rawChildProperties)
              : const <String, dynamic>{};
          final rawChildProps = childProperties['props'];
          final childProps = <String, dynamic>{
            ...childProperties,
            if (rawChildProps is Map)
              ...Map<String, dynamic>.from(rawChildProps),
          };
          return childType == 'listview' &&
              childProps['physics']?.toString().toLowerCase() == 'page' &&
              childProps['scrollDirection']?.toString().toLowerCase() ==
                  'horizontal';
        });

        final shouldWrapInMainAxisScrollView =
            scrollableOnMainAxis && !containsPagedViewport;
        final mainAxisBounded =
            incomingMainAxisBounded && !shouldWrapInMainAxisScrollView;

        // Before laying out a bounded horizontal row, inspect only the
        // schema-declared direct-child widths. If those preferred widths plus
        // spacing cannot fit, eligible content children are allowed to
        // participate in loose flex negotiation below. This is constraint
        // driven: no component ids, account ids, screen sizes, or magic widths
        // are used.
        var declaredFixedWidthOverflow = false;
        if (axis == Axis.horizontal &&
            mainAxisBounded &&
            constraints.maxWidth.isFinite) {
          final horizontalInsets =
              style.margin.horizontal + style.padding.horizontal;
          final availableFlexWidth =
              (constraints.maxWidth - horizontalInsets)
                  .clamp(0.0, double.infinity)
                  .toDouble();

          var declaredFixedWidthTotal =
              spacing * (children.length > 1 ? children.length - 1 : 0);

          for (final sourceChildNode in children) {
            final candidateNode = _resolveResponsiveNode(
              context,
              sourceChildNode,
            );

            final rawCandidateProperties = candidateNode['properties'];
            final candidateProperties = rawCandidateProperties is Map
                ? Map<String, dynamic>.from(rawCandidateProperties)
                : const <String, dynamic>{};
            final rawCandidateNestedProps = candidateProperties['props'];
            final candidateProps = <String, dynamic>{
              ...candidateProperties,
              if (rawCandidateNestedProps is Map)
                ...Map<String, dynamic>.from(rawCandidateNestedProps),
            };

            final rawCandidateStyle = candidateNode['style'];
            final candidateStyle = rawCandidateStyle is Map
                ? Map<String, dynamic>.from(rawCandidateStyle)
                : const <String, dynamic>{};

            final candidateType =
                candidateNode['type']?.toString().trim().toLowerCase() ?? '';
            final candidateRequestsExpandedWidth = _isFillDimension(
              candidateProps['width'] ?? candidateStyle['width'],
            );
            final candidateFlex = candidateProps['flex'];
            final candidateAlreadyFlexible =
                candidateRequestsExpandedWidth ||
                candidateType == 'expanded' ||
                (candidateFlex is num && candidateFlex.toInt() > 0);

            if (candidateAlreadyFlexible) continue;

            final declaredWidth = _schemaNumber(
              candidateProps['width'] ?? candidateStyle['width'],
            );
            final declaredMinWidth = _schemaNumber(
              candidateProps['minWidth'] ?? candidateStyle['minWidth'],
            );
            final preferredWidth = declaredWidth ?? declaredMinWidth;

            if (preferredWidth != null && preferredWidth > 0) {
              declaredFixedWidthTotal += preferredWidth;
            }
          }

          declaredFixedWidthOverflow =
              declaredFixedWidthTotal > availableFlexWidth;
        }

        final builtChildren = <Widget>[];
        var appliedFlex = false;

        for (var index = 0; index < children.length; index++) {
          final childNode = children[index];
          final effectiveChildNode = _resolveResponsiveNode(context, childNode);
          Widget child = build(context, effectiveChildNode, groupBinding);

          // A recursively built child may already be wrapped by another
          // component path. Flex children are illegal when this Row/Column
          // receives an unbounded main-axis constraint, such as inside a
          // same-axis SingleChildScrollView. Remove the wrapper here; this
          // parent re-applies schema flex only when constraints permit it.
          if (!mainAxisBounded && child is Flexible) {
            child = child.child;
          }

          final childType =
              effectiveChildNode['type']?.toString().trim().toLowerCase() ?? '';

          final rawProperties = effectiveChildNode['properties'];
          final childProperties = rawProperties is Map
              ? Map<String, dynamic>.from(rawProperties)
              : const <String, dynamic>{};

          final rawNestedProps = childProperties['props'];
          final childProps = <String, dynamic>{
            ...childProperties,
            if (rawNestedProps is Map)
              ...Map<String, dynamic>.from(rawNestedProps),
          };

          final rawStyle = effectiveChildNode['style'];
          final childStyle = rawStyle is Map
              ? Map<String, dynamic>.from(rawStyle)
              : const <String, dynamic>{};

          // A horizontal page-mode ListView is a viewport region. When it is
          // placed in a bounded vertical Flex, it must consume only the
          // remaining height; its individual pages handle their own vertical
          // scrolling. Without this, PageView takes the whole parent height
          // and the progress/pager controls overflow below it.
          final isPagedHorizontalViewport =
              childType == 'listview' &&
              childProps['physics']?.toString().trim().toLowerCase() ==
                  'page' &&
              childProps['scrollDirection']?.toString().trim().toLowerCase() ==
                  'horizontal';

          final requestsExpandedWidth = _isFillDimension(
            childProps['width'] ?? childStyle['width'],
          );
          final requestsExpandedHeight = _isFillDimension(
            childProps['height'] ?? childStyle['height'],
          );

          // Cross-axis expansion must never be represented by Flexible, and
          // double.infinity is legal only when that cross axis is bounded.
          // In a horizontally scrolling parent, for example, a nested Column
          // can receive unbounded width and must remain intrinsic.
          final crossAxisBounded = axis == Axis.horizontal
              ? constraints.hasBoundedHeight
              : constraints.hasBoundedWidth;
          if (crossAxisBounded &&
              axis == Axis.vertical &&
              requestsExpandedWidth) {
            child = SizedBox(width: double.infinity, child: child);
          } else if (crossAxisBounded &&
              axis == Axis.horizontal &&
              requestsExpandedHeight) {
            child = SizedBox(height: double.infinity, child: child);
          }

          int requestedFlex = 0;
          var tight = false;

          final explicitFlex = childProps['flex'];
          if (explicitFlex is num && explicitFlex.toInt() > 0) {
            requestedFlex = explicitFlex.toInt();
          }

          if (childType == 'expanded') {
            requestedFlex = requestedFlex > 0 ? requestedFlex : 1;
            tight = true;
          }

          if (requestsExpandedWidth && axis == Axis.horizontal) {
            requestedFlex = requestedFlex > 0 ? requestedFlex : 1;
            tight = true;
          }

          if (requestsExpandedHeight && axis == Axis.vertical) {
            requestedFlex = requestedFlex > 0 ? requestedFlex : 1;
            tight = true;
          }

          // The page viewport is the flexible content region between the
          // fixed header/brand area and the fixed progress/pager controls.
          // This is derived from the schema's listView + page physics contract,
          // not from any node ID or parameter name.
          if (axis == Axis.vertical && isPagedHorizontalViewport) {
            requestedFlex = requestedFlex > 0 ? requestedFlex : 1;
            tight = true;
          }

          // Bounded horizontal rows use a two-stage sizing policy:
          //
          //   1. In normal conditions, explicit schema widths stay exact and
          //      only unsized content participates in loose flex.
          //   2. If the direct schema-declared fixed widths themselves cannot
          //      fit the runtime width, eligible content/layout nodes with a
          //      preferred width are allowed to shrink proportionally.
          //
          // Explicit fixed leaf buttons remain intrinsic so action groups do
          // not get squeezed below their declared touch geometry. This avoids
          // both failure modes seen historically: oversized rigid rows and
          // over-compressed fixed action buttons.
          if (axis == Axis.horizontal &&
              mainAxisBounded &&
              requestedFlex == 0) {
            final hasExplicitWidth =
                childProps['width'] != null ||
                childProps['minWidth'] != null ||
                childProps['maxWidth'] != null ||
                childStyle['width'] != null ||
                childStyle['minWidth'] != null ||
                childStyle['maxWidth'] != null;

            final canAutoFlex =
                childType == 'column' ||
                childType == 'row' ||
                childType == 'container' ||
                childType == 'card' ||
                childType == 'text' ||
                childType == 'richtext' ||
                childType == 'label' ||
                childType == 'textfield' ||
                childType == 'dropdown' ||
                childType == 'button';

            final fixedLeafControl =
                childType == 'button' && hasExplicitWidth;

            final shouldAutoFlex =
                canAutoFlex &&
                !fixedLeafControl &&
                (!hasExplicitWidth || declaredFixedWidthOverflow);

            if (shouldAutoFlex) {
              final preferredWidth = _schemaNumber(
                childProps['width'] ?? childStyle['width'],
              );

              if (declaredFixedWidthOverflow &&
                  preferredWidth != null &&
                  preferredWidth > 0) {
                final preferredWeight = (preferredWidth * 10).round();
                requestedFlex = preferredWeight > 0 ? preferredWeight : 1;
              } else {
                requestedFlex = 1;
              }
              tight = false;
            }
          }

          if (mainAxisBounded && requestedFlex > 0) {
            child = Flexible(
              flex: requestedFlex,
              fit: tight ? FlexFit.tight : FlexFit.loose,
              child: child,
            );
            appliedFlex = true;
          }

          builtChildren.add(child);

          if (spacing > 0 && index < children.length - 1) {
            builtChildren.add(
              SizedBox(
                width: axis == Axis.horizontal ? spacing : 0,
                height: axis == Axis.vertical ? spacing : 0,
              ),
            );
          }
        }

        final flex = Flex(
          direction: axis,
          mainAxisAlignment: switch (props['mainAxisAlignment']) {
            'spaceBetween' => MainAxisAlignment.spaceBetween,
            'spaceAround' => MainAxisAlignment.spaceAround,
            'spaceEvenly' => MainAxisAlignment.spaceEvenly,
            'center' => MainAxisAlignment.center,
            'end' => MainAxisAlignment.end,
            _ => MainAxisAlignment.start,
          },
          crossAxisAlignment: switch (props['crossAxisAlignment']) {
            'start' => CrossAxisAlignment.start,
            'end' => CrossAxisAlignment.end,
            'stretch' => CrossAxisAlignment.stretch,
            'baseline' => CrossAxisAlignment.baseline,
            _ => CrossAxisAlignment.center,
          },
          textBaseline: props['crossAxisAlignment'] == 'baseline'
              ? TextBaseline.alphabetic
              : null,
          mainAxisSize: mainAxisBounded && appliedFlex
              ? MainAxisSize.max
              : MainAxisSize.min,
          children: builtChildren,
        );

        Widget result = Padding(
          padding: style.margin.add(style.padding),
          child: flex,
        );

        // If a bounded horizontal row is made entirely from intrinsic/fixed
        // children and their declared widths cannot fit the runtime width,
        // forcing the Row to paint outside its constraints produces the yellow
        // RenderFlex overflow stripe.  In that specific case there are no Flex
        // children, so it is safe to preserve every schema-declared child size
        // and expose the excess width through a horizontal viewport instead.
        //
        // This is driven only by the incoming constraints and the schema's
        // direct-child dimensions.  It does not depend on account ids, node ids,
        // component ids, device models, or a hard-coded screen width.
        final needsIntrinsicOverflowViewport =
            axis == Axis.horizontal &&
            mainAxisBounded &&
            declaredFixedWidthOverflow &&
            !appliedFlex;

        if (shouldWrapInMainAxisScrollView || needsIntrinsicOverflowViewport) {
          result = SingleChildScrollView(scrollDirection: axis, child: result);
        }

        return result;
      },
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ stack â”€â”€â”€â”€â”€â”€
  Widget _stack(
    BuildContext context,
    Map<String, dynamic> props,
    SduiStyle style,
    List<Map<String, dynamic>> children, [
    String? groupBinding,
  ]) {
    final widgets = children.map<Widget>((c) {
      final pos =
          (c['properties'] as Map?)?['position'] ??
          (c['style'] as Map?)?['position'];
      final child = build(context, c, groupBinding);
      if (pos is Map &&
          (pos['top'] != null ||
              pos['left'] != null ||
              pos['right'] != null ||
              pos['bottom'] != null)) {
        return Positioned(
          top: (pos['top'] as num?)?.toDouble(),
          right: (pos['right'] as num?)?.toDouble(),
          bottom: (pos['bottom'] as num?)?.toDouble(),
          left: (pos['left'] as num?)?.toDouble(),
          child: child,
        );
      }
      return child;
    }).toList();

    return Container(
      constraints: BoxConstraints(minHeight: style.dim('minHeight') ?? 0),
      padding: style.padding,
      margin: style.margin,
      decoration: style.decoration,
      clipBehavior: props['clipBehavior'] == 'hardEdge'
          ? Clip.hardEdge
          : Clip.none,
      child: Stack(children: widgets),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ text â”€â”€â”€â”€â”€â”€
  Widget _text(
    Map<String, dynamic> node,
    Map<String, dynamic> props,
    SduiStyle style,
  ) {
    final binding = props['textBinding'] as String?;
    String text = props['text']?.toString() ?? '';
    if (binding != null) {
      final v = state.resolveBinding(binding);
      if (v != null) text = v.toString();
    }

    final themeTypography =
        state.schema['theme']?['typography'] as Map? ?? const {};
    final themeFontFamily = themeTypography['fontFamily']?.toString();
    final inheritedBase = SduiStyle.withFontFamily(
      const TextStyle(),
      themeFontFamily,
    );
    var baseStyle = style.textStyle(inheritedBase) ?? inheritedBase;

    final maxLines = (props['maxLines'] as num?)?.toInt();
    final isEllipsis = props['overflow'] == 'ellipsis';

    final textWidget = Text(
      text,
      maxLines: maxLines,
      overflow: isEllipsis ? TextOverflow.ellipsis : null,
      style: baseStyle,
    );

    final nodeId = node['id']?.toString() ?? '';
    final isTitleLike = maxLines == 1 &&
        (isEllipsis ||
            nodeId.contains('title') ||
            nodeId.contains('subtitle') ||
            nodeId.contains('brand') ||
            nodeId.contains('label'));

    if (isTitleLike) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: textWidget,
      );
    }

    return textWidget;
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ icon â”€â”€â”€â”€â”€â”€
  Widget _icon(Map<String, dynamic> props, SduiStyle style) {
    final name = props['name'] as String? ?? '';
    final designSystemIconSize = state
        .schema['extensions']?['universalUi']?['designSystem']?['icons']?['size'];
    final size =
        (props['size'] as num?)?.toDouble() ??
        (state.schema['icons']?['size'] as num?)?.toDouble() ??
        (designSystemIconSize as num?)?.toDouble();

    final color =
        SduiStyle.color(style.s['color']?.toString()) ??
        SduiStyle.color(state.schema['icons']?['color']?.toString()) ??
        SduiStyle.color(state.schema['theme']?['colors']?['icon']?.toString());
    if (name.isEmpty || color == null || size == null) {
      return SchemaIssueWidget(
        title: 'Invalid icon schema',
        details: [
          if (name.isEmpty) 'properties.name â€” required schema icon name',
          if (color == null)
            'style.color or icons.color — required valid color',
          if (size == null)
            'properties.size, icons.size, or extensions.universalUi.designSystem.icons.size — required number',
        ],
        componentType: 'icon',
      );
    }

    final iconLibrary = state.schema['icons']?['library'];
    final source = iconLibrary is Map
        ? iconLibrary['source']?.toString()
        : null;
    final schemaIconPaths = iconLibrary is Map ? iconLibrary['paths'] : null;
    final svgBody = schemaIconPaths is Map
        ? schemaIconPaths[name]?.toString()
        : null;

    final Widget iconWidget;

    if (source == 'inline-svg' &&
        svgBody != null &&
        svgBody.trim().isNotEmpty) {
      final svgDocument =
          '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
          'viewBox="0 0 24 24" fill="none" stroke="currentColor" '
          'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
          '$svgBody</svg>';
      iconWidget = SvgPicture.string(
        svgDocument,
        width: size,
        height: size,
        fit: BoxFit.contain,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
    } else {
      // The schema asked for an icon of this size (send button, bubble).
      // A missing path is a schema gap. A multi-line diagnostic inside that
      // slot is laid out character-by-character and overflows the row by
      // the full error height ("BOTTOM OVERFLOWED"). Keep the slot at the
      // schema size so the button chrome still matches.
      iconWidget = SizedBox(width: size, height: size);
    }

    final hasAction = props['action'] != null || props['events'] != null;
    if (!hasAction) return iconWidget;

    return Builder(
      builder: (context) => InkWell(
        onTap: () => _handleButtonTap(context, props, null),
        child: iconWidget,
      ),
    );
  }

  static List<_SvgElement> _parseSvgElements(String svgString) {
    final out = <_SvgElement>[];

    for (final m in RegExp(r'd="([^"]+)"').allMatches(svgString)) {
      out.add(_SvgPath(m.group(1)!));
    }
    for (final m in RegExp("d='([^']+)'").allMatches(svgString)) {
      out.add(_SvgPath(m.group(1)!));
    }

    final circleRe = RegExp(r'<circle\b([^>]*)>', caseSensitive: false);
    for (final m in circleRe.allMatches(svgString)) {
      final attrs = m.group(1)!;
      final cx = _attrNum(attrs, 'cx') ?? 0;
      final cy = _attrNum(attrs, 'cy') ?? 0;
      final r = _attrNum(attrs, 'r') ?? 0;
      out.add(_SvgCircle(cx, cy, r));
    }

    final lineRe = RegExp(r'<line\b([^>]*)>', caseSensitive: false);
    for (final m in lineRe.allMatches(svgString)) {
      final attrs = m.group(1)!;
      final x1 = _attrNum(attrs, 'x1') ?? 0;
      final y1 = _attrNum(attrs, 'y1') ?? 0;
      final x2 = _attrNum(attrs, 'x2') ?? 0;
      final y2 = _attrNum(attrs, 'y2') ?? 0;
      out.add(_SvgLine(x1, y1, x2, y2));
    }

    final rectRe = RegExp(r'<rect\b([^>]*)>', caseSensitive: false);
    for (final m in rectRe.allMatches(svgString)) {
      final attrs = m.group(1)!;
      final x = _attrNum(attrs, 'x') ?? 0;
      final y = _attrNum(attrs, 'y') ?? 0;
      final w = _attrNum(attrs, 'width') ?? 0;
      final h = _attrNum(attrs, 'height') ?? 0;
      final rx = _attrNum(attrs, 'rx') ?? 0;
      out.add(_SvgRect(x, y, w, h, rx));
    }

    final polyRe = RegExp(
      r"points=["
      "\x27]([^"
      "\x27]+)["
      "\x27]",
      caseSensitive: false,
    );
    for (final m in polyRe.allMatches(svgString)) {
      final pts = m.group(1)!.trim().split(RegExp(r'[\s,]+'));
      final coords = <double>[];
      for (final p in pts) {
        final v = double.tryParse(p);
        if (v != null) coords.add(v);
      }
      if (coords.length >= 4) out.add(_SvgPolyline(coords));
    }

    return out;
  }

  static double? _attrNum(String attrs, String name) {
    final m = RegExp("$name=[\"']([.\\d]+)[\"']").firstMatch(attrs);
    return m != null ? double.tryParse(m.group(1)!) : null;
  }

  // ──────────────────────────────────────────────────────── image ──────────────────────
  Widget _image(Map<String, dynamic> props, SduiStyle style) {
    final networkUrl = _firstNonEmptyString([
      props['src'],
      props['url'],
      props['imageUrl'],
    ]);
    final assetPath = props['asset']?.toString().trim();

    final width = (props['width'] as num?)?.toDouble() ?? style.dim('width');
    final height = (props['height'] as num?)?.toDouble() ?? style.dim('height');
    final fit = _boxFit(props['fit']?.toString());
    final radius = style.borderRadius;

    Widget imageWidget;

    if (networkUrl != null && networkUrl.isNotEmpty) {
      imageWidget = CachedNetworkImage(
        imageUrl: networkUrl,
        cacheManager: SduiNetworkImageCache.manager,
        width: width,
        height: height,
        fit: fit,
        placeholder: (_, __) => _imagePlaceholder(
          width: width,
          height: height,
          label: props['placeholder']?.toString(),
        ),
        errorWidget: (_, __, ___) => _imageError(
          width: width,
          height: height,
          label: props['placeholder']?.toString() ?? networkUrl,
        ),
      );
    } else if (assetPath != null && assetPath.isNotEmpty) {
      imageWidget = Image.asset(
        assetPath,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) =>
            _imageError(width: width, height: height, label: assetPath),
      );
    } else {
      return const SizedBox.shrink();
    }

    if (radius != BorderRadius.zero) {
      imageWidget = ClipRRect(borderRadius: radius, child: imageWidget);
    }

    return imageWidget;
  }

  Widget _imagePlaceholder({double? width, double? height, String? label}) {
    final w = width ?? 40.0;
    final h = height ?? 40.0;
    return SizedBox(
      width: width,
      height: height,
      child: Center(
        child: SizedBox(
          width: math.min(w, 24.0),
          height: math.min(h, 24.0),
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _imageError({double? width, double? height, String? label}) {
    final w = width ?? 40.0;
    final h = height ?? 40.0;
    return Container(
      width: width,
      height: height,
      color: Colors.grey.withOpacity(0.06),
      child: Center(
        child: Icon(
          Icons.image_outlined,
          color: Colors.grey.withOpacity(0.35),
          size: math.min(w, h) * 0.5,
        ),
      ),
    );
  }

  static String? _firstNonEmptyString(List<dynamic> candidates) {
    for (final v in candidates) {
      final s = v?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  static BoxFit _boxFit(String? value) {
    switch (value?.toLowerCase().trim()) {
      case 'cover':
        return BoxFit.cover;
      case 'contain':
        return BoxFit.contain;
      case 'fill':
        return BoxFit.fill;
      case 'none':
        return BoxFit.none;
      case 'fitwidth':
        return BoxFit.fitWidth;
      case 'fitheight':
        return BoxFit.fitHeight;
      default:
        return BoxFit.cover;
    }
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ button â”€â”€â”€â”€â”€â”€â”€
  bool _selectsSchemaPage(Map<String, dynamic> node) {
    final props = node['properties'];
    final events = props is Map ? props['events'] : node['events'];
    if (events is! List) return false;
    for (final raw in events) {
      if (raw is! Map) continue;
      final action = raw['action'];
      if (action is! Map) continue;
      final value = action['value']?.toString() ?? '';
      if (value.startsWith('activePageIndex')) return true;
    }
    return false;
  }

  Widget _button(
    BuildContext context,
    Map<String, dynamic> node,
    Map<String, dynamic> props,
    SduiStyle style,
    List<Map<String, dynamic>> children, [
    String? groupBinding,
  ]) {
    if (state.pages.isEmpty && _selectsSchemaPage(node)) {
      return const SizedBox.shrink();
    }
    final content = children.length == 1
        ? build(context, children.first, groupBinding)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: _buildChildren(
              context,
              children,
              6,
              Axis.horizontal,
              groupBinding,
            ),
          );

    SduiStyle effectiveStyle = style;
    final actionValue = props['actionValue'];
    var isSelected = false;
    if (actionValue != null && groupBinding != null) {
      final currentValue = state.resolveBinding(groupBinding);
      isSelected = currentValue == actionValue;
      if (!isSelected) {
        final m2 = Map<String, dynamic>.from(style.s);
        m2['backgroundColor'] = style.s['unselectedBackgroundColor'];
        m2.remove('gradient');
        effectiveStyle = SduiStyle(m2);
      } else {
        final unselectedFallback = style.s['unselectedBackgroundColor']
            ?.toString();
        final ownBg = style.s['backgroundColor']?.toString();
        final injectedBg = style.s['selectedBackgroundColor'] as String?;
        final hasDistinctOwnBackground =
            ownBg != null &&
            (unselectedFallback == null ||
                ownBg.toUpperCase() != unselectedFallback.toUpperCase());
        final resolvedSelectedBg = hasDistinctOwnBackground
            ? ownBg
            : (injectedBg ?? ownBg);
        if (resolvedSelectedBg != null) {
          final m2 = Map<String, dynamic>.from(style.s);
          m2['backgroundColor'] = resolvedSelectedBg;
          m2.remove('selectedBackgroundColor');
          m2.remove('gradient');
          effectiveStyle = SduiStyle(m2);
        }
      }
    }

    Widget displayContent = content;
    if (!isSelected) {
      final unselectedTextColor = SduiStyle.color(
        style.s['unselectedTextColor']?.toString(),
      );
      if (unselectedTextColor != null) {
        displayContent = DefaultTextStyle.merge(
          style: TextStyle(color: unselectedTextColor),
          child: content,
        );
      }
    }

    Color? pageTextColor;
    final events = props['events'];
    if (events is List) {
      for (final e in events) {
        final action = (e as Map)['action'] as Map?;
        if (action == null) continue;
        if (action['type'] == 'update') {
          final expr = action['value']?.toString() ?? '';
          final pageMatch = RegExp(r'^activePageIndex=(\d+)$').firstMatch(expr);
          if (pageMatch != null) {
            final targetIndex = int.tryParse(pageMatch.group(1)!);
            if (targetIndex != null) {
              final themeColors =
                  (state.schema['theme']?['colors'] as Map?) ?? const {};
              final accentHex = themeColors['accent']?.toString();
              final secondaryHex = themeColors['secondary']?.toString();
              if (state.activePageIndex == targetIndex) {
                final m2 = Map<String, dynamic>.from(style.s)
                  ..['gradient'] = {
                    'type': 'linear',
                    'begin': 'topLeft',
                    'end': 'bottomRight',
                    'colors': [secondaryHex, accentHex],
                  }
                  ..['backgroundColor'] = accentHex
                  ..['borderColor'] = accentHex
                  ..['border'] = {'width': 1, 'color': accentHex};
                effectiveStyle = SduiStyle(m2);
              } else {
                final pagerParts =
                    (state.schema['extensions']?['universalUi']?['designSystem']?['componentStyles']?['pagerControls']?['parts']
                        as Map?) ??
                    const {};
                final pageButtonStyle =
                    (pagerParts['pageButton'] as Map?) ?? const {};
                final m2 = Map<String, dynamic>.from(style.s);
                m2.remove('gradient');
                m2['backgroundColor'] =
                    pageButtonStyle['backgroundColor'] ?? themeColors['shell'];
                m2['borderColor'] = pageButtonStyle['borderColor'];
                m2['border'] = pageButtonStyle['border'];
                effectiveStyle = SduiStyle(m2);
                final inactiveForeground =
                    pageButtonStyle['foregroundColor']?.toString() ??
                    themeColors['text']?.toString();

                pageTextColor = SduiStyle.color(inactiveForeground);
              }
            }
            break;
          }

          final isPrevArrow = RegExp(
            r'^activePageIndex=max\(activePageIndex-1',
          ).hasMatch(expr);
          final isNextArrow = RegExp(
            r'^activePageIndex=min\(activePageIndex\+1',
          ).hasMatch(expr);
          if (isPrevArrow || isNextArrow) {
            final isFirstPage = state.activePageIndex == 0;
            final isLastPage = state.activePageIndex == state.pages.length - 1;
            final shouldDisable =
                (isPrevArrow && isFirstPage) || (isNextArrow && isLastPage);
            if (shouldDisable) {
              final arrowDisabled =
                  (state.schema['extensions']?['universalUi']?['designSystem']?['componentStyles']?['pagerControls']?['parts']?['arrowDisabled']
                      as Map?) ??
                  const {};
              final themeColors =
                  (state.schema['theme']?['colors'] as Map?) ?? const {};
              final disabledBg = arrowDisabled['backgroundColor']?.toString() ??
                  themeColors['surface']?.toString() ??
                  themeColors['card']?.toString();
              final disabledFg = arrowDisabled['foregroundColor']?.toString() ??
                  themeColors['muted']?.toString() ??
                  themeColors['subtext']?.toString();
              final disabledOpacity = (arrowDisabled['opacity'] as num?)
                  ?.toDouble();
              final disabledBgColor = SduiStyle.color(disabledBg);
              final disabledFgColor = SduiStyle.color(disabledFg);
              if (disabledBg == null ||
                  disabledFg == null ||
                  disabledOpacity == null ||
                  disabledBgColor == null ||
                  disabledFgColor == null) {
                return SchemaIssueWidget(
                  title: 'Schema color missing',
                  details: const [
                    'Provide pagerControls.parts.arrowDisabled backgroundColor/foregroundColor/opacity',
                    'or theme.colors.surface/card and muted/subtext',
                  ],
                  componentType: node['type']?.toString(),
                  controlId: node['id']?.toString(),
                );
              }
              final m2 = Map<String, dynamic>.from(style.s);
              m2['backgroundColor'] = disabledBg;
              m2.remove('gradient');
              effectiveStyle = SduiStyle(m2);

              final pagerParts =
                  (state.schema['extensions']?['universalUi']?['designSystem']?['componentStyles']?['pagerControls']?['parts']
                      as Map?) ??
                  const {};
              final activePageButtonStyle =
                  (pagerParts['pageButtonActive'] as Map?) ?? const {};
              final activeForeground = activePageButtonStyle['foregroundColor']
                  ?.toString();

              pageTextColor = SduiStyle.color(activeForeground);

              final widthProp2 = props['width'] ?? style.s['width'];
              final isFullWidth2 = _isFillDimension(widthProp2);
              final disabledContent = ColorFiltered(
                colorFilter: ColorFilter.mode(disabledFgColor, BlendMode.srcIn),
                child: content,
              );
              final disabledWidget = Padding(
                padding: effectiveStyle.margin,
                child: Opacity(
                  opacity: disabledOpacity,
                  child: Container(
                    width: isFullWidth2
                        ? double.infinity
                        : effectiveStyle.dim('width'),
                    height: effectiveStyle.dim('height'),
                    constraints: BoxConstraints(
                      minWidth: effectiveStyle.dim('minWidth') ?? 0,
                      minHeight: effectiveStyle.dim('minHeight') ?? 0,
                    ),
                    padding: effectiveStyle.padding,
                    alignment: Alignment.center,
                    decoration: effectiveStyle.decoration,
                    child: disabledContent,
                  ),
                ),
              );
              // Leaf builders must not return Expanded. The immediate
              // parent Row/Column owns flex resolution.
              return disabledWidget;
            }
            break;
          }
        }
      }
    }

    final Widget finalContent;
    if (pageTextColor != null) {
      finalContent = ColorFiltered(
        colorFilter: ColorFilter.mode(pageTextColor, BlendMode.srcIn),
        child: displayContent,
      );
    } else {
      finalContent = displayContent;
    }

    final widthProp = props['width'] ?? style.s['width'];
    final isFullWidth = _isFillDimension(widthProp);

    return Padding(
      padding: effectiveStyle.margin,
      child: Semantics(
        button: true,
        label: props['semanticLabel'] as String? ?? props['label'] as String?,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: effectiveStyle.borderRadius,
            onTap: () => _handleButtonTap(
              context,
              props,
              actionValue,
              nodeId: node['id']?.toString(),
            ),
            child: Container(
              width: isFullWidth
                  ? double.infinity
                  : effectiveStyle.dim('width'),
              height: effectiveStyle.dim('height'),
              constraints: BoxConstraints(
                minWidth: effectiveStyle.dim('minWidth') ?? 0,
                minHeight: effectiveStyle.dim('minHeight') ?? 0,
              ),
              padding: effectiveStyle.padding,
              alignment: Alignment.center,
              decoration: effectiveStyle.decoration,
              child: finalContent,
            ),
          ),
        ),
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ fire events â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> _handleButtonTap(
    BuildContext context,
    Map<String, dynamic> props,
    dynamic actionValue, {
    String? nodeId,
  }) async {
    final actionRef = props['action'];
    if (actionRef is String && actionRef.trim().isNotEmpty) {
      await ActionRegistry.instance.dispatch(
        context: context,
        state: state,
        action: {'type': actionRef.trim(), 'value': actionRef.trim()},
        parameters: {'actionValue': actionValue},
      );
      return;
    }
    if (actionRef is Map) {
      await ActionRegistry.instance.dispatch(
        context: context,
        state: state,
        action: Map<String, dynamic>.from(actionRef),
        parameters: {'actionValue': actionValue},
      );
      return;
    }

    if (props['events'] != null) {
      await _fireEvents(context, props['events'], actionValue);
      return;
    }

    final hint =
        '${nodeId ?? ''} ${props['semanticLabel'] ?? ''} ${props['label'] ?? ''}'
            .toLowerCase();
    if (hint.contains('scan')) {
      await ActionRegistry.instance.dispatch(
        context: context,
        state: state,
        action: const {'type': 'openScanner', 'value': 'openScanner'},
      );
      return;
    }
    if (hint.contains('info')) {
      await ActionRegistry.instance.dispatch(
        context: context,
        state: state,
        action: const {'type': 'openDeviceInfo', 'value': 'openDeviceInfo'},
      );
    }
  }

  Future<void> _fireEvents(
    BuildContext context,
    dynamic events, [
    dynamic actionValue,
  ]) async {
    if (events is! List) return;
    for (final e in events) {
      if (e is! Map) continue;
      if (!context.mounted) return;

      final rawAction = e['action'];

      if (rawAction is String && rawAction.trim().isNotEmpty) {
        await ActionRegistry.instance.dispatch(
          context: context,
          state: state,
          action: {'type': rawAction.trim(), 'value': rawAction.trim()},
          parameters: {'actionValue': actionValue},
        );
        continue;
      }

      if (rawAction is! Map) continue;
      final action = Map<String, dynamic>.from(rawAction);
      await ActionRegistry.instance.dispatch(
        context: context,
        state: state,
        action: action,
        parameters: {'actionValue': actionValue},
      );
    }
  }

  Widget _progressIndicator(
    Map<String, dynamic> node,
    Map<String, dynamic> props,
    SduiStyle style,
  ) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final trackColor = SduiStyle.color(style.s['trackColor']?.toString());
        final height = style.dim('height');
        final radius = style.borderRadius;
        final fill = style.s['fill'];
        final stops = fill is Map ? fill['stops'] : null;
        final fillColors = <Color>[];
        if (stops is List) {
          for (final stop in stops) {
            if (stop is! Map) continue;
            final color = SduiStyle.color(stop['color']?.toString());
            if (color != null) fillColors.add(color);
          }
        }
        if (fillColors.isEmpty && fill is Map) {
          final fallback = SduiStyle.color(fill['fallbackColor']?.toString());
          if (fallback != null) fillColors.add(fallback);
        }

        final issues = <String>[];
        if (trackColor == null) {
          issues.add('style.trackColor â€” required valid color');
        }
        if (height == null) {
          issues.add('style.height â€” required number');
        }
        // radius is non-nullable: SduiStyle.borderRadius always returns BorderRadius.zero as fallback
        if (fillColors.isEmpty) {
          issues.add(
            'style.fill.stops[].color or style.fill.fallbackColor â€” required',
          );
        }
        if (issues.isNotEmpty) {
          return SchemaIssueWidget(
            title: 'Invalid progress schema',
            details: issues,
            componentType: node['type']?.toString(),
          );
        }

        if (state.pages.isEmpty) return const SizedBox.shrink();

        final pageCount = state.pages.length;
        final fraction = pageCount == 0
            ? 0.0
            : ((state.activePageIndex + 1) / pageCount).clamp(0.0, 1.0);

        final universalUi = state.schema['extensions'] is Map
            ? (state.schema['extensions'] as Map)['universalUi']
            : null;
        final animations = universalUi is Map
            ? universalUi['animations']
            : null;
        final transition = animations is Map
            ? animations['pageTransition']
            : null;
        final rawDuration = transition is Map ? transition['durationMs'] : null;
        final durationMs = rawDuration is num
            ? rawDuration.toInt()
            : int.tryParse(rawDuration?.toString() ?? '') ?? 0;

        return Padding(
          padding: style.margin,
          child: ClipRRect(
            borderRadius: radius,
            child: SizedBox(
              height: height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final targetWidth = constraints.maxWidth * fraction;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: trackColor!),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: AnimatedContainer(
                          key: ValueKey<String>(
                            'page-progress-${state.activePageIndex}-$pageCount',
                          ),
                          duration: Duration(milliseconds: durationMs),
                          curve: _pageTransitionCurveFromSchema(state.schema),
                          width: targetWidth,
                          decoration: BoxDecoration(
                            gradient: fillColors.length > 1
                                ? LinearGradient(colors: fillColors)
                                : null,
                            color: fillColors.length == 1
                                ? fillColors.first
                                : null,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ list view â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _listView(
    BuildContext context,
    Map<String, dynamic> props,
    SduiStyle style,
    List<Map<String, dynamic>> children, [
    String? groupBinding,
  ]) {
    final horizontal = props['scrollDirection'] == 'horizontal';
    if (state.pages.isEmpty &&
        children.isNotEmpty &&
        children.every(_selectsSchemaPage)) {
      return const SizedBox.shrink();
    }
    if (props['physics'] == 'page' && horizontal) {
      final pageIdentity = children
          .map(
            (page) {
              final id = page['id']?.toString() ??
                  page['properties']?['pageId']?.toString() ??
                  '';
              final childCount = (page['children'] as List?)?.length ?? 0;
              return '$id:$childCount';
            },
          )
          .join('|');

      // The parent Flex applies schema flex only when it has finite height.
      return _PageSlider(
        key: ValueKey('device_page_slider_$pageIdentity'),
        state: state,
        renderer: this,
        pages: children,
      );
    }
    final spacing = (props['spacing'] as num?)?.toDouble() ?? 0;

    if (horizontal && _isFillDimension(props['width'] ?? style.s['width'])) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final row = Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: _buildChildren(
              context,
              children,
              spacing,
              Axis.horizontal,
              groupBinding,
            ),
          );

          // A horizontal scroll view may itself be nested under an unbounded
          // horizontal constraint. Never promote that infinity into a child
          // BoxConstraints. When width is finite we keep the existing
          // center-with-minimum-viewport-width behavior; otherwise the row
          // remains intrinsic and the scroll view negotiates with its parent.
          final scrollChild =
              constraints.hasBoundedWidth && constraints.maxWidth.isFinite
              ? ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: row,
                )
              : row;

          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: scrollChild,
          );
        },
      );
    }

    return SingleChildScrollView(
      scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
      child: Flex(
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        mainAxisSize: MainAxisSize.min,
        children: _buildChildren(
          context,
          children,
          spacing,
          horizontal ? Axis.horizontal : Axis.vertical,
          groupBinding,
        ),
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ parameter control list â”€â”€â”€â”€â”€â”€â”€
  Widget _controlList(
    BuildContext context,
    Map<String, dynamic> props,
    SduiStyle style,
  ) {
    final pageNo = props['pageNo']?.toString();
    final pageId = props['pageId']?.toString();

    final filterBy = props['filterBy']?.toString();
    if (filterBy == 'pageNo' || filterBy == 'page_no') {
      final targetPage = props['pageNo']?.toString() ?? props['filterValue']?.toString();
      final activePage = (state.activePageIndex + 1).toString();
      if (targetPage != null && targetPage != activePage) {
        return const SizedBox.shrink();
      }
    }

    final spacing =
        (props['gap'] as num?)?.toDouble() ??
        (props['spacing'] as num?)?.toDouble() ??
        (style.s['spacing'] as num?)?.toDouble() ??
        (style.s['gap'] as num?)?.toDouble() ??
        _schemaNumber(state.schema['theme']?['spacing']?['cardGap']) ??
        _schemaNumber(
          state.schema['extensions']?['universalUi']?['designSystem']
              ?['componentStyles']?['parameterCard']?['stackedLayout']?['gap'],
        ) ??
        0;
    final publishedIds = SchemaRuntime.publishedControlIds(
      schema: state.schema,
      nodeControlIds: props['controlIds'] is List
          ? props['controlIds'] as List
          : null,
      pageNo: pageNo,
      pageId: pageId,
    );
    final byId = <String, Map<String, dynamic>>{};
    for (final control in state.controls) {
      final id = control['id']?.toString();
      if (id == null || id.isEmpty) continue;
      byId[id] = control;
    }
    var controls = <Map<String, dynamic>>[
      for (final id in publishedIds)
        if (byId[id] != null) byId[id]!,
    ];

    if (pageNo != null && pageNo.isNotEmpty) {
      controls = controls.where((c) {
        final cPage = c['pageNo']?.toString();
        if (cPage != null && cPage.isNotEmpty && cPage != pageNo) return false;
        final cId = c['id']?.toString() ?? '';
        if (cId.contains(':')) {
          final prefix = cId.split(':').first;
          if (int.tryParse(prefix) != null && prefix != pageNo) return false;
        }
        return true;
      }).toList(growable: false);
    }

    if (controls.isEmpty) {
      final targetPageNo = pageNo ?? (state.activePageIndex + 1).toString();
      controls = state.controls
          .where((c) {
            final cPage = c['pageNo']?.toString();
            final cId = c['id']?.toString() ?? '';
            if (cPage != null && cPage.isNotEmpty) {
              return cPage == targetPageNo;
            }
            if (cId.contains(':')) {
              final prefix = cId.split(':').first;
              if (int.tryParse(prefix) != null) {
                return prefix == targetPageNo;
              }
            }
            return targetPageNo == '1';
          })
          .where((c) => c['visible'] != false)
          .toList()
        ..sort(
          (a, b) => ((a['sequence'] as num?) ?? 0).compareTo(
            (b['sequence'] as num?) ?? 0,
          ),
        );
    }

    // Web paints a control only when the schema gives it a render target
    // (`renderAs`, for example ParameterCard). Protocol fragments such as
    // Get Status responses are listed on the page but have no renderAs, so
    // they stay out of the operation screen. If a document has no renderAs
    // at all, every published control is still shown.
    bool hasRenderTarget(Map<String, dynamic> control) {
      final renderAs = control['renderAs']?.toString().trim() ?? '';
      return renderAs.isNotEmpty;
    }

    if (controls.any(hasRenderTarget)) {
      controls = controls.where(hasRenderTarget).toList(growable: false);
    }

    final entries = _groupApiControls(controls);

    return Padding(
      padding: style.padding.add(style.margin),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportWidth = _responsiveViewportWidth(context);
          final viewportHeight = _responsiveViewportHeight(context);
          final orientation = _responsiveOrientation(context);
          final runtime = state.schemaRuntime;
          final layout = runtime.resolveResponsiveLayout(
            viewportWidth,
            logicalHeight: viewportHeight,
            orientation: orientation,
          );
          final columns = layout?.columns ?? 1;
          final mode = layout?.paramList ?? 'list';
          final useGrid = columns > 1 || mode == 'grid';

          Widget entryWidget(List<Map<String, dynamic>> entry) {
            // The web document renders every API parameter as an outer group,
            // even when that parameter currently has only one UI component.
            // Grouping is derived from schema identity; it does not depend on
            // parameter names or component names.
            return _ApiControlGroup(
              controls: entry,
              state: state,
              renderer: this,
              spacing: spacing,
            );
          }

          final column = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                entryWidget(entries[i]),
                if (i < entries.length - 1) SizedBox(height: spacing),
              ],
            ],
          );

          if (!useGrid) {
            // The device body gives this list a finite height. A max-size
            // column then overflows by the full content height (the yellow
            // "BOTTOM OVERFLOWED" stripe). Scroll only when the parent is
            // already bounded so an outer schema scroll view is not nested.
            if (constraints.maxHeight.isFinite) {
              return SingleChildScrollView(child: column);
            }
            return column;
          }

          return GridView.builder(
            shrinkWrap: !constraints.maxHeight.isFinite,
            physics: constraints.maxHeight.isFinite
                ? null
                : const NeverScrollableScrollPhysics(),
            itemCount: entries.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing,
              mainAxisExtent: _schemaNumber(layout?.config['controlExtent']),
              childAspectRatio:
                  _schemaNumber(layout?.config['childAspectRatio']) ?? 1,
            ),
            itemBuilder: (context, index) => entryWidget(entries[index]),
          );
        },
      ),
    );
  }

  Widget parameterCard(Map<String, dynamic> control, {required bool embedded}) {
    final id = SchemaPatch.nodeId(control) ?? identityHashCode(control).toString();
    // The control definition carries no parameter value, so a definition-only
    // fingerprint would return the identical widget instance after a value
    // change. Flutter then short-circuits in Element.updateChild and the card
    // never repaints. Including the parameter revision keeps the cache useful
    // for layout churn while letting any value change through.
    final fingerprint =
        '${SchemaPatch.nodeFingerprint(control)}|${state.parameterRevision}';
    final cached = _parameterCardCache[id];
    if (cached != null && cached.$1 == fingerprint) return cached.$2;
    final card = ParameterCard(
      key: ValueKey<String>(id),
      control: control,
      state: state,
      showLeftAccent: false,
      embedded: embedded,
    );
    _parameterCardCache[id] = (fingerprint, card);
    return card;
  }

  List<List<Map<String, dynamic>>> _groupApiControls(
    List<Map<String, dynamic>> controls,
  ) {
    final result = <List<Map<String, dynamic>>>[];
    final groupedIndexes = <String, int>{};

    for (final control in controls) {
      final explicitGroup =
          control['groupId'] ??
          control['groupKey'] ??
          control['parentControlId'] ??
          (control['group'] is Map ? (control['group'] as Map)['id'] : null);

      // A parameter/device-frame is the visual group used by the web preview.
      // The control ID is only a final identity fallback, so unrelated
      // controls are never merged accidentally.
      final semanticGroup =
          explicitGroup ??
          control['parameter'] ??
          control['parameterName'] ??
          control['deviceFrame']?['name'] ??
          control['id'];
      final page = control['pageNo']?.toString() ?? '';
      final groupIdentity = semanticGroup?.toString().trim() ?? '';
      final groupKey = '$page::$groupIdentity';

      final existing = groupedIndexes[groupKey];
      if (existing == null) {
        groupedIndexes[groupKey] = result.length;
        result.add(<Map<String, dynamic>>[control]);
      } else {
        result[existing].add(control);
      }
    }

    for (final group in result) {
      group.sort((a, b) {
        final ai = (a['apiComponentIndex'] as num?)?.toInt();
        final bi = (b['apiComponentIndex'] as num?)?.toInt();
        if (ai != null && bi != null) return ai.compareTo(bi);
        return ((a['sequence'] as num?) ?? 0).compareTo(
          (b['sequence'] as num?) ?? 0,
        );
      });
    }
    return result;
  }

  /// Renders a single API control group (e.g. Command Get Status with response controls).
  Widget renderControlGroup({
    required List<Map<String, dynamic>> controls,
    double spacing = 8.0,
    bool embedded = false,
  }) {
    return _ApiControlGroup(
      controls: controls,
      state: state,
      renderer: this,
      spacing: spacing,
    );
  }
}

class _ApiControlGroup extends StatelessWidget {
  const _ApiControlGroup({
    required this.controls,
    required this.state,
    required this.renderer,
    required this.spacing,
  });

  final List<Map<String, dynamic>> controls;
  final AppState state;
  final SduiRenderer renderer;
  final double spacing;

  static double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static Map<String, dynamic> _map(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value)
      : const <String, dynamic>{};

  @override
  Widget build(BuildContext context) {
    final first = controls.first;
    final rawGroup = first['group'];
    final groupMap = _map(rawGroup);
    final label =
        (groupMap['label'] ??
                first['parameter'] ??
                first['parameterName'] ??
                first['deviceFrame']?['name'])
            ?.toString()
            .trim() ??
        '';

    final designSystem = state
        .schema['extensions']?['universalUi']?['designSystem']?['componentStyles'];
    final parameterStyle = designSystem is Map
        ? _map(designSystem['parameterCard'])
        : const <String, dynamic>{};
    final parts = _map(parameterStyle['parts']);
    final metaStyle = _map(parts['metaChip'] ?? state.schema['theme']?['metaChip']);
    final leftAccent = _map(parts['leftAccent']);
    final accentBackground = _map(leftAccent['background']);
    final accentStops = accentBackground['stops'];

    final firstStyles = _map(first['styles']);
    final concreteCardStyle = _map(
      first['component']?['widgetTree']?['properties']?['props']?['cardStyle'],
    );
    final themeColors = _map(state.schema['theme']?['colors']);
    final themeBorders = _map(state.schema['theme']?['borders']);
    final themeRadius = _map(state.schema['theme']?['radius']);
    final themeSpacing = _map(state.schema['theme']?['spacing']);
    final themeTypography = _map(state.schema['theme']?['typography']);

    final background = SduiStyle.color(
      (firstStyles['cardColor'] ??
              concreteCardStyle['backgroundColor'] ??
              parameterStyle['backgroundColor'] ??
              themeColors['card'] ??
              themeColors['cardBackground'] ??
              themeColors['surface'])
          ?.toString(),
    );
    final border = SduiStyle.color(
      (firstStyles['borderColor'] ??
              _map(parameterStyle['border'])['color'] ??
              concreteCardStyle['borderColor'] ??
              themeColors['border'] ??
              themeColors['cardBorder'])
          ?.toString(),
    );
    final borderWidth = _number(
      firstStyles['borderWidth'] ??
          _map(parameterStyle['border'])['width'] ??
          parameterStyle['borderWidth'] ??
          concreteCardStyle['borderWidth'] ??
          themeBorders['size'],
    );
    final radius = _number(
      firstStyles['borderRadius'] ??
          parameterStyle['borderRadius'] ??
          concreteCardStyle['borderRadius'] ??
          themeRadius['card'],
    );
    final padding = _number(
      firstStyles['padding'] ??
          parameterStyle['padding'] ??
          concreteCardStyle['padding'] ??
          themeSpacing['cardPadding'],
    );
    final stackedGap =
        _number(_map(parameterStyle['stackedLayout'])['gap']) ?? spacing;
    final labelStyle = _map(parts['label']);
    final labelColor = SduiStyle.color(
      (firstStyles['mutedTextColor'] ??
              firstStyles['textColor'] ??
              labelStyle['color'] ??
              themeColors['text'] ??
              themeColors['textPrimary'])
          ?.toString(),
    );
    final labelSize = _number(labelStyle['fontSize']) ??
        _number(themeTypography['bodySize']) ??
        _number(themeTypography['fontSize']) ??
        14.0;
    final labelWeight = _fontWeightFromSchema(labelStyle['fontWeight']) ??
        _fontWeightFromSchema(themeTypography['bodyWeight']) ??
        _fontWeightFromSchema(themeTypography['fontWeight']) ??
        FontWeight.w600;

    final themeAccent = SduiStyle.color(
      themeColors['accent'] ?? themeColors['primary'],
    );

    final chipBackground = SduiStyle.color(
      (firstStyles['iconBackgroundColor'] ??
              metaStyle['backgroundColor'] ??
              themeColors['chipBackground'])
          ?.toString(),
    ) ??
        themeAccent?.withValues(alpha: 0.12);
    final chipColor = SduiStyle.color(
      (firstStyles['accentColor'] ??
              firstStyles['iconColor'] ??
              metaStyle['color'] ??
              themeColors['chipText'])
          ?.toString(),
    ) ??
        themeAccent;
    final chipHeight = _number(metaStyle['height']) ?? 24.0;
    final chipMinWidth = _number(metaStyle['minWidth']) ?? 40.0;
    final chipPadding = _number(metaStyle['paddingHorizontal']) ?? 8.0;
    final chipFontSize = _number(metaStyle['fontSize']) ?? 11.0;
    final chipFontWeight = _fontWeightFromSchema(metaStyle['fontWeight']) ?? FontWeight.w600;

    final accentConfigured = (leftAccent.isNotEmpty && leftAccent['visible'] == true) ||
        (firstStyles['leftAccent'] is Map && firstStyles['leftAccent']['visible'] == true);
    final accentVisible = accentConfigured && leftAccent['visible'] != false;
    final accentWidth = _number(leftAccent['width'] ?? firstStyles['leftAccent']?['width']);
    final accentInset = _number(leftAccent['insetVertical'] ?? firstStyles['leftAccent']?['insetVertical']) ?? 0.0;
    Color? accentStart;
    Color? accentEnd;
    if (accentStops is List && accentStops.isNotEmpty) {
      final firstStop = accentStops.first;
      final lastStop = accentStops.last;
      if (firstStop is Map) {
        accentStart = SduiStyle.color(firstStop['color']?.toString());
      }
      if (lastStop is Map) {
        accentEnd = SduiStyle.color(lastStop['color']?.toString());
      }
    }
    accentStart ??= SduiStyle.color(
      first['styles']?['leftAccent']?['colorStart']?.toString(),
    ) ?? themeAccent;
    accentEnd ??= SduiStyle.color(
      first['styles']?['leftAccent']?['colorEnd']?.toString(),
    ) ?? themeAccent;

    if (background == null ||
        border == null ||
        borderWidth == null ||
        radius == null ||
        padding == null ||
        labelColor == null ||
        labelSize == null ||
        labelWeight == null ||
        themeAccent == null ||
        chipBackground == null ||
        chipColor == null ||
        chipHeight == null ||
        chipMinWidth == null ||
        chipPadding == null ||
        chipFontSize == null ||
        chipFontWeight == null ||
        (accentVisible && (accentWidth == null || accentStart == null || accentEnd == null))) {
      return const SchemaIssueWidget(
        title: 'Schema tokens missing',
        details: [
          'Provide parameterCard / theme colors for card background, border, text, accent',
          'and metaChip height/minWidth/paddingHorizontal/fontSize/fontWeight',
          'plus theme.radius.card, borders.size, spacing.cardPadding',
        ],
        componentType: 'apiControlGroup',
      );
    }

    final resolvedBackground = background;
    final resolvedBorder = border;
    final resolvedBorderWidth = borderWidth;
    final resolvedRadius = radius;
    final resolvedPadding = padding;
    final resolvedLabelColor = labelColor;
    final resolvedLabelSize = labelSize;
    final resolvedLabelWeight = labelWeight;
    final resolvedChipBackground = chipBackground;
    final resolvedChipColor = chipColor;
    final resolvedChipHeight = chipHeight;
    final resolvedChipMinWidth = chipMinWidth;
    final resolvedChipPadding = chipPadding;
    final resolvedChipFontSize = chipFontSize;
    final resolvedChipFontWeight = chipFontWeight;
    final resolvedAccentWidth = accentVisible ? (accentWidth ?? 0.0) : 0.0;

    final chipText = SchemaRuntime.parameterGroupChipLabel(
      count: controls.length,
      metaChipStyle: metaStyle,
    );
    final shadow = _shadowFromSchema(parameterStyle['shadow']);
    final overflow = parameterStyle['overflow']?.toString().trim().toLowerCase();
    final clipBehavior = switch (overflow) {
      'hidden' || 'clip' => Clip.hardEdge,
      'antialias' || 'antiAlias' => Clip.antiAlias,
      _ => Clip.none,
    };

    return Container(
      clipBehavior: clipBehavior,
      decoration: BoxDecoration(
        color: resolvedBackground,
        border: Border.all(color: resolvedBorder, width: resolvedBorderWidth),
        borderRadius: BorderRadius.circular(resolvedRadius),
        boxShadow: shadow == null ? const [] : [shadow],
      ),
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              resolvedPadding + resolvedAccentWidth,
              resolvedPadding,
              resolvedPadding,
              resolvedPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (label.isNotEmpty) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          labelStyle['uppercase'] == true
                              ? label.toUpperCase()
                              : label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: resolvedLabelColor,
                            fontSize: resolvedLabelSize,
                            fontWeight: resolvedLabelWeight,
                          ),
                        ),
                      ),
                      Container(
                        constraints: BoxConstraints(
                          minWidth: resolvedChipMinWidth,
                          minHeight: resolvedChipHeight,
                        ),
                        padding: EdgeInsets.symmetric(
                          horizontal: resolvedChipPadding,
                        ),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: resolvedChipBackground,
                          borderRadius: BorderRadius.circular(
                            resolvedChipHeight / 2,
                          ),
                        ),
                        child: Text(
                          chipText,
                          style: TextStyle(
                            color: resolvedChipColor,
                            fontSize: resolvedChipFontSize,
                            fontWeight: resolvedChipFontWeight,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: stackedGap),
                ],
                _responseRows(
                  controls: controls,
                  state: state,
                  renderer: renderer,
                  spacing: stackedGap,
                ),
              ],
            ),
          ),
          if (accentVisible)
            Positioned(
              left: 0,
              top: accentInset,
              bottom: accentInset,
              width: resolvedAccentWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [accentStart!, accentEnd!],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Response rows of a trigger command stay hidden until that trigger is on.
///
/// The schema says so with `deviceFrame.trigger_ui` containing true. The
/// trigger control itself (the power button) stays visible either way.
Widget _responseRows({
  required List<Map<String, dynamic>> controls,
  required AppState state,
  required SduiRenderer renderer,
  required double spacing,
}) {
  Map<String, dynamic>? trigger;
  for (final control in controls) {
    if (!AppState.frameRevealsResponseRows(control)) continue;
    trigger = control;
    break;
  }

  Widget column(List<Map<String, dynamic>> visible) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < visible.length; i++) ...[
          renderer.parameterCard(visible[i], embedded: true),
          if (i < visible.length - 1) SizedBox(height: spacing),
        ],
      ],
    );
  }

  if (trigger == null) return column(controls);

  final binding = trigger['binding']?.toString() ?? '';
  final revealBinding = trigger['revealBinding']?.toString().trim();
  final triggerId = trigger['id']?.toString();

  final listenables = <Listenable>[
    state.listenableForControl(
      id: triggerId,
      binding: binding,
    ),
  ];
  if (revealBinding != null && revealBinding.isNotEmpty) {
    listenables.add(state.listenableForBinding(revealBinding));
  }

  return AnimatedBuilder(
    animation: Listenable.merge(listenables),
    builder: (context, _) {
      final bindingVal = state.resolveBinding(binding);
      final revealVal = (revealBinding != null && revealBinding.isNotEmpty)
          ? state.resolveBinding(revealBinding)
          : null;
      final open = (revealVal != null && AppState.telemetryIsOn(revealVal)) ||
          AppState.telemetryIsOn(bindingVal);
      final visible = open
          ? controls
          : controls
              .where((control) => !AppState.isResponseControl(control))
              .toList(growable: false);
      return column(visible);
    },
  );
}

FontWeight? _fontWeightFromSchema(dynamic value) {
  final numeric = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  if (numeric == null) return null;
  final normalized = (numeric ~/ 100).clamp(1, 9);
  return FontWeight.values[normalized - 1];
}

BoxShadow? _shadowFromSchema(dynamic value) {
  if (value is! Map) return null;
  final color = SduiStyle.color(value['color']?.toString());
  final x = _ApiControlGroup._number(value['x']);
  final y = _ApiControlGroup._number(value['y']);
  final blur = _ApiControlGroup._number(value['blur']);
  if (color == null || x == null || y == null || blur == null) return null;
  return BoxShadow(color: color, offset: Offset(x, y), blurRadius: blur);
}

Curve _pageTransitionCurveFromSchema(Map<String, dynamic> schema) {
  final universalUi = schema['extensions'] is Map
      ? (schema['extensions'] as Map)['universalUi']
      : null;
  final animations = universalUi is Map ? universalUi['animations'] : null;
  final transition = animations is Map ? animations['pageTransition'] : null;
  final easing = transition is Map
      ? transition['easing']?.toString().trim().toLowerCase()
      : null;

  return switch (easing) {
    'linear' => Curves.linear,
    'easein' => Curves.easeIn,
    'easeout' => Curves.easeOut,
    'easeinout' => Curves.easeInOut,
    'easeincubic' => Curves.easeInCubic,
    'easeoutcubic' => Curves.easeOutCubic,
    'easeinoutcubic' => Curves.easeInOutCubic,
    _ => Curves.linear,
  };
}

double? _schemaNumber(dynamic value) {
  if (value is num) return value.toDouble();
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return null;

  // Schema dimensions may be emitted as logical numbers or CSS-like px/dp
  // strings. Flutter logical pixels map directly to the schema's
  // density-independent dimension contract.
  final simple = RegExp(
    r'^(-?[0-9]+(?:\.[0-9]+)?)\s*(?:px|dp|sp)?$',
    caseSensitive: false,
  ).firstMatch(raw);
  if (simple != null) return double.tryParse(simple.group(1)!);

  // Support the generator's simple form: calc(16px + 6px).
  final calc = RegExp(
    r'^calc\(\s*(-?[0-9]+(?:\.[0-9]+)?)\s*(?:px|dp)?\s*([+-])\s*'
    r'(-?[0-9]+(?:\.[0-9]+)?)\s*(?:px|dp)?\s*\)$',
    caseSensitive: false,
  ).firstMatch(raw);
  if (calc != null) {
    final a = double.tryParse(calc.group(1)!)!;
    final b = double.tryParse(calc.group(3)!)!;
    return calc.group(2) == '-' ? a - b : a + b;
  }
  return null;
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ page slider â”€â”€â”€â”€â”€â”€â”€â”€
class _PageSlider extends StatefulWidget {
  const _PageSlider({
    super.key,
    required this.state,
    required this.renderer,
    required this.pages,
  });
  final AppState state;
  final SduiRenderer renderer;
  final List<Map<String, dynamic>> pages;

  @override
  State<_PageSlider> createState() => _PageSliderState();
}

class _PageSliderState extends State<_PageSlider> {
  late PageController _controller;
  late List<ScrollController> _scrollControllers;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();

    _controller = PageController(
      initialPage: _safePageIndex(widget.state.activePageIndex),
    );
    _scrollControllers = List<ScrollController>.generate(
      widget.pages.length,
      (_) => ScrollController(),
    );

    widget.state.addListener(_syncFromState);
    _scheduleSync();
  }

  int _safePageIndex(int requestedIndex) {
    if (widget.pages.isEmpty) return 0;

    return requestedIndex.clamp(0, widget.pages.length - 1);
  }


  void _scheduleSync() {
    if (_syncScheduled || !mounted) return;

    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) {
        _syncFromState();
      }
    });
  }

  int _pageTransitionDurationMs() {
    final universalUi = widget.state.schema['extensions'] is Map
        ? (widget.state.schema['extensions'] as Map)['universalUi']
        : null;
    final animations = universalUi is Map ? universalUi['animations'] : null;
    final transition = animations is Map ? animations['pageTransition'] : null;
    final raw = transition is Map ? transition['durationMs'] : null;

    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  Curve _pageTransitionCurve() {
    final universalUi = widget.state.schema['extensions'] is Map
        ? (widget.state.schema['extensions'] as Map)['universalUi']
        : null;
    final animations = universalUi is Map ? universalUi['animations'] : null;
    final transition = animations is Map ? animations['pageTransition'] : null;
    final easing = transition is Map
        ? transition['easing']?.toString().trim().toLowerCase()
        : null;

    return switch (easing) {
      'linear' => Curves.linear,
      'easein' => Curves.easeIn,
      'easeout' => Curves.easeOut,
      'easeinout' => Curves.easeInOut,
      'easeincubic' => Curves.easeInCubic,
      'easeoutcubic' => Curves.easeOutCubic,
      'easeinoutcubic' => Curves.easeInOutCubic,
      _ => Curves.linear,
    };
  }

  void _syncFromState() {
    if (!mounted || widget.pages.isEmpty) return;

    final target = _safePageIndex(widget.state.activePageIndex);

    if (!_controller.hasClients) {
      _scheduleSync();
      return;
    }

    final current = _controller.page?.round() ?? _controller.initialPage;

    if (current == target) return;

    final durationMs = _pageTransitionDurationMs();

    if (durationMs <= 0) {
      _controller.jumpToPage(target);
      return;
    }

    _controller.animateToPage(
      target,
      duration: Duration(milliseconds: durationMs),
      curve: _pageTransitionCurve(),
    );
  }

  @override
  void didUpdateWidget(covariant _PageSlider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.removeListener(_syncFromState);
      widget.state.addListener(_syncFromState);
    }

    while (_scrollControllers.length < widget.pages.length) {
      _scrollControllers.add(ScrollController());
    }
    while (_scrollControllers.length > widget.pages.length) {
      final removed = _scrollControllers.removeLast();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        removed.dispose();
      });
    }

    _scheduleSync();
  }

  @override
  void dispose() {
    widget.state.removeListener(_syncFromState);
    _controller.dispose();
    for (final controller in _scrollControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) {
      return const SizedBox.shrink();
    }

    // A horizontal viewport must always receive a finite cross-axis height.
    // Normally the parent Flex supplies it. The fallback below protects the
    // renderer when an API schema nests the page viewport under a vertical
    // shrink-wrap/scrollable structure. The preferred height comes from the
    // schema preview contract and is capped to the actual device viewport.
    final mediaHeight = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final schemaPreviewHeight = _schemaNumber(
          widget
                  .state
                  .schema['extensions']?['universalUi']?['extensions']?['exactHtmlPreview']?['mobileView']?['device']?['previewHeight'] ??
              widget.state.schema['responsive']?['preview']?['height'],
        );

        final fallbackHeight = schemaPreviewHeight == null
            ? mediaHeight
            : schemaPreviewHeight.clamp(1.0, mediaHeight).toDouble();
        final viewportHeight =
            constraints.hasBoundedHeight &&
                constraints.maxHeight.isFinite &&
                constraints.maxHeight > 0
            ? constraints.maxHeight
            : fallbackHeight;

        return SizedBox(
          height: viewportHeight,
          child: AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[
              widget.state.navigationListenable,
              widget.state.schemaStructureListenable,
            ]),
            builder: (context, _) {
              return PageView.builder(
                controller: _controller,
                itemCount: widget.pages.length,
                onPageChanged: (index) {
                  if (widget.state.activePageIndex != index) {
                    widget.state.activePageIndex = index;
                  }
                },
                itemBuilder: (context, index) {
                  final page = widget.pages[index];

                  final pageId =
                      page['id']?.toString() ??
                      page['properties']?['pageId']?.toString() ??
                      'page_$index';

                  while (_scrollControllers.length <= index) {
                    _scrollControllers.add(ScrollController());
                  }
                  final scrollController = _scrollControllers[index];
                  final themeColors =
                      widget.state.schema['theme']?['colors'] as Map? ??
                      const {};
                  final thumbColor = SduiStyle.color(
                    themeColors['accent']?.toString(),
                  );
                  final trackColor = SduiStyle.color(
                    themeColors['border']?.toString(),
                  );
                  final scrollbarRadius = _schemaNumber(
                    widget.state.schema['theme']?['radius']?['pill'],
                  );
                  final scrollbarThickness = _schemaNumber(
                    widget
                        .state
                        .schema['extensions']?['universalUi']?['designSystem']?['componentStyles']?['progress']?['height'],
                  );
                  final effectiveThumbColor = thumbColor ??
                      SduiStyle.color(themeColors['primary']?.toString());
                  if (effectiveThumbColor == null ||
                      scrollbarThickness == null ||
                      scrollbarRadius == null) {
                    return const SchemaIssueWidget(
                      title: 'Schema tokens missing',
                      details: [
                        'Provide theme.colors.accent or primary for scrollbar thumb',
                        'theme.radius.pill, and progress.height for thickness',
                      ],
                      componentType: 'pagePager',
                    );
                  }
                  final effectiveTrackColor = trackColor ?? Colors.transparent;
                  final effectiveRadius = scrollbarRadius;

                  final isPageEmpty =
                      page['children'] is List && (page['children'] as List).isEmpty;
                  final pageTitle = page['title']?.toString() ??
                      page['properties']?['title']?.toString() ??
                      page['properties']?['label']?.toString();
                  final pageBody = isPageEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 30.0),
                            child: MiniOrbitPageLoadingView(
                              pageNo: index + 1,
                              pageTitle: pageTitle,
                              accentColor: effectiveThumbColor,
                            ),
                          ),
                        )
                      : widget.renderer.build(context, page);

                  return _KeepAlivePageSlide(
                    key: ValueKey(pageId.isNotEmpty ? pageId : 'page_idx_$index'),
                    child: RawScrollbar(
                      controller: scrollController,
                      thumbVisibility: false,
                      trackVisibility: false,
                      interactive: true,
                      thumbColor: effectiveThumbColor.withValues(alpha: 0.6),
                      trackColor: effectiveTrackColor,
                      radius: Radius.circular(effectiveRadius),
                      thickness: math.min(scrollbarThickness, 4.0),
                      child: SingleChildScrollView(
                        controller: scrollController,
                        primary: false,
                        child: pageBody,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _KeepAlivePageSlide extends StatefulWidget {
  const _KeepAlivePageSlide({super.key, required this.child});
  final Widget child;

  @override
  State<_KeepAlivePageSlide> createState() => _KeepAlivePageSlideState();
}

class _KeepAlivePageSlideState extends State<_KeepAlivePageSlide>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ SVG element types â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
sealed class _SvgElement {}

class _SvgPath extends _SvgElement {
  _SvgPath(this.d);
  final String d;
}

class _SvgCircle extends _SvgElement {
  _SvgCircle(this.cx, this.cy, this.r);
  final double cx, cy, r;
}

class _SvgLine extends _SvgElement {
  _SvgLine(this.x1, this.y1, this.x2, this.y2);
  final double x1, y1, x2, y2;
}

class _SvgRect extends _SvgElement {
  _SvgRect(this.x, this.y, this.w, this.h, this.rx);
  final double x, y, w, h, rx;
}

class _SvgPolyline extends _SvgElement {
  _SvgPolyline(this.coords);
  final List<double> coords;
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ SVG icon painter â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _SvgIconPainter extends CustomPainter {
  const _SvgIconPainter({required this.elements, required this.color});

  final List<_SvgElement> elements;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (elements.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale, scale);

    for (final el in elements) {
      try {
        switch (el) {
          case _SvgPath(:final d):
            _drawPathData(canvas, paint, d);
          case _SvgCircle(:final cx, :final cy, :final r):
            canvas.drawOval(
              Rect.fromCircle(center: Offset(cx, cy), radius: r),
              paint,
            );
          case _SvgLine(:final x1, :final y1, :final x2, :final y2):
            canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
          case _SvgRect(:final x, :final y, :final w, :final h, :final rx):
            if (rx > 0) {
              canvas.drawRRect(
                RRect.fromRectXY(Rect.fromLTWH(x, y, w, h), rx, rx),
                paint,
              );
            } else {
              canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
            }
          case _SvgPolyline(:final coords):
            final path = Path();
            path.moveTo(coords[0], coords[1]);
            for (var i = 2; i + 1 < coords.length; i += 2) {
              path.lineTo(coords[i], coords[i + 1]);
            }
            canvas.drawPath(path, paint);
        }
      } catch (_) {}
    }

    canvas.restore();
  }

  static void _drawPathData(Canvas canvas, Paint paint, String d) {
    final path = Path();
    final re = RegExp(
      r'([MmLlHhVvCcSsQqTtAaZz])|'
      r'([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)',
    );
    final tokens = re.allMatches(d.trim()).map((m) => m.group(0)!).toList();

    int i = 0;
    double cx = 0, cy = 0;
    double? lastCpx, lastCpy;
    String cmd = 'M';

    double nextNum() {
      while (i < tokens.length && RegExp(r'^[A-Za-z]$').hasMatch(tokens[i])) {
        i++;
      }
      if (i < tokens.length) return double.tryParse(tokens[i++]) ?? 0;
      return 0;
    }

    while (i < tokens.length) {
      final t = tokens[i];
      if (RegExp(r'^[A-Za-z]$').hasMatch(t)) {
        cmd = t;
        i++;
        if (cmd == 'z' || cmd == 'Z') {
          path.close();
          lastCpx = lastCpy = null;
          continue;
        }
      }

      final bool rel = cmd == cmd.toLowerCase();

      switch (cmd.toUpperCase()) {
        case 'M':
          final x = nextNum() + (rel ? cx : 0);
          final y = nextNum() + (rel ? cy : 0);
          path.moveTo(x, y);
          cx = x;
          cy = y;
          cmd = rel ? 'l' : 'L';
        case 'L':
          final x = nextNum() + (rel ? cx : 0);
          final y = nextNum() + (rel ? cy : 0);
          path.lineTo(x, y);
          cx = x;
          cy = y;
        case 'H':
          final x = nextNum() + (rel ? cx : 0);
          path.lineTo(x, cy);
          cx = x;
        case 'V':
          final y = nextNum() + (rel ? cy : 0);
          path.lineTo(cx, y);
          cy = y;
        case 'C':
          final x1 = nextNum() + (rel ? cx : 0);
          final y1 = nextNum() + (rel ? cy : 0);
          final x2 = nextNum() + (rel ? cx : 0);
          final y2 = nextNum() + (rel ? cy : 0);
          final x = nextNum() + (rel ? cx : 0);
          final y = nextNum() + (rel ? cy : 0);
          path.cubicTo(x1, y1, x2, y2, x, y);
          lastCpx = x2;
          lastCpy = y2;
          cx = x;
          cy = y;
        case 'S':
          final rfx = cx + (cx - (lastCpx ?? cx));
          final rfy = cy + (cy - (lastCpy ?? cy));
          final x2 = nextNum() + (rel ? cx : 0);
          final y2 = nextNum() + (rel ? cy : 0);
          final x = nextNum() + (rel ? cx : 0);
          final y = nextNum() + (rel ? cy : 0);
          path.cubicTo(rfx, rfy, x2, y2, x, y);
          lastCpx = x2;
          lastCpy = y2;
          cx = x;
          cy = y;
        case 'Q':
          final x1 = nextNum() + (rel ? cx : 0);
          final y1 = nextNum() + (rel ? cy : 0);
          final x = nextNum() + (rel ? cx : 0);
          final y = nextNum() + (rel ? cy : 0);
          path.quadraticBezierTo(x1, y1, x, y);
          lastCpx = x1;
          lastCpy = y1;
          cx = x;
          cy = y;
        case 'T':
          final rfx = cx + (cx - (lastCpx ?? cx));
          final rfy = cy + (cy - (lastCpy ?? cy));
          final x = nextNum() + (rel ? cx : 0);
          final y = nextNum() + (rel ? cy : 0);
          path.quadraticBezierTo(rfx, rfy, x, y);
          lastCpx = rfx;
          lastCpy = rfy;
          cx = x;
          cy = y;
        case 'A':
          final rx = nextNum();
          final ry = nextNum();
          nextNum();
          nextNum();
          nextNum();
          final x = nextNum() + (rel ? cx : 0);
          final y = nextNum() + (rel ? cy : 0);
          path.arcToPoint(Offset(x, y), radius: Radius.circular((rx + ry) / 2));
          cx = x;
          cy = y;
        default:
          i++;
      }

      if (!{'C', 'S', 'Q', 'T'}.contains(cmd.toUpperCase())) {
        lastCpx = lastCpy = null;
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SvgIconPainter old) =>
      old.color != color || old.elements != elements;
}
