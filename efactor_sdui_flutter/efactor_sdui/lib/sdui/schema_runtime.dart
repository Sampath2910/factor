import 'package:flutter/widgets.dart';

import '../state/app_state.dart';

/// Runtime screen information exposed by Flutter for the current app view.
///
/// Logical dimensions are the values that should be used for responsive UI.
/// Physical dimensions are retained only for diagnostics/device information.
class DeviceScreenMetrics {
  const DeviceScreenMetrics({
    required this.logicalWidth,
    required this.logicalHeight,
    required this.physicalWidth,
    required this.physicalHeight,
    required this.devicePixelRatio,
    required this.orientation,
    required this.paddingTop,
    required this.paddingRight,
    required this.paddingBottom,
    required this.paddingLeft,
    required this.viewInsetTop,
    required this.viewInsetRight,
    required this.viewInsetBottom,
    required this.viewInsetLeft,
    required this.textScaleFactor,
  });

  factory DeviceScreenMetrics.fromContext(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final view = View.of(context);

    return DeviceScreenMetrics(
      logicalWidth: size.width,
      logicalHeight: size.height,
      physicalWidth: view.physicalSize.width,
      physicalHeight: view.physicalSize.height,
      devicePixelRatio: view.devicePixelRatio,
      orientation: size.width > size.height ? 'landscape' : 'portrait',
      paddingTop: padding.top,
      paddingRight: padding.right,
      paddingBottom: padding.bottom,
      paddingLeft: padding.left,
      viewInsetTop: viewInsets.top,
      viewInsetRight: viewInsets.right,
      viewInsetBottom: viewInsets.bottom,
      viewInsetLeft: viewInsets.left,
      textScaleFactor: MediaQuery.textScalerOf(context).scale(1.0),
    );
  }

  final double logicalWidth;
  final double logicalHeight;
  final double physicalWidth;
  final double physicalHeight;
  final double devicePixelRatio;
  final String orientation;
  final double paddingTop;
  final double paddingRight;
  final double paddingBottom;
  final double paddingLeft;
  final double viewInsetTop;
  final double viewInsetRight;
  final double viewInsetBottom;
  final double viewInsetLeft;
  final double textScaleFactor;

  double get safeWidth => (logicalWidth - paddingLeft - paddingRight)
      .clamp(0.0, double.infinity)
      .toDouble();

  double get safeHeight => (logicalHeight - paddingTop - paddingBottom)
      .clamp(0.0, double.infinity)
      .toDouble();

  Map<String, dynamic> toMap() => <String, dynamic>{
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'physicalWidth': physicalWidth,
    'physicalHeight': physicalHeight,
    'devicePixelRatio': devicePixelRatio,
    'orientation': orientation,
    'safeWidth': safeWidth,
    'safeHeight': safeHeight,
    'padding': <String, double>{
      'top': paddingTop,
      'right': paddingRight,
      'bottom': paddingBottom,
      'left': paddingLeft,
    },
    'viewInsets': <String, double>{
      'top': viewInsetTop,
      'right': viewInsetRight,
      'bottom': viewInsetBottom,
      'left': viewInsetLeft,
    },
    'textScaleFactor': textScaleFactor,
  };
}

/// The responsive layout selected from the schema for a particular width.
class SchemaResponsiveLayout {
  const SchemaResponsiveLayout({
    required this.name,
    required this.minimumWidth,
    required this.config,
  });

  final String name;
  final double minimumWidth;
  final Map<String, dynamic> config;

  double? get maxContentWidth {
    final value = config['maxContentWidth'] ?? config['maximumContentWidth'];
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '');
  }

  int? get columns {
    final value = config['columns'];
    return value is num ? value.toInt() : null;
  }

  String? get paramList => config['paramList']?.toString();

  String? get navigation => config['navigation']?.toString();
}

class _ResponsiveBreakpointCandidate {
  const _ResponsiveBreakpointCandidate({
    required this.name,
    required this.minimumWidth,
    required this.maximumWidth,
    required this.minimumHeight,
    required this.maximumHeight,
    this.orientation,
  });

  final String name;
  final double minimumWidth;
  final double maximumWidth;
  final double minimumHeight;
  final double maximumHeight;
  final String? orientation;
}

/// Helper runtime class for evaluating schema visibility, accessibility,
/// dynamic layout, and schema responsive rules.
class SchemaRuntime {
  SchemaRuntime(this.schema);

  final Map<String, dynamic> schema;

  /// Resolves `node.styleRef` against `extensions.universalUi.designSystem`.
  ///
  /// Studio emits both a short key (`parameterCard`) and a dotted path
  /// (`designSystem.componentStyles.parameterCard`). Either form must map to
  /// the same design-system map; the renderer must not invent a style.
  static Map<String, dynamic> resolveComponentStyle(
    Map<String, dynamic> schema,
    String? styleRef,
  ) {
    final ref = styleRef?.trim() ?? '';
    if (ref.isEmpty) return const <String, dynamic>{};

    final extensions = schema['extensions'];
    final universalUi = extensions is Map ? extensions['universalUi'] : null;
    final designSystem = universalUi is Map ? universalUi['designSystem'] : null;
    final componentStyles =
        designSystem is Map ? designSystem['componentStyles'] : null;

    Map<String, dynamic>? asStyleMap(dynamic value) {
      if (value is Map) {
        return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
      }
      return null;
    }

    Map<String, dynamic>? walk(dynamic root, List<String> parts) {
      dynamic current = root;
      for (final part in parts) {
        if (current is! Map) return null;
        dynamic matchingKey;
        for (final key in current.keys) {
          if (key.toString() == part) {
            matchingKey = key;
            break;
          }
        }
        if (matchingKey == null) return null;
        current = current[matchingKey];
      }
      return asStyleMap(current);
    }

    if (componentStyles is Map) {
      final direct = asStyleMap(componentStyles[ref]);
      if (direct != null) return direct;
    }

    final parts = ref
        .split('.')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return const <String, dynamic>{};

    final fromRoot = walk(schema, parts);
    if (fromRoot != null) return fromRoot;

    final fromUniversal = walk(universalUi, parts);
    if (fromUniversal != null) return fromUniversal;

    final fromDesignSystem = walk(designSystem, parts);
    if (fromDesignSystem != null) return fromDesignSystem;

    if (componentStyles is Map) {
      final fromTail = asStyleMap(componentStyles[parts.last]);
      if (fromTail != null) return fromTail;
    }

    return const <String, dynamic>{};
  }

  /// Caption painted on the grouped ParameterCard meta chip.
  ///
  /// The schema owns the count. Optional `textTemplate` / `unit` / `suffix`
  /// values come from `parameterCard.parts.metaChip`. When those are absent,
  /// the web chrome uses "{count} UI".
  static String parameterGroupChipLabel({
    required int count,
    Map<String, dynamic> metaChipStyle = const <String, dynamic>{},
  }) {
    final template =
        (metaChipStyle['textTemplate'] ??
                metaChipStyle['labelTemplate'] ??
                metaChipStyle['format'])
            ?.toString();
    if (template != null && template.contains('{count}')) {
      return template.replaceAll('{count}', '$count');
    }

    final unit =
        (metaChipStyle['unit'] ??
                metaChipStyle['suffix'] ??
                metaChipStyle['label'])
            ?.toString()
            .trim() ??
        '';
    if (unit.isNotEmpty) {
      final separator = metaChipStyle['separator']?.toString() ?? ' ';
      return '$count$separator$unit';
    }

    return '$count UI';
  }

  /// Control ids the published document wants rendered for a page.
  ///
  /// `schemaControlList.controlIds` can be a stale shorter copy. Navigation
  /// and `pages[]` also publish controlIds. Use the longest schema-owned list
  /// so controls such as TUNING are not dropped when one copy is incomplete.
  static List<String> publishedControlIds({
    required Map<String, dynamic> schema,
    List<dynamic>? nodeControlIds,
    String? pageNo,
    String? pageId,
  }) {
    List<String> asIds(dynamic raw) {
      if (raw is! List) return const <String>[];
      return raw
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
    }

    List<String> fromPages(dynamic pages) {
      if (pages is! List) return const <String>[];
      for (final raw in pages) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString();
        final no = raw['pageNo']?.toString();
        final matchesId = pageId != null && pageId.isNotEmpty && id == pageId;
        final matchesNo = pageNo != null && pageNo.isNotEmpty && no == pageNo;
        if (matchesId || matchesNo) return asIds(raw['controlIds']);
      }
      return const <String>[];
    }

    final candidates = <List<String>>[
      asIds(nodeControlIds),
      fromPages(schema['navigation']?['pages']),
      fromPages(schema['pages']),
      fromPages(
        schema['extensions']?['universalUi']?['dashboard']?['pages'],
      ),
    ];

    List<String> best = const <String>[];
    for (final candidate in candidates) {
      if (candidate.length > best.length) best = candidate;
    }
    return best;
  }

  bool isVisible(
    Map<String, dynamic> node,
    Map<String, dynamic> props,
    AppState state,
  ) {
    if (props['visibility'] == false) return false;
    final cond = props['visibleIf'] ?? props['visibilityCondition'];
    if (cond != null) {
      return evaluateCondition(cond, state, defaultValue: true);
    }
    return true;
  }

  bool isEnabled(
    Map<String, dynamic> node,
    Map<String, dynamic> props,
    AppState state,
  ) {
    if (props['enabled'] == false || props['disabled'] == true) return false;
    final cond = props['enabledIf'] ?? props['enableCondition'];
    if (cond != null) {
      return evaluateCondition(cond, state, defaultValue: true);
    }
    return true;
  }

  Map<String, dynamic>? _accessibilityEntry({
    String? controlId,
    String? binding,
  }) {
    final accessibility = schema['accessibility'];
    final labels = accessibility is Map ? accessibility['labels'] : null;
    if (labels is! List) return null;

    final normalizedId = controlId?.trim();
    final normalizedBinding = binding?.trim();
    for (final raw in labels.whereType<Map>()) {
      final id = raw['controlId']?.toString().trim();
      final itemBinding = raw['binding']?.toString().trim();
      if (normalizedId != null &&
          normalizedId.isNotEmpty &&
          id == normalizedId) {
        return Map<String, dynamic>.from(raw);
      }
      if (normalizedBinding != null &&
          normalizedBinding.isNotEmpty &&
          itemBinding == normalizedBinding) {
        return Map<String, dynamic>.from(raw);
      }
    }
    return null;
  }

  String? semanticLabel({
    String? controlId,
    String? binding,
    String? fallback,
  }) {
    final entry = _accessibilityEntry(controlId: controlId, binding: binding);
    final label = entry?['label']?.toString().trim();
    return label == null || label.isEmpty ? fallback : label;
  }

  String? semanticRole({String? controlId, String? binding}) {
    final entry = _accessibilityEntry(controlId: controlId, binding: binding);
    final role = entry?['role']?.toString().trim().toLowerCase();
    return role == null || role.isEmpty ? null : role;
  }

  double get minimumTouchTarget {
    final direct = schema['accessibility'];
    final universal = schema['extensions']?['universalUi']?['accessibility'];
    final serverDriven =
        schema['extensions']?['serverDrivenUi']?['accessibility'];
    final raw = direct is Map && direct['minTouchTarget'] is num
        ? direct['minTouchTarget']
        : universal is Map && universal['minTouchTarget'] is num
        ? universal['minTouchTarget']
        : serverDriven is Map && serverDriven['minTouchTarget'] is num
        ? serverDriven['minTouchTarget']
        : null;
    return raw is num
        ? raw.toDouble().clamp(0.0, double.infinity).toDouble()
        : 0.0;
  }

  bool evaluateCondition(
    dynamic condition,
    AppState state, {
    bool defaultValue = true,
  }) {
    if (condition is bool) return condition;
    if (condition is String) {
      final val = state.resolveBinding(condition);
      if (val is bool) return val;
      if (val != null) return val.toString().toLowerCase() == 'true';
    }
    return defaultValue;
  }

  /// Returns the responsive contract from the executable schema.
  ///
  /// The current backend emits it at the schema root. The Universal UI and
  /// serverDrivenUi locations remain supported for compatible schema versions.
  Map<String, dynamic>? get responsive {
    final direct = schema['responsive'];
    if (direct is Map) {
      return Map<String, dynamic>.from(direct);
    }

    final universal = schema['extensions']?['universalUi']?['responsive'];
    if (universal is Map) {
      return Map<String, dynamic>.from(universal);
    }

    final serverDriven = schema['extensions']?['serverDrivenUi']?['responsive'];
    if (serverDriven is Map) {
      return Map<String, dynamic>.from(serverDriven);
    }

    return null;
  }

  /// Resolves the current breakpoint exclusively from the schema contract.
  ///
  /// Supported backend formats:
  ///
  /// 1. Minimum-width form (legacy/current Device renderer compatible):
  ///    `"compact": 0, "medium": 600, "expanded": 840`
  ///
  /// 2. Range form (current Home schema compatible):
  ///    `"compact": {"minimumWidth": 360, "maximumWidth": 599}`
  ///
  /// Optional minimumHeight / maximumHeight / orientation constraints are
  /// also honored when the backend publishes them. Flutter never matches on
  /// a phone model name.
  String? resolveBreakpointName(
    double logicalWidth, {
    double? logicalHeight,
    String? orientation,
  }) {
    final rawBreakpoints = responsive?['breakpoints'];
    if (rawBreakpoints is! Map || rawBreakpoints.isEmpty) return null;

    final candidates = <_ResponsiveBreakpointCandidate>[];

    for (final entry in rawBreakpoints.entries) {
      final name = entry.key.toString().trim();
      if (name.isEmpty) continue;

      final raw = entry.value;
      if (raw is num) {
        candidates.add(
          _ResponsiveBreakpointCandidate(
            name: name,
            minimumWidth: raw.toDouble(),
            maximumWidth: double.infinity,
            minimumHeight: 0,
            maximumHeight: double.infinity,
          ),
        );
        continue;
      }

      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
      final minimumWidth =
          _number(map['minimumWidth'] ?? map['minWidth'] ?? map['from']) ?? 0;
      final maximumWidth =
          _number(map['maximumWidth'] ?? map['maxWidth'] ?? map['to']) ??
          double.infinity;
      final minimumHeight =
          _number(map['minimumHeight'] ?? map['minHeight']) ?? 0;
      final maximumHeight =
          _number(map['maximumHeight'] ?? map['maxHeight']) ?? double.infinity;
      final requiredOrientation = map['orientation']?.toString().trim();

      candidates.add(
        _ResponsiveBreakpointCandidate(
          name: name,
          minimumWidth: minimumWidth,
          maximumWidth: maximumWidth,
          minimumHeight: minimumHeight,
          maximumHeight: maximumHeight,
          orientation:
              requiredOrientation == null ||
                  requiredOrientation.isEmpty ||
                  requiredOrientation == 'any'
              ? null
              : requiredOrientation,
        ),
      );
    }

    if (candidates.isEmpty) return null;

    final resolvedOrientation = orientation?.trim().toLowerCase();
    final height = logicalHeight ?? double.infinity;

    final matches = candidates
        .where((candidate) {
          final orientationMatches =
              candidate.orientation == null ||
              candidate.orientation!.toLowerCase() == resolvedOrientation;
          return orientationMatches &&
              logicalWidth >= candidate.minimumWidth &&
              logicalWidth <= candidate.maximumWidth &&
              height >= candidate.minimumHeight &&
              height <= candidate.maximumHeight;
        })
        .toList(growable: false);

    if (matches.isNotEmpty) {
      // Prefer the most specific / highest lower bound when ranges overlap.
      final sorted = List<_ResponsiveBreakpointCandidate>.from(matches)
        ..sort((a, b) => b.minimumWidth.compareTo(a.minimumWidth));
      return sorted.first.name;
    }

    // Numeric/minimum-width contracts traditionally mean "use the highest
    // breakpoint whose minimumWidth is <= the viewport". Preserve that
    // behavior when no explicit range matched.
    final eligible =
        candidates
            .where((candidate) => logicalWidth >= candidate.minimumWidth)
            .toList(growable: false)
          ..sort((a, b) => b.minimumWidth.compareTo(a.minimumWidth));
    if (eligible.isNotEmpty) return eligible.first.name;

    // A phone narrower than every published minimumWidth still needs a
    // layout. Use the smallest declared breakpoint instead of failing.
    final smallest = List<_ResponsiveBreakpointCandidate>.from(candidates)
      ..sort((a, b) => a.minimumWidth.compareTo(b.minimumWidth));
    return smallest.first.name;
  }

  SchemaResponsiveLayout? resolveResponsiveLayout(
    double logicalWidth, {
    double? logicalHeight,
    String? orientation,
  }) {
    final responsiveConfig = responsive;
    if (responsiveConfig == null) {
      return const SchemaResponsiveLayout(
        name: 'compact',
        minimumWidth: 0,
        config: <String, dynamic>{
          'maxContentWidth': 430.0,
          'columns': 1,
          'navigation': 'pager',
        },
      );
    }

    final name = resolveBreakpointName(
      logicalWidth,
      logicalHeight: logicalHeight,
      orientation: orientation,
    );
    if (name == null) return null;

    final rawLayouts = responsiveConfig['layouts'];
    Map<String, dynamic> layout = const <String, dynamic>{};
    if (rawLayouts is Map && rawLayouts[name] is Map) {
      layout = Map<String, dynamic>.from(
        (rawLayouts[name] as Map).cast<dynamic, dynamic>(),
      );
    }

    final rawBreakpoints = responsiveConfig['breakpoints'];
    double minimumWidth = 0;
    if (rawBreakpoints is Map) {
      final raw = rawBreakpoints[name];
      if (raw is num) {
        minimumWidth = raw.toDouble();
      } else if (raw is Map) {
        minimumWidth =
            _number(raw['minimumWidth'] ?? raw['minWidth'] ?? raw['from']) ?? 0;
      }
    }

    return SchemaResponsiveLayout(
      name: name,
      minimumWidth: minimumWidth,
      config: layout,
    );
  }

  /// Deep-merges a component/page/layout's breakpoint override into the base
  /// object. Existing schemas that do not publish responsiveLayout are left
  /// byte-for-byte equivalent at runtime.
  ///
  /// Supported local keys:
  ///   responsiveLayout: { compact: {...}, medium: {...} }
  ///   responsiveOverrides: { compact: {...}, medium: {...} }
  ///
  /// A selected override may optionally contain portrait / landscape maps;
  /// those are merged last.
  Map<String, dynamic> resolveResponsiveMap(
    Map<String, dynamic> source,
    double logicalWidth, {
    double? logicalHeight,
    String? orientation,
  }) {
    final name = resolveBreakpointName(
      logicalWidth,
      logicalHeight: logicalHeight,
      orientation: orientation,
    );
    if (name == null) return Map<String, dynamic>.from(source);

    Map<String, dynamic> result = Map<String, dynamic>.from(source);

    for (final key in const <String>[
      'responsiveLayout',
      'responsiveOverrides',
    ]) {
      final rawOverrides = source[key];
      if (rawOverrides is! Map) continue;

      final common = rawOverrides['all'];
      if (common is Map) {
        final commonMap = Map<String, dynamic>.from(
          common.cast<dynamic, dynamic>(),
        );
        result = _deepMerge(result, commonMap);

        final orientationKey = orientation?.trim().toLowerCase();
        if (orientationKey != null && orientationKey.isNotEmpty) {
          final commonOrientation = commonMap[orientationKey];
          if (commonOrientation is Map) {
            result = _deepMerge(
              result,
              Map<String, dynamic>.from(
                commonOrientation.cast<dynamic, dynamic>(),
              ),
            );
          }
        }
      }

      final selected = rawOverrides[name];
      if (selected is! Map) continue;
      final selectedMap = Map<String, dynamic>.from(
        selected.cast<dynamic, dynamic>(),
      );
      result = _deepMerge(result, selectedMap);

      final orientationKey = orientation?.trim().toLowerCase();
      if (orientationKey != null && orientationKey.isNotEmpty) {
        final orientationOverride = selectedMap[orientationKey];
        if (orientationOverride is Map) {
          result = _deepMerge(
            result,
            Map<String, dynamic>.from(
              orientationOverride.cast<dynamic, dynamic>(),
            ),
          );
        }
      }
    }

    return result;
  }

  /// Resolves an arbitrary layout map using the same breakpoint contract.
  Map<String, dynamic> resolveLayoutMap(
    Map<String, dynamic> layout,
    double logicalWidth, {
    double? logicalHeight,
    String? orientation,
  }) => resolveResponsiveMap(
    layout,
    logicalWidth,
    logicalHeight: logicalHeight,
    orientation: orientation,
  );

  bool? get useSafeArea {
    final value = responsive?['safeArea'];
    return value is bool ? value : null;
  }

  String? get dimensionPolicy => responsive?['dimensionPolicy']?.toString();

  bool get usesLogicalDimensions =>
      dimensionPolicy?.trim().toLowerCase() == 'logical';

  /// Compatibility helpers now resolve from schema rather than fixed widths.
  int columns(double width) => resolveResponsiveLayout(width)?.columns ?? 1;

  String paramListMode(double width) =>
      resolveResponsiveLayout(width)?.paramList ?? 'list';

  Map<String, dynamic> layoutForWidth(double width) =>
      resolveResponsiveLayout(width)?.config ?? const <String, dynamic>{};

  static double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '');
  }

  static Map<String, dynamic> _deepMerge(
    Map<String, dynamic> base,
    Map<String, dynamic> override,
  ) {
    final result = Map<String, dynamic>.from(base);
    for (final entry in override.entries) {
      final current = result[entry.key];
      final incoming = entry.value;
      if (current is Map && incoming is Map) {
        result[entry.key] = _deepMerge(
          Map<String, dynamic>.from(current.cast<dynamic, dynamic>()),
          Map<String, dynamic>.from(incoming.cast<dynamic, dynamic>()),
        );
      } else {
        result[entry.key] = incoming;
      }
    }
    return result;
  }
}
