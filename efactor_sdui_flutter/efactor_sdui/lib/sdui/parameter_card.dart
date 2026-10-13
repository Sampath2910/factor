import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'component_registry.dart';
import 'renderer.dart';
import 'schema_guard.dart';
import 'style.dart';

/// Strict schema-driven renderer for one entry of `controls[]`.
///
/// No visual fallback is invented here. A missing/invalid visual field renders
/// a compact, detailed schema error naming the exact JSON path.
class ParameterCard extends StatelessWidget {
  const ParameterCard({
    super.key,
    required this.control,
    required this.state,
    this.showLeftAccent = true,
    this.embedded = false,
  });

  final Map<String, dynamic> control;
  final AppState state;

  /// The outer parameter group owns the single visible accent line.
  /// Standalone cards retain their schema-declared accent.
  final bool showLeftAccent;

  /// Nested inside `_ApiControlGroup`. The group already paints the left
  /// accent and the parameter title; this card still keeps its own white
  /// surface, border and shadow — the same nested ParameterCard web shows.
  final bool embedded;

  Map<String, dynamic> get _liveControl {
    final id = control['id']?.toString() ?? '';
    if (id.isEmpty) return control;
    return state.controlById(id) ?? control;
  }

  Map<String, dynamic> get _cardProps {
    final component = _liveControl['component'];
    if (component is! Map) return const {};
    final tree = component['widgetTree'];
    if (tree is! Map) return const {};
    final properties = tree['properties'];
    if (properties is! Map) return const {};
    final props = properties['props'];
    if (props is! Map) return const {};
    return Map<String, dynamic>.from(props);
  }

  Map<String, dynamic> get _cardStyle =>
      Map<String, dynamic>.from((_cardProps['cardStyle'] as Map?) ?? const {});

  Map<String, dynamic> get _styles =>
      Map<String, dynamic>.from((_liveControl['styles'] as Map?) ?? const {});

  @override
  Widget build(BuildContext context) {
    final control = _liveControl;
    final id = control['id']?.toString() ?? '';
    final binding = control['binding']?.toString() ?? '';
    final catalogComponent = _resolvedCatalogComponent(control);
    final isApiGenerated = _isApiGeneratedControl(control);
    final isResponse = AppState.isResponseControl(control);
    // The OUTER group already paints the parameter name. Inner captions must
    // never be catalog/protocol component types (TEXT, TOGGLE SWITCH, …).
    final label = _resolvedFieldLabel(control, catalogComponent);
    final componentType = _resolvedComponentType(control, catalogComponent);

    final styles = _styles;
    final cardStyle = _cardStyle;
    final parameterCardDesign = _parameterCardDesignStyle();
    final designParts = Map<String, dynamic>.from(
      (parameterCardDesign['parts'] as Map?) ?? const {},
    );
    final designLayout = Map<String, dynamic>.from(
      (parameterCardDesign['layout'] as Map?) ?? const {},
    );
    final designStackedLayout = Map<String, dynamic>.from(
      (parameterCardDesign['stackedLayout'] as Map?) ?? const {},
    );

    // Style precedence is broad -> concrete. Shared design-system values are
    // defaults only; the control/card declarations always win.
    final leftAccent = _deepMergeMaps(
      Map<String, dynamic>.from(
        (designParts['leftAccent'] as Map?) ?? const {},
      ),
      _deepMergeMaps(
        Map<String, dynamic>.from(
          (cardStyle['leftAccent'] as Map?) ?? const {},
        ),
        Map<String, dynamic>.from((styles['leftAccent'] as Map?) ?? const {}),
      ),
    );
    final iconBubble = _deepMergeMaps(
      Map<String, dynamic>.from(
        (designParts['iconBubble'] as Map?) ?? const {},
      ),
      _deepMergeMaps(
        Map<String, dynamic>.from(
          (cardStyle['iconBubble'] as Map?) ?? const {},
        ),
        Map<String, dynamic>.from((styles['iconBubble'] as Map?) ?? const {}),
      ),
    );
    final fieldLabel = _deepMergeMaps(
      Map<String, dynamic>.from((designParts['label'] as Map?) ?? const {}),
      Map<String, dynamic>.from((cardStyle['fieldLabel'] as Map?) ?? const {}),
    );
    final fieldValue = _deepMergeMaps(
      Map<String, dynamic>.from((designParts['value'] as Map?) ?? const {}),
      Map<String, dynamic>.from((cardStyle['fieldValue'] as Map?) ?? const {}),
    );

    // For API-generated controls the control-level catalog selection is the
    // authoritative component contract. The backend can carry a stale copied
    // component.widgetTree from the source protocol field (for example a
    // copied Switch tree while catalogComponentType selects autoTriggerTimer).
    // In that case using the copied widgetTree layout first turns a schema
    // slider into a compact row accessory even though the selected catalog
    // explicitly declares a stacked slider. Prefer the selected catalog only
    // for API-generated controls; Studio-authored controls continue to use
    // their concrete widgetTree layout exactly as declared.
    final rawLayout = isApiGenerated && catalogComponent != null
        ? (catalogComponent['layout'] ??
            catalogComponent['position'] ??
            _cardProps['layout'])
        : _cardProps['layout'];
    var layout = rawLayout?.toString().trim().toLowerCase() ?? '';
    final widgetTreeType =
        control['component']?['widgetTree']?['type']?.toString() ?? '';
    final schemaSegmented = layout == 'segmented' ||
        _normalizedType(componentType) == 'segmented' ||
        _normalizedType(control['variant']?.toString()) == 'segmented' ||
        _normalizedType(widgetTreeType) == 'segmentedcontrol';
    // Studio Direction is a SegmentedControl. Its widget tree publishes
    // options and omits props.layout. The component type is the layout.
    if (schemaSegmented && layout != 'row' && layout != 'stacked') {
      layout = 'segmented';
    }
    if (layout.isEmpty && (embedded || isResponse)) {
      layout = 'row';
    }

    final gridColumns = (designLayout['columns'] as List?)
            ?.map((value) => value.toString().trim().toLowerCase())
            .toList(growable: false) ??
        (embedded ? const <String>['auto', '1fr'] : const <String>[]);
    final gridGap = _number(designLayout['gap']) ?? (embedded ? 8.0 : null);
    final gridAlignItems = designLayout['alignItems']?.toString() ?? (embedded ? 'center' : null);
    final stackedGap = _number(designStackedLayout['gap']) ?? 8.0;

    final missing = <String>[];
    void need(bool valid, String path, String expectation) {
      if (!valid) missing.add('$path — $expectation');
    }

    final themeColors = _map(state.schema['theme']?['colors']);
    final themeSpacing = _map(state.schema['theme']?['spacing']);
    final themeRadius = _map(state.schema['theme']?['radius']);
    final themeBorders = _map(state.schema['theme']?['borders']);
    final designBorder = _map(parameterCardDesign['border']);
    final designIcons = _map(
      state.schema['extensions']?['universalUi']?['designSystem']?['icons'],
    );

    // Control cardStyle wins, then the shared parameterCard design system,
    // then theme tokens. Command/input controls in this schema omit
    // widgetTree.cardStyle and rely on those shared schema objects.
    final background = SduiStyle.color(
      (styles['cardColor'] ??
              cardStyle['backgroundColor'] ??
              parameterCardDesign['backgroundColor'] ??
              themeColors['cardBackground'] ??
              themeColors['surface'] ??
              themeColors['background'])
          ?.toString(),
    ) ?? (embedded ? const Color(0x00000000) : null);
    final borderColor = SduiStyle.color(
      (styles['borderColor'] ??
              cardStyle['borderColor'] ??
              parameterCardDesign['borderColor'] ??
              designBorder['color'] ??
              themeColors['cardBorder'] ??
              themeColors['border'] ??
              themeBorders['color'])
          ?.toString(),
    ) ?? (embedded ? const Color(0x00000000) : null);
    final borderWidth = _number(
      cardStyle['borderWidth'] ??
          styles['borderWidth'] ??
          parameterCardDesign['borderWidth'] ??
          designBorder['width'] ??
          themeBorders['size'],
    ) ?? (embedded ? 0.0 : null);
    final radius = _number(
      cardStyle['borderRadius'] ??
          styles['borderRadius'] ??
          parameterCardDesign['borderRadius'] ??
          themeRadius['card'],
    ) ?? (embedded ? 0.0 : null);
    final padding = _number(
      cardStyle['padding'] ??
          styles['padding'] ??
          parameterCardDesign['padding'] ??
          themeSpacing['cardPadding'],
    ) ?? (embedded ? 8.0 : null);
    final minHeight = _number(
      cardStyle['minHeight'] ??
          styles['minHeight'] ??
          parameterCardDesign['minHeight'],
    ) ?? (embedded ? 44.0 : null);

    final accentVisible =
        !embedded && showLeftAccent && leftAccent['visible'] != false;
    final accentWidth = _number(leftAccent['width']);
    final accentPair = _accentColors(leftAccent);
    final accentStart = accentPair.$1;
    final accentEnd = accentPair.$2;

    final bubbleWidth = _number(iconBubble['width'] ?? iconBubble['size']) ??
        (embedded ? 36.0 : null);
    final bubbleHeight = _number(iconBubble['height'] ?? iconBubble['size']) ??
        (embedded ? 36.0 : null);
    final bubbleBackground = SduiStyle.color(
      iconBubble['backgroundColor']?.toString(),
    ) ?? (embedded ? const Color(0x242563EB) : null);
    final bubbleIconSize = _number(
      iconBubble['iconSize'] ??
          state.schema['icons']?['size'] ??
          designIcons['size'] ??
          iconBubble['size'],
    ) ?? (embedded ? 20.0 : null);
    final bubbleIconColor = SduiStyle.color(
      (iconBubble['iconColor'] ??
              styles['iconColor'] ??
              themeColors['icon'] ??
              themeColors['accent'] ??
              themeColors['primary'])
          ?.toString(),
    ) ?? (embedded ? const Color(0xFF2563EB) : null);

    final labelColor = SduiStyle.color(
      (fieldLabel['color'] ??
              styles['mutedTextColor'] ??
              themeColors['textPrimary'] ??
              themeColors['text'])
          ?.toString(),
    ) ?? (embedded ? const Color(0xFF64748B) : null);
    final labelSize = _number(fieldLabel['fontSize']) ?? (embedded ? 12.0 : null);
    final labelWeight = _fontWeight(fieldLabel['fontWeight']) ?? (embedded ? FontWeight.w600 : null);
    final uppercase = embedded ? false : (fieldLabel['uppercase'] == true);
    final valueColor = SduiStyle.color(
      (fieldValue['color'] ??
              styles['textColor'] ??
              themeColors['textPrimary'] ??
              themeColors['text'])
          ?.toString(),
    ) ?? (embedded ? const Color(0xFF1E293B) : null);
    final valueSize = _number(fieldValue['fontSize']) ?? (embedded ? 14.0 : null);
    final valueWeight = _fontWeight(fieldValue['fontWeight']) ?? (embedded ? FontWeight.w600 : null);

    need(
      id.isNotEmpty,
      'controls[].id',
      'required non-empty control identifier',
    );
    need(binding.isNotEmpty, 'controls[$id].binding', 'required state binding');
    // Inner captions are optional. The outer group already renders the
    // parameter name; web shows the live value rather than componentLabel.
    need(
      componentType.isNotEmpty,
      'controls[$id].componentType',
      'required component type',
    );
    need(
      background != null,
      'controls[$id].styles.cardColor or component.widgetTree.properties.props.cardStyle.backgroundColor',
      'required valid color',
    );
    need(
      borderColor != null,
      'controls[$id].styles.borderColor or component.widgetTree.properties.props.cardStyle.borderColor',
      'required valid color',
    );
    need(
      borderWidth != null,
      'controls[$id].cardStyle.borderWidth or '
          'designSystem.componentStyles.parameterCard.borderWidth or '
          'theme.borders.size',
      'required number',
    );
    need(
      radius != null,
      'controls[$id].cardStyle.borderRadius or '
          'designSystem.componentStyles.parameterCard.borderRadius or '
          'theme.radius.card',
      'required number',
    );
    need(
      padding != null,
      'controls[$id].cardStyle.padding or '
          'designSystem.componentStyles.parameterCard.padding or '
          'theme.spacing.cardPadding',
      'required number',
    );
    need(
      minHeight != null,
      'controls[$id].cardStyle.minHeight or '
          'designSystem.componentStyles.parameterCard.minHeight',
      'required number',
    );
    if (accentVisible) {
      need(
        accentWidth != null,
        'controls[$id].styles.leftAccent.width',
        'required number when accent is visible',
      );
      need(
        accentStart != null,
        'controls[$id].styles.leftAccent.colorStart',
        'required valid color',
      );
      need(
        accentEnd != null,
        'controls[$id].styles.leftAccent.colorEnd',
        'required valid color',
      );
    }
    need(
      bubbleWidth != null,
      'controls[$id].styles.iconBubble.size/width or '
          'extensions.universalUi.designSystem.componentStyles.parameterCard.parts.iconBubble.width',
      'required number',
    );
    need(
      bubbleHeight != null,
      'controls[$id].styles.iconBubble.size/height or '
          'extensions.universalUi.designSystem.componentStyles.parameterCard.parts.iconBubble.height',
      'required number',
    );
    need(
      bubbleBackground != null,
      'controls[$id].styles.iconBubble.backgroundColor',
      'required valid color',
    );
    need(
      bubbleIconSize != null,
      'controls[$id].styles.iconBubble.iconSize or icons.size',
      'required number',
    );
    need(
      bubbleIconColor != null,
      'controls[$id].styles.iconBubble.iconColor',
      'required valid color',
    );
    need(
      labelColor != null,
      'controls[$id].component.widgetTree.properties.props.cardStyle.fieldLabel.color',
      'required valid color',
    );
    need(
      labelSize != null,
      'controls[$id].component.widgetTree.properties.props.cardStyle.fieldLabel.fontSize',
      'required number',
    );
    need(
      labelWeight != null,
      'controls[$id].component.widgetTree.properties.props.cardStyle.fieldLabel.fontWeight',
      'required weight 100â€“900',
    );
    need(
      uppercase is bool,
      'controls[$id].component.widgetTree.properties.props.cardStyle.fieldLabel.uppercase',
      'required boolean',
    );
    need(
      valueColor != null,
      'controls[$id].component.widgetTree.properties.props.cardStyle.fieldValue.color',
      'required valid color',
    );
    need(
      valueSize != null,
      'controls[$id].component.widgetTree.properties.props.cardStyle.fieldValue.fontSize',
      'required number',
    );
    need(
      valueWeight != null,
      'controls[$id].component.widgetTree.properties.props.cardStyle.fieldValue.fontWeight',
      'required weight 100â€“900',
    );
    need(
      layout == 'row' || layout == 'stacked' || layout == 'segmented',
      'controls[$id].component.widgetTree.properties.props.layout or '
          'components.catalog[].layout or controls[$id].componentType',
      'required row, stacked, or segmented',
    );

    final catalogPosition = _catalogPosition(control);
    final usesInlineGrid = layout == 'row' && catalogPosition == 'inline';
    if (layout == 'row') {
      final effectiveType =
          designLayout['type']?.toString().trim().toLowerCase() ??
              (embedded ? 'grid' : '');
      need(
        effectiveType == 'grid',
        'extensions.universalUi.designSystem.componentStyles.parameterCard.layout.type',
        'required grid for row ParameterCard placement',
      );
      need(
        gridColumns.length >= 2,
        'extensions.universalUi.designSystem.componentStyles.parameterCard.layout.columns',
        'required at least icon and content tracks',
      );
      need(
        gridGap != null,
        'extensions.universalUi.designSystem.componentStyles.parameterCard.layout.gap',
        'required number',
      );
      need(
        _crossAxisAlignmentFromSchema(gridAlignItems) != null,
        'extensions.universalUi.designSystem.componentStyles.parameterCard.layout.alignItems',
        'required start, center, end, or stretch',
      );
      if (gridColumns.length >= 2) {
        need(
          _gridTrackKind(gridColumns[0]) != null,
          'extensions.universalUi.designSystem.componentStyles.parameterCard.layout.columns[0]',
          'supported track: auto, <number>, <number>px, or <number>fr',
        );
        need(
          _gridTrackKind(gridColumns[1]) != null,
          'extensions.universalUi.designSystem.componentStyles.parameterCard.layout.columns[1]',
          'supported track: auto, <number>, <number>px, or <number>fr',
        );
      }
    }
    if (usesInlineGrid) {
      need(
        _number(fieldLabel['marginBottom']) != null,
        'extensions.universalUi.designSystem.componentStyles.parameterCard.parts.label.marginBottom '
            'or controls[$id].component.widgetTree.properties.props.cardStyle.fieldLabel.marginBottom',
        'required number for label-to-inline-component spacing',
      );
    }
    if (layout == 'stacked') {
      need(
        stackedGap != null,
        'extensions.universalUi.designSystem.componentStyles.parameterCard.stackedLayout.gap',
        'required number for stacked cards',
      );
      need(
        gridGap != null,
        'extensions.universalUi.designSystem.componentStyles.parameterCard.layout.gap',
        'required number for the stacked card header',
      );
      need(
        _crossAxisAlignmentFromSchema(gridAlignItems) != null,
        'extensions.universalUi.designSystem.componentStyles.parameterCard.layout.alignItems',
        'required start, center, end, or stretch for the stacked card header',
      );
    }

    final overflow = (_cardProps['overflow'] ??
            cardStyle['overflow'] ??
            parameterCardDesign['overflow'])
        ?.toString()
        .trim()
        .toLowerCase();
    final clipBehavior = switch (overflow) {
      'visible' => Clip.none,
      'hidden' || 'clip' => Clip.hardEdge,
      'antialias' || 'antiAlias' => Clip.antiAlias,
      _ => Clip.none,
    };

    final shadow = embedded ? null : _shadowForControl(state.schema, id, missing);

    if (missing.isNotEmpty) {
      return SchemaIssueWidget(
        title: 'Invalid ParameterCard schema',
        details: missing,
        controlId: id,
        componentType: componentType,
        binding: binding,
      );
    }

    final listenProps = control['component']?['props'];
    final listenToLogGate = listenProps is Map &&
        listenProps['variant']?.toString().trim().toLowerCase() == 'terminal';
    final cardListenable = listenToLogGate
        ? Listenable.merge(<Listenable>[
            state.listenableForControl(id: id, binding: binding),
            ...state.logGateListenables(),
          ])
        : state.listenableForControl(id: id, binding: binding);

    return AnimatedBuilder(
      animation: cardListenable,
      builder: (context, _) {
        final control = _liveControl;
        final renderer = SduiRenderer(state);
        final widgetTree = control['component']?['widgetTree'] as Map?;
        final inlineChildren = List<Map<String, dynamic>>.from(
          widgetTree?['children'] as List? ?? const [],
        );
        final schemaChildren = _resolvedSchemaChildren(
          inlineChildren: inlineChildren,
          sourceControl: control,
          catalogComponent: catalogComponent,
          binding: binding,
          resolvedComponentType: componentType,
        );
        final rawMetaChipNode =
            schemaChildren.cast<Map<String, dynamic>?>().firstWhere(
                  (child) => _normalizedType(child?['type']) == 'metachip',
                  orElse: () => null,
                );
        final metaChipProps = rawMetaChipNode == null
            ? const <String, dynamic>{}
            : Map<String, dynamic>.from(
                (rawMetaChipNode['properties']?['props'] as Map?) ?? const {},
              );
        final showMetaChip = () {
          final explicit = _boolOrNull(_cardProps['showMetaChip']) ??
              _boolOrNull(metaChipProps['visible']) ??
              _boolOrNull(metaChipProps['visibility']);
          if (explicit != null) return explicit;
          // Stacked sliders already paint MIN / current / MAX. Web does not
          // also place a trailing value chip on that row.
          if (layout == 'stacked') return false;
          return true;
        }();
        final metaChipNode = showMetaChip ? rawMetaChipNode : null;

        // `position` is schema data from the component catalog. Inline
        // controls are placed by the ParameterCard design-system grid rather
        // than by a Flutter-authored width or offset.
        final effectiveLayout = usesInlineGrid ? 'inline-grid' : layout;

        final bodyChildren = schemaChildren
            .where((child) => _normalizedType(child['type']) != 'metachip')
            .map((child) => _enrichChildNode(child, control))
            .toList(growable: false);

        final normalizedComponentType = _normalizedType(componentType);
        final componentMap = control['component'] is Map
            ? control['component'] as Map
            : null;
        final componentProps = componentMap?['props'] is Map
            ? componentMap!['props'] as Map
            : null;
        final readOnlyTelemetry = control['readOnly'] == true ||
            control['interactive'] == false ||
            componentMap?['readOnly'] == true ||
            componentMap?['interactive'] == false ||
            componentProps?['readOnly'] == true;
        final isTerminalConsole =
            componentProps?['variant']?.toString().trim().toLowerCase() ==
                'terminal';
        // A command response row is a text field whose content is the
        // response name or the live cloud reading. Collapsing it to a header
        // would paint the placeholder OFF instead of that field.
        final isResponseText = AppState.isResponseControl(control) &&
            (normalizedComponentType == 'textfield' ||
                normalizedComponentType == 'text');
        // Read-only text/value rows (voltage, current, rpm, name, …) show the
        // bound reading itself. The catalog TextField is often missing colors
        // and would replace the reading with a schema error.
        final isHeaderOnlyValue = !isTerminalConsole &&
            !isResponseText &&
            ((bodyChildren.isEmpty &&
                (normalizedComponentType == 'value' ||
                    normalizedComponentType == 'text' ||
                    normalizedComponentType == 'auto' ||
                    normalizedComponentType == 'listtile')) ||
            (readOnlyTelemetry &&
                (normalizedComponentType == 'textfield' ||
                    normalizedComponentType == 'text' ||
                    normalizedComponentType == 'value' ||
                    normalizedComponentType == 'auto')));

        // A value/text control with no schema child already displays its bound
        // value in the ParameterCard header. Building the registry value again
        // below the header duplicates the same value. This is determined only
        // from the schema component type and child structure.
        //
        // A row card's single control is a trailing accessory and must retain
        // its schema size. A stacked card renders its children as a vertical
        // content area. This distinction prevents PowerButton/Switch widgets
        // from being stretched and centered across the full card width.
        final componentWidget = isHeaderOnlyValue
            ? const SizedBox.shrink()
            : bodyChildren.isNotEmpty
                ? (effectiveLayout == 'row' && bodyChildren.length == 1
                    ? renderer.build(context, bodyChildren.first, binding)
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var index = 0;
                              index < bodyChildren.length;
                              index++) ...[
                            renderer.build(
                                context, bodyChildren[index], binding),
                            if (index != bodyChildren.length - 1)
                              SizedBox(
                                height: effectiveLayout == 'stacked'
                                    ? stackedGap!
                                    : gridGap ?? 0,
                              ),
                          ],
                        ],
                      ))
                : ComponentRegistry.instance.hasBuilder(componentType)
                    ? () {
                        final treeProps = control['component']?['widgetTree']?['properties']?['props'] as Map?;
                        final compProps = control['component']?['props'] as Map?;
                        List<dynamic>? resolveCleanOptions() {
                          final clean = AppState.optionsFor(control);
                          if (clean.isNotEmpty) return clean;
                          return null;
                        }
                        final cleanOpts = resolveCleanOptions();
                        return ComponentRegistry.instance.build(
                          context: context,
                          node: <String, dynamic>{
                            'type': componentType,
                            'properties': <String, dynamic>{
                              'binding': binding,
                              'props': <String, dynamic>{
                                if (treeProps is Map)
                                  ...Map<String, dynamic>.from(treeProps),
                                if (compProps is Map)
                                  ...Map<String, dynamic>.from(compProps),
                                if (cleanOpts != null) 'options': cleanOpts,
                              },
                            },
                          },
                          props: <String, dynamic>{
                            ...control,
                            'binding': binding,
                            if (compProps is Map)
                              ...Map<String, dynamic>.from(compProps),
                            if (cleanOpts != null) 'options': cleanOpts,
                          },
                          style: SduiStyle(control['styles'] as Map?),
                          children: const [],
                          state: state,
                          renderer: renderer,
                        );
                      }()
                    : const SizedBox.shrink();

        final rowComponentWidget =
            isHeaderOnlyValue ? const SizedBox.shrink() : componentWidget;

        // A schema diagnostic contains explanatory text and is therefore not
        // a compact trailing accessory such as Switch/PowerButton.
        //
        // Putting a SchemaIssueWidget at the end of this Row can consume
        // hundreds of logical pixels and squeeze the label into a few pixels,
        // producing RenderFlex "RIGHT OVERFLOWED" stripes.
        //
        // Keep the diagnostic visible; only change its layout.
        final rowComponentHasSchemaIssue =
            rowComponentWidget is SchemaIssueWidget;
        // Segmented controls (Direction) publish options on the component,
        // not a row accessory. Place that control under the header, the same
        // way a schema diagnostic is kept out of the icon row.
        final placeBodyBelowHeader = effectiveLayout == 'segmented' ||
            rowComponentHasSchemaIssue ||
            isTerminalConsole;

        // Row lays out non-flex children with an unbounded horizontal
        // constraint before it allocates space to Expanded/Flexible children.
        // Full-width controls (for example a schema slider) therefore must not
        // be inserted as a raw trailing Row child: descendants that stretch to
        // their available width would receive maxWidth=Infinity.
        //
        // Give every non-flex row accessory a *loose* finite allocation. Compact
        // controls keep their intrinsic size; width-sensitive controls can use
        // the remaining width. Existing schema Flex wrappers are preserved.
        Widget constrainRowAccessory(Widget child) {
          if (child is Flexible) return child;
          return Flexible(fit: FlexFit.loose, child: child);
        }

        final liveValue = state.resolveBinding(binding);
        final displayValue = _displayValueForControl(
          control: control,
          componentType: componentType,
          liveValue: liveValue,
          state: state,
        );
        // A text field already paints the bound value. The schema card label
        // (widgetTree.properties.props.label) is the caption web shows above
        // that field — for example "tuning" — while protocol `label` is often
        // the field role ("Data") and is not the caption. Switches and gauges
        // keep the header value (ON / OFF) and do not repeat that caption.
        final textFieldShowsValue = !isHeaderOnlyValue &&
            normalizedComponentType == 'textfield';
        var caption = label;
        if (caption.isEmpty && textFieldShowsValue) {
          final treeLabel = _cardProps['label']?.toString().trim() ?? '';
          if (treeLabel.isNotEmpty && !_isUiComponentTypeName(treeLabel)) {
            caption = treeLabel;
          }
        }
        final showCaption = caption.isNotEmpty &&
            caption.toLowerCase() != displayValue.toLowerCase() &&
            !_isUiComponentTypeName(caption);
        // Schema value first (including the published placeholder), then the
        // same text updates when the cloud replaces the binding. An explicit
        // showValueInHeader wins. Otherwise a visible text field is the value,
        // so the header does not paint the same string a second time.
        final explicitHeaderValue =
            _boolOrNull(_cardProps['showValueInHeader']);
        final showHeaderValue = !isTerminalConsole &&
            displayValue.isNotEmpty &&
            (explicitHeaderValue ?? !textFieldShowsValue);

        var iconName = control['icon']?.toString() ?? '';
        if (iconName.isEmpty) {
          iconName = _fallbackIconForControl(control, componentType);
        }
        if (iconName.isEmpty && !embedded) {
          return SchemaIssueWidget(
            title: 'Missing control icon',
            details: ['controls[$id].icon — required schema icon name'],
            controlId: id,
            componentType: componentType,
            binding: binding,
          );
        }

        // The outer `_ApiControlGroup` already paints the ParameterCard
        // surface, border, shadow and padding. Nested inner rows are only
        // icon + value + accessory — the same inline contract web uses.
        final rowPadding = embedded
            ? EdgeInsets.zero
            : EdgeInsets.fromLTRB(
                padding! + (accentVisible ? accentWidth! : 0),
                padding,
                padding,
                padding,
              );

        return Container(
          constraints: BoxConstraints(minHeight: embedded ? 0 : minHeight!),
          clipBehavior: embedded ? Clip.none : clipBehavior,
          decoration: embedded
              ? const BoxDecoration()
              : BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(radius!),
                  border: Border.all(color: borderColor!, width: borderWidth!),
                  boxShadow: [shadow!],
                ),
          child: Stack(
            children: [
              Padding(
                padding: rowPadding,
                child: effectiveLayout == 'inline-grid'
                    ? Row(
                        crossAxisAlignment: _crossAxisAlignmentFromSchema(
                          gridAlignItems,
                        )!,
                        children: [
                          _wrapGridTrack(
                            track: gridColumns[0],
                            child: _buildSchemaIconBubble(
                              context: context,
                              renderer: renderer,
                              iconName: iconName,
                              bubbleWidth: bubbleWidth!,
                              bubbleHeight: bubbleHeight!,
                              bubbleBackground: bubbleBackground!,
                              bubbleIconSize: bubbleIconSize!,
                              bubbleIconColor: bubbleIconColor!,
                            ),
                          ),
                          SizedBox(width: gridGap!),
                          _wrapGridTrack(
                            track: gridColumns[1],
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (showCaption)
                                  Text(
                                    uppercase == true
                                        ? caption.toUpperCase()
                                        : caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: _themeFontFamily(),
                                      fontSize: labelSize,
                                      fontWeight: labelWeight,
                                      color: labelColor,
                                      letterSpacing: _number(
                                        fieldLabel['letterSpacing'],
                                      ),
                                    ),
                                  ),
                                if (showHeaderValue) ...[
                                  SizedBox(
                                    height:
                                        _number(fieldLabel['marginBottom']) ??
                                            0,
                                  ),
                                  Text(
                                    displayValue,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: _themeFontFamily(),
                                      fontSize: valueSize,
                                      fontWeight: valueWeight,
                                      color: valueColor,
                                      height: _number(fieldValue['lineHeight']),
                                    ),
                                  ),
                                ],
                                if (!isHeaderOnlyValue) ...[
                                  SizedBox(
                                    height: _number(
                                      fieldLabel['marginBottom'],
                                    )!,
                                  ),
                                  componentWidget,
                                ],
                              ],
                            ),
                          ),
                          if (metaChipNode != null &&
                              gridColumns.length >= 3) ...[
                            SizedBox(width: gridGap),
                            _wrapGridTrack(
                              track: gridColumns[2],
                              child: _buildMetaChip(
                                context: context,
                                renderer: renderer,
                                node: metaChipNode,
                                binding: binding,
                              ),
                            ),
                          ],
                        ],
                      )
                    : effectiveLayout == 'stacked'
                        ? Row(
                            crossAxisAlignment: _crossAxisAlignmentFromSchema(
                              gridAlignItems,
                            )!,
                            children: [
                              _buildSchemaIconBubble(
                                context: context,
                                renderer: renderer,
                                iconName: iconName,
                                bubbleWidth: bubbleWidth!,
                                bubbleHeight: bubbleHeight!,
                                bubbleBackground: bubbleBackground!,
                                bubbleIconSize: bubbleIconSize!,
                                bubbleIconColor: bubbleIconColor!,
                              ),
                              SizedBox(width: gridGap!),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (showCaption)
                                      Text(
                                        uppercase == true
                                            ? caption.toUpperCase()
                                            : caption,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: _themeFontFamily(),
                                          fontSize: labelSize,
                                          fontWeight: labelWeight,
                                          color: labelColor,
                                          letterSpacing: _number(
                                            fieldLabel['letterSpacing'],
                                          ),
                                        ),
                                      ),
                                    if (showHeaderValue)
                                      Text(
                                        displayValue,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: _themeFontFamily(),
                                          fontSize: valueSize,
                                          fontWeight: valueWeight,
                                          color: valueColor,
                                          height: _number(
                                            fieldValue['lineHeight'],
                                          ),
                                        ),
                                      ),
                                    if ((showCaption || showHeaderValue) &&
                                        !isHeaderOnlyValue)
                                      SizedBox(height: stackedGap!),
                                    if (!isHeaderOnlyValue) componentWidget,
                                  ],
                                ),
                              ),
                              if (metaChipNode != null) ...[
                                SizedBox(width: gridGap),
                                _buildMetaChip(
                                  context: context,
                                  renderer: renderer,
                                  node: metaChipNode,
                                  binding: binding,
                                ),
                              ],
                            ],
                          )
                        : placeBodyBelowHeader
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Keep the schema-owned icon/label header readable.
                                  Row(
                                    crossAxisAlignment:
                                        _crossAxisAlignmentFromSchema(
                                      gridAlignItems,
                                    )!,
                                    children: [
                                      _buildSchemaIconBubble(
                                        context: context,
                                        renderer: renderer,
                                        iconName: iconName,
                                        bubbleWidth: bubbleWidth!,
                                        bubbleHeight: bubbleHeight!,
                                        bubbleBackground: bubbleBackground!,
                                        bubbleIconSize: bubbleIconSize!,
                                        bubbleIconColor: bubbleIconColor!,
                                      ),
                                      SizedBox(width: gridGap!),
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (showCaption)
                                              Text(
                                                uppercase == true
                                                    ? caption.toUpperCase()
                                                    : caption,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontFamily:
                                                      _themeFontFamily(),
                                                  fontSize: labelSize,
                                                  fontWeight: labelWeight,
                                                  color: labelColor,
                                                  letterSpacing: _number(
                                                    fieldLabel['letterSpacing'],
                                                  ),
                                                ),
                                              ),
                                            if (showHeaderValue) ...[
                                              SizedBox(
                                                height: _number(
                                                      fieldLabel[
                                                          'marginBottom'],
                                                    ) ??
                                                    0,
                                              ),
                                              Text(
                                                displayValue,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontFamily:
                                                      _themeFontFamily(),
                                                  fontSize: valueSize,
                                                  fontWeight: valueWeight,
                                                  color: valueColor,
                                                  height: _number(
                                                    fieldValue['lineHeight'],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),

                                  // A diagnostic gets the complete available card
                                  // width instead of competing with the icon and label
                                  // in the same horizontal Row.
                                  SizedBox(height: gridGap),
                                  rowComponentWidget,
                                ],
                              )
                            : Row(
                                crossAxisAlignment:
                                    _crossAxisAlignmentFromSchema(
                                  gridAlignItems,
                                )!,
                                children: [
                                  _buildSchemaIconBubble(
                                    context: context,
                                    renderer: renderer,
                                    iconName: iconName,
                                    bubbleWidth: bubbleWidth!,
                                    bubbleHeight: bubbleHeight!,
                                    bubbleBackground: bubbleBackground!,
                                    bubbleIconSize: bubbleIconSize!,
                                    bubbleIconColor: bubbleIconColor!,
                                  ),
                                  SizedBox(width: gridGap!),
                                  if (showCaption || showHeaderValue)
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (showCaption)
                                            Text(
                                              uppercase == true
                                                  ? caption.toUpperCase()
                                                  : caption,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: _themeFontFamily(),
                                                fontSize: labelSize,
                                                fontWeight: labelWeight,
                                                color: labelColor,
                                                letterSpacing: _number(
                                                  fieldLabel['letterSpacing'],
                                                ),
                                              ),
                                            ),
                                          if (showHeaderValue)
                                            Text(
                                              displayValue,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: _themeFontFamily(),
                                                fontSize: valueSize,
                                                fontWeight: valueWeight,
                                                color: valueColor,
                                                height: _number(
                                                  fieldValue['lineHeight'],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    )
                                  else
                                    Expanded(
                                      child: rowComponentWidget is! SizedBox
                                          ? rowComponentWidget
                                          : const SizedBox.shrink(),
                                    ),
                                  if ((showCaption || showHeaderValue) &&
                                      rowComponentWidget is! SizedBox) ...[
                                    SizedBox(width: gridGap),
                                    constrainRowAccessory(rowComponentWidget),
                                  ],
                                ],
                              ),
              ),
              if (accentVisible)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: 0,
                  width: accentWidth,
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
      },
    );
  }

  String? _themeFontFamily() {
    final value =
        state.schema['theme']?['typography']?['fontFamily']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  String resolvedFieldLabel(
    Map<String, dynamic> sourceControl, [
    Map<String, dynamic>? catalogComponent,
  ]) =>
      _resolvedFieldLabel(sourceControl, catalogComponent);

  String _resolvedFieldLabel(
    Map<String, dynamic> sourceControl,
    Map<String, dynamic>? catalogComponent,
  ) {
    String? nonEmpty(dynamic value) {
      if (value is Map || value is List) return null;
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    // The outer group already shows the parameter name. Inner captions must
    // never be protocol/catalog component types — web does not paint
    // "TEXT", "TOGGLE SWITCH", "TRIGGER", or "SLIDER" inside the card.
    final typeCaptions = <String>{};
    void addCaption(dynamic value) {
      final text = nonEmpty(value);
      if (text != null) typeCaptions.add(text.toLowerCase());
    }

    addCaption(sourceControl['componentLabel']);
    addCaption(sourceControl['protocolMeta']?['ui_type']);
    addCaption(catalogComponent?['label']);
    addCaption(catalogComponent?['id']);
    addCaption(sourceControl['componentType']);
    addCaption(sourceControl['controlType']);
    addCaption(sourceControl['catalogComponentType']);
    addCaption(sourceControl['flutterWidget']);
    final uiComponents = sourceControl['protocolMeta']?['ui_components'];
    if (uiComponents is List) {
      for (final raw in uiComponents) {
        if (raw is Map) addCaption(raw['ui_type']);
      }
    }

    final directFieldLabel = nonEmpty(sourceControl['fieldLabel']);
    if (directFieldLabel != null &&
        !typeCaptions.contains(directFieldLabel.toLowerCase()) &&
        !_isUiComponentTypeName(directFieldLabel)) {
      return directFieldLabel;
    }

    // Response rows in command frames have their field names defined in
    // deviceFrame.response[N].default_name or value or protocolMeta.default
    // (e.g. Speed, Direction, Buzzer, Lamp, Voltage).
    final isResponse = AppState.isResponseControl(sourceControl);
    final responseField = AppState.responseFieldFor(sourceControl);
    final rawRespName = responseField?['default_name']?.toString().trim();
    final candidateName = (rawRespName != null &&
            rawRespName.isNotEmpty &&
            rawRespName.toLowerCase() != 'data' &&
            rawRespName.toLowerCase() != 'none')
        ? rawRespName
        : (responseField?['value'] ??
            responseField?['asperui_value'] ??
            sourceControl['protocolMeta']?['default'] ??
            responseField?['default_name'] ??
            responseField?['Field_description']);
    final responseName = nonEmpty(candidateName);
    if (responseName != null &&
        responseName.toLowerCase() != 'none' &&
        !typeCaptions.contains(responseName.toLowerCase()) &&
        !_isUiComponentTypeName(responseName)) {
      return responseName;
    }

    final declaredValue = (nonEmpty(sourceControl['value']) ??
            nonEmpty(
              sourceControl['component'] is Map
                  ? sourceControl['component']['displayValue']
                  : null,
            ) ??
            '')
        .toUpperCase();
    if (!isResponse && (declaredValue == 'ON' || declaredValue == 'OFF')) {
      // The outer card title is the parameter name. Inside a group the web
      // still paints that name on the row (COMMAND GET STATUS / OFF).
      if (!embedded) return '';
      final parameter = nonEmpty(
            sourceControl['parameter'] ?? sourceControl['parameterName'],
          ) ??
          '';
      if (parameter.isNotEmpty && !_isUiComponentTypeName(parameter)) {
        return parameter;
      }
      return '';
    }

    // Multi-field command rows (tuning / Remote Pairing) share one parameter
    // name. The per-row caption is commands[N].default_name when it differs.
    final parameter = nonEmpty(
          sourceControl['parameter'] ?? sourceControl['parameterName'],
        ) ??
        '';
    final commandField = AppState.commandFieldFor(sourceControl);
    final fieldName = nonEmpty(commandField?['default_name']);
    if (fieldName != null &&
        fieldName.toLowerCase() != 'data' &&
        fieldName.toLowerCase() != 'none' &&
        fieldName.toLowerCase() != parameter.toLowerCase() &&
        !typeCaptions.contains(fieldName.toLowerCase()) &&
        !_isUiComponentTypeName(fieldName)) {
      return fieldName;
    }

    // Grouped controls name the inner row as "{parameter} {role}" — Command,
    // Response, Error — while the outer group already paints the parameter.
    // Use only the schema-declared remainder; do not invent a caption.
    final rawLabel = nonEmpty(sourceControl['label']) ?? '';
    if (parameter.isNotEmpty &&
        rawLabel.toLowerCase().startsWith(parameter.toLowerCase())) {
      final remainder = rawLabel.substring(parameter.length).trim();
      if (remainder.isNotEmpty &&
          !typeCaptions.contains(remainder.toLowerCase()) &&
          !_isUiComponentTypeName(remainder)) {
        return remainder;
      }
    }
    return '';
  }

  bool _isUiComponentTypeName(String text) {
    final normalized = text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[-_]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    const names = {
      'text',
      'enter text',
      'entertext',
      'toggle switch',
      'toggle',
      'toggle button',
      'switch',
      'trigger',
      'text trigger',
      'slider',
      'cmd',
      'display',
      'button',
      'notification',
      'drop down',
      'dropdown',
      'dropdown button',
      'dropdownbutton',
      'select',
    };
    return names.contains(normalized);
  }

  bool _isApiGeneratedControl(Map<String, dynamic> sourceControl) {
    final source =
        sourceControl['componentTypeSource']?.toString().trim().toLowerCase();
    // Presence of apiComponentKey is not enough: Studio-authored controls keep
    // that key while still owning widgetTree. Only source == api may replace
    // that tree with the catalog template.
    return source == 'api';
  }

  Map<String, dynamic>? _resolvedCatalogComponent(
    Map<String, dynamic> sourceControl,
  ) {
    String? requested = sourceControl['catalogComponentType']?.toString();

    // New API-generated entries declare the final catalog type at the control
    // level even when the copied inline widgetTree still describes the source
    // command slider. The control-level API declaration is authoritative.
    if ((requested == null || requested.trim().isEmpty) &&
        _isApiGeneratedControl(sourceControl)) {
      final type = _normalizedType(
        sourceControl['componentType'] ?? sourceControl['controlType'],
      );
      requested = switch (type) {
        'button' => 'pushButton',
        'switch' => 'toggleSwitch',
        'powergauge' => 'hueCircle',
        'slider' => 'slider',
        'dropdown' || 'dropdownbutton' || 'select' => 'dropdown',
        _ => null,
      };
    }

    // `auto` with an empty widget tree is a read-only value contract.
    if ((requested == null || requested.trim().isEmpty) &&
        _normalizedType(sourceControl['componentType']) == 'auto') {
      requested = 'text';
    }

    if (requested == null || requested.trim().isEmpty) return null;
    final catalog = state.schema['components']?['catalog'];
    if (catalog is! List) return null;
    for (final entry in catalog) {
      if (entry is! Map) continue;
      if (_normalizedType(entry['id']) == _normalizedType(requested)) {
        return Map<String, dynamic>.from(entry);
      }
    }
    return null;
  }

  String _resolvedComponentType(
    Map<String, dynamic> sourceControl,
    Map<String, dynamic>? catalogComponent,
  ) {
    if (_isApiGeneratedControl(sourceControl) ||
        _normalizedType(sourceControl['componentType']) == 'auto') {
      final fromCatalog = catalogComponent?['baseType'] ??
          catalogComponent?['flutterWidget'] ??
          catalogComponent?['widgetTree']?['type'];
      if (fromCatalog != null && fromCatalog.toString().trim().isNotEmpty) {
        return fromCatalog.toString();
      }
    }
    final declaredType = (sourceControl['componentType'] ??
                sourceControl['component']?['type'] ??
                sourceControl['type'])
            ?.toString() ??
        '';
    if (declaredType.isNotEmpty && _normalizedType(declaredType) != 'auto') {
      return declaredType;
    }
    final metaUiType = sourceControl['protocolMeta']?['ui_type']
        ?.toString()
        .trim()
        .toLowerCase();
    if (metaUiType != null) {
      if (metaUiType.contains('drop') || metaUiType.contains('select')) {
        return 'dropdown';
      }
    }
    return declaredType;
  }

  List<Map<String, dynamic>> _resolvedSchemaChildren({
    required List<Map<String, dynamic>> inlineChildren,
    required Map<String, dynamic> sourceControl,
    required Map<String, dynamic>? catalogComponent,
    required String binding,
    required String resolvedComponentType,
  }) {
    final isApiGenerated = _isApiGeneratedControl(sourceControl);
    final isAuto = _normalizedType(sourceControl['componentType']) == 'auto';
    final catalogTree = catalogComponent?['widgetTree'];

    // A schema `auto` control with no concrete child is a read-only value
    // row.  Its value is already rendered by the ParameterCard header.  Do
    // not materialize a generic catalog Text child as a second/trailing copy
    // of the same value (for example Array / Response / Error rows).
    if (isAuto && inlineChildren.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    if (isApiGenerated && catalogTree is Map && catalogComponent != null) {
      final materialized = _materializeCatalogNode(
        Map<String, dynamic>.from(catalogTree),
        binding,
        catalogComponent,
      );
      return <Map<String, dynamic>>[materialized];
    }

    // `inlineComponentContract` requires component.widgetTree. When that tree
    // is absent, the schema catalog entry the control already selected is the
    // executable fallback — not a renderer-invented layout.
    if (inlineChildren.isEmpty &&
        catalogTree is Map &&
        catalogComponent != null) {
      final materialized = _materializeCatalogNode(
        Map<String, dynamic>.from(catalogTree),
        binding,
        catalogComponent,
      );
      return <Map<String, dynamic>>[materialized];
    }

    return inlineChildren;
  }

  Map<String, dynamic> _materializeCatalogNode(
    Map<String, dynamic> node,
    String binding,
    Map<String, dynamic> catalogComponent,
  ) {
    dynamic materialize(dynamic value) {
      if (value is String) return value.replaceAll('{{binding}}', binding);
      if (value is List) return value.map(materialize).toList();
      if (value is Map) {
        return value.map(
          (key, item) => MapEntry(key.toString(), materialize(item)),
        );
      }
      return value;
    }

    final result = Map<String, dynamic>.from(materialize(node) as Map);
    final properties = Map<String, dynamic>.from(
      (result['properties'] as Map?) ?? const {},
    );
    properties['binding'] = binding;

    final props = Map<String, dynamic>.from(
      (properties['props'] as Map?) ?? const {},
    );

    // Merge the copied component props only when that copied component is the
    // same catalog component selected by the API-generated control. If the two
    // contracts disagree, the selected controls[].catalogComponentType is the
    // only coherent executable contract and its catalog widgetTree must remain
    // intact. This rule is type/catalog driven and contains no model, account,
    // control-id or literal UI-value special cases.
    //
    // A missing inline widgetTree means the copied component.props are not a
    // complete visual contract (they are often leftover switch colors). Keep
    // the catalog widgetTree intact in that case.
    final hasInlineTree = control['component']?['widgetTree'] is Map;
    final componentProps = hasInlineTree &&
            _inlineComponentMatchesCatalog(
              control,
              catalogComponent,
            )
        ? sourceControlPropsForBinding(binding)
        : const <String, dynamic>{};

    final mergedProps = _deepMergeMaps(props, componentProps);
    final sliderLabel = catalogComponent['sliderLabel']?.toString().trim();
    if (sliderLabel != null &&
        sliderLabel.isNotEmpty &&
        (mergedProps['kicker'] == null ||
            mergedProps['kicker'].toString().trim().isEmpty)) {
      mergedProps['kicker'] = sliderLabel;
    }

    if (_normalizedType(result['type']) == 'dropdown' ||
        _normalizedType(result['type']) == 'dropdownbutton' ||
        _normalizedType(catalogComponent['id']) == 'dropdown') {
      final clean = AppState.optionsFor(control);
      if (clean.isNotEmpty) {
        mergedProps['options'] = clean;
      }
    }

    properties['props'] = mergedProps;
    result['properties'] = properties;
    return result;
  }

  bool _inlineComponentMatchesCatalog(
    Map<String, dynamic> sourceControl,
    Map<String, dynamic> catalogComponent,
  ) {
    final selectedCatalogId = _normalizedType(catalogComponent['id']);
    final component = sourceControl['component'];
    if (component is! Map) return true;

    final copiedCatalogId = _normalizedType(
      component['catalogComponentType'] ??
          component['widgetTree']?['properties']?['props']
              ?['catalogComponentType'],
    );
    if (copiedCatalogId.isNotEmpty && selectedCatalogId.isNotEmpty) {
      return copiedCatalogId == selectedCatalogId;
    }

    final copiedType = _normalizedType(
      component['type'] ?? component['flutterWidget'],
    );
    final catalogBaseType = _normalizedType(
      catalogComponent['baseType'] ?? catalogComponent['flutterWidget'],
    );
    final catalogTreeType = _normalizedType(
      catalogComponent['widgetTree']?['type'],
    );

    if (copiedType.isEmpty) return true;
    return copiedType == catalogBaseType || copiedType == catalogTreeType;
  }

  Map<String, dynamic> sourceControlPropsForBinding(String binding) {
    final props = control['component']?['props'];
    return props is Map
        ? Map<String, dynamic>.from(props)
        : <String, dynamic>{};
  }

  Map<String, dynamic> _parameterCardDesignStyle() {
    final extensions = state.schema['extensions'];
    if (extensions is! Map) return const <String, dynamic>{};
    final universalUi = extensions['universalUi'];
    if (universalUi is! Map) return const <String, dynamic>{};
    final designSystem = universalUi['designSystem'];
    if (designSystem is! Map) return const <String, dynamic>{};
    final componentStyles = designSystem['componentStyles'];
    if (componentStyles is! Map) return const <String, dynamic>{};
    final parameterCard = componentStyles['parameterCard'];
    return parameterCard is Map
        ? Map<String, dynamic>.from(parameterCard)
        : const <String, dynamic>{};
  }

  String? _gridTrackKind(String track) {
    final value = track.trim().toLowerCase();
    if (value == 'auto') return 'auto';
    if (RegExp(r'^\d+(?:\.\d+)?fr$').hasMatch(value)) return 'fr';
    if (RegExp(r'^\d+(?:\.\d+)?(?:px)?$').hasMatch(value)) {
      return 'fixed';
    }
    return null;
  }

  double? _gridTrackNumber(String track) {
    final value =
        track.trim().toLowerCase().replaceAll('px', '').replaceAll('fr', '');
    return double.tryParse(value);
  }

  Widget _wrapGridTrack({required String track, required Widget child}) {
    switch (_gridTrackKind(track)) {
      case 'fr':
        final flex = ((_gridTrackNumber(track) ?? 1) * 1000).round().clamp(
              1,
              1000000,
            );
        return Expanded(flex: flex.toInt(), child: child);
      case 'fixed':
        return SizedBox(width: _gridTrackNumber(track), child: child);
      case 'auto':
        return child;
      default:
        return child;
    }
  }

  CrossAxisAlignment? _crossAxisAlignmentFromSchema(dynamic value) {
    switch (value?.toString().trim().toLowerCase()) {
      case 'start':
      case 'flex-start':
        return CrossAxisAlignment.start;
      case 'center':
        return CrossAxisAlignment.center;
      case 'end':
      case 'flex-end':
        return CrossAxisAlignment.end;
      case 'stretch':
        return CrossAxisAlignment.stretch;
      default:
        return null;
    }
  }

  String? _catalogPosition(Map<String, dynamic> sourceControl) {
    final requested = (sourceControl['catalogComponentType'] ??
            sourceControl['override']?['componentType'] ??
            sourceControl['component']?['catalogComponentType'])
        ?.toString();
    if (requested == null || requested.isEmpty) return null;

    final catalog = state.schema['components']?['catalog'];
    if (catalog is! List) return null;
    for (final entry in catalog) {
      if (entry is! Map) continue;
      if (entry['id']?.toString().toLowerCase() == requested.toLowerCase()) {
        return entry['position']?.toString().toLowerCase();
      }
    }
    return null;
  }

  static bool? _boolOrNull(dynamic value) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'false' || text == '0' || text == 'no') return false;
    return null;
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

  Map<String, dynamic> _enrichChildNode(
    Map<String, dynamic> child,
    Map<String, dynamic> sourceControl,
  ) {
    final result = Map<String, dynamic>.from(child);
    final properties = Map<String, dynamic>.from(
      (result['properties'] as Map?) ?? const {},
    );

    final childProps = properties['props'] is Map
        ? Map<String, dynamic>.from(properties['props'] as Map)
        : <String, dynamic>{};

    final selectedCatalog = _resolvedCatalogComponent(sourceControl);
    final hasConflictingCopiedComponent =
        _isApiGeneratedControl(sourceControl) &&
            selectedCatalog != null &&
            !_inlineComponentMatchesCatalog(sourceControl, selectedCatalog);

    // A generated control can contain two different UI contracts at once:
    // controls[].catalogComponentType may select one component while the copied
    // component/component.props still belongs to a previous protocol UI type.
    // When that happens, do not leak stale switch/readOnly/disabled styling
    // into the catalog component that was actually selected. The catalog child
    // stays authoritative, while matching generated controls and all
    // Studio-authored controls preserve their existing merge behavior.
    final componentProps = hasConflictingCopiedComponent
        ? const <String, dynamic>{}
        : sourceControl['component']?['props'] is Map
            ? Map<String, dynamic>.from(
                sourceControl['component']['props'] as Map)
            : <String, dynamic>{};
    final controlProps = hasConflictingCopiedComponent
        ? const <String, dynamic>{}
        : sourceControl['props'] is Map
            ? Map<String, dynamic>.from(sourceControl['props'] as Map)
            : <String, dynamic>{};

    // Merge from broad defaults to the concrete child. This preserves nested
    // style.parts.track.gradient, thumb styling, labels, and containers.
    var props = _deepMergeMaps(componentProps, controlProps);
    props = _deepMergeMaps(props, childProps);

    final componentStyle = hasConflictingCopiedComponent
        ? const <String, dynamic>{}
        : sourceControl['component']?['style'] is Map
            ? Map<String, dynamic>.from(
                sourceControl['component']['style'] as Map)
            : <String, dynamic>{};
    final controlStyle = hasConflictingCopiedComponent
        ? const <String, dynamic>{}
        : sourceControl['style'] is Map
            ? Map<String, dynamic>.from(sourceControl['style'] as Map)
            : sourceControl['styles'] is Map
                ? Map<String, dynamic>.from(sourceControl['styles'] as Map)
                : <String, dynamic>{};
    final childStyle = result['style'] is Map
        ? Map<String, dynamic>.from(result['style'] as Map)
        : <String, dynamic>{};

    var mergedStyle = _deepMergeMaps(componentStyle, controlStyle);
    mergedStyle = _deepMergeMaps(mergedStyle, childStyle);

    final accessory = Map<String, dynamic>.from(
      (sourceControl['rightAccessory'] as Map?) ?? const {},
    );

    if (_normalizedType(result['type']) == 'powerbutton' &&
        !hasConflictingCopiedComponent) {
      if (accessory['activeColor'] != null) {
        props['activeColor'] = accessory['activeColor'];
      }
      if (accessory['inactiveColor'] != null) {
        props['inactiveColor'] = accessory['inactiveColor'];
      }
    }

    if (_normalizedType(result['type']) == 'elevatedbutton' &&
        !hasConflictingCopiedComponent) {
      // Prefer schema-authored captions only (props / accessory / control
      // label / parameter). Do not invent Material sizes or colors here.
      final declaredLabel = <dynamic>[
        props['label'],
        accessory['label'],
        sourceControl['label'],
        sourceControl['parameter'],
        sourceControl['parameterName'],
        sourceControl['component'] is Map
            ? (sourceControl['component'] as Map)['displayValue']
            : null,
      ]
          .map((value) => value?.toString().trim())
          .whereType<String>()
          .where((value) => value.isNotEmpty)
          .where((value) => !_isUiComponentTypeName(value))
          .toList(growable: false);
      // When the schema only published labelBinding, copy a schema caption so
      // ElevatedButton still has a required label from schema fields.
      if (declaredLabel.isNotEmpty &&
          (props['label'] == null ||
              props['label'].toString().trim().isEmpty)) {
        props['label'] = declaredLabel.first;
      }
      // Trigger captions are schema display labels. The live binding holds the
      // protocol byte and must not replace the button text after a send —
      // unless the control declares options (mapped live state).
      final valueType =
          sourceControl['valueType']?.toString().trim().toLowerCase();
      if (valueType == 'trigger' &&
          AppState.optionsFor(sourceControl).isEmpty) {
        props.remove('labelBinding');
      }
    }

    final childType = _normalizedType(result['type']);
    if (props['options'] != null ||
        childType == 'dropdown' ||
        childType == 'dropdownbutton' ||
        childType == 'select' ||
        childType == 'buttongroup' ||
        childType == 'segmentedcontrol' ||
        childType == 'segmented') {
      final clean = AppState.optionsFor(sourceControl);
      if (clean.isNotEmpty) {
        props['options'] = clean;
      } else if (props['options'] != null) {
        final normalized = AppState.normalizeEnumOptions(props['options']);
        if (normalized.isNotEmpty) {
          props['options'] = normalized;
        }
      }
    }

    properties['props'] = props;
    result['properties'] = properties;
    if (mergedStyle.isNotEmpty) {
      result['style'] = mergedStyle;
    }
    return result;
  }

  Widget _buildSchemaIconBubble({
    required BuildContext context,
    required SduiRenderer renderer,
    required String iconName,
    required double bubbleWidth,
    required double bubbleHeight,
    required Color bubbleBackground,
    required double bubbleIconSize,
    required Color bubbleIconColor,
  }) {
    return Container(
      width: bubbleWidth,
      height: bubbleHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bubbleBackground,
        shape: BoxShape.circle,
      ),
      child: renderer.build(context, <String, dynamic>{
        'type': 'icon',
        'properties': <String, dynamic>{
          'name': iconName,
          'size': bubbleIconSize,
        },
        'style': <String, dynamic>{'color': _colorString(bubbleIconColor)},
      }),
    );
  }

  String _displayValueForControl({
    required Map<String, dynamic> control,
    required String componentType,
    required dynamic liveValue,
    AppState? state,
  }) {
    final framed = state?.getControlReading(control) ??
        AppState.schemaFrameReading(control);
    if (framed != null &&
        (AppState.isUnsetTelemetryValue(liveValue) ||
            AppState.isCommandFieldNamePlaceholder(control, liveValue) ||
            AppState.readingsAreEqual(liveValue, control['parameter']) ||
            AppState.readingsAreEqual(liveValue, control['parameterName']) ||
            AppState.readingsAreEqual(liveValue, control['label']))) {
      liveValue = framed;
    }

    final normalized = componentType.trim().toLowerCase();

    bool? booleanState(dynamic value) {
      if (value is bool) return value;
      if (value is num) {
        if (value == 1) return true;
        if (value == 0) return false;
      }
      final text = value?.toString().trim().toLowerCase();
      if (<String>{'on', 'true', 'yes', '1', '01'}.contains(text)) return true;
      if (<String>{'off', 'false', 'no', '0', '00'}.contains(text)) {
        return false;
      }
      return null;
    }

    final boolValue = booleanState(liveValue);
    final declaredDisplay = <dynamic>[
      control['value'],
      control['override'] is Map ? (control['override'] as Map)['value'] : null,
      control['component'] is Map
          ? (control['component'] as Map)['displayValue']
          : null,
    ]
        .map((value) => value?.toString().trim().toUpperCase())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet();
    final declaresOnOffDisplay =
        declaredDisplay.contains('ON') || declaredDisplay.contains('OFF');

    if ((normalized == 'switch' || control['valueType'] == 'boolean') &&
        boolValue != null) {
      return boolValue ? 'ON' : 'OFF';
    }

    if (declaresOnOffDisplay) {
      if (boolValue != null) {
        return boolValue ? 'ON' : 'OFF';
      }
      return 'OFF';
    }

    if (normalized == 'segmented' || normalized == 'segmentedcontrol') {
      return _formatLiveDisplay(liveValue ?? control['value'] ?? '');
    }

    // Sliders already paint the number on the track. Text, value, and
    // read-only fields do not — the header is the reading.
    final widgetTree = control['component']?['widgetTree'];
    final children = widgetTree is Map ? widgetTree['children'] : null;
    if (children is List && children.isNotEmpty) {
      final renderedTypes = children
          .whereType<Map>()
          .map((child) => _normalizedType(child['type']))
          .toSet();
      if (renderedTypes.contains('slider') ||
          renderedTypes.contains('schemaslider')) {
        return '';
      }
    }

    // Binding is the source of truth. Schema seeds it on load (`--` or a
    // real reading). Cloud writes replace that same binding and this text
    // rebuilds. Do not drop the schema value because it is a placeholder.
    if (liveValue != null) {
      if (AppState.isFrameFieldNameOrPlaceholder(control, liveValue)) {
        if (framed != null &&
            !AppState.isFrameFieldNameOrPlaceholder(control, framed)) {
          liveValue = framed;
        } else {
          final declared = control['initialValue'] ??
              control['value'] ??
              control['component']?['props']?['value'] ??
              control['component']?['props']?['text'] ??
              control['props']?['value'] ??
              control['props']?['text'];
          if (declared != null &&
              !AppState.isFrameFieldNameOrPlaceholder(control, declared)) {
            liveValue = declared;
          } else {
            return '';
          }
        }
      }
      final mapped = _schemaDisplayForLiveValue(control, liveValue);
      final text = _formatLiveDisplay(mapped);
      if (text.isNotEmpty) return text;
    }

    final resolved = control['component']?['displayValue'] ??
        control['value'] ??
        control['initialValue'] ??
        control['component']?['props']?['value'] ??
        control['component']?['props']?['text'] ??
        control['props']?['value'] ??
        control['props']?['text'];
    if (AppState.isFrameFieldNameOrPlaceholder(control, resolved)) {
      if (framed != null &&
          !AppState.isFrameFieldNameOrPlaceholder(control, framed)) {
        return _formatLiveDisplay(framed);
      }
      return '';
    }
    return _formatLiveDisplay(resolved);
  }

  /// Maps a protocol value through schema options / valueMap when present.
  dynamic _schemaDisplayForLiveValue(
    Map<String, dynamic> control,
    dynamic liveValue,
  ) {
    if (liveValue == null || AppState.isUnsetTelemetryValue(liveValue)) {
      return '';
    }
    final liveStr = liveValue.toString().trim();
    if (RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(liveStr)) {
      return '';
    }

    final treeProps = control['component']?['widgetTree']?['properties']?['props'] as Map?;
    final controlProps = control['props'] as Map?;
    final candidates = <dynamic>[
      controlProps?['options'],
      treeProps?['options'],
      control['options'],
      control['component']?['options'],
      control['component'] is Map &&
              (control['component'] as Map)['props'] is Map
          ? (control['component'] as Map)['props']['options']
          : null,
      control['valueMap'],
      control['component'] is Map
          ? (control['component'] as Map)['valueMap']
          : null,
      control['component'] is Map &&
              (control['component'] as Map)['props'] is Map
          ? (control['component'] as Map)['props']['valueMap']
          : null,
    ];

    for (final candidate in candidates) {
      if (candidate is Map) {
        final map = Map<String, dynamic>.from(candidate);
        final key = liveValue.toString();
        if (map.containsKey(key)) return map[key];
        final lower = key.toLowerCase();
        for (final entry in map.entries) {
          if (entry.key.toLowerCase() == lower) return entry.value;
        }
      }
    }

    final matched = AppState.resolveEnumOption(control, liveValue);
    if (matched != null) {
      final label = matched['label'] ?? matched['text'] ?? matched['title'];
      if (label != null && label.toString().trim().isNotEmpty) {
        final labelStr = label.toString().trim();
        if (!RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(labelStr)) {
          return labelStr;
        }
      }
    }

    return liveValue;
  }

  String _formatLiveDisplay(dynamic resolved) {
    if (resolved == null) return '';
    if (resolved is num) {
      final number = resolved.toDouble();
      return number == number.roundToDouble()
          ? number.toInt().toString()
          : number.toString();
    }
    final text = resolved.toString();
    if (RegExp(r'^\[.+\]\s*(\[.+\])+$').hasMatch(text.trim())) {
      return '';
    }
    return text;
  }

  Widget _buildMetaChip({
    required BuildContext context,
    required SduiRenderer renderer,
    required Map<String, dynamic> node,
    required String binding,
  }) {
    final properties = Map<String, dynamic>.from(
      (node['properties'] as Map?) ?? const {},
    );
    final rawProps = properties['props'];
    final props = rawProps is Map
        ? Map<String, dynamic>.from(rawProps)
        : <String, dynamic>{};
    final theme = (state.schema['theme'] as Map?) ?? const {};
    final radiusMap = (theme['radius'] as Map?) ?? const {};
    final iconConfig = (state.schema['icons'] as Map?) ?? const {};
    final designMetaChip = state.schema['extensions']?['universalUi']
            ?['designSystem']?['componentStyles']?['parameterCard']?['parts']
        ?['metaChip'];
    final metaChipStyle = designMetaChip is Map
        ? Map<String, dynamic>.from(designMetaChip)
        : const <String, dynamic>{};

    final chipBinding =
        (properties['binding'] ?? props['binding'] ?? binding).toString();
    final liveValue = state.resolveBinding(chipBinding);
    final displayValue = liveValue?.toString() ?? props['value']?.toString();
    final backgroundColor = SduiStyle.color(
      props['backgroundColor']?.toString(),
    );
    final textColor = SduiStyle.color(props['textColor']?.toString());
    final iconColor = SduiStyle.color(props['iconColor']?.toString());
    final radius = _number(
      props['borderRadius'] ??
          metaChipStyle['borderRadius'] ??
          radiusMap['pill'],
    );
    final horizontalPadding = _number(
      props['paddingHorizontal'] ?? metaChipStyle['paddingHorizontal'],
    );
    final height = _number(props['height'] ?? metaChipStyle['height']);
    final gap = _number(props['gap'] ?? metaChipStyle['gap']);
    final iconSize = _number(
      props['iconSize'] ??
          metaChipStyle['iconSize'] ??
          iconConfig['size'] ??
          state.schema['extensions']?['universalUi']?['designSystem']?['icons']
              ?['size'],
    );
    final iconName = props['icon']?.toString();

    final issues = <String>[];
    if (displayValue == null) {
      issues.add('properties.props.value or binding value â€” required');
    }
    if (backgroundColor == null) {
      issues.add('properties.props.backgroundColor â€” required valid color');
    }
    if (textColor == null) {
      issues.add('properties.props.textColor â€” required valid color');
    }
    if (iconColor == null) {
      issues.add('properties.props.iconColor â€” required valid color');
    }
    if (radius == null) {
      issues.add(
        'properties.props.borderRadius or theme.radius.pill â€” required number',
      );
    }
    if (horizontalPadding == null) {
      issues.add(
        'properties.props.paddingHorizontal or designSystem.componentStyles.parameterCard.parts.metaChip.paddingHorizontal â€” required number',
      );
    }
    if (height == null) {
      issues.add(
        'properties.props.height or designSystem.componentStyles.parameterCard.parts.metaChip.height â€” required number',
      );
    }
    if (gap == null) {
      issues.add(
        'properties.props.gap or designSystem.componentStyles.parameterCard.parts.metaChip.gap â€” required number',
      );
    }
    if (iconName == null || iconName.isEmpty) {
      issues.add('properties.props.icon â€” required schema icon name');
    }
    if (iconSize == null) {
      issues.add('properties.props.iconSize or icons.size â€” required number');
    }

    if (issues.isNotEmpty) {
      return SchemaIssueWidget(
        title: 'Invalid metaChip schema',
        details: issues,
        componentType: node['type']?.toString(),
        binding: chipBinding,
      );
    }

    return Container(
      height: height!,
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding!),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(radius!),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          renderer.build(context, <String, dynamic>{
            'type': 'icon',
            'properties': <String, dynamic>{'name': iconName, 'size': iconSize},
            'style': <String, dynamic>{'color': props['iconColor']},
          }),
          SizedBox(width: gap!),
          Text(displayValue!, style: TextStyle(color: textColor)),
        ],
      ),
    );
  }

  static String _normalizedType(dynamic value) {
    final raw = value?.toString();
    if (raw == null) return '';
    return raw
        .trim()
        .toLowerCase()
        .replaceAll('-', '')
        .replaceAll('_', '')
        .replaceAll(' ', '');
  }

  static BoxShadow? _shadowForControl(
    Map<String, dynamic> schema,
    String id,
    List<String> missing,
  ) {
    final raw = schema['theme']?['shadows']?['card'];
    if (raw is! Map) {
      missing.add('theme.shadows.card — required card shadow object');
      return null;
    }
    final shadow = Map<String, dynamic>.from(raw);
    final color = SduiStyle.color(shadow['color']?.toString());
    final x = _number(shadow['offsetX']);
    final y = _number(shadow['offsetY']);
    final blur = _number(shadow['blurRadius']);
    final spread = _number(shadow['spreadRadius']);
    if (color == null)
      missing.add('theme.shadows.card.color — required valid color');
    if (x == null) {
      missing.add('theme.shadows.card.offsetX — required number');
    }
    if (y == null) {
      missing.add('theme.shadows.card.offsetY — required number');
    }
    if (blur == null) {
      missing.add('theme.shadows.card.blurRadius — required number');
    }
    if (spread == null) {
      missing.add('theme.shadows.card.spreadRadius — required number');
    }
    if (color == null ||
        x == null ||
        y == null ||
        blur == null ||
        spread == null) return null;
    return BoxShadow(
      color: color,
      offset: Offset(x, y),
      blurRadius: blur,
      spreadRadius: spread,
    );
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    }
    return const <String, dynamic>{};
  }

  static (Color?, Color?) _accentColors(Map<String, dynamic> leftAccent) {
    Color? start = SduiStyle.color(leftAccent['colorStart']?.toString());
    Color? end = SduiStyle.color(leftAccent['colorEnd']?.toString());
    final background = _map(leftAccent['background']);
    final stops = background['stops'];
    if (stops is List && stops.isNotEmpty) {
      final first = stops.first;
      final last = stops.last;
      if (first is Map) {
        start ??= SduiStyle.color(first['color']?.toString());
      }
      if (last is Map) {
        end ??= SduiStyle.color(last['color']?.toString());
      }
    }
    start ??= SduiStyle.color(background['fallbackColor']?.toString());
    end ??= start;
    return (start, end);
  }

  static double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return null;
    final match = RegExp(
      r'^(-?[0-9]+(?:\.[0-9]+)?)\s*(?:px|dp|sp)?$',
      caseSensitive: false,
    ).firstMatch(raw);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  static FontWeight? _fontWeight(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final index = (value.toInt() ~/ 100 - 1).clamp(0, 8);
      return FontWeight.values[index];
    }
    final str = value.toString().toLowerCase().trim();
    if (str == 'bold') return FontWeight.w700;
    if (str == 'extrabold' || str == 'extra-bold') return FontWeight.w800;
    if (str == 'semibold' || str == 'semi-bold') return FontWeight.w600;
    if (str == 'medium') return FontWeight.w500;
    if (str == 'black') return FontWeight.w900;
    if (str == 'regular' || str == 'normal') return FontWeight.w400;
    final parsed = int.tryParse(str);
    if (parsed != null) {
      final index = (parsed ~/ 100 - 1).clamp(0, 8);
      return FontWeight.values[index];
    }
    return null;
  }

  static String _colorString(dynamic value) {
    if (value is Color) {
      final a = (value.a * 255.0).round().clamp(0, 255);
      final r = (value.r * 255.0).round().clamp(0, 255);
      final g = (value.g * 255.0).round().clamp(0, 255);
      final b = (value.b * 255.0).round().clamp(0, 255);
      return '#${a.toRadixString(16).padLeft(2, '0')}'
          '${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')}';
    }
    return value?.toString() ?? '';
  }

  static String _fallbackIconForControl(
    Map<String, dynamic> control,
    String componentType,
  ) {
    final direct = control['icon']?.toString().trim();
    if (direct != null && direct.isNotEmpty) return direct;

    final stylesIcon = control['styles']?['icon']?.toString().trim();
    if (stylesIcon != null && stylesIcon.isNotEmpty) return stylesIcon;

    final id = control['id']?.toString().toLowerCase() ?? '';
    final param = (control['parameter'] ?? control['label'] ?? control['default_name'])?.toString().toLowerCase() ?? '';

    if (id.contains('speed') || param.contains('speed')) return 'speed';
    if (id.contains('direction') || param.contains('direction')) return 'compass';
    if (id.contains('buzzer') || param.contains('buzzer')) return 'bell';
    if (id.contains('lamp') || param.contains('lamp') || id.contains('light') || param.contains('light')) return 'lightbulb';
    if (id.contains('power') || param.contains('power') || componentType.toLowerCase() == 'button') return 'power';
    if (id.contains('timer') || param.contains('timer')) return 'timer';
    if (id.contains('voltage') || param.contains('voltage') || id.contains('current') || param.contains('current') || id.contains('watt') || param.contains('watt')) return 'bolt';
    if (id.contains('fan') || param.contains('fan')) return 'fan';
    if (id.contains('wifi') || param.contains('wifi')) return 'wifi';
    if (id.contains('lock') || param.contains('lock')) return 'lock';
    if (componentType.toLowerCase() == 'switch' || componentType.toLowerCase() == 'slider') return 'sliders';

    return 'settings';
  }
}
