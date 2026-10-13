import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'action_registry.dart';
import 'renderer.dart';
import 'style.dart';
import 'schema_guard.dart';

/// Signature for component builders in the SDUI framework.
typedef SduiComponentBuilder =
    Widget Function({
      required BuildContext context,
      required Map<String, dynamic> node,
      required Map<String, dynamic> props,
      required SduiStyle style,
      required List<Map<String, dynamic>> children,
      required AppState state,
      required SduiRenderer renderer,
      String? groupBinding,
    });

/// Lightweight error widget displaying missing components or actions cleanly for debugging.
class SduiErrorWidget extends StatelessWidget {
  const SduiErrorWidget({
    super.key,
    required this.message,
    this.details = const [],
  });

  final String message;
  final List<String> details;

  @override
  Widget build(BuildContext context) => SchemaIssueWidget(
    title: message,
    details: details.isEmpty
        ? const [
            'The renderer did not invent a fallback. Correct the schema and reload.',
          ]
        : details,
  );
}

/// Fully dynamic Component Registry for the SDUI Engine.
class ComponentRegistry {
  ComponentRegistry._() {
    _registerDefaultComponents();
  }

  static final ComponentRegistry instance = ComponentRegistry._();

  final Map<String, SduiComponentBuilder> _builders = {};

  static String _normalize(String type) => type
      .trim()
      .toLowerCase()
      .replaceAll('-', '')
      .replaceAll('_', '')
      .replaceAll(' ', '');

  /// Register a component builder dynamically.
  void register(String componentType, SduiComponentBuilder builder) {
    if (componentType.trim().isEmpty) return;
    _builders[_normalize(componentType)] = builder;
  }

  /// Check if a component type is registered.
  bool hasBuilder(String componentType) =>
      _builders.containsKey(_normalize(componentType));

  /// Main entry point to build a component widget by requesting from registry or schema.
  Widget build({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    final rawType = node['type']?.toString() ?? '';
    final normalized = _normalize(rawType);

    // Canonical aliases declared by the schema contract.
    final canonical = <String, String>{
      'dropdownbutton': 'dropdown',
      'text': 'value',
      'auto': 'value',
      'sliderwithlabel': 'slider',
    }[normalized];
    final resolvedType = canonical == null ? normalized : _normalize(canonical);

    // Resolve API-defined components before code builders when their template
    // expands to a different primitive root (for example IconButton ->
    // container). This lets future components composed from known primitives
    // work without a Flutter release while avoiding self-recursion for
    // ButtonGroup and FireControlPanel, whose template root is the same type.
    final schemaComponent = _resolveSchemaComponent(rawType, state);
    final schemaTree = schemaComponent?['widgetTree'];
    final schemaRootType = schemaTree is Map
        ? _normalize(schemaTree['type']?.toString() ?? '')
        : '';
    final shouldExpandSchemaTemplate =
        schemaTree is Map &&
        schemaRootType.isNotEmpty &&
        schemaRootType != resolvedType;

    if (shouldExpandSchemaTemplate) {
      final binding = (props['binding'] ?? node['binding'] ?? groupBinding)
          ?.toString();
      final materialized = _materializeSchemaValue(schemaTree, <String, String>{
        if (binding != null) 'binding': binding,
      });
      if (materialized is Map) {
        final expanded = Map<String, dynamic>.from(materialized);
        final expandedProperties = Map<String, dynamic>.from(
          expanded['properties'] as Map? ?? const {},
        );
        final invocationEvents = props['events'] ?? node['events'];
        if (binding != null && binding.isNotEmpty) {
          expandedProperties['binding'] = binding;
        }
        if (invocationEvents != null) {
          expandedProperties['events'] = invocationEvents;
        }
        expanded['properties'] = expandedProperties;
        Widget result = renderer.build(
          context,
          expanded,
          binding ?? groupBinding,
        );
        return _wrapTemplateInteraction(
          child: result,
          binding: binding ?? '',
          events: invocationEvents,
          state: state,
        );
      }
    }

    // Registered algorithmic builders handle primitives and components whose
    // schema template root is the same algorithmic type.
    if (_builders.containsKey(resolvedType)) {
      return _builders[resolvedType]!(
        context: context,
        node: node,
        props: props,
        style: style,
        children: children,
        state: state,
        renderer: renderer,
        groupBinding: groupBinding,
      );
    }

    // Components without a native builder can still expand from the API.
    if (schemaTree is Map) {
      final binding = (props['binding'] ?? node['binding'] ?? groupBinding)
          ?.toString();
      final materialized = _materializeSchemaValue(schemaTree, <String, String>{
        if (binding != null) 'binding': binding,
      });
      if (materialized is Map) {
        return renderer.build(
          context,
          Map<String, dynamic>.from(materialized),
          binding ?? groupBinding,
        );
      }
    }

    // Fallback to clean, lightweight error widget
    return SduiErrorWidget(message: 'Component not registered: $rawType');
  }

  static Widget _wrapTemplateInteraction({
    required Widget child,
    required String binding,
    required dynamic events,
    required AppState state,
  }) {
    if (binding.isEmpty || events is! List || events.isEmpty) return child;
    final eventMaps = events.whereType<Map>().toList();
    final hasTapLikeEvent = eventMaps.any((event) {
      final name = event['event']?.toString().toLowerCase() ?? '';
      return name == 'ontap' || name == 'onpressed' || name == 'onclick';
    });
    if (!hasTapLikeEvent) return child;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        final current = state.resolveBinding(binding);
        for (final event in eventMaps) {
          final action = event['action'];
          if (action is! Map) continue;
          final type = action['type']?.toString().toLowerCase() ?? '';
          if (type == 'update') {
            final targetBinding = (action['binding']?.toString().trim().isNotEmpty ?? false)
                ? action['binding']!.toString().trim()
                : binding;
            final isToggle = action['toggle'] == true ||
                action['toggle']?.toString().toLowerCase() == 'true';
            final explicit = action['value'];
            if (isToggle) {
              final targetCurrent = state.resolveBinding(targetBinding);
              final targetOn = AppState.telemetryIsOn(targetCurrent);
              state.setBinding(targetBinding, !targetOn);
            } else if (explicit != null) {
              state.setBinding(targetBinding, explicit);
            } else if (current is bool) {
              state.setBinding(targetBinding, !current);
            } else {
              final currentOn = AppState.telemetryIsOn(current);
              state.setBinding(targetBinding, !currentOn);
            }
          } else if (type == 'send') {
            await state.sendBinding(binding);
          }
        }
      },
      child: child,
    );
  }

  dynamic _materializeSchemaValue(
    dynamic value,
    Map<String, String> variables,
  ) {
    if (value is String) {
      var result = value;
      for (final entry in variables.entries) {
        result = result.replaceAll('{{${entry.key}}}', entry.value);
      }
      return result;
    }
    if (value is List) {
      return value
          .map((item) => _materializeSchemaValue(item, variables))
          .toList();
    }
    if (value is Map) {
      return value.map(
        (key, item) =>
            MapEntry(key.toString(), _materializeSchemaValue(item, variables)),
      );
    }
    return value;
  }

  /// Helper to resolve component definition from schema registerComponents or catalog.
  Map<String, dynamic>? _resolveSchemaComponent(String type, AppState state) {
    final normalizedTarget = _normalize(type);
    if (normalizedTarget.isEmpty) return null;

    final registerComponents = state.schema['registerComponents'];
    if (registerComponents is Map) {
      for (final entry in registerComponents.entries) {
        if (_normalize(entry.key) == normalizedTarget && entry.value is Map) {
          return Map<String, dynamic>.from(entry.value as Map);
        }
      }
    }

    final catalog = state.schema['components']?['catalog'];
    if (catalog is List) {
      for (final entry in catalog) {
        if (entry is Map &&
            _normalize(entry['id']?.toString() ?? '') == normalizedTarget) {
          return Map<String, dynamic>.from(entry);
        }
      }
    }

    return null;
  }

  /// Resolves the shared Switch visual contract without depending on a
  /// model number, node id, parameter name, control id, or schema version.
  ///
  /// Priority:
  /// 1. canonical universalUi design-system contract;
  /// 2. concrete tree selected by rendering.layout;
  /// 3. ui.widgetTree compatibility projection.
  ///
  /// Control-local props/style still override this shared contract in the
  /// actual switch builder.
  static Map<String, dynamic> _resolveSharedSwitchContract(
    Map<String, dynamic> schema,
  ) {
    final canonical =
        schema['extensions']?['universalUi']?['designSystem']?['componentStyles']?['parameterCard']?['parts']?['switch'];
    if (canonical is Map) {
      return Map<String, dynamic>.from(canonical);
    }

    bool isSwitchContract(Map<dynamic, dynamic> candidate) {
      return candidate['trackWidth'] is num &&
          candidate['trackHeight'] is num &&
          candidate['thumbSize'] is num;
    }

    Map<String, dynamic>? walk(dynamic value) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.key.toString().trim().toLowerCase() == 'switch' &&
              entry.value is Map &&
              isSwitchContract(entry.value as Map)) {
            return Map<String, dynamic>.from(entry.value as Map);
          }
        }
        for (final child in value.values) {
          final found = walk(child);
          if (found != null) return found;
        }
      } else if (value is List) {
        for (final child in value) {
          final found = walk(child);
          if (found != null) return found;
        }
      }
      return null;
    }

    dynamic valueAtPath(String rawPath) {
      final path = rawPath.trim();
      if (path.isEmpty) return null;
      dynamic current = schema;
      for (final rawPart in path.split('.')) {
        if (current is! Map) return null;
        final part = rawPart.trim().toLowerCase();
        dynamic matchedKey;
        for (final key in current.keys) {
          if (key.toString().trim().toLowerCase() == part) {
            matchedKey = key;
            break;
          }
        }
        if (matchedKey == null) return null;
        current = current[matchedKey];
      }
      return current;
    }

    final renderingLayout =
        schema['rendering']?['layout']?.toString().trim() ?? '';
    final declaredTree = renderingLayout.isEmpty
        ? null
        : valueAtPath(renderingLayout);

    return walk(declaredTree) ??
        walk(schema['ui']?['widgetTree']) ??
        const <String, dynamic>{};
  }

  /// Register built-in SDUI components.
  void _registerDefaultComponents() {
    _registerPrimitives();
    _registerControlComponents();
  }

  void _registerPrimitives() {
    // Custom / Container fallback children builder
    register('custom', ({
      required context,
      required node,
      required props,
      required style,
      required children,
      required state,
      required renderer,
      groupBinding,
    }) {
      if (children.isNotEmpty) {
        return Column(
          children: children
              .map((c) => renderer.build(context, c, groupBinding))
              .toList(),
        );
      }
      return const SizedBox.shrink();
    });
  }

  void _registerControlComponents() {
    // Switch component
    register('switch', ({
      required context,
      required node,
      required props,
      required style,
      required children,
      required state,
      required renderer,
      groupBinding,
    }) {
      final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
      final value = state.resolveBinding(binding);

      final themeColors = state.schema['theme']?['colors'] as Map? ?? const {};
      final switchPart = _resolveSharedSwitchContract(state.schema);

      // Resolve semantic ON/OFF properties first. The web renderer uses the
      // design-system switch contract, while active/inactive aliases are kept
      // only for schemas that do not expose on/off names.
      // The canonical visual source for every switch is the shared
      // ParameterCard switch contract. Control-level aliases are consulted only
      // when that canonical contract omits a value. This matches the web
      // renderer and prevents duplicated control copies from overriding the
      // design-system state colors.
      final nodeSwitch =
          (props['switch'] is Map ? props['switch'] as Map : null) ??
          (props['cardStyle'] is Map && props['cardStyle']['switch'] is Map
              ? props['cardStyle']['switch'] as Map
              : null) ??
          (style.s['switch'] is Map ? style.s['switch'] as Map : null);

      final activeTrack = SduiStyle.color(
        props['onTrackColor'] ??
            props['activeTrackColor'] ??
            props['activeColor'] ??
            nodeSwitch?['onTrackColor'] ??
            nodeSwitch?['activeTrackColor'] ??
            nodeSwitch?['activeColor'] ??
            style.s['onTrackColor'] ??
            style.s['activeTrackColor'] ??
            switchPart['onTrackColor'] ??
            themeColors['toggleOn'],
      );
      final inactiveTrack = SduiStyle.color(
        props['offTrackColor'] ??
            props['inactiveTrackColor'] ??
            props['inactiveColor'] ??
            nodeSwitch?['offTrackColor'] ??
            nodeSwitch?['inactiveTrackColor'] ??
            nodeSwitch?['inactiveColor'] ??
            style.s['offTrackColor'] ??
            style.s['inactiveTrackColor'] ??
            switchPart['offTrackColor'] ??
            themeColors['toggleOff'],
      );
      final activeThumb = SduiStyle.color(
        props['onThumbColor'] ??
            props['activeThumbColor'] ??
            nodeSwitch?['onThumbColor'] ??
            nodeSwitch?['activeThumbColor'] ??
            style.s['onThumbColor'] ??
            style.s['activeThumbColor'] ??
            switchPart['onThumbColor'] ??
            themeColors['surface'],
      );
      final inactiveThumb = SduiStyle.color(
        props['offThumbColor'] ??
            props['inactiveThumbColor'] ??
            nodeSwitch?['offThumbColor'] ??
            nodeSwitch?['inactiveThumbColor'] ??
            style.s['offThumbColor'] ??
            style.s['inactiveThumbColor'] ??
            switchPart['offThumbColor'] ??
            themeColors['surface'],
      );
      final trackWidth = _asDouble(
        props['trackWidth'] ??
            nodeSwitch?['trackWidth'] ??
            style.s['trackWidth'] ??
            switchPart['trackWidth'],
      );
      final trackHeight = _asDouble(
        props['trackHeight'] ??
            nodeSwitch?['trackHeight'] ??
            style.s['trackHeight'] ??
            switchPart['trackHeight'],
      );
      final thumbSize = _asDouble(
        props['thumbSize'] ??
            nodeSwitch?['thumbSize'] ??
            style.s['thumbSize'] ??
            switchPart['thumbSize'],
      );

      if (binding.isEmpty ||
          activeTrack == null ||
          inactiveTrack == null ||
          activeThumb == null ||
          inactiveThumb == null ||
          trackWidth == null ||
          trackHeight == null ||
          thumbSize == null) {
        return SchemaIssueWidget(
          title: 'Invalid switch schema',
          details: [
            if (binding.isEmpty) 'binding — required non-empty binding',
            if (activeTrack == null)
              'activeTrackColor/onTrackColor/activeColor — required valid color',
            if (inactiveTrack == null)
              'inactiveTrackColor/offTrackColor/inactiveColor — required valid color',
            if (activeThumb == null)
              'activeThumbColor/onThumbColor — required valid color',
            if (inactiveThumb == null)
              'inactiveThumbColor/offThumbColor — required valid color',
            if (trackWidth == null)
              'extensions.universalUi.designSystem.componentStyles.parameterCard.parts.switch.trackWidth — required number',
            if (trackHeight == null)
              'extensions.universalUi.designSystem.componentStyles.parameterCard.parts.switch.trackHeight — required number',
            if (thumbSize == null)
              'extensions.universalUi.designSystem.componentStyles.parameterCard.parts.switch.thumbSize — required number',
          ],
          componentType: node['type']?.toString(),
          binding: binding,
        );
      }

      final isOn =
          value == true ||
          value == 1 ||
          value.toString().toLowerCase() == 'on' ||
          value.toString().toLowerCase() == 'true';

      final resolvedTrackColor = isOn ? activeTrack : inactiveTrack;
      final resolvedThumbColor = isOn ? activeThumb : inactiveThumb;
      final horizontalInset = (trackHeight - thumbSize).abs() / 2;

      return Semantics(
        toggled: isOn,
        button: true,
        child: GestureDetector(
          onTap: state.isBindingWritable(binding)
              ? () => state.setBinding(binding, !isOn)
              : null,
          child: SizedBox(
            width: trackWidth,
            height: trackHeight > thumbSize ? trackHeight : thumbSize,
            child: Center(
              child: Container(
                width: trackWidth,
                height: trackHeight,
                padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                decoration: BoxDecoration(
                  color: resolvedTrackColor,
                  borderRadius: BorderRadius.circular(trackHeight / 2),
                ),
                child: Align(
                  alignment: isOn
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: BoxDecoration(
                      color: resolvedThumbColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });

    // Slider & SliderWithLabel component
    register('slider', _buildSliderWidget);
    register('sliderwithlabel', _buildSliderWidget);
    register('schemaslider', _buildSliderWidget);

    // Gauge & PowerGauge
    register('gauge', _buildRadialGaugeWidget);
    register('powergauge', _buildRadialGaugeWidget);
    register('AnimatedRadialGauge', _buildRadialGaugeWidget);
    register('NeedleGauge', _buildRadialGaugeWidget);
    register('RotaryKnob', _buildRadialGaugeWidget);
    register('LinearGauge', _buildLinearGaugeWidget);
    register('SegmentedControl', _buildButtonGroupWidget);
    register('segmented', _buildButtonGroupWidget);
    register('ButtonGroup', _buildButtonGroupWidget);
    register('FireControlPanel', _buildFireControlPanelWidget);
    register('ToggleButton', _buildToggleButtonWidget);
    register('IconButton', _buildIconButtonWidget);

    // NeedleGauge
    register('needlegauge', ({
      required context,
      required node,
      required props,
      required style,
      required children,
      required state,
      required renderer,
      groupBinding,
    }) {
      final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
      final value = state.resolveBinding(binding);

      final axis = (props['axis'] as Map?) ?? const {};
      final gMin =
          (axis['min'] as num?)?.toDouble() ??
          (axis['minimum'] as num?)?.toDouble();
      final gMax =
          (axis['max'] as num?)?.toDouble() ??
          (axis['maximum'] as num?)?.toDouble();
      if (gMin == null || gMax == null || gMax <= gMin) {
        return SchemaIssueWidget(
          title: 'Invalid needleGauge range schema',
          details: [
            if (gMin == null) 'props.axis.min/minimum — required number',
            if (gMax == null) 'props.axis.max/maximum — required number',
            if (gMin != null && gMax != null && gMax <= gMin)
              'axis.max must be greater than axis.min',
          ],
          componentType: node['type']?.toString(),
          binding: binding,
        );
      }

      final currentVal = value is num
          ? value.toDouble()
          : (double.tryParse(value?.toString() ?? '') ?? gMin);
      final clampedVal = currentVal.clamp(gMin, gMax);

      final width = (props['width'] as num?)?.toDouble();
      final height = (props['height'] as num?)?.toDouble();
      final accentColor = SduiStyle.color(
        props['activeColor'] ?? style.s['accentColor'],
      );
      final inactiveColor = SduiStyle.color(props['inactiveColor']);
      final needleColor = SduiStyle.color(props['needleColor']);
      final trackWidth = (props['trackWidth'] as num?)?.toDouble();
      final needleWidth = (props['needleWidth'] as num?)?.toDouble();
      final centerRadius = (props['centerRadius'] as num?)?.toDouble();
      if (width == null ||
          height == null ||
          accentColor == null ||
          inactiveColor == null ||
          needleColor == null ||
          trackWidth == null ||
          needleWidth == null ||
          centerRadius == null) {
        return SchemaIssueWidget(
          title: 'Invalid needleGauge schema',
          details: [
            if (width == null) 'props.width — required number',
            if (height == null) 'props.height — required number',
            if (accentColor == null)
              'props.activeColor/style.accentColor — required valid color',
            if (inactiveColor == null)
              'props.inactiveColor — required valid color',
            if (needleColor == null) 'props.needleColor — required valid color',
            if (trackWidth == null) 'props.trackWidth — required number',
            if (needleWidth == null) 'props.needleWidth — required number',
            if (centerRadius == null) 'props.centerRadius — required number',
          ],
          componentType: node['type']?.toString(),
          binding: binding,
        );
      }
      return SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _GaugeNeedlePainter(
            value: clampedVal,
            min: gMin,
            max: gMax,
            accentColor: accentColor,
            inactiveColor: inactiveColor,
            needleColor: needleColor,
            trackWidth: trackWidth,
            needleWidth: needleWidth,
            centerRadius: centerRadius,
          ),
        ),
      );
    });

    // Dropdown component. Field geometry, typography and menu appearance
    // are consumed from schema when declared; no model/control-name logic is used.
    register('dropdown', ({
      required context,
      required node,
      required props,
      required style,
      required children,
      required state,
      required renderer,
      groupBinding,
    }) {
      final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
      final value = state.resolveBinding(binding);
      final theme = state.schema['theme'] as Map? ?? const {};
      final themeColors = theme['colors'] as Map? ?? const {};
      final typography = theme['typography'] as Map? ?? const {};

      final rawOptions = props['options'] ??
          node['options'] ??
          node['properties']?['props']?['options'] ??
          (node['properties'] is Map ? (node['properties'] as Map)['options'] : null);
      var options = AppState.normalizeEnumOptions(
        rawOptions,
        rawValues: props['values'] ?? node['values'],
      );
      if (options.isEmpty && binding.isNotEmpty) {
        for (final ctrl in state.controls) {
          if (ctrl['binding']?.toString() == binding) {
            options = AppState.optionsFor(ctrl);
            if (options.isNotEmpty) break;
          }
        }
      }

      final textColor = SduiStyle.color(
        props['textColor'] ?? themeColors['text'],
      );
      final backgroundColor = SduiStyle.color(
        props['backgroundColor'] ?? props['container']?['backgroundColor'],
      );
      final borderColor = SduiStyle.color(
        props['borderColor'] ?? props['container']?['borderColor'],
      );
      final borderWidth = _asDouble(
        props['borderWidth'] ?? props['container']?['borderWidth'],
      );
      final borderRadius = _asDouble(
        props['borderRadius'] ?? props['container']?['borderRadius'],
      );
      final fieldHeight = _asDouble(props['height'] ?? props['fieldHeight']);
      final menuMaxHeight = _asDouble(props['menuMaxHeight']);
      final itemHeight = _asDouble(
        props['itemHeight'] ?? props['optionHeight'],
      );
      final padding = _edgeInsets(
        props['padding'] ?? props['container']?['padding'],
      );
      final fontFamily = (props['fontFamily'] ?? typography['fontFamily'])
          ?.toString()
          .trim();
      final fontSize = _asDouble(props['fontSize'] ?? typography['bodySize']);
      final fontWeight = SduiStyle.fontWeight(
        props['fontWeight'] ?? typography['bodyWeight'],
      );
      final dropdownStyle =
          style.textStyle(
            TextStyle(
              color: textColor,
              fontFamily: fontFamily == null || fontFamily.isEmpty
                  ? null
                  : fontFamily,
              fontSize: fontSize,
              fontWeight: fontWeight,
            ),
          ) ??
          TextStyle(
            color: textColor,
            fontFamily: fontFamily == null || fontFamily.isEmpty
                ? null
                : fontFamily,
            fontSize: fontSize,
            fontWeight: fontWeight,
          );

      Map<String, dynamic>? selectedOption;
      final isRawBracketString = value is String &&
          RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(value.trim());
      if (!isRawBracketString && value != null) {
        Map<String, dynamic>? controlForBinding;
        if (binding.isNotEmpty) {
          for (final ctrl in state.controls) {
            if (ctrl['binding']?.toString() == binding) {
              controlForBinding = ctrl;
              break;
            }
          }
        }
        if (controlForBinding != null) {
          selectedOption =
              AppState.resolveEnumOption(controlForBinding, value);
        }
        if (selectedOption == null) {
          for (final option in options) {
            if (AppState.enumOptionEntryMatches(option, value)) {
              selectedOption = option;
              break;
            }
          }
        }
      }
      final currentValue = selectedOption?['value'];

      // DropdownButton uses a 48 logical-pixel closed-button height when it is
      // not dense. Some SDUI schemas intentionally declare a smaller field
      // height (for example 44 logical pixels). Constraining a non-dense
      // DropdownButton below kMinInteractiveDimension makes Flutter's internal
      // vertical Flex overflow. Keep the schema's field height, but
      // automatically use the compact DropdownButton layout whenever that
      // height cannot contain the framework's normal interactive dimension.
      // This is geometry-driven and applies to every schema/account.
      final schemaDense = props['isDense'];
      final effectiveIsDense = schemaDense == true ||
          (fieldHeight != null && fieldHeight < kMinInteractiveDimension);

      final rawHint = (props['hint'] ?? node['hint'])?.toString().trim() ?? '';
      final hintText = rawHint.isEmpty ? 'Choose' : rawHint;

      final dropdown = DropdownButton<dynamic>(
        value: options.isEmpty ? null : currentValue,
        hint: Text(
          hintText,
          style: dropdownStyle.copyWith(
            color: dropdownStyle.color?.withValues(alpha: 0.6),
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        underline: const SizedBox.shrink(),
        isExpanded: props['isExpanded'] == true,
        isDense: effectiveIsDense,
        dropdownColor: backgroundColor,
        menuMaxHeight: menuMaxHeight,
        itemHeight: itemHeight != null && itemHeight >= kMinInteractiveDimension
            ? itemHeight
            : null,
        borderRadius: borderRadius == null
            ? null
            : BorderRadius.circular(borderRadius),
        style: dropdownStyle,
        items: options.isEmpty
            ? const <DropdownMenuItem<dynamic>>[]
            : [
                for (final o in options)
                  DropdownMenuItem(
                    value: o['value'],
                    child: Text(
                      o['label']?.toString() ?? o['value'].toString(),
                      style: dropdownStyle,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
              ],
        onChanged: binding.isNotEmpty && options.isNotEmpty
            ? (v) => state.setBinding(binding, v)
            : null,
      );

      Widget result = dropdown;
      if (padding != null ||
          backgroundColor != null ||
          borderColor != null ||
          borderRadius != null) {
        result = Container(
          padding: padding,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: borderRadius == null
                ? null
                : BorderRadius.circular(borderRadius),
            border: borderColor == null
                ? null
                : Border.all(color: borderColor, width: borderWidth ?? 1),
          ),
          child: result,
        );
      }
      if (fieldHeight != null) {
        result = SizedBox(height: fieldHeight, child: result);
      }
      return result;
    });

    // ElevatedButton component. All visual values come from the schema.
    register('elevatedbutton', ({
      required context,
      required node,
      required props,
      required style,
      required children,
      required state,
      required renderer,
      groupBinding,
    }) {
      final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
      final value = state.resolveBinding(binding);
      final theme = state.schema['theme'] as Map? ?? const {};
      final themeColors = theme['colors'] as Map? ?? const {};
      final themeRadius = theme['radius'] as Map? ?? const {};
      final themeSpacing = theme['spacing'] as Map? ?? const {};
      String? firstNonEmpty(List<dynamic> values) {
        for (final value in values) {
          final text = value?.toString().trim();
          if (text != null && text.isNotEmpty) return text;
        }
        return null;
      }

      Map<String, dynamic>? triggerControl;
      List<Map<String, dynamic>> triggerOptions = const [];
      if (binding.isNotEmpty) {
        for (final ctrl in state.controls) {
          if (ctrl['binding']?.toString() == binding) {
            triggerControl = ctrl;
            break;
          }
        }
        if (triggerControl != null) {
          final valueType =
              triggerControl['valueType']?.toString().trim().toLowerCase();
          if (valueType == 'trigger') {
            triggerOptions = AppState.optionsFor(triggerControl);
          }
        }
      }

      final staticLabel = firstNonEmpty([
        props['label'],
        props['actionText'],
        props['text'],
        triggerControl?['label'],
        triggerControl?['parameter'],
        triggerControl?['parameterName'],
        triggerControl?['rightAccessory'] is Map
            ? (triggerControl!['rightAccessory'] as Map)['label']
            : null,
      ]);

      // labelBinding often points at the same parameter binding. Until a real
      // protocol value arrives the binding may still hold the schema field
      // name — treat that as unset and keep the schema static caption.
      String? liveLabel;
      if (props['labelBinding'] != null) {
        final raw =
            state.resolveBinding(props['labelBinding'].toString());
        final rawText = raw?.toString().trim() ?? '';
        final isPlaceholder = rawText.isEmpty ||
            (triggerControl != null &&
                AppState.isFrameFieldNameOrPlaceholder(
                  triggerControl,
                  raw,
                ));
        if (!isPlaceholder) {
          liveLabel = rawText;
        }
      }

      // When the control declares options, map the live protocol value through
      // those schema options (no product-specific labels).
      String? mappedTriggerLabel;
      if (triggerOptions.isNotEmpty) {
        final matched = triggerControl != null
            ? AppState.resolveEnumOption(triggerControl, value)
            : null;
        final optionLabel = matched?['label']?.toString().trim();
        if (optionLabel != null && optionLabel.isNotEmpty) {
          mappedTriggerLabel = staticLabel != null &&
                  staticLabel.toLowerCase() != optionLabel.toLowerCase()
              ? '$staticLabel: $optionLabel'
              : optionLabel;
        }
      }

      final label = mappedTriggerLabel ??
          staticLabel ??
          liveLabel ??
          firstNonEmpty([
            if (value != null &&
                (triggerControl == null ||
                    !AppState.isFrameFieldNameOrPlaceholder(
                      triggerControl,
                      value,
                    )))
              value,
          ]);
      final backgroundColor = SduiStyle.color(
        props['backgroundColor'] ??
            props['color'] ??
            themeColors['buttonBg'] ??
            themeColors['primary'],
      );
      final textColor = SduiStyle.color(
        props['textColor'] ??
            themeColors['buttonText'] ??
            themeColors['surface'],
      );
      final borderColor = SduiStyle.color(
        props['borderColor'] ?? backgroundColor,
      );
      final borderWidth = (props['borderWidth'] as num?)?.toDouble() ?? 0;
      // Radius / padding come only from control props or schema theme tokens.
      final borderRadius =
          (props['borderRadius'] as num?)?.toDouble() ??
          (themeRadius['button'] as num?)?.toDouble();
      final paddingMap = props['padding'] is Map
          ? Map<String, dynamic>.from(props['padding'] as Map)
          : null;
      final schemaPadding = (themeSpacing['cardPadding'] as num?)?.toDouble();
      final uniformPadding = props['padding'] is num
          ? (props['padding'] as num).toDouble()
          : null;
      final top = (paddingMap?['top'] as num?)?.toDouble() ??
          uniformPadding ??
          schemaPadding;
      final right = (paddingMap?['right'] as num?)?.toDouble() ??
          uniformPadding ??
          schemaPadding;
      final bottom = (paddingMap?['bottom'] as num?)?.toDouble() ??
          uniformPadding ??
          schemaPadding;
      final left = (paddingMap?['left'] as num?)?.toDouble() ??
          uniformPadding ??
          schemaPadding;

      if (binding.isEmpty ||
          label == null ||
          label.isEmpty ||
          backgroundColor == null ||
          textColor == null ||
          borderColor == null ||
          borderRadius == null ||
          top == null ||
          right == null ||
          bottom == null ||
          left == null) {
        return SchemaIssueWidget(
          title: 'Invalid ElevatedButton schema',
          details: [
            if (binding.isEmpty)
              'properties.binding — required non-empty binding',
            if (label == null || label.isEmpty)
              'props.label or props.labelBinding — required label',
            if (backgroundColor == null)
              'props.backgroundColor/color — required valid color',
            if (textColor == null)
              'props.textColor — required valid color',
            if (borderColor == null)
              'props.borderColor or resolved background color — required valid color',
            if (borderRadius == null)
              'props.borderRadius — required number',
            if (top == null || right == null || bottom == null || left == null)
              'props.padding — required numeric padding',
          ],
          componentType: node['type']?.toString(),
          binding: binding,
        );
      }

      final screenWidth = MediaQuery.sizeOf(context).width;
      final isNarrow = screenWidth < 375;
      final effectiveLeft = isNarrow ? left.clamp(6.0, 10.0) : left;
      final effectiveRight = isNarrow ? right.clamp(6.0, 10.0) : right;

      return ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: textColor,
          padding: EdgeInsets.fromLTRB(effectiveLeft, top, effectiveRight, bottom),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(borderRadius),
            side: BorderSide(color: borderColor, width: borderWidth),
          ),
        ),
        onPressed: !state.isBindingWritable(binding)
            ? null
            : () async {
          // Triggers that declare schema options: cycle to the next option
          // value, then send via setBinding dispatch.
          if (triggerOptions.length >= 2) {
            var currentIndex = -1;
            for (var i = 0; i < triggerOptions.length; i++) {
              if (AppState.enumOptionEntryMatches(triggerOptions[i], value)) {
                currentIndex = i;
                break;
              }
            }
            final next =
                triggerOptions[(currentIndex + 1) % triggerOptions.length];
            state.setBinding(binding, next['value']);
            return;
          }
          final events = (props['events'] as List? ?? const [])
              .whereType<Map>();
          final hasSend = events.any(
            (event) =>
                event['action'] is Map &&
                (event['action'] as Map)['type']?.toString() == 'send',
          );
          if (hasSend) {
            await state.sendBinding(binding);
          } else {
            state.setBinding(binding, value);
          }
        },
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
          ),
        ),
      );
    });

    // PowerButton component. State styling is resolved only from schema.
    register('powerbutton', ({
      required context,
      required node,
      required props,
      required style,
      required children,
      required state,
      required renderer,
      groupBinding,
    }) {
      final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
      final current = state.resolveBinding(binding);
      final isOn =
          current == true ||
          current == 1 ||
          current?.toString().trim().toLowerCase() == 'on' ||
          current?.toString().trim().toLowerCase() == 'true';

      final themeColors = state.schema['theme']?['colors'] as Map? ?? const {};
      final activeColor = SduiStyle.color(
        props['activeColor'] ?? props['color'] ?? themeColors['buttonBg'],
      );
      final inactiveColor = SduiStyle.color(
        props['inactiveColor'] ?? themeColors['surface'],
      );
      final activeGlyphColor = SduiStyle.color(
        props['activeGlyphColor'] ??
            props['activeTextColor'] ??
            themeColors['buttonText'],
      );
      final inactiveGlyphColor = SduiStyle.color(
        props['inactiveGlyphColor'] ??
            props['color'] ??
            themeColors['buttonBg'],
      );
      final borderColor = SduiStyle.color(
        props['borderColor'] ?? props['color'] ?? themeColors['buttonBg'],
      );
      final size = _asDouble(props['size']);
      final actionDot = state
          .schema['extensions']?['universalUi']?['designSystem']?['componentStyles']?['parameterCard']?['parts']?['actionDot'];
      final borderWidth = _asDouble(
        props['borderWidth'] ??
            (actionDot is Map ? actionDot['borderWidth'] : null),
      );

      final issues = <String>[];
      if (binding.isEmpty)
        issues.add('properties.binding — required non-empty binding');
      if (activeColor == null)
        issues.add(
          'props.activeColor/props.color — required valid color',
        );
      if (inactiveColor == null)
        issues.add(
          'props.inactiveColor — required valid color',
        );
      if (activeGlyphColor == null)
        issues.add(
          'props.activeGlyphColor — required valid color',
        );
      if (inactiveGlyphColor == null)
        issues.add(
          'props.inactiveGlyphColor/props.color — required valid color',
        );
      if (borderColor == null)
        issues.add(
          'props.borderColor/props.color — required valid color',
        );
      if (size == null) issues.add('props.size — required number');
      if (borderWidth == null)
        issues.add(
          'props.borderWidth or parameterCard.parts.actionDot.borderWidth — required number',
        );
      if (issues.isNotEmpty) {
        return SchemaIssueWidget(
          title: 'Invalid PowerButton schema',
          details: issues,
          componentType: node['type']?.toString(),
          binding: binding,
        );
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => state.setBinding(binding, !isOn),
        child: SizedBox.square(
          dimension: size!,
          child: CustomPaint(
            painter: _PowerButtonPainter(
              backgroundColor: isOn ? activeColor! : inactiveColor!,
              glyphColor: isOn ? activeGlyphColor! : inactiveGlyphColor!,
              borderColor: borderColor!,
              borderWidth: borderWidth!,
            ),
          ),
        ),
      );
    });

    // TextField component
    register('textfield', ({
      required context,
      required node,
      required props,
      required style,
      required children,
      required state,
      required renderer,
      groupBinding,
    }) {
      final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
      final matched = state.controlForBinding(binding) ??
          (props.containsKey('id')
              ? Map<String, dynamic>.from(props.cast<dynamic, dynamic>())
              : null);
      final rawResolved = _stringFieldValue(state.resolveBinding(binding));
      final fallbackProps = _stringFieldValue(props['text']) ??
          _stringFieldValue(props['initialValue']) ??
          _stringFieldValue(props['value']) ??
          _stringFieldValue(matched?['initialValue']) ??
          _stringFieldValue(matched?['value']) ??
          '';
      final resolved = (rawResolved != null && rawResolved.isNotEmpty)
          ? rawResolved
          : fallbackProps;
      final value = matched == null
          ? resolved
          : state.presentedFieldText(matched, resolved);

      final themeColors = state.schema['theme']?['colors'] as Map? ?? const {};
      final container = props['container'] as Map? ?? const {};
      final theme = state.schema['theme'] as Map? ?? const {};
      final themeRadius = theme['radius'] as Map? ?? const {};
      final themeSpacing = theme['spacing'] as Map? ?? const {};
      final typography = theme['typography'] as Map? ?? const {};
      final textColor = SduiStyle.color(
        props['textColor'] ?? themeColors['text'],
      );
      final fillColor = SduiStyle.color(
        props['backgroundColor'] ??
            container['backgroundColor'] ??
            themeColors['surface'],
      );
      final borderColor = SduiStyle.color(
        props['borderColor'] ??
            container['borderColor'] ??
            themeColors['border'],
      );
      final focusedBorderColor = SduiStyle.color(
        props['focusedBorderColor'] ?? themeColors['accent'],
      );
      final borderRadius =
          (props['borderRadius'] as num?)?.toDouble() ??
          (container['borderRadius'] as num?)?.toDouble() ??
          (themeRadius['button'] as num?)?.toDouble();
      final containerPadding = container['padding'];
      final schemaPadding = (themeSpacing['cardPadding'] as num?)?.toDouble();
      final horizontalPadding =
          (props['horizontalPadding'] as num?)?.toDouble() ??
          (containerPadding as num?)?.toDouble() ??
          ((containerPadding as Map?)?['horizontal'] as num?)?.toDouble() ??
          schemaPadding;
      final verticalPadding =
          (props['verticalPadding'] as num?)?.toDouble() ??
          (containerPadding as num?)?.toDouble() ??
          ((containerPadding as Map?)?['vertical'] as num?)?.toDouble() ??
          schemaPadding;
      final borderWidth =
          _asDouble(props['borderWidth'] ?? container['borderWidth']) ?? 1;
      final focusedBorderWidth =
          _asDouble(props['focusedBorderWidth']) ?? borderWidth;
      final fieldHeight = _asDouble(props['height'] ?? props['fieldHeight']);
      final minHeight = _asDouble(props['minHeight']);
      final fontFamily = (props['fontFamily'] ?? typography['fontFamily'])
          ?.toString()
          .trim();
      final fontSize = _asDouble(props['fontSize'] ?? typography['bodySize']);
      final fontWeight = SduiStyle.fontWeight(
        props['fontWeight'] ?? typography['bodyWeight'],
      );
      if (binding.isEmpty ||
          textColor == null ||
          borderColor == null ||
          focusedBorderColor == null ||
          borderRadius == null ||
          horizontalPadding == null ||
          verticalPadding == null) {
        return SchemaIssueWidget(
          title: 'Invalid textField schema',
          details: [
            if (binding.isEmpty) 'binding — required non-empty binding',
            if (textColor == null)
              'props.textColor — required valid color',
            if (borderColor == null)
              'props.borderColor — required valid color',
            if (focusedBorderColor == null)
              'props.focusedBorderColor — required valid color',
            if (borderRadius == null)
              'props.borderRadius or props.container.borderRadius — required number',
            if (horizontalPadding == null)
              'props.horizontalPadding or props.container.padding — required number',
            if (verticalPadding == null)
              'props.verticalPadding or props.container.padding — required number',
          ],
          componentType: node['type']?.toString(),
          binding: binding,
        );
      }

      final readOnly = props['readOnly'] == true ||
          props['enabled'] == false ||
          props['interactive'] == false;
      final enabled = props['enabled'] != false && props['interactive'] != false;
      final variant = props['variant']?.toString().trim().toLowerCase();
      final expands = props['expands'] == true;
      final declaredMax = props['maxLines'];
      final maxLines = expands && declaredMax == null
          ? null
          : (declaredMax as num?)?.toInt() ?? 1;
      final minLines = (props['minLines'] as num?)?.toInt();
      final promptColor = SduiStyle.color(props['promptColor']);
      final effectiveTextColor =
          variant == 'terminal' && promptColor != null ? promptColor : textColor;

      Widget field = _SchemaBoundTextField(
        binding: binding,
        value: value,
        state: state,
        terminal: variant == 'terminal',
        readOnly: readOnly,
        enabled: enabled,
        disabledBorderColor: SduiStyle.color(props['disabledBorderColor']),
        disabledOpacity: _asDouble(props['disabledOpacity']) ??
            _asDouble((props['style'] as Map?)?['disabled']?['opacity']),
        hintText:
            props['hintText']?.toString() ?? props['placeholder']?.toString(),
        maxLines: maxLines,
        minLines: minLines,
        textColor: effectiveTextColor,
        fillColor: fillColor,
        borderColor: borderColor,
        focusedBorderColor: focusedBorderColor,
        borderRadius: borderRadius,
        contentPadding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: verticalPadding,
        ),
        borderWidth: borderWidth,
        focusedBorderWidth: focusedBorderWidth,
        height: fieldHeight,
        minHeight: minHeight,
        fontFamily: fontFamily == null || fontFamily.isEmpty
            ? null
            : fontFamily,
        fontSize: fontSize,
        fontWeight: fontWeight,
      );

      return _wrapTextFieldSendButton(
        context: context,
        field: field,
        send: props['sendButton'],
        binding: binding,
        state: state,
        renderer: renderer,
        readOnly: readOnly,
      );
    });

    // Value display component
    register('value', ({
      required context,
      required node,
      required props,
      required style,
      required children,
      required state,
      required renderer,
      groupBinding,
    }) {
      final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
      final rawVal =
          state.resolveBinding(binding) ?? props['value'] ?? node['value'];
      return Text(
        rawVal?.toString() ?? '',
        style: style.textStyle(const TextStyle()),
      );
    });

    register('brandbar', _buildBrandBarWidget);
    register('BrandBar', _buildBrandBarWidget);
  }

  static Widget _buildBrandBarWidget({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final logo = props['logo'] is Map
            ? Map<String, dynamic>.from(
                (props['logo'] as Map).cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};
        final status = props['status'] is Map
            ? Map<String, dynamic>.from(
                (props['status'] as Map).cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};
        final parts = style.s['parts'] is Map
            ? Map<String, dynamic>.from(
                (style.s['parts'] as Map).cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};
        final titleStyle = parts['title'] is Map
            ? Map<String, dynamic>.from(
                (parts['title'] as Map).cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};
        final subtitleStyle = parts['subtitle'] is Map
            ? Map<String, dynamic>.from(
                (parts['subtitle'] as Map).cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};
        final statusStyle = parts['status'] is Map
            ? Map<String, dynamic>.from(
                (parts['status'] as Map).cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};
        final markStyle = parts['mark'] is Map
            ? Map<String, dynamic>.from(
                (parts['mark'] as Map).cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};

        final online = _brandBarAsBool(state.resolveBinding('state.online'));
        final labelBinding = status['labelBinding']?.toString();
        final liveLabel = labelBinding == null || labelBinding.isEmpty
            ? null
            : state.resolveBinding(labelBinding)?.toString();
        final label = (liveLabel != null && liveLabel.trim().isNotEmpty)
            ? liveLabel
            : status['text']?.toString() ?? '';

        final theme = state.schema['theme'];
        final rawThemeColors = theme is Map ? theme['colors'] : null;
        final themeColors = rawThemeColors is Map
            ? Map<String, dynamic>.from(
                rawThemeColors.cast<dynamic, dynamic>(),
              )
            : const <String, dynamic>{};
        final onlineHex = _firstThemeColor(themeColors, const [
          'success',
          'online',
          'ok',
        ]);
        final offlineHex = _firstThemeColor(themeColors, const [
          'error',
          'danger',
          'offline',
        ]);
        final statusHex = online == true
            ? (onlineHex ?? statusStyle['color']?.toString())
            : (status['color']?.toString() ??
                  offlineHex ??
                  statusStyle['color']?.toString());
        final statusColor = SduiStyle.color(statusHex);

        final title = props['title']?.toString() ?? '';
        final subtitle = props['subtitle']?.toString() ?? '';
        final logoUrl =
            (logo['src'] ?? logo['url'] ?? logo['path'])?.toString() ?? '';

        final markWidth = (markStyle['width'] as num?)?.toDouble() ?? 110;
        final markHeight = (markStyle['height'] as num?)?.toDouble() ?? 28;
        final gap = style.s['layout'] is Map
            ? ((style.s['layout'] as Map)['gap'] as num?)?.toDouble() ?? 12.0
            : 12.0;
        final dotSize = (statusStyle['dotSize'] as num?)?.toDouble() ?? 8;

        return Container(
          margin: style.margin,
          padding: style.padding,
          decoration: style.decoration,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (logoUrl.isNotEmpty)
                SizedBox(
                  width: markWidth,
                  height: markHeight,
                  child: renderer.build(context, <String, dynamic>{
                    'type': 'image',
                    'properties': <String, dynamic>{
                      'src': logoUrl,
                      'url': logoUrl,
                      'fit': logo['fit'] ?? markStyle['fit'] ?? 'contain',
                    },
                    'style': markStyle,
                  }),
                ),
              if (logoUrl.isNotEmpty) SizedBox(width: gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: (titleStyle['maxLines'] as num?)?.toInt() ?? 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: SduiStyle.color(titleStyle['color']?.toString()),
                          fontSize: (titleStyle['fontSize'] as num?)?.toDouble(),
                          fontWeight: FontWeight.w900,
                          height: (titleStyle['lineHeight'] as num?)?.toDouble(),
                        ),
                      ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines:
                            (subtitleStyle['maxLines'] as num?)?.toInt() ?? 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: SduiStyle.color(
                            subtitleStyle['color']?.toString(),
                          ),
                          fontSize: (subtitleStyle['fontSize'] as num?)
                              ?.toDouble(),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
              if (status['visible'] != false &&
                  label.isNotEmpty &&
                  statusColor != null) ...[
                SizedBox(width: gap),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: dotSize,
                      height: dotSize,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: statusColor.withValues(alpha: 0.12),
                            spreadRadius:
                                (statusStyle['dotHaloWidth'] as num?)
                                    ?.toDouble() ??
                                5,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: (statusStyle['fontSize'] as num?)?.toDouble(),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static String? _firstThemeColor(Map<String, dynamic> colors, List<String> keys) {
    for (final key in keys) {
      final value = colors[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static bool? _brandBarAsBool(dynamic value) {
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

  static Widget _buildLinearGaugeWidget({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    return _buildSliderWidget(
      context: context,
      node: node,
      props: props,
      style: style,
      children: children,
      state: state,
      renderer: renderer,
      groupBinding: groupBinding,
    );
  }

  static Widget _buildToggleButtonWidget({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    return ComponentRegistry.instance._builders[_normalize('switch')]!(
      context: context,
      node: node,
      props: props,
      style: style,
      children: children,
      state: state,
      renderer: renderer,
      groupBinding: groupBinding,
    );
  }

  static Widget _buildIconButtonWidget({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    return ComponentRegistry.instance._builders[_normalize('powerbutton')]!(
      context: context,
      node: node,
      props: props,
      style: style,
      children: children,
      state: state,
      renderer: renderer,
      groupBinding: groupBinding,
    );
  }

  static Widget _buildButtonGroupWidget({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    final binding =
        (props['binding'] ?? node['binding'] ?? groupBinding)?.toString() ?? '';
    final rawOptions = props['options'] ??
        node['options'] ??
        node['properties']?['props']?['options'];
    var resolvedOptions = AppState.normalizeEnumOptions(
      rawOptions,
      rawValues: props['values'] ?? node['values'],
    );
    if (resolvedOptions.isEmpty && binding.isNotEmpty) {
      for (final ctrl in state.controls) {
        if (ctrl['binding']?.toString() == binding) {
          resolvedOptions = AppState.optionsFor(ctrl);
          if (resolvedOptions.isNotEmpty) break;
        }
      }
    }
    final options = resolvedOptions;
    final boundValue = state.resolveBinding(binding)?.toString();
    final schemaValue = props['value']?.toString();
    bool matchesOption(String? candidate) {
      if (candidate == null || candidate.isEmpty) return false;
      for (final option in options) {
        final value = option['value']?.toString() ?? '';
        final label = option['label']?.toString() ?? value;
        if (_schemaValuesEquivalent(candidate, value) ||
            _schemaValuesEquivalent(candidate, label)) {
          return true;
        }
      }
      return false;
    }

    // Protocol frames can publish a wire code (for example "01") that is not
    // one of props.options. The control's own schema value is the selection
    // until a live value actually matches an option.
    final selected = matchesOption(boundValue)
        ? boundValue
        : (matchesOption(schemaValue) ? schemaValue : boundValue);
    final theme = state.schema['theme'] is Map
        ? Map<String, dynamic>.from(state.schema['theme'] as Map)
        : const <String, dynamic>{};
    final themeColors = theme['colors'] is Map
        ? Map<String, dynamic>.from(theme['colors'] as Map)
        : const <String, dynamic>{};
    final themeSpacing = theme['spacing'] is Map
        ? Map<String, dynamic>.from(theme['spacing'] as Map)
        : const <String, dynamic>{};
    final themeRadius = theme['radius'] is Map
        ? Map<String, dynamic>.from(theme['radius'] as Map)
        : const <String, dynamic>{};
    final themeBorders = theme['borders'] is Map
        ? Map<String, dynamic>.from(theme['borders'] as Map)
        : const <String, dynamic>{};
    final themeType = theme['typography'] is Map
        ? Map<String, dynamic>.from(theme['typography'] as Map)
        : const <String, dynamic>{};

    Color? colorFrom(dynamic explicit, List<String> themeKeys) {
      final parsed = SduiStyle.color(explicit?.toString());
      if (parsed != null) return parsed;
      for (final key in themeKeys) {
        final themeColor = SduiStyle.color(themeColors[key]?.toString());
        if (themeColor != null) return themeColor;
      }
      return null;
    }

    double? numberFrom(dynamic explicit, Map<String, dynamic> bucket, List<String> keys) {
      final direct = _asDouble(explicit);
      if (direct != null) return direct;
      for (final key in keys) {
        final parsed = _asDouble(bucket[key]);
        if (parsed != null) return parsed;
      }
      return null;
    }

    final selectedBackground = colorFrom(
      props['selectedBackgroundColor'],
      const ['buttonBg', 'primary', 'accent'],
    ) ??
        SduiStyle.color(themeColors['accent']?.toString()) ??
        const Color(0xFF2563EB);
    final selectedText = colorFrom(
      props['selectedTextColor'],
      const ['buttonText', 'surface'],
    ) ?? const Color(0xFFFFFFFF);
    final unselectedBackground = colorFrom(
      props['unselectedBackgroundColor'],
      const ['surface', 'background'],
    ) ??
        SduiStyle.color(themeColors['chipBackground']?.toString()) ??
        const Color(0xFFF1F5F9);
    final unselectedText = colorFrom(
      props['unselectedTextColor'],
      const ['text'],
    ) ??
        SduiStyle.color(themeColors['textPrimary']?.toString()) ??
        const Color(0xFF1E293B);
    final containerBackground = colorFrom(
      props['containerBackgroundColor'],
      const ['surface', 'background'],
    ) ??
        SduiStyle.color(themeColors['cardBackground']?.toString()) ??
        const Color(0xFFF8FAFC);
    final containerBorder = colorFrom(
      props['containerBorderColor'],
      const ['border'],
    ) ??
        SduiStyle.color(themeColors['cardBorder']?.toString()) ??
        const Color(0xFFE2E8F0);
    final containerBorderWidth = numberFrom(
      props['containerBorderWidth'],
      themeBorders,
      const ['size'],
    ) ?? 1.0;
    final containerRadius = numberFrom(
      props['containerBorderRadius'],
      themeRadius,
      const ['button', 'card'],
    ) ?? 8.0;
    final containerPadding = numberFrom(
      props['containerPadding'],
      themeSpacing,
      const ['segmentPadding', 'cardGap'],
    ) ?? 3.0;
    final spacing = numberFrom(
      props['spacing'],
      themeSpacing,
      const ['segmentGap', 'cardGap'],
    ) ?? 4.0;
    final buttonRadius = numberFrom(
      props['buttonBorderRadius'],
      themeRadius,
      const ['pill', 'button'],
    ) ?? 8.0;
    final fontSize = numberFrom(
      props['buttonFontSize'],
      themeType,
      const ['bodySize'],
    ) ?? 13.0;
    final fontWeight = _fontWeight(
      props['buttonFontWeight'] ?? themeType['bodyWeight'],
    );
    final padding = _edgeInsets(props['buttonPadding']) ??
        const EdgeInsets.symmetric(
          horizontal: 6.0,
          vertical: 8.0,
        );
    final issues = <String>[];
    if (binding.isEmpty) issues.add('binding — required non-empty binding');
    if (options.isEmpty) issues.add('props.options — required non-empty list');
    if (issues.isNotEmpty) {
      return SchemaIssueWidget(
        title: 'Invalid ButtonGroup schema',
        details: issues,
        componentType: node['type']?.toString(),
        binding: binding,
      );
    }
    IconData? optionIcon(String label, String value) {
      final text = '$label $value'.toLowerCase();
      if (text.contains('clockwise') &&
          !text.contains('anti') &&
          !text.contains('counter')) {
        return Icons.rotate_right;
      }
      if (text.contains('anti') ||
          text.contains('counter') ||
          text.contains('ccw')) {
        return Icons.rotate_left;
      }
      return null;
    }

    Widget buildButton(Map<String, dynamic> option) {
      final value = option['value']?.toString() ?? '';
      final label = option['label']?.toString() ?? value;
      final isSelected =
          _schemaValuesEquivalent(selected, value) ||
          _schemaValuesEquivalent(selected, label);
      final icon = optionIcon(label, value);
      final foregroundColor = isSelected ? selectedText : unselectedText;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => state.setBinding(binding, value),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: isSelected ? selectedBackground : unselectedBackground,
            border: Border.all(
              color: isSelected ? selectedBackground : containerBorder,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: (fontSize - 1).clamp(12.0, 16.0),
                  color: foregroundColor,
                ),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foregroundColor,
                      fontSize: fontSize,
                      fontWeight: fontWeight,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final useSegmentedRow = options.length >= 2 && options.length <= 4;
    return Container(
      padding: EdgeInsets.all(containerPadding),
      decoration: BoxDecoration(
        color: containerBackground,
        border: containerBorderWidth > 0
            ? Border.all(
                color: containerBorder,
                width: containerBorderWidth,
              )
            : null,
        borderRadius: BorderRadius.circular(containerRadius),
      ),
      child: useSegmentedRow
          ? Row(
              children: [
                for (var i = 0; i < options.length; i++) ...[
                  if (i > 0) SizedBox(width: spacing),
                  Expanded(child: buildButton(options[i])),
                ],
              ],
            )
          : Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: options.map(buildButton).toList(),
            ),
    );
  }

  static Widget _buildFireControlPanelWidget({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    final binding =
        (props['binding'] ?? node['binding'] ?? groupBinding)?.toString() ?? '';
    final commands = (props['commands'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final kicker = props['kicker']?.toString();
    final kickerColor = SduiStyle.color(props['kickerColor']);
    final kickerFontSize = _asDouble(props['kickerFontSize']);
    final kickerFontWeight = SduiStyle.fontWeight(props['kickerFontWeight']);
    final statusColor = SduiStyle.color(props['statusColor']);
    final background = SduiStyle.color(props['containerBackgroundColor']);
    final border = SduiStyle.color(props['containerBorderColor']);
    final borderWidth = _asDouble(props['containerBorderWidth']);
    final radius = _asDouble(props['containerBorderRadius']);
    final padding = _asDouble(props['containerPadding']);
    final spacing = _asDouble(props['spacing']);
    final runSpacing = _asDouble(props['runSpacing'] ?? props['spacing']);
    final issues = <String>[];
    if (binding.isEmpty) issues.add('binding — required non-empty binding');
    if (commands.isEmpty)
      issues.add('props.commands — required non-empty list');
    if (background == null)
      issues.add('props.containerBackgroundColor — required valid color');
    if (border == null)
      issues.add('props.containerBorderColor — required valid color');
    if (borderWidth == null)
      issues.add('props.containerBorderWidth — required number');
    if (radius == null)
      issues.add('props.containerBorderRadius — required number');
    if (padding == null) issues.add('props.containerPadding — required number');
    if (kicker != null && kickerColor == null) {
      issues.add(
        'props.kickerColor — required valid color when props.kicker is present',
      );
    }
    if (kicker != null && kickerFontSize == null) {
      issues.add(
        'props.kickerFontSize — required number when props.kicker is present',
      );
    }
    if (kicker != null && kickerFontWeight == null) {
      issues.add(
        'props.kickerFontWeight — required supported font weight when props.kicker is present',
      );
    }
    if (props['showStatusValue'] == true && statusColor == null) {
      issues.add(
        'props.statusColor — required valid color when showStatusValue is true',
      );
    }
    if (spacing == null) issues.add('props.spacing — required number');
    if (runSpacing == null)
      issues.add('props.runSpacing or props.spacing — required number');
    if (issues.isNotEmpty) {
      return SchemaIssueWidget(
        title: 'Invalid FireControlPanel schema',
        details: issues,
        componentType: node['type']?.toString(),
        binding: binding,
      );
    }
    final current = state.resolveBinding(binding)?.toString() ?? '';
    return Container(
      padding: EdgeInsets.all(padding!),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border!, width: borderWidth!),
        borderRadius: BorderRadius.circular(radius!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (kicker != null)
            Text(
              kicker,
              style: TextStyle(
                color: kickerColor,
                fontSize: kickerFontSize,
                fontWeight: kickerFontWeight,
              ),
            ),
          if (props['showStatusValue'] == true)
            Text(current, style: TextStyle(color: statusColor)),
          Wrap(
            spacing: spacing!,
            runSpacing: runSpacing!,
            children: commands.map((command) {
              final value = command['value'];
              final label =
                  command['label']?.toString() ?? value?.toString() ?? '';
              final bg = SduiStyle.color(command['backgroundColor']);
              final fg = SduiStyle.color(command['textColor']);
              final buttonRadius = _asDouble(command['borderRadius']);
              final buttonPadding = _edgeInsets(command['padding']);
              if (bg == null ||
                  fg == null ||
                  buttonRadius == null ||
                  buttonPadding == null) {
                return SchemaIssueWidget(
                  title: 'Invalid FireControlPanel command',
                  details: const [
                    'Each command requires backgroundColor, textColor, borderRadius, and padding.',
                  ],
                  componentType: node['type']?.toString(),
                  binding: binding,
                );
              }
              final screenWidth = MediaQuery.sizeOf(context).width;
              final isNarrow = screenWidth < 375;
              final effPadding = isNarrow
                  ? EdgeInsets.symmetric(
                      horizontal: (buttonPadding.horizontal / 2).clamp(6.0, 10.0),
                      vertical: buttonPadding.vertical / 2,
                    )
                  : buttonPadding;
              return ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: bg,
                  foregroundColor: fg,
                  padding: effPadding,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(buttonRadius),
                  ),
                ),
                onPressed: () => state.setBinding(binding, value),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  static Widget _buildSliderWidget({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
    final value = state.resolveBinding(binding);
    final effectiveProps = _resolveSliderVisualProps(
      _resolveSliderPropsFromSchema(
        props: props,
        binding: binding,
        state: state,
      ),
      style.s,
    );
    final min = _asDouble(effectiveProps['min'] ?? effectiveProps['minimum']);
    final max = _asDouble(effectiveProps['max'] ?? effectiveProps['maximum']);
    final step = _asDouble(effectiveProps['step']);
    final activeColor = SduiStyle.color(effectiveProps['activeColor']);
    final inactiveColor = SduiStyle.color(effectiveProps['inactiveColor']);
    final gradientColors =
        (effectiveProps['_trackGradientColors'] as List?)
            ?.whereType<Color>()
            .toList() ??
        const <Color>[];
    final gradientStops = (effectiveProps['_trackGradientStops'] as List?)
        ?.whereType<double>()
        .toList();
    final gradientBegin = effectiveProps['_trackGradientBegin'] as Alignment?;
    final gradientEnd = effectiveProps['_trackGradientEnd'] as Alignment?;
    final trackHeight = _asDouble(effectiveProps['trackHeight']);
    final thumbRadius = _asDouble(effectiveProps['thumbRadius']);
    final thumbBorderColor = SduiStyle.color(
      effectiveProps['thumbBorderColor'],
    );
    final thumbBorderWidth = _asDouble(effectiveProps['thumbBorderWidth']);
    final labelColor = SduiStyle.color(effectiveProps['labelColor']);
    final valueColor = SduiStyle.color(effectiveProps['valueColor']);
    final rangeFontSize = _asDouble(effectiveProps['rangeFontSize']);
    final currentValueFontSize = _asDouble(
      effectiveProps['currentValueFontSize'],
    );
    final rangeFontWeight = _fontWeight(effectiveProps['rangeFontWeight']);
    final currentValueFontWeight = _fontWeight(
      effectiveProps['currentValueFontWeight'],
    );
    final variant = effectiveProps['variant']?.toString().trim().toLowerCase();
    final kicker = effectiveProps['kicker']?.toString().trim() ?? '';
    final valueSuffix = effectiveProps['valueSuffix']?.toString() ?? '';
    final kickerColor = SduiStyle.color(effectiveProps['kickerColor']);
    final kickerFontSize = _asDouble(effectiveProps['kickerFontSize']);
    final kickerFontWeight = _fontWeight(effectiveProps['kickerFontWeight']);
    final statusColor = SduiStyle.color(effectiveProps['_statusColor']);
    final isTimerVariant = variant == 'timer';
    final showLabels = effectiveProps['showMinMaxLabels'] == true;
    final showTickMarks = effectiveProps['showTickMarks'];
    final container = Map<String, dynamic>.from(
      (effectiveProps['container'] as Map?) ?? const {},
    );
    final containerVisible = container['visible'] == true;
    final containerBackground = SduiStyle.color(container['backgroundColor']);
    final containerBorder = SduiStyle.color(container['borderColor']);
    final containerBorderWidth = _asDouble(container['borderWidth']);
    final containerRadius = _asDouble(container['borderRadius']);
    final containerPadding = _asDouble(container['padding']);

    final issues = <String>[];
    if (binding.isEmpty) issues.add('binding — required non-empty binding');
    if (min == null) issues.add('props.min/minimum — required number');
    if (max == null) issues.add('props.max/maximum — required number');
    if (step == null || step <= 0)
      issues.add('props.step — required positive number');
    if (min != null && max != null && max <= min)
      issues.add('props.max must be greater than props.min');
    if (activeColor == null)
      issues.add('props.activeColor — required valid color');
    if (inactiveColor == null)
      issues.add('props.inactiveColor — required valid color');
    if (trackHeight == null) issues.add('props.trackHeight — required number');
    if (thumbRadius == null) issues.add('props.thumbRadius — required number');
    if (thumbBorderColor == null)
      issues.add('props.thumbBorderColor — required valid color');
    if (thumbBorderWidth == null) {
      issues.add('props.thumbBorderWidth — required number');
    }
    if (showLabels && labelColor == null) {
      issues.add('props.labelColor — required valid color');
    }
    if (showLabels && valueColor == null) {
      issues.add('props.valueColor — required valid color');
    }
    if (showLabels && rangeFontSize == null) {
      issues.add('props.rangeFontSize — required number');
    }
    if (showLabels && currentValueFontSize == null) {
      issues.add('props.currentValueFontSize — required number');
    }
    if (isTimerVariant && kicker.isNotEmpty && kickerColor == null) {
      issues.add(
        'props.kickerColor or control statusColor — required valid color for timer kicker',
      );
    }
    if (isTimerVariant && kicker.isNotEmpty && kickerFontSize == null) {
      issues.add('props.kickerFontSize — required number for timer kicker');
    }
    // kickerFontWeight is non-nullable (FontWeight) — null check removed.
    if (showTickMarks is! bool) {
      issues.add(
        'props.showTickMarks — required boolean so the renderer does not invent tick visibility',
      );
    }
    if (gradientColors.isNotEmpty &&
        (gradientBegin == null || gradientEnd == null)) {
      issues.add(
        'props.trackGradient begin/end or angle — required when a track gradient is present',
      );
    }
    if (containerVisible && containerBackground == null) {
      issues.add('props.container.backgroundColor — required valid color');
    }
    if (containerVisible && containerBorder == null) {
      issues.add('props.container.borderColor — required valid color');
    }
    if (containerVisible && containerBorderWidth == null) {
      issues.add('props.container.borderWidth — required number');
    }
    if (containerVisible && containerRadius == null) {
      issues.add('props.container.borderRadius — required number');
    }
    if (containerVisible && containerPadding == null) {
      issues.add('props.container.padding — required number');
    }

    if (issues.isNotEmpty) {
      return SchemaIssueWidget(
        title: 'Invalid slider schema',
        details: issues,
        componentType: node['type']?.toString(),
        binding: binding,
      );
    }

    final safeMin = min!;
    final safeMax = max!;
    final numericValue = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    // autoTriggerTimer and other schema sliders are published with a numeric
    // range even when the live binding is still a leftover boolean / OFF / null
    // (device offline). Web paints the range start. Do not replace the control
    // with a diagnostic for a non-numeric idle value.
    final clampedValue = (numericValue ?? safeMin).clamp(safeMin, safeMax);
    final divisions = ((safeMax - safeMin) / step!).round();

    final slider = SliderTheme(
      data: SliderThemeData(
        activeTrackColor: activeColor,
        inactiveTrackColor: inactiveColor,
        activeTickMarkColor: showTickMarks == true
            ? activeColor
            : Colors.transparent,
        inactiveTickMarkColor: showTickMarks == true
            ? inactiveColor
            : Colors.transparent,
        thumbColor: activeColor,
        trackHeight: trackHeight,
        trackShape: gradientColors.length >= 2
            ? _SchemaGradientSliderTrackShape(
                colors: gradientColors,
                stops: gradientStops,
                begin: gradientBegin!,
                end: gradientEnd!,
                trackHeight: trackHeight!,
                inactiveColor: inactiveColor!,
              )
            : null,
        thumbShape: _SchemaRoundThumbShape(
          radius: thumbRadius!,
          fillColor: activeColor!,
          borderColor: thumbBorderColor!,
          borderWidth: thumbBorderWidth!,
        ),
        overlayShape: SliderComponentShape.noOverlay,
      ),
      child: Slider(
        value: clampedValue,
        min: safeMin,
        max: safeMax,
        divisions: divisions > 0 ? divisions : null,
        onChanged: state.isBindingWritable(binding)
            ? (next) => state.setBinding(binding, next, dispatch: false)
            : null,
        onChangeEnd: state.isBindingWritable(binding)
            ? (committed) {
                // Drag/tap already wrote the value via onChanged. A second
                // setBinding with the same number used to return before send.
                // Schema onValueCommitted must still emit the device frame.
                state.setBinding(binding, committed, dispatch: false);
                state.sendBinding(binding);
              }
            : null,
      ),
    );

    String displayNumber(num number) =>
        '${_formatSchemaNumber(number)}$valueSuffix';

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final hasFiniteWidth =
            constraints.hasBoundedWidth && constraints.maxWidth.isFinite;

        Widget labels() {
          final minimumLabel = Text(
            isTimerVariant
                ? displayNumber(safeMin)
                : 'MIN ${_formatSchemaNumber(safeMin)}',
            style: TextStyle(
              color: labelColor,
              fontSize: rangeFontSize,
              fontWeight: rangeFontWeight,
            ),
          );
          final currentLabel = Text(
            isTimerVariant
                ? displayNumber(clampedValue)
                : _formatSchemaNumber(clampedValue),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: valueColor,
              fontSize: currentValueFontSize,
              fontWeight: currentValueFontWeight,
            ),
          );
          final maximumLabel = Text(
            isTimerVariant
                ? displayNumber(safeMax)
                : 'MAX ${_formatSchemaNumber(safeMax)}',
            style: TextStyle(
              color: labelColor,
              fontSize: rangeFontSize,
              fontWeight: rangeFontWeight,
            ),
          );

          if (hasFiniteWidth) {
            return Row(
              children: [
                minimumLabel,
                Expanded(child: currentLabel),
                maximumLabel,
              ],
            );
          }

          // A Slider can also be used directly as a Row child. Row measures
          // non-flex children with an unbounded horizontal constraint, where an
          // Expanded label is illegal. Keep all schema text visible and
          // intrinsic until an ancestor provides a finite width.
          final labelGap = _asDouble(
                effectiveProps['labelGap'] ?? effectiveProps['gap'],
              ) ??
              0;
          return Wrap(
            spacing: labelGap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [minimumLabel, currentLabel, maximumLabel],
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: hasFiniteWidth
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.start,
          children: [
            // `kicker` is an explicit schema field used by the slider
            // catalog (BRIGHTNESS, AIRFLOW, CCT, TIMER, etc.). Rendering it
            // must not depend on a Flutter-invented `variant` discriminator
            // that the current catalog does not publish.
            if (kicker.isNotEmpty) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (statusColor != null) ...[
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: statusColor, width: 1.5),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    kicker,
                    style: TextStyle(
                      color: kickerColor ?? labelColor,
                      fontSize: kickerFontSize ?? rangeFontSize,
                      fontWeight: kickerFontWeight,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (showLabels) labels(),
            hasFiniteWidth ? slider : IntrinsicWidth(child: slider),
          ],
        );
      },
    );

    if (!containerVisible) return content;
    return Container(
      padding: EdgeInsets.all(containerPadding!),
      decoration: BoxDecoration(
        color: containerBackground,
        border: Border.all(
          color: containerBorder!,
          width: containerBorderWidth!,
        ),
        borderRadius: BorderRadius.circular(containerRadius!),
      ),
      child: content,
    );
  }

  static Map<String, dynamic> _resolveSliderVisualProps(
    Map<String, dynamic> props,
    Map<String, dynamic> style,
  ) {
    Map<String, dynamic> mapOf(dynamic value) {
      return value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
    }

    final resolved = Map<String, dynamic>.from(props);
    final parts = mapOf(style['parts']);
    final trackPart = mapOf(parts['track']);
    final thumbPart = mapOf(parts['thumb']);
    final styleTrack = mapOf(style['track']);
    final styleThumb = mapOf(style['thumb']);

    dynamic firstValue(List<dynamic> values) {
      for (final value in values) {
        if (value != null) return value;
      }
      return null;
    }

    void fillIfMissing(String key, List<dynamic> candidates) {
      // The concrete slider props in controls[].component.widgetTree are the
      // authoritative visual contract.  style/styleRef values are fallbacks
      // only and must never replace a color already supplied by that control.
      if (resolved[key] != null) return;
      final value = firstValue(candidates);
      if (value != null) resolved[key] = value;
    }

    void fillIfMissingColor(String key, List<dynamic> candidates) {
      final existing = resolved[key];
      if (existing != null && SduiStyle.color(existing) != null) return;
      // Drop non-color placeholders (e.g. gradient maps from style.track.background)
      // that would otherwise fail "required valid color" validation.
      if (existing != null && SduiStyle.color(existing) == null) {
        resolved.remove(key);
      }
      for (final candidate in candidates) {
        if (candidate != null && SduiStyle.color(candidate) != null) {
          resolved[key] = candidate;
          return;
        }
      }
    }

    fillIfMissingColor('activeColor', [
      trackPart['activeColor'],
      trackPart['fillColor'],
      trackPart['color'],
      styleTrack['activeColor'],
      styleTrack['fillColor'],
      styleTrack['color'],
      style['activeColor'],
      style['trackColor'],
    ]);
    fillIfMissingColor('inactiveColor', [
      trackPart['inactiveColor'],
      trackPart['backgroundColor'],
      styleTrack['inactiveColor'],
      styleTrack['backgroundColor'],
      style['inactiveColor'],
    ]);
    fillIfMissing('trackHeight', [
      trackPart['height'],
      trackPart['thickness'],
      styleTrack['height'],
      styleTrack['thickness'],
      style['trackHeight'],
      4.0,
    ]);
    fillIfMissing('thumbRadius', [
      thumbPart['radius'],
      thumbPart['size'] is num
          ? (thumbPart['size'] as num).toDouble() / 2
          : null,
      styleThumb['radius'],
      styleThumb['size'] is num
          ? (styleThumb['size'] as num).toDouble() / 2
          : null,
      style['thumbRadius'],
      8.0,
    ]);
    fillIfMissing('thumbBorderColor', [
      thumbPart['borderColor'],
      mapOf(thumbPart['border'])['color'],
      styleThumb['borderColor'],
      mapOf(styleThumb['border'])['color'],
      style['thumbBorderColor'],
      resolved['activeColor'] ?? '#2563EB',
    ]);
    fillIfMissing('thumbBorderWidth', [
      thumbPart['borderWidth'],
      mapOf(thumbPart['border'])['width'],
      styleThumb['borderWidth'],
      mapOf(styleThumb['border'])['width'],
      style['thumbBorderWidth'],
      2.0,
    ]);

    final gradientCandidates = <dynamic>[
      // Component props are authoritative and therefore checked first.
      props['trackGradient'],
      props['gradient'],
      props['trackGradientColors'],
      props['gradientColors'],
      props['trackColors'],
      trackPart['gradient'],
      trackPart['background'],
      styleTrack['gradient'],
      styleTrack['background'],
      style['trackGradient'],
      style['gradient'],
      style['background'],
    ];

    Map<String, dynamic>? gradientMap;
    List? gradientList;
    for (final candidate in gradientCandidates) {
      if (candidate is Map) {
        final candidateMap = Map<String, dynamic>.from(candidate);
        final colors = candidateMap['colors'] ?? candidateMap['stops'];
        if (colors is List && colors.length >= 2) {
          gradientMap = candidateMap;
          break;
        }
      } else if (candidate is List && candidate.length >= 2) {
        gradientList = candidate;
        break;
      }
    }

    final colors = <Color>[];
    final stops = <double>[];

    if (gradientMap != null) {
      final rawColors = gradientMap['colors'];
      if (rawColors is List) {
        for (final raw in rawColors) {
          final color = SduiStyle.color(raw?.toString());
          if (color != null) colors.add(color);
        }
      } else {
        final rawStops = gradientMap['stops'];
        if (rawStops is List) {
          for (final raw in rawStops) {
            if (raw is! Map) continue;
            final color = SduiStyle.color(raw['color']?.toString());
            if (color != null) {
              colors.add(color);
              final offset = _asDouble(
                raw['offset'] ?? raw['stop'] ?? raw['position'],
              );
              if (offset != null) stops.add(offset > 1 ? offset / 100 : offset);
            }
          }
        }
      }

      final rawNumericStops =
          gradientMap['stopPositions'] ??
          gradientMap['positions'] ??
          (gradientMap['colors'] is List ? gradientMap['stops'] : null);
      if (rawNumericStops is List && rawNumericStops.every((e) => e is num)) {
        stops
          ..clear()
          ..addAll(
            rawNumericStops
                .map((e) => (e as num).toDouble())
                .map((e) => e > 1 ? e / 100 : e),
          );
      }

      final angle = _asDouble(gradientMap['angle']);
      final anglePair = angle == null ? null : _alignmentsFromDegrees(angle);
      // begin/end must come from the schema (explicit or via angle). No invented
      // Alignment defaults when the schema omits them.
      resolved['_trackGradientBegin'] =
          _alignmentFromSchema(gradientMap['begin']) ?? anglePair?.$1;
      resolved['_trackGradientEnd'] =
          _alignmentFromSchema(gradientMap['end']) ?? anglePair?.$2;
    } else if (gradientList != null) {
      for (final raw in gradientList) {
        final color = SduiStyle.color(raw?.toString());
        if (color != null) colors.add(color);
      }
    }

    if (colors.length >= 2) {
      resolved['_trackGradientColors'] = colors;
      if (stops.length == colors.length) {
        resolved['_trackGradientStops'] = stops;
      }
      // Only adopt colors that the schema itself published in the track gradient.
      if (SduiStyle.color(resolved['activeColor']) == null) {
        resolved['activeColor'] = colors.first;
      }
      if (SduiStyle.color(resolved['inactiveColor']) == null) {
        resolved['inactiveColor'] = colors.last;
      }
    }
    resolved['showTickMarks'] ??= false;
    return resolved;
  }

  static (Alignment, Alignment) _alignmentsFromDegrees(double degrees) {
    final radians = degrees * math.pi / 180.0;
    final dx = math.cos(radians);
    final dy = math.sin(radians);
    return (Alignment(-dx, -dy), Alignment(dx, dy));
  }

  static Alignment? _alignmentFromSchema(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'left' || 'centerleft' => Alignment.centerLeft,
      'right' || 'centerright' => Alignment.centerRight,
      'top' || 'topcenter' => Alignment.topCenter,
      'bottom' || 'bottomcenter' => Alignment.bottomCenter,
      'topleft' => Alignment.topLeft,
      'topright' => Alignment.topRight,
      'bottomleft' => Alignment.bottomLeft,
      'bottomright' => Alignment.bottomRight,
      'center' => Alignment.center,
      _ => null,
    };
  }

  static Map<String, dynamic> _resolveSliderPropsFromSchema({
    required Map<String, dynamic> props,
    required String binding,
    required AppState state,
  }) {
    final resolved = Map<String, dynamic>.from(props);
    if (binding.isEmpty) return resolved;

    Map<String, dynamic>? control;
    for (final item in state.controls) {
      if (item['binding']?.toString() == binding) {
        control = item;
        break;
      }
    }
    if (control == null) return resolved;

    final constraints = control['constraints'] as Map? ?? const {};
    final accessory = control['rightAccessory'] as Map? ?? const {};
    final componentProps = control['component']?['props'] as Map? ?? const {};
    final commandList = control['deviceFrame']?['commands'];
    Map? displayValue;
    dynamic protocolStep;
    if (commandList is List) {
      for (final command in commandList.whereType<Map>()) {
        if (command['display_value'] is Map) {
          displayValue = command['display_value'] as Map;
        }
        protocolStep ??= command['slider_step_value'];
      }
    }

    final catalogId = control['catalogComponentType']?.toString().trim();
    Map<String, dynamic>? catalogProps;
    Map<String, dynamic>? catalogEntry;
    final catalog = state.schema['components']?['catalog'];
    // Only resolve catalog props when the control declares catalogComponentType.
    // Do not invent a default catalog id such as "slider".
    if (catalog is List && catalogId != null && catalogId.isNotEmpty) {
      for (final entry in catalog.whereType<Map>()) {
        if (_normalize(entry['id']?.toString() ?? '') !=
            _normalize(catalogId)) {
          continue;
        }
        catalogEntry = Map<String, dynamic>.from(entry);
        final treeProps = entry['widgetTree']?['properties']?['props'];
        if (treeProps is Map) {
          catalogProps = Map<String, dynamic>.from(treeProps);
        }
        break;
      }
    }

    double? number(dynamic value) => _asDouble(value);
    bool validRange(dynamic min, dynamic max) {
      final a = number(min);
      final b = number(max);
      return a != null && b != null && b > a;
    }

    bool validStep(dynamic step) => (number(step) ?? 0) > 0;

    // Use the inline values when valid. Otherwise resolve the same semantic
    // fields through the schema hierarchy. Catalog values are used only when
    // all generated copies are invalid or empty, matching the web catalog.
    if (!validRange(
      resolved['min'] ?? resolved['minimum'],
      resolved['max'] ?? resolved['maximum'],
    )) {
      final rangeCandidates = <List<dynamic>>[
        [componentProps['min'], componentProps['max']],
        [constraints['minimum'], constraints['maximum']],
        [accessory['min'], accessory['max']],
        [displayValue?['min'], displayValue?['max']],
        [catalogProps?['min'], catalogProps?['max']],
      ];
      for (final candidate in rangeCandidates) {
        if (validRange(candidate[0], candidate[1])) {
          resolved['min'] = number(candidate[0]);
          resolved['max'] = number(candidate[1]);
          break;
        }
      }
      if (!validRange(resolved['min'], resolved['max'])) {
        resolved['min'] ??= 0.0;
        resolved['max'] ??= 100.0;
      }
    }

    if (!validStep(resolved['step'])) {
      final stepCandidates = <dynamic>[
        componentProps['step'],
        constraints['step'],
        accessory['step'],
        protocolStep,
        catalogProps?['step'],
      ];
      for (final candidate in stepCandidates) {
        if (validStep(candidate)) {
          resolved['step'] = number(candidate);
          break;
        }
      }
      if (!validStep(resolved['step'])) {
        resolved['step'] = 1.0;
      }
    }

    final activeColorCandidates = <dynamic>[
      props['activeColor'],
      componentProps['activeColor'],
      control['props'] is Map ? (control['props'] as Map)['activeColor'] : null,
      catalogProps?['activeColor'],
      control['styles'] is Map
          ? (control['styles'] as Map)['accentColor']
          : null,
      state.schema['theme']?['colors']?['primary'],
      state.schema['theme']?['colors']?['accent'],
      '#2563EB',
    ];
    for (final candidate in activeColorCandidates) {
      if (candidate != null &&
          candidate.toString().trim().isNotEmpty &&
          SduiStyle.color(candidate) != null) {
        resolved['activeColor'] = candidate;
        break;
      }
    }

    final inactiveColorCandidates = <dynamic>[
      props['inactiveColor'],
      componentProps['inactiveColor'],
      control['props'] is Map
          ? (control['props'] as Map)['inactiveColor']
          : null,
      accessory['inactiveColor'],
      catalogProps?['inactiveColor'],
      control['styles'] is Map
          ? (control['styles'] as Map)['inactiveColor']
          : null,
      state.schema['theme']?['colors']?['inactiveTrackColor'],
      state.schema['theme']?['colors']?['inactive'],
      state.schema['theme']?['colors']?['border'],
      '#CBD5E1',
    ];
    for (final candidate in inactiveColorCandidates) {
      if (candidate != null &&
          candidate.toString().trim().isNotEmpty &&
          SduiStyle.color(candidate) != null) {
        resolved['inactiveColor'] = candidate;
        break;
      }
    }

    // The component-level props carry semantic variant metadata such as
    // `valueSuffix`. Concrete child props remain authoritative because these
    // values are only filled when the child did not already provide them.
    for (final entry in componentProps.entries) {
      resolved.putIfAbsent(entry.key.toString(), () => entry.value);
    }

    final controlStyles = control['styles'];
    if (controlStyles is Map && controlStyles['statusColor'] != null) {
      resolved.putIfAbsent('_statusColor', () => controlStyles['statusColor']);
    }

    if (catalogProps != null) {
      for (final entry in catalogProps.entries) {
        resolved.putIfAbsent(entry.key, () => entry.value);
      }
    }

    final catalogSliderLabel = catalogEntry?['sliderLabel']?.toString().trim();
    if (catalogSliderLabel != null && catalogSliderLabel.isNotEmpty) {
      resolved.putIfAbsent('kicker', () => catalogSliderLabel);
    }
    // variant / timer behavior must come from catalog widgetTree props (or the
    // control itself). Do not invent variant from a hardcoded catalog id.

    return resolved;
  }

  static bool _schemaValuesEquivalent(dynamic left, dynamic right) {
    if (left == right) return true;
    final a = left?.toString().trim().toLowerCase() ?? '';
    final b = right?.toString().trim().toLowerCase() ?? '';
    if (a == b) return true;

    const trueValues = {'true', 'on', 'yes', '1', '01'};
    const falseValues = {'false', 'off', 'no', '0', '00'};
    if (trueValues.contains(a) && trueValues.contains(b)) return true;
    if (falseValues.contains(a) && falseValues.contains(b)) return true;

    final aNumber = num.tryParse(a);
    final bNumber = num.tryParse(b);
    return aNumber != null && bNumber != null && aNumber == bNumber;
  }

  static String _formatSchemaNumber(num value) {
    final asDouble = value.toDouble();
    return asDouble == asDouble.roundToDouble()
        ? asDouble.toInt().toString()
        : asDouble.toString();
  }

  static Widget _buildRadialGaugeWidget({
    required BuildContext context,
    required Map<String, dynamic> node,
    required Map<String, dynamic> props,
    required SduiStyle style,
    required List<Map<String, dynamic>> children,
    required AppState state,
    required SduiRenderer renderer,
    String? groupBinding,
  }) {
    final binding = (props['binding'] ?? node['binding'])?.toString() ?? '';
    final axis = (props['axis'] as Map?) ?? const {};
    final axisStyle = (axis['style'] as Map?) ?? const {};
    final pointer = (axis['pointer'] as Map?) ?? const {};
    final pointerBorder = (pointer['border'] as Map?) ?? const {};
    final builder = (props['builder'] as Map?) ?? const {};
    final builderStyle = (builder['style'] as Map?) ?? const {};

    final minimum = _asDouble(axis['min'] ?? axis['minimum'] ?? props['min']);
    final maximum = _asDouble(axis['max'] ?? axis['maximum'] ?? props['max']);
    final step = _asDouble(props['step']);
    final width = _asDouble(props['width']);
    final height = _asDouble(props['height']);
    final durationMs = (props['duration'] as num?)?.toInt();
    final sweepDegrees = _asDouble(
      axis['sweepDegrees'] ?? props['sweepDegrees'],
    );

    // Some generated schemas keep arcStart at component.props while the
    // concrete AnimatedRadialGauge child contains the remaining gauge data.
    // Resolve that alias by binding instead of depending on a parameter name.
    Map<String, dynamic> boundComponentProps = const {};
    final schemaControls = state.schema['controls'];
    if (schemaControls is List && binding.isNotEmpty) {
      for (final item in schemaControls.whereType<Map>()) {
        if (item['binding']?.toString() != binding) continue;
        final component = item['component'];
        if (component is Map && component['props'] is Map) {
          boundComponentProps = Map<String, dynamic>.from(
            component['props'] as Map,
          );
        }
        break;
      }
    }

    // arcStart is authoritative schema data. Do not derive it from the
    // sweep or substitute a renderer-owned start-angle formula.
    // The generated control currently stores it at component.props.arcStart;
    // a component may also place the same field directly in gauge props/axis.
    final arcStartDegrees = _asDouble(
      boundComponentProps['arcStart'] ?? props['arcStart'] ?? axis['arcStart'],
    );
    final thickness = _asDouble(axisStyle['thickness']);
    final pointerWidth = _asDouble(pointer['width']);
    final pointerHeight = _asDouble(pointer['height']);
    final pointerColor = SduiStyle.color(pointer['color']?.toString());
    final pointerBorderColor = SduiStyle.color(
      pointerBorder['color']?.toString(),
    );
    final pointerBorderWidth = _asDouble(pointerBorder['width']);
    final pointerType = pointer['type']?.toString() ?? '';
    final pointerRadius = _asDouble(pointer['borderRadius']);
    final pointerPosition = (pointer['position'] as Map?) ?? const {};
    final pointerPositionType = pointerPosition['type']?.toString() ?? '';
    final pointerOffset = (pointerPosition['offset'] as Map?) ?? const {};
    final pointerDx = _asDouble(pointerOffset['dx']);
    final pointerDy = _asDouble(pointerOffset['dy']);
    final cornerRadius = _asDouble(
      (axisStyle['cornerRadius'] as Map?)?['radius'],
    );

    final zones =
        (axis['zones'] as List?)
            ?.whereType<Map>()
            .map((zone) => Map<String, dynamic>.from(zone))
            .toList() ??
        const <Map<String, dynamic>>[];

    // The web contract represents a progress gauge with schema zones. The
    // leading zone color is the active arc and the trailing zone color is the
    // inactive arc. This prevents package defaults (such as green) from being
    // introduced when the schema itself specifies blue/grey colors.
    Color? activeColor = SduiStyle.color(
      axisStyle['activeColor']?.toString() ?? props['activeColor']?.toString(),
    );
    Color? inactiveColor = SduiStyle.color(
      axisStyle['inactiveColor']?.toString() ??
          axisStyle['background']?.toString() ??
          props['inactiveColor']?.toString(),
    );
    for (final zone in zones) {
      activeColor ??= SduiStyle.color(zone['color']?.toString());
      if (activeColor != null) break;
    }
    for (final zone in zones.reversed) {
      inactiveColor ??= SduiStyle.color(zone['color']?.toString());
      if (inactiveColor != null) break;
    }

    final labelColor = SduiStyle.color(builderStyle['color']?.toString());
    final labelFontSize = _asDouble(builderStyle['fontSize']);
    final labelFontWeight = SduiStyle.fontWeight(builderStyle['fontWeight']);
    final labelAlignment = _alignmentFromSchema(builderStyle['alignment']);
    final secondaryFontSize = _asDouble(builderStyle['secondaryFontSize']);
    final secondaryFontWeight = SduiStyle.fontWeight(
      builderStyle['secondaryFontWeight'],
    );

    final issues = <String>[];
    if (binding.isEmpty) {
      issues.add('properties.binding — required binding');
    }
    if (minimum == null) {
      issues.add('props.axis.min/props.min — required number');
    }
    if (maximum == null) {
      issues.add('props.axis.max/props.max — required number');
    }
    if (minimum != null && maximum != null && maximum <= minimum) {
      issues.add('maximum must be greater than minimum');
    }
    if (step == null) {
      issues.add('props.step — required number');
    } else if (step <= 0) {
      issues.add('props.step — must be greater than zero');
    }
    if (width == null) {
      issues.add('props.width — required number');
    }
    if (height == null) {
      issues.add('props.height — required number');
    }
    if (durationMs == null) {
      issues.add('props.duration — required milliseconds');
    }
    if (sweepDegrees == null) {
      issues.add(
        'props.axis.sweepDegrees/props.sweepDegrees — required number',
      );
    }
    if (arcStartDegrees == null) {
      issues.add(
        'component.props.arcStart/props.arcStart/props.axis.arcStart — required number',
      );
    }
    if (thickness == null) {
      issues.add('props.axis.style.thickness — required number');
    }
    if (activeColor == null) {
      issues.add(
        'props.axis.style.activeColor/props.activeColor/first zone color — required valid color',
      );
    }
    if (inactiveColor == null) {
      issues.add(
        'props.axis.style.inactiveColor/background/props.inactiveColor/last zone color — required valid color',
      );
    }
    if (pointerWidth == null) {
      issues.add('props.axis.pointer.width — required number');
    }
    if (pointerHeight == null) {
      issues.add('props.axis.pointer.height — required number');
    }
    if (pointerColor == null) {
      issues.add('props.axis.pointer.color — required valid color');
    }
    if (pointerBorderColor == null) {
      issues.add('props.axis.pointer.border.color — required valid color');
    }
    if (pointerBorderWidth == null) {
      issues.add('props.axis.pointer.border.width — required number');
    }
    if (pointerRadius == null) {
      issues.add('props.axis.pointer.borderRadius — required number');
    }
    if (pointerDx == null || pointerDy == null) {
      issues.add('props.axis.pointer.position.offset.dx/dy — required numbers');
    }
    if (cornerRadius == null) {
      issues.add('props.axis.style.cornerRadius.radius — required number');
    }
    if (pointerType != 'GaugePointer.triangle') {
      issues.add(
        'props.axis.pointer.type — expected GaugePointer.triangle, received $pointerType',
      );
    }
    if (pointerPositionType != 'GaugePointerPosition.surface') {
      issues.add(
        'props.axis.pointer.position.type — expected GaugePointerPosition.surface, received $pointerPositionType',
      );
    }
    if (labelColor == null) {
      issues.add('props.builder.style.color — required valid color');
    }
    if (labelFontSize == null) {
      issues.add('props.builder.style.fontSize — required number');
    }
    if (labelFontWeight == null) {
      issues.add(
        'props.builder.style.fontWeight — required supported font weight',
      );
    }
    if (labelAlignment == null) {
      issues.add(
        'props.builder.style.alignment — required supported alignment',
      );
    }
    if (secondaryFontSize == null) {
      issues.add('props.builder.style.secondaryFontSize — required number');
    }
    if (secondaryFontWeight == null) {
      issues.add(
        'props.builder.style.secondaryFontWeight — required supported font weight',
      );
    }

    if (issues.isNotEmpty) {
      return SchemaIssueWidget(
        title: 'Invalid radial gauge schema',
        details: issues,
        componentType: node['type']?.toString(),
        binding: binding,
      );
    }

    final minValue = minimum!;
    final maxValue = maximum!;
    final gaugeWidth = width!;
    final gaugeHeight = height!;
    final gaugeSweep = sweepDegrees!;
    final gaugeArcStart = arcStartDegrees!;
    final gaugeThickness = thickness!;
    final gaugePointerWidth = pointerWidth!;
    final gaugePointerHeight = pointerHeight!;
    final gaugePointerColor = pointerColor!;
    final gaugePointerBorderColor = pointerBorderColor!;
    final gaugePointerBorderWidth = pointerBorderWidth!;
    final gaugePointerRadius = pointerRadius!;
    final gaugePointerDx = pointerDx!;
    final gaugePointerDy = pointerDy!;
    final gaugeCornerRadius = cornerRadius!;
    final gaugeActiveColor = activeColor!;
    final gaugeInactiveColor = inactiveColor!;
    final gaugeLabelColor = labelColor!;
    final gaugeLabelFontSize = labelFontSize!;
    final gaugeLabelFontWeight = labelFontWeight!;
    final gaugeLabelAlignment = labelAlignment!;
    final gaugeSecondaryFontSize = secondaryFontSize!;
    final gaugeSecondaryFontWeight = secondaryFontWeight!;
    final gaugeDurationMs = durationMs!;
    final gaugeStep = step!;

    final rawValue = state.resolveBinding(binding);
    final parsedValue = rawValue is num
        ? rawValue.toDouble()
        : double.tryParse(rawValue?.toString() ?? '');
    final currentValue = (parsedValue ?? minValue)
        .clamp(minValue, maxValue)
        .toDouble();

    void updateFromLocalPosition(Offset localPosition) {
      final center = Offset(gaugeWidth / 2, gaugeHeight / 2);
      final startRadians = math.pi * gaugeArcStart / 180;
      final sweepRadians = math.pi * gaugeSweep / 180;
      var angle = math.atan2(
        localPosition.dy - center.dy,
        localPosition.dx - center.dx,
      );
      if (angle < 0) angle += math.pi * 2;
      var start = startRadians % (math.pi * 2);
      if (start < 0) start += math.pi * 2;
      var delta = angle - start;
      if (delta < 0) delta += math.pi * 2;

      // Positions in the gauge's open gap snap to the nearest endpoint.
      if (delta > sweepRadians) {
        final distanceToStart = (math.pi * 2) - delta;
        final distanceToEnd = delta - sweepRadians;
        delta = distanceToStart < distanceToEnd ? 0 : sweepRadians;
      }

      final fraction = (delta / sweepRadians).clamp(0.0, 1.0);
      var next = minValue + (maxValue - minValue) * fraction;
      next = minValue + ((next - minValue) / gaugeStep).round() * gaugeStep;
      next = next.clamp(minValue, maxValue).toDouble();
      state.setBinding(binding, next);
    }

    final labelText = _formatSchemaNumber(currentValue);
    final maximumText = _formatSchemaNumber(maxValue);

    return SizedBox(
      width: gaugeWidth,
      height: gaugeHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => updateFromLocalPosition(details.localPosition),
        onPanStart: (details) => updateFromLocalPosition(details.localPosition),
        onPanUpdate: (details) =>
            updateFromLocalPosition(details.localPosition),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: currentValue, end: currentValue),
          duration: Duration(milliseconds: gaugeDurationMs),
          builder: (context, animatedValue, child) {
            return Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  painter: _SchemaRadialGaugePainter(
                    minimum: minValue,
                    maximum: maxValue,
                    value: animatedValue,
                    sweepDegrees: gaugeSweep,
                    arcStartDegrees: gaugeArcStart,
                    thickness: gaugeThickness,
                    activeColor: gaugeActiveColor,
                    inactiveColor: gaugeInactiveColor,
                    pointerWidth: gaugePointerWidth,
                    pointerHeight: gaugePointerHeight,
                    pointerColor: gaugePointerColor,
                    pointerBorderColor: gaugePointerBorderColor,
                    pointerBorderWidth: gaugePointerBorderWidth,
                    pointerType: pointerType,
                    pointerCornerRadius: gaugePointerRadius,
                    pointerDx: gaugePointerDx,
                    pointerDy: gaugePointerDy,
                    roundedEnds: gaugeCornerRadius > 0,
                  ),
                ),
                Align(
                  alignment: gaugeLabelAlignment,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: labelText,
                          style: TextStyle(
                            color: gaugeLabelColor,
                            fontSize: gaugeLabelFontSize,
                            fontWeight: gaugeLabelFontWeight,
                          ),
                        ),
                        TextSpan(
                          text: ' /$maximumText',
                          style: TextStyle(
                            color: gaugeLabelColor,
                            fontSize: gaugeSecondaryFontSize,
                            fontWeight: gaugeSecondaryFontWeight,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SchemaRadialGaugePainter extends CustomPainter {
  const _SchemaRadialGaugePainter({
    required this.minimum,
    required this.maximum,
    required this.value,
    required this.sweepDegrees,
    required this.arcStartDegrees,
    required this.thickness,
    required this.activeColor,
    required this.inactiveColor,
    required this.pointerWidth,
    required this.pointerHeight,
    required this.pointerColor,
    required this.pointerBorderColor,
    required this.pointerBorderWidth,
    required this.pointerType,
    required this.pointerCornerRadius,
    required this.pointerDx,
    required this.pointerDy,
    required this.roundedEnds,
  });

  final double minimum;
  final double maximum;
  final double value;
  final double sweepDegrees;
  final double arcStartDegrees;
  final double thickness;
  final Color activeColor;
  final Color inactiveColor;
  final double pointerWidth;
  final double pointerHeight;
  final Color pointerColor;
  final Color? pointerBorderColor;
  final double pointerBorderWidth;
  final String pointerType;
  final double pointerCornerRadius;
  final double pointerDx;
  final double pointerDy;
  final bool roundedEnds;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.max(
      0.0,
      math.min(size.width, size.height) / 2 -
          math.max(thickness, pointerHeight) / 2,
    );
    final rect = Rect.fromCircle(center: center, radius: radius);
    final startAngle = math.pi * arcStartDegrees / 180;
    final sweepAngle = math.pi * sweepDegrees / 180;
    final fraction = ((value - minimum) / (maximum - minimum)).clamp(0.0, 1.0);
    final activeSweep = sweepAngle * fraction;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = roundedEnds ? StrokeCap.round : StrokeCap.butt
      ..color = inactiveColor;
    canvas.drawArc(rect, startAngle, sweepAngle, false, trackPaint);

    if (activeSweep > 0) {
      final activePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = roundedEnds ? StrokeCap.round : StrokeCap.butt
        ..color = activeColor;
      canvas.drawArc(rect, startAngle, activeSweep, false, activePaint);
    }

    final pointerAngle = startAngle + activeSweep;
    final direction = Offset(math.cos(pointerAngle), math.sin(pointerAngle));
    final tangent = Offset(-direction.dy, direction.dx);

    // GaugePointerPosition.surface places the pointer base on the arc surface.
    // The schema triangle points inward toward the gauge centre, matching the
    // web preview. dx moves tangentially and dy moves radially.
    final surfaceCenter =
        center + direction * (radius + pointerDy) + tangent * pointerDx;
    final left = surfaceCenter + tangent * (pointerWidth / 2);
    final right = surfaceCenter - tangent * (pointerWidth / 2);
    final tip = surfaceCenter - direction * pointerHeight;

    final path = _roundedTriangle(
      tip,
      left,
      right,
      pointerType.toLowerCase().contains('triangle') ? pointerCornerRadius : 0,
    );
    canvas.drawPath(path, Paint()..color = pointerColor);
    if (pointerBorderColor != null && pointerBorderWidth > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = pointerBorderWidth
          ..strokeJoin = StrokeJoin.round
          ..color = pointerBorderColor!,
      );
    }
  }

  static Path _roundedTriangle(Offset a, Offset b, Offset c, double radius) {
    if (radius <= 0) {
      return Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(c.dx, c.dy)
        ..close();
    }

    Offset toward(Offset from, Offset to, double distance) {
      final delta = to - from;
      final length = delta.distance;
      if (length == 0) return from;
      return from + delta * (math.min(distance, length / 3) / length);
    }

    final aToB = toward(a, b, radius);
    final aToC = toward(a, c, radius);
    final bToA = toward(b, a, radius);
    final bToC = toward(b, c, radius);
    final cToA = toward(c, a, radius);
    final cToB = toward(c, b, radius);

    return Path()
      ..moveTo(aToB.dx, aToB.dy)
      ..lineTo(bToA.dx, bToA.dy)
      ..quadraticBezierTo(b.dx, b.dy, bToC.dx, bToC.dy)
      ..lineTo(cToB.dx, cToB.dy)
      ..quadraticBezierTo(c.dx, c.dy, cToA.dx, cToA.dy)
      ..lineTo(aToC.dx, aToC.dy)
      ..quadraticBezierTo(a.dx, a.dy, aToB.dx, aToB.dy)
      ..close();
  }

  @override
  bool shouldRepaint(covariant _SchemaRadialGaugePainter oldDelegate) {
    return oldDelegate.minimum != minimum ||
        oldDelegate.maximum != maximum ||
        oldDelegate.value != value ||
        oldDelegate.sweepDegrees != sweepDegrees ||
        oldDelegate.arcStartDegrees != arcStartDegrees ||
        oldDelegate.thickness != thickness ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.pointerWidth != pointerWidth ||
        oldDelegate.pointerHeight != pointerHeight ||
        oldDelegate.pointerColor != pointerColor ||
        oldDelegate.pointerBorderColor != pointerBorderColor ||
        oldDelegate.pointerBorderWidth != pointerBorderWidth ||
        oldDelegate.pointerType != pointerType ||
        oldDelegate.pointerCornerRadius != pointerCornerRadius ||
        oldDelegate.pointerDx != pointerDx ||
        oldDelegate.pointerDy != pointerDy ||
        oldDelegate.roundedEnds != roundedEnds;
  }
}

class _SchemaGradientSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _SchemaGradientSliderTrackShape({
    required this.colors,
    required this.stops,
    required this.begin,
    required this.end,
    required this.trackHeight,
    required this.inactiveColor,
  });

  final List<Color> colors;
  final List<double>? stops;
  final Alignment begin;
  final Alignment end;
  final double trackHeight;
  final Color inactiveColor;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme.copyWith(trackHeight: trackHeight),
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(rect.height / 2);
    final shader = LinearGradient(
      colors: colors,
      stops: stops,
      begin: begin,
      end: end,
    ).createShader(rect);

    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..shader = shader,
    );
  }
}

class _SchemaRoundThumbShape extends SliderComponentShape {
  const _SchemaRoundThumbShape({
    required this.radius,
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
  });

  final double radius;
  final Color fillColor;
  final Color borderColor;
  final double borderWidth;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(radius + borderWidth);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(center, radius, Paint()..color = fillColor);
    if (borderWidth > 0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = borderColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = borderWidth,
      );
    }
  }
}

class _PowerButtonPainter extends CustomPainter {
  const _PowerButtonPainter({
    required this.backgroundColor,
    required this.glyphColor,
    required this.borderColor,
    required this.borderWidth,
  });

  final Color backgroundColor;
  final Color glyphColor;
  final Color borderColor;
  final double borderWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - borderWidth) / 2;

    final backgroundPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = backgroundColor;
    canvas.drawCircle(center, radius, backgroundPaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..color = borderColor;
    canvas.drawCircle(center, radius, ringPaint);

    final glyphPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = StrokeCap.round
      ..color = glyphColor;
    final glyphRadius = radius * 0.48;
    final rect = Rect.fromCircle(center: center, radius: glyphRadius);
    canvas.drawArc(rect, -math.pi * 0.20, math.pi * 1.40, false, glyphPaint);
    canvas.drawLine(
      Offset(center.dx, center.dy - radius * 0.62),
      Offset(center.dx, center.dy - radius * 0.08),
      glyphPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _PowerButtonPainter oldDelegate) {
    return oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.glyphColor != glyphColor ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.borderWidth != borderWidth;
  }
}

class _SchemaBoundTextField extends StatefulWidget {
  const _SchemaBoundTextField({
    required this.binding,
    required this.value,
    required this.state,
    required this.terminal,
    required this.readOnly,
    required this.enabled,
    required this.hintText,
    required this.maxLines,
    required this.minLines,
    required this.textColor,
    required this.fillColor,
    required this.borderColor,
    required this.focusedBorderColor,
    required this.borderRadius,
    required this.contentPadding,
    required this.borderWidth,
    required this.focusedBorderWidth,
    required this.height,
    required this.minHeight,
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    this.disabledBorderColor,
    this.disabledOpacity,
  });

  final String binding;
  final String value;
  final AppState state;
  final bool terminal;
  final bool readOnly;
  final bool enabled;
  final Color? disabledBorderColor;
  final double? disabledOpacity;
  final String? hintText;
  final int? maxLines;
  final int? minLines;
  final Color? textColor;
  final Color? fillColor;
  final Color? borderColor;
  final Color? focusedBorderColor;
  final double borderRadius;
  final EdgeInsets contentPadding;
  final double borderWidth;
  final double focusedBorderWidth;
  final double? height;
  final double? minHeight;
  final String? fontFamily;
  final double? fontSize;
  final FontWeight? fontWeight;

  @override
  State<_SchemaBoundTextField> createState() => _SchemaBoundTextFieldState();
}

class _SchemaBoundTextFieldState extends State<_SchemaBoundTextField> {
  late final TextEditingController _controller;
  ScrollController? _scroll;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    if (widget.terminal) _scroll = ScrollController();
  }

  @override
  void didUpdateWidget(covariant _SchemaBoundTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text && widget.value != oldWidget.value) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
      if (widget.terminal) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final scroll = _scroll;
          if (!mounted || scroll == null || !scroll.hasClients) return;
          scroll.jumpTo(scroll.position.maxScrollExtent);
        });
      }
    }
  }

  @override
  void dispose() {
    _scroll?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget field = Opacity(
      opacity: widget.enabled ? 1 : (widget.disabledOpacity ?? 1),
      child: TextField(
      controller: _controller,
      readOnly: widget.readOnly,
      enabled: widget.enabled,
      minLines: widget.maxLines == null ||
              (widget.minLines != null &&
                  widget.minLines! <= widget.maxLines!)
          ? widget.minLines
          : null,
      maxLines: widget.maxLines,
      style: TextStyle(
        color: widget.textColor,
        fontFamily: widget.fontFamily,
        fontSize: widget.fontSize,
        fontWeight: widget.fontWeight,
      ),
      decoration: InputDecoration(
        hintText: widget.hintText,
        filled: widget.fillColor != null,
        fillColor: widget.fillColor,
        contentPadding: widget.contentPadding,
        isDense: true,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          borderSide: BorderSide(
            color: widget.borderColor!,
            width: widget.borderWidth,
          ),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          borderSide: BorderSide(
            color: widget.disabledBorderColor ?? widget.borderColor!,
            width: widget.borderWidth,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          borderSide: BorderSide(
            color: widget.focusedBorderColor!,
            width: widget.focusedBorderWidth,
          ),
        ),
      ),
      onChanged: widget.binding.isNotEmpty &&
              !widget.readOnly &&
              widget.enabled
          ? (text) => widget.state.setBinding(widget.binding, text)
          : null,
      textAlignVertical: TextAlignVertical.center,
    ),
    );
    if (widget.terminal && _scroll != null) {
      final font = (widget.fontSize != null && widget.fontSize! > 0)
          ? widget.fontSize!
          : 13.0;
      final minLines = widget.minLines ?? 3;
      final textLines = widget.value.trim().isEmpty
          ? minLines
          : widget.value.split('\n').length;
      final lineExtent = font * 1.35;
      final pad = widget.contentPadding.vertical;
      final minHeight = lineExtent * minLines + pad;
      final contentHeight = lineExtent * math.max(textLines, minLines) + pad;
      final maxHeight = math.max(
        minHeight,
        MediaQuery.sizeOf(context).height * 0.32,
      );
      final height = math.min(math.max(contentHeight, minHeight), maxHeight);
      field = SizedBox(
        height: height,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (details) {
            final scroll = _scroll;
            if (scroll != null && scroll.hasClients) {
              final newOffset = (scroll.offset - details.delta.dy)
                  .clamp(0.0, scroll.position.maxScrollExtent);
              scroll.jumpTo(newOffset);
            }
          },
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: textLines > minLines,
            interactive: true,
            child: TextField(
              controller: _controller,
              scrollController: _scroll,
              readOnly: widget.readOnly,
              enabled: widget.enabled,
              expands: true,
              scrollPhysics: const AlwaysScrollableScrollPhysics(),
              keyboardType: TextInputType.multiline,
              minLines: null,
              maxLines: null,
              style: TextStyle(
                color: widget.textColor,
                fontFamily: widget.fontFamily,
                fontSize: font,
                fontWeight: widget.fontWeight,
              ),
              decoration: InputDecoration(
                hintText: widget.hintText,
                filled: widget.fillColor != null,
                fillColor: widget.fillColor,
                contentPadding: widget.contentPadding,
                isDense: true,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  borderSide: BorderSide(
                    color: widget.borderColor!,
                    width: widget.borderWidth,
                  ),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  borderSide: BorderSide(
                    color: widget.disabledBorderColor ?? widget.borderColor!,
                    width: widget.borderWidth,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  borderSide: BorderSide(
                    color: widget.focusedBorderColor!,
                    width: widget.focusedBorderWidth,
                  ),
                ),
              ),
              onChanged: widget.binding.isNotEmpty &&
                      !widget.readOnly &&
                      widget.enabled
                  ? (text) => widget.state.setBinding(widget.binding, text)
                  : null,
              textAlignVertical: TextAlignVertical.top,
            ),
          ),
        ),
      );
      return field;
    }
    if (widget.height != null) {
      field = SizedBox(height: widget.height, child: field);
    } else if (widget.minHeight != null) {
      field = ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.minHeight!),
        child: field,
      );
    }
    return field;
  }
}

EdgeInsets? _edgeInsets(dynamic value) {
  if (value is num) return EdgeInsets.all(value.toDouble());
  if (value is Map) {
    double? number(String key) => (value[key] as num?)?.toDouble();
    final top = number('top') ?? number('vertical');
    final right = number('right') ?? number('horizontal');
    final bottom = number('bottom') ?? number('vertical');
    final left = number('left') ?? number('horizontal');
    if (top != null && right != null && bottom != null && left != null) {
      return EdgeInsets.fromLTRB(left, top, right, bottom);
    }
  }
  return null;
}

FontWeight _fontWeight(dynamic value) {
  final numeric = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  switch (numeric) {
    case 100:
      return FontWeight.w100;
    case 200:
      return FontWeight.w200;
    case 300:
      return FontWeight.w300;
    case 400:
      return FontWeight.w400;
    case 500:
      return FontWeight.w500;
    case 600:
      return FontWeight.w600;
    case 700:
      return FontWeight.w700;
    case 800:
      return FontWeight.w800;
    case 900:
      return FontWeight.w900;
    default:
      return FontWeight.normal;
  }
}

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

String? _stringFieldValue(dynamic value) {
  if (value == null) return null;
  if (value is bool) return null;
  if (value is num) return value.toString();
  final text = value.toString();
  if (text.trim().isEmpty) return null;
  final lower = text.trim().toLowerCase();
  if (lower == 'true' || lower == 'false') return null;
  return text;
}

Widget _wrapTextFieldSendButton({
  required BuildContext context,
  required Widget field,
  required dynamic send,
  required String binding,
  required AppState state,
  required SduiRenderer renderer,
  bool readOnly = false,
}) {
  // A read-only field is a display. The Display console publishes
  // sendButton as {visible, label} only, and catalog `cmd` has no
  // send button, so drawing the missing-icon diagnostic replaces the log.
  // Writable fields such as Send Data still require a complete button.
  if (readOnly) return field;
  if (send is! Map) return field;
  final visible = send['visible'];
  if (visible == false ||
      visible?.toString().trim().toLowerCase() == 'false') {
    return field;
  }

  final iconName = send['icon']?.toString().trim() ?? '';
  final size = _asDouble(send['size']);
  final radius = _asDouble(send['borderRadius']);
  final iconSize = _asDouble(send['iconSize']);
  final backgroundColor = SduiStyle.color(send['backgroundColor']);
  final iconColor = SduiStyle.color(send['iconColor']);
  final action = send['action'];
  final actionMap = action is Map
      ? Map<String, dynamic>.from(action)
      : const <String, dynamic>{};
  final actionBinding = actionMap['binding']?.toString() ?? binding;
  final actionType = actionMap['type']?.toString().trim().toLowerCase() ?? '';

  final issues = <String>[];
  if (iconName.isEmpty) issues.add('sendButton.icon — required schema icon name');
  if (size == null) issues.add('sendButton.size — required number');
  if (radius == null) issues.add('sendButton.borderRadius — required number');
  if (iconSize == null) issues.add('sendButton.iconSize — required number');
  if (backgroundColor == null) {
    issues.add('sendButton.backgroundColor — required valid color');
  }
  if (iconColor == null) {
    issues.add('sendButton.iconColor — required valid color');
  }
  if (actionType.isNotEmpty && actionType != 'send') {
    issues.add('sendButton.action.type — required "send"');
  }
  if (actionBinding.isEmpty) {
    issues.add('sendButton.action.binding — required non-empty binding');
  }

  if (issues.isNotEmpty) {
    // Incomplete sendButton is a schema gap. Keep the diagnostic under the
    // field. Placing it in the icon slot or as a non-flex row sibling gives
    // it a few pixels of width, wraps every character, and paints
    // "BOTTOM OVERFLOWED" down the card.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        SchemaIssueWidget(
          title: 'Invalid textField sendButton schema',
          details: issues,
          componentType: 'textField',
          binding: binding,
        ),
      ],
    );
  }

  final sendWidget = Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: actionBinding.isEmpty
          ? null
          : () async {
              if (actionMap.isNotEmpty) {
                await ActionRegistry.instance.dispatch(
                  context: context,
                  state: state,
                  action: actionMap,
                );
              } else {
                await state.sendBinding(actionBinding);
              }
            },
      borderRadius: BorderRadius.circular(radius!),
      child: Ink(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Center(
          child: renderer.build(context, <String, dynamic>{
            'type': 'icon',
            'properties': <String, dynamic>{
              'name': iconName,
              'size': iconSize,
            },
            'style': <String, dynamic>{
              'color': send['iconColor'],
            },
          }),
        ),
      ),
    ),
  );

  final gap = _asDouble(send['gap'] ?? send['spacing']) ??
      _asDouble(
        state.schema['extensions']?['universalUi']?['designSystem']
            ?['componentStyles']?['parameterCard']?['layout']?['gap'],
      ) ??
      _asDouble(state.schema['theme']?['spacing']?['cardGap']);

  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(child: field),
      if (gap != null && gap > 0) SizedBox(width: gap),
      sendWidget,
    ],
  );
}

class _GaugeNeedlePainter extends CustomPainter {
  _GaugeNeedlePainter({
    required this.value,
    required this.min,
    required this.max,
    required this.accentColor,
    required this.inactiveColor,
    required this.needleColor,
    required this.trackWidth,
    required this.needleWidth,
    required this.centerRadius,
  });

  final double value;
  final double min;
  final double max;
  final Color accentColor;
  final Color inactiveColor;
  final Color needleColor;
  final double trackWidth;
  final double needleWidth;
  final double centerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 10;

    final trackPaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = trackWidth
      ..strokeCap = StrokeCap.round;

    final activePaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = trackWidth
      ..strokeCap = StrokeCap.round;

    const startAngle = 150.0 * math.pi / 180.0;
    const sweepAngle = 240.0 * math.pi / 180.0;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    final fraction = max > min ? (value - min) / (max - min) : 0.0;
    final currentSweep = sweepAngle * fraction.clamp(0.0, 1.0);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      currentSweep,
      false,
      activePaint,
    );

    final needleAngle = startAngle + currentSweep;
    final needleEnd = Offset(
      center.dx + (radius - 15) * math.cos(needleAngle),
      center.dy + (radius - 15) * math.sin(needleAngle),
    );

    final needlePaint = Paint()
      ..color = needleColor
      ..strokeWidth = needleWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(center, needleEnd, needlePaint);
    canvas.drawCircle(center, centerRadius, Paint()..color = needleColor);
  }

  @override
  bool shouldRepaint(covariant _GaugeNeedlePainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.min != min ||
        oldDelegate.max != max ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.needleColor != needleColor ||
        oldDelegate.trackWidth != trackWidth ||
        oldDelegate.needleWidth != needleWidth ||
        oldDelegate.centerRadius != centerRadius;
  }
}
