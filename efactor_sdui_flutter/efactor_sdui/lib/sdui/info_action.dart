import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../state/app_state.dart';
import '../services/device_info_cache_manager.dart';
import '../services/json_http.dart';
import 'schema_runtime.dart';
import 'icons.dart';
import 'style.dart';

/// Presents the Device Info screen entirely from the live Device schema.
///
/// Features:
/// - Local persistence: Device info data and schema are stored locally so that
///   subsequent opens load instantly with zero blocking spinner delay.
/// - Background silent revalidation: If new data is available on the server,
///   it updates the displayed values seamlessly in the background.
/// - Dynamic across all models: Works for any hardware model and node identity.
Future<void> handleOpenInfo(
  BuildContext context,
  AppState state,
  Map<String, dynamic> action,
) async {
  final schema = state.schema;
  final identity = state.resolveDeviceIdentity();
  final modelId = identity.modelId ?? '';
  final nodeId = identity.nodeId ?? '';

  final actionId = _firstText(<dynamic>[action['value'], action['id']]);
  final declaredAction = actionId == null
      ? null
      : state.lookupActionMap(actionId);
  final effectiveAction = <String, dynamic>{
    if (declaredAction != null) ...declaredAction,
    ...action,
  };
  var declaredInfoPage = _resolveInfoPage(schema, effectiveAction);

  // If live schema didn't contain infoPage directly (e.g. multi-page or offline),
  // retrieve the previously saved infoPage schema from local storage:
  if (declaredInfoPage == null && modelId.isNotEmpty) {
    declaredInfoPage = await DeviceInfoCacheManager.instance.getCachedInfoSchema(
      modelId: modelId,
      nodeId: nodeId,
    );
  }

  if (declaredInfoPage == null) {
    if (!context.mounted) return;
    await _showMessage(
      context,
      title: effectiveAction['label']?.toString() ?? 'Information',
      message:
          'The live Device schema does not contain the requested information page.',
    );
    return;
  }

  // Persist the resolved infoPage schema locally for instant retrieval:
  if (modelId.isNotEmpty) {
    unawaited(
      DeviceInfoCacheManager.instance.saveInfoSchema(
        modelId: modelId,
        nodeId: nodeId,
        schema: declaredInfoPage,
      ),
    );
  }

  final viewport = MediaQuery.sizeOf(context);
  final orientation = viewport.width > viewport.height
      ? 'landscape'
      : 'portrait';
  final responsiveRuntime = SchemaRuntime(schema);
  final infoPage = responsiveRuntime.resolveResponsiveMap(
    declaredInfoPage,
    viewport.width,
    logicalHeight: viewport.height,
    orientation: orientation,
  );

  final metaInfo = _asMap(_asMap(schema['meta'])?['infoPage']);
  final entryScreenId = _firstText(<dynamic>[
    effectiveAction['entryScreen'],
    infoPage['entryScreen'],
    metaInfo?['entryScreen'],
  ]);

  if (entryScreenId == null) {
    if (!context.mounted) return;
    await _showMessage(
      context,
      title: infoPage['title']?.toString() ?? 'Information',
      message: 'The information page does not declare an entry screen.',
    );
    return;
  }

  final screens = _asMap(infoPage['screens']);
  final declaredScreen = _asMap(screens?[entryScreenId]);
  if (declaredScreen == null) {
    if (!context.mounted) return;
    await _showMessage(
      context,
      title: infoPage['title']?.toString() ?? 'Information',
      message:
          'The information entry screen "$entryScreenId" is missing from the live schema.',
    );
    return;
  }

  final screen = responsiveRuntime.resolveResponsiveMap(
    declaredScreen,
    viewport.width,
    logicalHeight: viewport.height,
    orientation: orientation,
  );

  final dataSourceId = _firstText(<dynamic>[
    effectiveAction['load'],
    effectiveAction['dataSource'],
    infoPage['dataSource'],
    _asMap(_asMap(schema['meta'])?['infoPage'])?['dataSource'],
  ]);

  final source = dataSourceId == null
      ? null
      : _asMap(_asMap(schema['dataSources'])?[dataSourceId]);

  final rawDataSourceUrl = _firstText(<dynamic>[
    source?['url'],
    infoPage['dataUrl'],
    _asMap(source?['nativeApi'])?['url'],
  ]);
  final resolvedUrl = rawDataSourceUrl != null
      ? resolveInfoTemplateValue(state, rawDataSourceUrl)?.toString()
      : null;

  // 1. Check local persistent cache first!
  dynamic cachedPayload;
  if (modelId.isNotEmpty || (resolvedUrl != null && resolvedUrl.isNotEmpty)) {
    cachedPayload = await DeviceInfoCacheManager.instance.getCachedInfoData(
      modelId: modelId,
      nodeId: nodeId,
      url: resolvedUrl,
    );
  }

  var resolver = _InfoBindingResolver.fromPayloads(
    schema: schema,
    infoPage: infoPage,
    dataSource: source,
    fetchedPayload: cachedPayload,
  );

  final resolverNotifier = ValueNotifier<_InfoBindingResolver>(resolver);

  final loadPolicy = source?['load']?.toString().trim();
  final shouldLoadOnAction = loadPolicy == 'onAction';
  final hasUnresolvedBindings = _hasUnresolvedDeclaredBindings(
    screen,
    infoPage,
    resolver,
  );

  // If no cached payload exists (first time loading):
  // We fetch from the network, immediately save locally to disk & memory, and display.
  // If cached payload DOES exist:
  // We DO NOT BLOCK the user! The page displays instantly from local cache (0ms).
  // In the background, silent revalidation fetches any fresh updates and applies them seamlessly.
  if (cachedPayload == null && (shouldLoadOnAction || hasUnresolvedBindings)) {
    final fetchedPayload = await _tryLoadSchemaDeclaredInfoData(
      context: context,
      state: state,
      infoPage: infoPage,
      dataSource: source,
      resolvedUrl: resolvedUrl,
      showBlockingLoader: true,
    );

    if (fetchedPayload != null) {
      if (modelId.isNotEmpty || (resolvedUrl != null && resolvedUrl.isNotEmpty)) {
        await DeviceInfoCacheManager.instance.saveInfoData(
          modelId: modelId,
          nodeId: nodeId,
          url: resolvedUrl,
          data: fetchedPayload,
        );
      }
      resolver = _InfoBindingResolver.fromPayloads(
        schema: schema,
        infoPage: infoPage,
        dataSource: source,
        fetchedPayload: fetchedPayload,
      );
      resolverNotifier.value = resolver;
    }
  } else if (cachedPayload != null && (shouldLoadOnAction || hasUnresolvedBindings)) {
    // Silent background revalidation (stale-while-revalidate)
    unawaited(() async {
      try {
        final freshPayload = await _tryLoadSchemaDeclaredInfoData(
          context: null,
          state: state,
          infoPage: infoPage,
          dataSource: source,
          resolvedUrl: resolvedUrl,
          showBlockingLoader: false,
        );
        if (freshPayload != null) {
          if (modelId.isNotEmpty || (resolvedUrl != null && resolvedUrl.isNotEmpty)) {
            await DeviceInfoCacheManager.instance.saveInfoData(
              modelId: modelId,
              nodeId: nodeId,
              url: resolvedUrl,
              data: freshPayload,
            );
          }
          resolverNotifier.value = _InfoBindingResolver.fromPayloads(
            schema: schema,
            infoPage: infoPage,
            dataSource: source,
            fetchedPayload: freshPayload,
          );
        }
      } catch (err) {
        logDebug('[INFO_ACTION] Background revalidation error: $err');
      }
    }());
  }

  if (!context.mounted) {
    resolverNotifier.dispose();
    return;
  }

  final actionPresentation = effectiveAction['presentation']?.toString().trim();
  final presentation =
      _firstText(<dynamic>[
        actionPresentation == 'schema' ? null : actionPresentation,
        infoPage['presentation'],
      ]) ??
      'modal';

  bool removed = false;
  try {
    if (presentation == 'modal' || presentation == 'sheet') {
      removed =
          await _showInfoBottomSheet(
            context: context,
            state: state,
            schema: schema,
            infoPage: infoPage,
            screen: screen,
            resolver: resolver,
            resolverNotifier: resolverNotifier,
          ) ==
          true;
    } else {
      removed =
          await Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (routeContext) => Scaffold(
                body: SafeArea(
                  child: _SchemaInfoScreen(
                    state: state,
                    schema: schema,
                    infoPage: infoPage,
                    screen: screen,
                    resolver: resolver,
                    resolverNotifier: resolverNotifier,
                    onClose: () => Navigator.of(routeContext).maybePop(),
                  ),
                ),
              ),
            ),
          ) ==
          true;
    }
  } finally {
    resolverNotifier.dispose();
  }

  if (removed) {
    if (modelId.isNotEmpty) {
      await DeviceInfoCacheManager.instance.remove(
        modelId: modelId,
        nodeId: nodeId,
      );
    }
    await state.notifyDeviceRemoved();
  }
}

Future<bool?> _showInfoBottomSheet({
  required BuildContext context,
  required AppState state,
  required Map<String, dynamic> schema,
  required Map<String, dynamic> infoPage,
  required Map<String, dynamic> screen,
  required _InfoBindingResolver resolver,
  ValueNotifier<_InfoBindingResolver>? resolverNotifier,
}) {
  final viewport = MediaQuery.sizeOf(context);
  final runtime = SchemaRuntime(schema);
  final orientation = viewport.width > viewport.height
      ? 'landscape'
      : 'portrait';
  final theme = runtime.resolveResponsiveMap(
    _asMap(infoPage['theme']) ?? const <String, dynamic>{},
    viewport.width,
    logicalHeight: viewport.height,
    orientation: orientation,
  );
  final layout = runtime.resolveResponsiveMap(
    _asMap(infoPage['layout']) ?? const <String, dynamic>{},
    viewport.width,
    logicalHeight: viewport.height,
    orientation: orientation,
  );
  final sheetColor =
      SduiStyle.color(theme['backgroundColor']) ??
      Theme.of(context).canvasColor;
  final declaredMaxWidth = _asDouble(layout['maxWidth']);
  final initialChildSize = (_asDouble(layout['initialChildSize']) ?? 0.82)
      .clamp(0.05, 1.0)
      .toDouble();
  final minChildSize = (_asDouble(layout['minChildSize']) ?? 0.50)
      .clamp(0.05, 1.0)
      .toDouble();
  final maxChildSize = (_asDouble(layout['maxChildSize']) ?? 0.96)
      .clamp(0.05, 1.0)
      .toDouble();
  final effectiveMinChildSize = minChildSize <= maxChildSize
      ? minChildSize
      : maxChildSize;
  final effectiveMaxChildSize = maxChildSize >= effectiveMinChildSize
      ? maxChildSize
      : effectiveMinChildSize;
  final effectiveInitialChildSize = initialChildSize
      .clamp(effectiveMinChildSize, effectiveMaxChildSize)
      .toDouble();

  return showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: sheetColor,
    builder: (sheetContext) {
      final availableWidth = MediaQuery.sizeOf(sheetContext).width;
      final effectiveMaxWidth = declaredMaxWidth == null
          ? availableWidth
          : declaredMaxWidth.clamp(0.0, availableWidth).toDouble();
      return Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: effectiveInitialChildSize,
            minChildSize: effectiveMinChildSize,
            maxChildSize: effectiveMaxChildSize,
            builder: (_, controller) {
              return _SchemaInfoScreen(
                state: state,
                schema: schema,
                infoPage: infoPage,
                screen: screen,
                resolver: resolver,
                resolverNotifier: resolverNotifier,
                scrollController: controller,
                onClose: () => Navigator.of(sheetContext).pop(),
              );
            },
          ),
        ),
      );
    },
  );
}

class _SchemaInfoScreen extends StatefulWidget {
  const _SchemaInfoScreen({
    required this.state,
    required this.schema,
    required this.infoPage,
    required this.screen,
    required this.resolver,
    this.resolverNotifier,
    required this.onClose,
    this.scrollController,
  });

  final AppState state;
  final Map<String, dynamic> schema;
  final Map<String, dynamic> infoPage;
  final Map<String, dynamic> screen;
  final _InfoBindingResolver resolver;
  final ValueNotifier<_InfoBindingResolver>? resolverNotifier;
  final VoidCallback onClose;
  final ScrollController? scrollController;

  @override
  State<_SchemaInfoScreen> createState() => _SchemaInfoScreenState();
}

class _SchemaInfoScreenState extends State<_SchemaInfoScreen> {
  bool _actionBusy = false;
  late _InfoBindingResolver _resolver;

  @override
  void initState() {
    super.initState();
    _resolver = widget.resolver;
    widget.resolverNotifier?.addListener(_onResolverChanged);
  }

  @override
  void didUpdateWidget(_SchemaInfoScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolverNotifier != widget.resolverNotifier) {
      oldWidget.resolverNotifier?.removeListener(_onResolverChanged);
      widget.resolverNotifier?.addListener(_onResolverChanged);
    }
    if (widget.resolverNotifier == null &&
        oldWidget.resolver != widget.resolver) {
      _resolver = widget.resolver;
    }
  }

  @override
  void dispose() {
    widget.resolverNotifier?.removeListener(_onResolverChanged);
    super.dispose();
  }

  void _onResolverChanged() {
    if (mounted && widget.resolverNotifier != null) {
      setState(() {
        _resolver = widget.resolverNotifier!.value;
      });
    }
  }

  AppState get state => widget.state;
  Map<String, dynamic> get schema => widget.schema;
  Map<String, dynamic> get infoPage => widget.infoPage;
  Map<String, dynamic> get screen => widget.screen;
  _InfoBindingResolver get resolver => _resolver;
  VoidCallback get onClose => widget.onClose;
  ScrollController? get scrollController => widget.scrollController;

  Future<void> _runAction(
    BuildContext context,
    Map<String, dynamic> trigger,
  ) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final outcome = await _executeInfoAction(
        context: context,
        state: state,
        infoPage: infoPage,
        screen: screen,
        resolver: resolver,
        trigger: trigger,
      );

      if (outcome.removed && context.mounted) {
        Navigator.of(context).pop<bool>(true);
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final runtime = SchemaRuntime(schema);
    final orientation = viewport.width > viewport.height
        ? 'landscape'
        : 'portrait';
    final effectiveInfoPage = runtime.resolveResponsiveMap(
      infoPage,
      viewport.width,
      logicalHeight: viewport.height,
      orientation: orientation,
    );
    final effectiveScreen = runtime.resolveResponsiveMap(
      screen,
      viewport.width,
      logicalHeight: viewport.height,
      orientation: orientation,
    );
    final pageTheme = runtime.resolveResponsiveMap(
      _asMap(effectiveInfoPage['theme']) ?? const <String, dynamic>{},
      viewport.width,
      logicalHeight: viewport.height,
      orientation: orientation,
    );
    final layout = runtime.resolveResponsiveMap(
      _asMap(effectiveScreen['layout']) ??
          _asMap(effectiveInfoPage['layout']) ??
          const <String, dynamic>{},
      viewport.width,
      logicalHeight: viewport.height,
      orientation: orientation,
    );
    final rootTheme = _asMap(schema['theme']) ?? const <String, dynamic>{};
    final typography =
        _asMap(rootTheme['typography']) ?? const <String, dynamic>{};

    final backgroundColor =
        SduiStyle.color(pageTheme['backgroundColor']) ??
        Theme.of(context).scaffoldBackgroundColor;
    final surfaceColor =
        SduiStyle.color(pageTheme['surfaceColor']) ??
        Theme.of(context).cardColor;
    final textColor =
        SduiStyle.color(pageTheme['textColor']) ??
        Theme.of(context).colorScheme.onSurface;
    final mutedTextColor =
        SduiStyle.color(pageTheme['mutedTextColor']) ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    final borderColor =
        SduiStyle.color(pageTheme['borderColor']) ??
        Theme.of(context).dividerColor;
    final accentColor =
        SduiStyle.color(pageTheme['accentColor']) ??
        Theme.of(context).colorScheme.primary;
    final fontFamily = _firstText(<dynamic>[
      pageTheme['fontFamily'],
      typography['fontFamily'],
    ]);

    final title =
        _firstText(<dynamic>[
          effectiveScreen['title'],
          effectiveInfoPage['title'],
        ]) ??
        '';
    final sections = _prepareInfoSections(
      state,
      effectiveScreen,
      effectiveInfoPage,
    );

    return ColoredBox(
      color: backgroundColor,
      child: Column(
        children: <Widget>[
          Material(
            color: backgroundColor,
            child: SafeArea(
              bottom: false,
              child: Row(
                children: <Widget>[
                  IconButton(
                    onPressed: onClose,
                    icon: Icon(Icons.chevron_left, color: accentColor),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor,
                        fontFamily: fontFamily,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: borderColor),
          if (_actionBusy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: sections.isEmpty
                ? Center(
                    child: Text(
                      'The information screen has no schema sections.',
                      style: TextStyle(
                        color: mutedTextColor,
                        fontFamily: fontFamily,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: scrollController,
                    padding: EdgeInsets.all(
                      _asDouble(layout['contentPadding']) ?? 16,
                    ),
                    itemCount: sections.length,
                    itemBuilder: (context, index) {
                      final section = sections[index];
                      final rowsRaw = section['rows'];
                      final rows = rowsRaw is List
                          ? rowsRaw
                                .whereType<Map>()
                                .map(
                                  (value) => Map<String, dynamic>.from(value),
                                )
                                .toList(growable: false)
                          : const <Map<String, dynamic>>[];

                      if (rows.isEmpty) return const SizedBox.shrink();

                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == sections.length - 1
                              ? 0
                              : (_asDouble(layout['sectionGap']) ?? 12),
                        ),
                        child: Card(
                          margin: EdgeInsets.zero,
                          color: surfaceColor,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            side: BorderSide(color: borderColor),
                            borderRadius: BorderRadius.circular(
                              _asDouble(layout['sectionRadius']) ?? 16,
                            ),
                          ),
                          child: Column(
                            children: <Widget>[
                              for (
                                var rowIndex = 0;
                                rowIndex < rows.length;
                                rowIndex++
                              ) ...<Widget>[
                                _SchemaInfoRow(
                                  schema: schema,
                                  row: rows[rowIndex],
                                  infoPage: effectiveInfoPage,
                                  layout: layout,
                                  resolver: resolver,
                                  textColor: textColor,
                                  mutedTextColor: mutedTextColor,
                                  accentColor: accentColor,
                                  fontFamily: fontFamily,
                                  actionsEnabled: !_actionBusy,
                                  onAction: _runAction,
                                ),
                                if (rowIndex < rows.length - 1)
                                  Divider(
                                    height: 1,
                                    indent: 16,
                                    endIndent: 16,
                                    color: borderColor,
                                  ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SchemaInfoRow extends StatelessWidget {
  const _SchemaInfoRow({
    required this.schema,
    required this.row,
    required this.infoPage,
    required this.layout,
    required this.resolver,
    required this.textColor,
    required this.mutedTextColor,
    required this.accentColor,
    required this.actionsEnabled,
    required this.onAction,
    this.fontFamily,
  });

  final Map<String, dynamic> schema;
  final Map<String, dynamic> row;
  final Map<String, dynamic> infoPage;
  final Map<String, dynamic> layout;
  final _InfoBindingResolver resolver;
  final Color textColor;
  final Color mutedTextColor;
  final Color accentColor;
  final bool actionsEnabled;
  final Future<void> Function(
    BuildContext context,
    Map<String, dynamic> trigger,
  )
  onAction;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final id = row['id']?.toString().trim() ?? '';
    final rowType = row['type']?.toString().trim().toLowerCase() ?? '';
    final label = row['label']?.toString() ?? '';
    final subtitle = row['subtitle']?.toString();
    final fieldBindings = _asMap(infoPage['fieldBindings']);
    final fieldFallback = id.isEmpty
        ? null
        : _fieldBindingPath(fieldBindings?[id]);
    final rowValueBinding = _firstText(<dynamic>[
      row['valueBinding'],
      row['bind'],
    ]);

    if (rowType == 'button') {
      final iconName = row['icon']?.toString().trim();
      final actionStyle = row['style']?.toString().trim().toLowerCase();
      final isDanger = actionStyle == 'danger' || actionStyle == 'destructive';
      final buttonColor = isDanger
          ? Theme.of(context).colorScheme.error
          : accentColor;

      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: _asDouble(layout['actionHorizontalPadding']) ?? 12,
          vertical: _asDouble(layout['actionVerticalPadding']) ?? 10,
        ),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: actionsEnabled ? () => onAction(context, row) : null,
            icon: iconName == null || iconName.isEmpty
                ? const SizedBox.shrink()
                : SduiIcon(schema: schema, name: iconName, color: buttonColor),
            label: Text(
              label,
              style: TextStyle(
                color: buttonColor,
                fontFamily: fontFamily,
                fontWeight: FontWeight.w700,
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: buttonColor,
              side: BorderSide(color: buttonColor),
              minimumSize: Size(0, _asDouble(layout['actionMinHeight']) ?? 48),
            ),
          ),
        ),
      );
    }

    final value = _resolveFirstMeaningful(resolver, <dynamic>[
      rowValueBinding,
      fieldFallback,
    ]);
    final sideValue = _resolveFirstMeaningful(resolver, <dynamic>[
      row['sideValueBinding'],
      fieldFallback,
    ]);
    final copyValue = _resolveFirstMeaningful(resolver, <dynamic>[
      row['copyValueBinding'],
    ]);
    final href = _resolveFirstMeaningful(resolver, <dynamic>[
      row['hrefBinding'],
      fieldFallback,
    ]);

    final iconName = row['icon']?.toString().trim();
    final hasHref = _validLaunchUri(href) != null;
    final hasCopy = _isMeaningful(copyValue);
    final trailingAction = _asMap(row['trailingAction']);

    final trailingChildren = <Widget>[];
    if (_isMeaningful(sideValue)) {
      trailingChildren.add(
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: _asDouble(layout['trailingMaxWidth']) ?? 160,
          ),
          child: Text(
            _displayValue(sideValue),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: textColor,
              fontFamily: fontFamily,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    if (hasCopy) {
      trailingChildren.add(
        IconButton(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(text: _displayValue(copyValue)),
            );
          },
          icon: Icon(Icons.copy_outlined, color: accentColor),
        ),
      );
    }
    if (trailingAction != null) {
      final actionLabel = _firstText(<dynamic>[
        trailingAction['label'],
        trailingAction['text'],
      ]);
      final actionIcon = trailingAction['icon']?.toString().trim();
      trailingChildren.add(
        TextButton.icon(
          onPressed: actionsEnabled
              ? () => onAction(context, trailingAction)
              : null,
          icon: actionIcon == null || actionIcon.isEmpty
              ? const SizedBox.shrink()
              : SduiIcon(
                  schema: schema,
                  name: actionIcon,
                  color: Theme.of(context).colorScheme.error,
                ),
          label: Text(
            actionLabel ?? '',
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontFamily: fontFamily,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    Widget? trailing;
    if (trailingChildren.isNotEmpty) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: trailingChildren,
      );
    } else if (hasHref) {
      trailing = Icon(Icons.chevron_right, color: mutedTextColor);
    }

    final resolvedValue = _applyValueMap(
      value,
      _asMap(row['valueMap']) ?? _fieldBindingValueMap(fieldBindings?[id]),
    );
    final resolvedSubtitle = _isMeaningful(resolvedValue)
        ? _displayValue(resolvedValue)
        : subtitle?.trim();

    return ListTile(
      leading: iconName == null || iconName.isEmpty
          ? null
          : SduiIcon(schema: schema, name: iconName, color: accentColor),
      title: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontFamily: fontFamily,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: resolvedSubtitle == null || resolvedSubtitle.isEmpty
          ? null
          : Text(
              resolvedSubtitle,
              style: TextStyle(color: mutedTextColor, fontFamily: fontFamily),
            ),
      trailing: trailing,
      onTap: hasHref
          ? () async {
              final uri = _validLaunchUri(href);
              if (uri == null) return;
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          : null,
    );
  }
}

List<Map<String, dynamic>> _prepareInfoSections(
  AppState state,
  Map<String, dynamic> screen,
  Map<String, dynamic> infoPage,
) {
  final rawSections = screen['sections'];
  final sections = rawSections is List
      ? rawSections.whereType<Map>().map((rawSection) {
          final section = Map<String, dynamic>.from(rawSection);
          final rawRows = section['rows'];
          if (rawRows is List) {
            section['rows'] = rawRows
                .whereType<Map>()
                .map((rawRow) => Map<String, dynamic>.from(rawRow))
                .toList();
          }
          return section;
        }).toList()
      : <Map<String, dynamic>>[];

  // Accept footer actions declared either at infoPage.footerActions (legacy /
  // Device schema v4) or at screens.<entry>.footerActions (IoT schema v2.4+).
  // Both are schema-owned; Flutter only normalizes the shape for rendering.
  final footerActions = <Map<String, dynamic>>[];

  void collectFooter(dynamic rawFooter) {
    final values = rawFooter is Map
        ? rawFooter.values
        : rawFooter is List
        ? rawFooter
        : const <dynamic>[];
    for (final rawAction in values) {
      final action = _asMap(rawAction);
      if (action != null) footerActions.add(Map<String, dynamic>.from(action));
    }
  }

  collectFooter(infoPage['footerActions']);
  collectFooter(screen['footerActions']);

  Map<String, dynamic>? footerForAction(String actionId) {
    for (final action in footerActions) {
      final id = _firstText(<dynamic>[
        action['action'],
        action['actionId'],
        action['value'],
      ]);
      if (id == actionId) return action;
    }
    return null;
  }

  Map<String, dynamic> normalizeTrigger(dynamic rawTrigger) {
    final direct = _asMap(rawTrigger);
    if (direct != null) return Map<String, dynamic>.from(direct);

    final actionId = rawTrigger?.toString().trim() ?? '';
    if (actionId.isEmpty) return <String, dynamic>{};

    final matchingFooter = footerForAction(actionId);
    final resolved = _resolveInfoActionDefinition(
      state: state,
      infoPage: infoPage,
      trigger: <String, dynamic>{'action': actionId},
    ).action;

    final resolvedLabel = resolved == null
        ? null
        : _firstText(<dynamic>[resolved['label'], resolved['title']]);

    return <String, dynamic>{
      'action': actionId,
      if (matchingFooter != null) ...matchingFooter,
      if (matchingFooter == null && resolvedLabel != null)
        'label': resolvedLabel,
      if (resolved != null && resolved['confirmBeforeExecute'] == true)
        'confirm': true,
    };
  }

  // v2.4 can publish a compact trailingAction as an action id string. Older
  // Device schemas publish the full action object. Normalize both without
  // inventing an endpoint, node id, token, label, or icon.
  for (final section in sections) {
    final rows = section['rows'];
    if (rows is! List) continue;
    for (final rawRow in rows) {
      if (rawRow is! Map) continue;
      final row = rawRow.cast<String, dynamic>();
      final trailing = row['trailingAction'];
      if (trailing != null && trailing is! Map) {
        final normalized = normalizeTrigger(trailing);
        if (normalized.isNotEmpty) row['trailingAction'] = normalized;
      }
    }
  }

  final inlineActions = _asMap(infoPage['inlineActions']);
  if (inlineActions != null) {
    for (final rawAction in inlineActions.values) {
      final action = _asMap(rawAction);
      if (action == null) continue;
      final rowId = action['rowId']?.toString().trim();
      if (rowId == null || rowId.isEmpty) continue;

      for (final section in sections) {
        final rows = section['rows'];
        if (rows is! List) continue;
        for (final rawRow in rows) {
          if (rawRow is! Map) continue;
          final row = rawRow.cast<String, dynamic>();
          if (row['id']?.toString().trim() == rowId &&
              row['trailingAction'] == null) {
            row['trailingAction'] = Map<String, dynamic>.from(action);
          }
        }
      }
    }
  }

  final existingIds = <String>{};
  for (final section in sections) {
    final rows = section['rows'];
    if (rows is! List) continue;
    for (final rawRow in rows) {
      if (rawRow is! Map) continue;
      final id = rawRow['id']?.toString().trim();
      if (id != null && id.isNotEmpty) existingIds.add(id);
    }
  }

  final footerRows = <Map<String, dynamic>>[];
  for (final action in footerActions) {
    final id = action['id']?.toString().trim();
    if (id != null && id.isNotEmpty && existingIds.contains(id)) continue;
    footerRows.add(<String, dynamic>{...action, 'type': 'button'});
  }

  if (footerRows.isNotEmpty) {
    sections.add(<String, dynamic>{
      'id': '_schema_footer_actions',
      'type': 'group',
      'style': 'footerAction',
      'rows': footerRows,
    });
  }

  return sections;
}

class _InfoActionOutcome {
  const _InfoActionOutcome({
    required this.success,
    this.removed = false,
    this.message,
  });

  final bool success;
  final bool removed;
  final String? message;
}

Future<_InfoActionOutcome> _executeInfoAction({
  required BuildContext context,
  required AppState state,
  required Map<String, dynamic> infoPage,
  required Map<String, dynamic> screen,
  required _InfoBindingResolver resolver,
  required Map<String, dynamic> trigger,
}) async {
  final resolved = _resolveInfoActionDefinition(
    state: state,
    infoPage: infoPage,
    trigger: trigger,
  );
  final action = resolved.action;
  final actionId = resolved.actionId;

  if (action == null) {
    if (context.mounted) {
      _showSnackBar(
        context,
        'The live schema does not define this information action.',
        error: true,
      );
    }
    return const _InfoActionOutcome(success: false);
  }

  // Resolve the platform-specific transport before executing the action.
  // Web keeps the datasource/action root contract. Android/iOS merge the
  // server-declared nativeApi transport (url/method/query/headers/body/auth)
  // while inheriting response/confirmation/orchestration metadata.
  final transportAction = _effectiveInfoActionTransport(action);

  final type = action['type']?.toString().trim();
  if (type == 'dismiss' || type == 'navigateBack') {
    if (context.mounted) Navigator.of(context).maybePop();
    return const _InfoActionOutcome(success: true);
  }

  final requiresRequest =
      type == 'api' ||
      type == 'removeDevice' ||
      transportAction['url'] != null ||
      transportAction['proxyUrl'] != null ||
      transportAction['apiUrl'] != null ||
      transportAction['fallbackUrl'] != null;

  if (!requiresRequest) {
    await state.dispatchAction(action, context: context);
    return const _InfoActionOutcome(success: true);
  }

  final confirmed = await _confirmInfoAction(
    context: context,
    action: action,
    trigger: trigger,
    infoPage: infoPage,
    screen: screen,
    resolver: resolver,
  );
  if (!confirmed) {
    return const _InfoActionOutcome(success: false);
  }

  final uri = _resolveInfoActionUri(state, transportAction);
  if (uri == null) {
    if (context.mounted) {
      _showSnackBar(
        context,
        'The live schema does not contain a mobile-reachable URL for this action.',
        error: true,
      );
    }
    return const _InfoActionOutcome(success: false);
  }

  final resolvedQuery = _resolveInfoActionMap(
    state,
    _asMap(transportAction['query']) ?? const <String, dynamic>{},
  );
  final auth = _asMap(transportAction['auth']) ?? const <String, dynamic>{};
  final token = state.accessToken.trim();

  final tokenParam = _firstText(<dynamic>[
    auth['accessTokenParam'],
    auth['queryParam'],
    auth['param'],
  ]);
  if (tokenParam != null &&
      token.isNotEmpty &&
      !resolvedQuery.containsKey(tokenParam)) {
    resolvedQuery[tokenParam] = token;
  }

  final queryParameters = <String, String>{...uri.queryParameters};
  for (final entry in resolvedQuery.entries) {
    if (entry.value == null) continue;
    queryParameters[entry.key] = entry.value.toString();
  }
  final requestUri = uri.replace(
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  );

  final headers = <String, String>{'Accept': 'application/json'};
  final rawHeaders = _resolveInfoActionMap(
    state,
    _asMap(transportAction['headers']) ?? const <String, dynamic>{},
  );
  for (final entry in rawHeaders.entries) {
    if (entry.value == null) continue;
    headers[entry.key] = _normalizeInfoAuthorizationHeader(
      state,
      entry.key,
      entry.value.toString(),
    );
  }

  final tokenHeader = _firstText(<dynamic>[auth['header'], auth['headerName']]);
  if ((tokenParam != null || tokenHeader != null) && token.isEmpty) {
    if (context.mounted) {
      _showSnackBar(
        context,
        'This action requires an authenticated session.',
        error: true,
      );
    }
    return const _InfoActionOutcome(success: false);
  }
  if (tokenHeader != null && token.isNotEmpty) {
    headers[tokenHeader] = _normalizeInfoAuthorizationHeader(
      state,
      tokenHeader,
      token,
    );
  }

  final rawBody = transportAction.containsKey('body')
      ? transportAction['body']
      : transportAction.containsKey('payload')
      ? transportAction['payload']
      : null;
  final body = rawBody == null ? null : _resolveInfoActionValue(state, rawBody);

  final requestValidationError = _validateInfoActionRequest(
    action: transportAction,
    query: resolvedQuery,
    body: body,
  );
  if (requestValidationError != null) {
    if (context.mounted) {
      _showSnackBar(context, requestValidationError, error: true);
    }
    return const _InfoActionOutcome(success: false);
  }

  if (body != null) headers['Content-Type'] = 'application/json';

  final method =
      _firstText(<dynamic>[transportAction['method']])?.toUpperCase() ?? 'POST';
  final timeoutMs = (transportAction['timeoutMs'] as num?)?.toInt() ?? 30000;

  http.Client? client;
  try {
    client = http.Client();
    final request = http.Request(method, requestUri);
    request.headers.addAll(headers);
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final streamed = await client
        .send(request)
        .timeout(Duration(milliseconds: timeoutMs > 0 ? timeoutMs : 30000));
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode == 401 || response.statusCode == 403) {
      final authFailure = state.onAuthenticationFailure;
      if (authFailure != null) await authFailure();
      if (context.mounted) {
        _showSnackBar(context, 'Authentication failed.', error: true);
      }
      return const _InfoActionOutcome(success: false);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final backendMessage = _extractHttpErrorMessage(response);
      final message = backendMessage == null
          ? 'Request failed with HTTP ${response.statusCode}.'
          : 'Request failed with HTTP ${response.statusCode}: $backendMessage';
      if (context.mounted) {
        _showSnackBar(context, message, error: true);
      }
      return _InfoActionOutcome(success: false, message: message);
    }

    dynamic decoded;
    final raw = utf8.decode(response.bodyBytes).trim();
    if (raw.isNotEmpty) {
      try {
        decoded = decodeJsonBody(
          body: raw,
          contentType: response.headers['content-type'],
          source: 'device-info',
        );
      } on FormatException {
        if (looksLikeHtml(raw)) {
          throw FormatException(
            'API returned HTML instead of JSON for device info.',
          );
        }
        decoded = raw;
      }
    }

    final decodedMap = _asMap(decoded);
    final responseContract = _asMap(transportAction['response']);
    final successField = _firstText(<dynamic>[
      responseContract?['successField'],
      'success',
    ]);
    final statusField = _firstText(<dynamic>[
      responseContract?['statusField'],
      'status',
    ]);
    final messageField = _firstText(<dynamic>[
      responseContract?['messageField'],
      'message',
    ]);
    final errorField = _firstText(<dynamic>[
      responseContract?['errorField'],
      'error',
    ]);

    final successValue = decodedMap == null
        ? null
        : _readPath(decodedMap, successField ?? 'success');
    final statusValue = decodedMap == null
        ? null
        : _readPath(decodedMap, statusField ?? 'status');
    final statusText = statusValue?.toString().trim().toLowerCase();
    final explicitFailure =
        decodedMap != null &&
        (successValue == false ||
            decodedMap['ok'] == false ||
            <String>{
              'error',
              'failed',
              'failure',
              'invalid',
              'denied',
            }.contains(statusText));

    final responseSchema = _asMap(transportAction['responseSchema']);
    final responseProperties = _asMap(responseSchema?['properties']);
    final requiresSuccessBoolean = responseProperties?['success'] is Map;
    final explicitSuccess =
        successValue == true ||
        decodedMap?['ok'] == true ||
        <String>{
          'ok',
          'success',
          'successful',
          'succeeded',
        }.contains(statusText);

    if (explicitFailure || (requiresSuccessBoolean && !explicitSuccess)) {
      final declaredMessage = decodedMap == null || messageField == null
          ? null
          : _readPath(decodedMap, messageField);
      final declaredError = decodedMap == null || errorField == null
          ? null
          : _readPath(decodedMap, errorField);
      final message =
          _firstText(<dynamic>[
            declaredMessage,
            decodedMap?['description'],
            declaredError,
            decodedMap?['message'],
            decodedMap?['error'],
          ]) ??
          'The server did not confirm that the action succeeded.';
      final safeMessage = _redactInfoError(message);
      if (context.mounted) {
        _showSnackBar(context, safeMessage, error: true);
      }
      return _InfoActionOutcome(success: false, message: safeMessage);
    }

    final rawMessage = _firstText(<dynamic>[
      decodedMap == null || messageField == null
          ? null
          : _readPath(decodedMap, messageField),
      decodedMap?['message'],
      decodedMap?['description'],
    ]);
    final message = rawMessage == null ? null : _redactInfoError(rawMessage);
    if (context.mounted && message != null) {
      _showSnackBar(context, message);
    }

    final removed = _isSchemaRemovalAction(
      state: state,
      infoPage: infoPage,
      actionId: actionId,
      action: action,
    );
    return _InfoActionOutcome(
      success: true,
      removed: removed,
      message: message,
    );
  } catch (error) {
    if (context.mounted) {
      _showSnackBar(
        context,
        'Request could not be completed: ${_redactInfoError(error.toString())}',
        error: true,
      );
    }
    return const _InfoActionOutcome(success: false);
  } finally {
    client?.close();
  }
}

({Map<String, dynamic>? action, String? actionId})
_resolveInfoActionDefinition({
  required AppState state,
  required Map<String, dynamic> infoPage,
  required Map<String, dynamic> trigger,
}) {
  final directAction = _asMap(trigger['action']);
  final actionId = directAction == null
      ? _firstText(<dynamic>[
          trigger['action'],
          trigger['actionId'],
          trigger['value'],
        ])
      : _firstText(<dynamic>[directAction['id'], directAction['value']]);

  if (directAction != null) {
    return (action: directAction, actionId: actionId);
  }

  final apiContracts = _asMap(state.schema['apiContracts']);
  final dataSources = _asMap(state.schema['dataSources']);
  final infoActions = _asMap(infoPage['actions']);
  final merged = <String, dynamic>{};

  if (actionId != null) {
    final contract = _unwrapActionDefinition(apiContracts?[actionId]);
    if (contract != null) merged.addAll(contract);

    // IoT schema v2.4 publishes removeDevice as a datasource instead of an
    // action/apiContract. Treat that server-declared datasource as an action
    // transport contract while preserving higher-precedence action overrides.
    final dataSource = _unwrapActionDefinition(dataSources?[actionId]);
    if (dataSource != null) merged.addAll(dataSource);

    final rootAction = state.lookupActionMap(actionId);
    if (rootAction != null) merged.addAll(rootAction);

    final infoAction = _unwrapActionDefinition(infoActions?[actionId]);
    if (infoAction != null) merged.addAll(infoAction);
  }

  for (final key in const <String>[
    'method',
    'url',
    'proxyUrl',
    'apiUrl',
    'fallbackUrl',
    'query',
    'auth',
    'headers',
    'body',
    'payload',
    'timeoutMs',
    'requestSchema',
    'response',
    'responseSchema',
    'confirm',
    'confirmBeforeExecute',
    'refresh',
    'refreshAfter',
    'nativeApi',
  ]) {
    if (trigger.containsKey(key)) merged[key] = trigger[key];
  }

  if (merged.isEmpty) {
    final triggerType = trigger['type']?.toString().trim();
    if (triggerType != null &&
        triggerType.isNotEmpty &&
        triggerType != 'button' &&
        triggerType != 'detailRow') {
      merged.addAll(trigger);
    }
  }

  if (merged.isEmpty) return (action: null, actionId: actionId);
  if (merged['type'] == null && actionId != null) {
    merged['type'] = actionId;
  }
  return (action: merged, actionId: actionId);
}

Map<String, dynamic>? _unwrapActionDefinition(dynamic raw) {
  final map = _asMap(raw);
  if (map == null) return null;
  final nested = _asMap(map['action']);
  if (nested == null) return map;
  return <String, dynamic>{...map, ...nested}..remove('action');
}

Future<bool> _confirmInfoAction({
  required BuildContext context,
  required Map<String, dynamic> action,
  required Map<String, dynamic> trigger,
  required Map<String, dynamic> infoPage,
  required Map<String, dynamic> screen,
  required _InfoBindingResolver resolver,
}) async {
  dynamic rawConfirm = trigger['confirm'];
  rawConfirm ??= action['confirm'];
  if (rawConfirm == null && action['confirmBeforeExecute'] == true) {
    rawConfirm = true;
  }
  if (rawConfirm == null || rawConfirm == false) return true;

  final confirm = _asMap(rawConfirm) ?? const <String, dynamic>{};
  final title =
      _firstText(<dynamic>[
        confirm['title'],
        trigger['label'],
        trigger['text'],
      ]) ??
      'Confirm';
  final message = _firstText(<dynamic>[confirm['message']]) ?? 'Continue?';
  final details = _confirmationDetails(
    confirm: confirm,
    infoPage: infoPage,
    screen: screen,
    resolver: resolver,
  );

  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(message),
          if (details.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            for (final detail in details)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(detail),
              ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            _firstText(<dynamic>[confirm['confirmLabel'], trigger['label']]) ??
                'Confirm',
          ),
        ),
      ],
    ),
  );
  return result == true;
}

List<String> _confirmationDetails({
  required Map<String, dynamic> confirm,
  required Map<String, dynamic> infoPage,
  required Map<String, dynamic> screen,
  required _InfoBindingResolver resolver,
}) {
  final fields = confirm['fields'];
  if (fields is! List) return const <String>[];
  final fieldBindings = _asMap(infoPage['fieldBindings']);
  final rowsById = <String, Map<String, dynamic>>{};
  final sections = screen['sections'];
  if (sections is List) {
    for (final rawSection in sections) {
      final section = _asMap(rawSection);
      final rows = section?['rows'];
      if (rows is! List) continue;
      for (final rawRow in rows) {
        final row = _asMap(rawRow);
        final id = row?['id']?.toString().trim();
        if (row != null && id != null && id.isNotEmpty) rowsById[id] = row;
      }
    }
  }

  final result = <String>[];
  for (final rawField in fields) {
    final id = rawField.toString().trim();
    if (id.isEmpty) continue;
    final row = rowsById[id];
    final binding = _firstText(<dynamic>[
      row?['valueBinding'],
      row?['bind'],
      row?['sideValueBinding'],
      _fieldBindingPath(fieldBindings?[id]),
    ]);
    final value = resolver.resolve(binding);
    if (!_isMeaningful(value)) continue;
    final label = _firstText(<dynamic>[row?['label'], id]) ?? id;
    result.add('$label: ${_displayValue(value)}');
  }
  return result;
}

String _normalizeInfoAuthorizationHeader(
  AppState state,
  String name,
  String value,
) {
  final headerName = name.trim();
  final headerValue = value.trim();
  if (headerName.toLowerCase() != 'authorization' || headerValue.isEmpty) {
    return headerValue;
  }

  // Preserve an explicit schema-provided scheme. For the mobile Device/IoT
  // path, add Bearer only when the schema resolves Authorization directly to
  // the current runtime access token. No device or token value is hardcoded.
  final firstWhitespace = headerValue.indexOf(RegExp(r'\s'));
  if (firstWhitespace > 0 &&
      headerValue.substring(firstWhitespace).trim().isNotEmpty) {
    return headerValue;
  }

  final runtimeToken = state.accessToken.trim();
  if (runtimeToken.isNotEmpty && headerValue == runtimeToken) {
    return 'Bearer $headerValue';
  }

  return headerValue;
}

String? _validateInfoActionRequest({
  required Map<String, dynamic> action,
  required Map<String, dynamic> query,
  required dynamic body,
}) {
  final requestSchema = _asMap(action['requestSchema']);
  final requiredFields = requestSchema?['required'];
  if (requiredFields is! List) return null;

  final bodyMap = _asMap(body);
  for (final rawName in requiredFields) {
    final name = rawName.toString().trim();
    if (name.isEmpty) continue;
    final value = query.containsKey(name) ? query[name] : bodyMap?[name];
    if (value == null || (value is String && value.trim().isEmpty)) {
      return 'The live schema requires "$name" for this action, but its runtime value is unavailable.';
    }
  }
  return null;
}

Map<String, dynamic> _effectiveInfoActionTransport(
  Map<String, dynamic> action,
) {
  if (kIsWeb) return action;

  final nativeApi = _asMap(action['nativeApi']);
  final nativeUrl = nativeApi?['url']?.toString().trim() ?? '';
  if (nativeApi == null || nativeUrl.isEmpty) return action;

  final effective = Map<String, dynamic>.from(action);
  const transportKeys = <String>{
    'url',
    'method',
    'query',
    'headers',
    'body',
    'payload',
    'auth',
    'timeoutMs',
    'requestSchema',
    'response',
    'responseSchema',
  };

  for (final key in transportKeys) {
    if (nativeApi.containsKey(key)) {
      effective[key] = nativeApi[key];
    }
  }

  // Do not keep a browser-session auth declaration when the backend publishes
  // a native transport without its own auth object. Native headers can carry
  // the secure-state token directly.
  if (!nativeApi.containsKey('auth')) {
    effective.remove('auth');
  }

  return effective;
}

Uri? _resolveInfoActionUri(AppState state, Map<String, dynamic> action) {
  final nativeApi = _asMap(action['nativeApi']);
  final candidates = kIsWeb
      ? <dynamic>[
          action['proxyUrl'],
          action['url'],
          action['apiUrl'],
          action['fallbackUrl'],
        ]
      : <dynamic>[
          nativeApi?['url'],
          action['apiUrl'],
          action['fallbackUrl'],
          action['url'],
          action['proxyUrl'],
        ];
  final connection = _asMap(state.schema['_clientConnection']);
  final base = Uri.tryParse(connection?['schemaUrl']?.toString() ?? '');
  Uri? loopbackFallback;

  for (final candidate in candidates) {
    final raw = candidate?.toString().trim();
    if (raw == null || raw.isEmpty) continue;
    final parsed = Uri.tryParse(raw);
    if (parsed == null) continue;

    if (parsed.hasScheme) {
      if (!_isLoopbackUri(parsed)) return parsed;
      loopbackFallback ??= parsed;
      continue;
    }

    if (base != null && base.hasScheme) {
      final resolved = base.resolve(raw);
      if (!_isLoopbackUri(resolved)) return resolved;
      loopbackFallback ??= resolved;
    }
  }

  return loopbackFallback;
}

Map<String, dynamic> _resolveInfoActionMap(
  AppState state,
  Map<String, dynamic> source,
) {
  return source.map(
    (key, value) => MapEntry(key, _resolveInfoActionValue(state, value)),
  );
}

dynamic _resolveInfoActionValue(AppState state, dynamic value) {
  return resolveInfoTemplateValue(state, value);
}


bool _isSchemaRemovalAction({
  required AppState state,
  required Map<String, dynamic> infoPage,
  required String? actionId,
  required Map<String, dynamic> action,
}) {
  final metaInfo = _asMap(_asMap(state.schema['meta'])?['infoPage']);
  final controlBindings = _asMap(infoPage['controlBindings']);
  final declaredRemoval = _firstText(<dynamic>[
    metaInfo?['removeDeviceAction'],
    infoPage['removeDeviceAction'],
    controlBindings?['removeDeviceAction'],
  ]);
  final type = action['type']?.toString().trim();
  final value = action['value']?.toString().trim();

  return (declaredRemoval != null && actionId == declaredRemoval) ||
      type == 'removeDevice' ||
      value == 'removeDevice';
}

void _showSnackBar(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted || message.trim().isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: error ? 5 : 3),
    ),
  );
}

String? _extractHttpErrorMessage(http.Response response) {
  final raw = utf8.decode(response.bodyBytes).trim();
  if (raw.isEmpty || raw.startsWith('<')) return null;

  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }

  final map = _asMap(decoded);
  if (map == null) return null;

  final errorMap = _asMap(map['error']);
  final message = _firstText(<dynamic>[
    map['message'],
    map['description'],
    map['Description'],
    errorMap?['message'],
    errorMap?['description'],
    map['error'] is String ? map['error'] : null,
  ]);
  if (message == null) return null;

  return _redactInfoError(message);
}

String _redactInfoError(String text) {
  return text.replaceAllMapped(
    RegExp(r'([?&][^=&\s]*token[^=]*=)[^&\s]+', caseSensitive: false),
    (match) => '${match.group(1)}<redacted>',
  );
}

Map<String, dynamic>? _resolveInfoPage(
  Map<String, dynamic> schema,
  Map<String, dynamic> action,
) {
  final metaInfo = _asMap(_asMap(schema['meta'])?['infoPage']);
  final schemaPath = _firstText(<dynamic>[
    action['schemaPath'],
    metaInfo?['entry'],
  ]);

  final candidates = <dynamic>[
    if (schemaPath != null) _readPath(schema, schemaPath),
    action['infoPage'],
    schema['infoPage'],
    _readPath(schema, 'extensions.serverDrivenUi.infoPage'),
    _readPath(schema, 'extensions.universalUi.infoPage'),
  ];

  for (final candidate in candidates) {
    final map = _asMap(candidate);
    if (map != null) return map;
  }

  final pages = schema['pages'];
  if (pages is List) {
    for (final page in pages) {
      if (page is Map) {
        final map = _asMap(page['infoPage']);
        if (map != null) return map;
      }
    }
  }

  final dataMap = _asMap(schema['data']);
  if (dataMap != null) {
    final map = _asMap(dataMap['infoPage']);
    if (map != null) return map;
    final dataPages = dataMap['pages'];
    if (dataPages is List) {
      for (final page in dataPages) {
        if (page is Map) {
          final map = _asMap(page['infoPage']);
          if (map != null) return map;
        }
      }
    }
  }

  return null;
}

String? _fieldBindingPath(dynamic raw) {
  final map = _asMap(raw);
  if (map != null) {
    return _firstText(<dynamic>[
      map['bind'],
      map['valueBinding'],
      map['path'],
      map['binding'],
    ]);
  }
  return _firstText(<dynamic>[raw]);
}

Map<String, dynamic>? _fieldBindingValueMap(dynamic raw) {
  return _asMap(_asMap(raw)?['valueMap']);
}

dynamic _applyValueMap(dynamic value, Map<String, dynamic>? valueMap) {
  if (valueMap == null || value == null) return value;
  final candidates = <String>[
    value.toString(),
    if (value is bool) value ? 'true' : 'false',
  ];
  for (final key in candidates) {
    if (valueMap.containsKey(key)) return valueMap[key];
  }
  return value;
}

bool _hasUnresolvedDeclaredBindings(
  Map<String, dynamic> screen,
  Map<String, dynamic> infoPage,
  _InfoBindingResolver resolver,
) {
  final sections = screen['sections'];
  if (sections is! List) return false;

  final fieldBindings = _asMap(infoPage['fieldBindings']);

  for (final rawSection in sections) {
    final section = _asMap(rawSection);
    final rows = section?['rows'];
    if (rows is! List) continue;

    for (final rawRow in rows) {
      final row = _asMap(rawRow);
      if (row == null) continue;
      final id = row['id']?.toString().trim() ?? '';
      final fallback = id.isEmpty
          ? null
          : _fieldBindingPath(fieldBindings?[id]);

      for (final binding in <dynamic>[
        row['valueBinding'],
        row['bind'],
        row['sideValueBinding'],
        row['copyValueBinding'],
        row['hrefBinding'],
        fallback,
      ]) {
        final raw = _fieldBindingPath(binding);
        if (raw == null || raw.isEmpty) continue;
        if (_isMeaningful(resolver.resolve(raw))) continue;
        return true;
      }
    }
  }

  return false;
}

Future<dynamic> _tryLoadSchemaDeclaredInfoData({
  BuildContext? context,
  required AppState state,
  required Map<String, dynamic> infoPage,
  required Map<String, dynamic>? dataSource,
  String? resolvedUrl,
  bool showBlockingLoader = false,
  http.Client? client,
}) async {
  final rawUrl = resolvedUrl ??
      _firstText(<dynamic>[
        dataSource?['url'],
        infoPage['dataUrl'],
        _asMap(dataSource?['nativeApi'])?['url'],
      ]);
  if (rawUrl == null) return null;

  final finalUrl = resolveInfoTemplateValue(state, rawUrl)?.toString().trim();
  if (finalUrl == null || finalUrl.isEmpty) return null;

  final uri = Uri.tryParse(finalUrl);
  if (uri == null || !uri.hasScheme || _isLoopbackUri(uri)) {
    return null;
  }

  final method = _firstText(<dynamic>[
    dataSource?['method'],
    _asMap(dataSource?['nativeApi'])?['method'],
  ])?.toUpperCase() ?? 'GET';
  if (method != 'GET') {
    return null;
  }

  final headers = <String, String>{'Accept': 'application/json'};
  final rawHeaders = _asMap(dataSource?['headers']) ??
      _asMap(_asMap(dataSource?['nativeApi'])?['headers']);
  if (rawHeaders != null) {
    for (final entry in rawHeaders.entries) {
      final val = resolveInfoTemplateValue(state, entry.value)?.toString();
      if (val != null && val.isNotEmpty) {
        headers[entry.key] = val;
      }
    }
  }

  final token = state.accessToken.trim();
  final auth = _asMap(dataSource?['auth']) ??
      _asMap(_asMap(dataSource?['nativeApi'])?['auth']);
  final tokenHeader = _firstText(<dynamic>[
    auth?['header'],
    auth?['headerName'],
  ]);
  if (tokenHeader != null && token.isNotEmpty) {
    headers[tokenHeader] = _normalizeInfoAuthorizationHeader(
      state,
      tokenHeader,
      token,
    );
  } else if (token.isNotEmpty && !headers.containsKey('Authorization')) {
    headers['Authorization'] = 'Bearer $token';
  }

  final timeoutMs = (dataSource?['timeoutMs'] as num?)?.toInt() ??
      (_asMap(dataSource?['nativeApi'])?['timeoutMs'] as num?)?.toInt();
  final timeout = Duration(
    milliseconds: timeoutMs != null && timeoutMs > 0 ? timeoutMs : 15000,
  );

  var dialogShown = false;
  if (showBlockingLoader && context != null && context.mounted) {
    dialogShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
  }

  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient.get(uri, headers: headers).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final raw = utf8.decode(response.bodyBytes).trim();
    if (raw.isEmpty || looksLikeHtml(raw)) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  } catch (_) {
    return null;
  } finally {
    if (client == null) {
      httpClient.close();
    }
    if (dialogShown && context != null && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}

class _InfoBindingResolver {
  _InfoBindingResolver(this._roots);

  factory _InfoBindingResolver.fromPayloads({
    required Map<String, dynamic> schema,
    required Map<String, dynamic> infoPage,
    required Map<String, dynamic>? dataSource,
    dynamic fetchedPayload,
  }) {
    final roots = <dynamic>[];

    void add(dynamic value) {
      if (value == null) return;
      if (value is Map || value is List) roots.add(value);
    }

    final fetchedSchema = _findDeviceSchema(fetchedPayload);
    add(fetchedSchema);
    add(fetchedPayload);
    add(schema);

    final responsePath = _firstText(<dynamic>[
      dataSource?['responsePath'],
      infoPage['responsePath'],
    ]);

    if (responsePath != null) {
      final snapshot = List<dynamic>.from(roots);
      for (final root in snapshot) {
        final resolved = _readAlternativePath(root, responsePath);
        add(resolved);
      }
    }

    return _InfoBindingResolver(roots);
  }

  final List<dynamic> _roots;

  dynamic resolve(String? binding) {
    final raw = binding?.trim();
    if (raw == null || raw.isEmpty) return null;

    for (final option in raw.split('|')) {
      final path = option.trim();
      if (path.isEmpty) continue;
      for (final root in _roots) {
        final value = _readPath(root, path);
        if (_isMeaningful(value)) return value;
      }
    }
    return null;
  }
}

dynamic _resolveFirstMeaningful(
  _InfoBindingResolver resolver,
  List<dynamic> bindings,
) {
  for (final binding in bindings) {
    final raw = binding?.toString().trim();
    if (raw == null || raw.isEmpty) continue;
    final value = resolver.resolve(raw);
    if (_isMeaningful(value)) return value;
  }
  return null;
}

dynamic _readAlternativePath(dynamic root, String expression) {
  for (final option in expression.split('|')) {
    final value = _readPath(root, option.trim());
    if (value != null) return value;
  }
  return null;
}

dynamic _readPath(dynamic root, String path) {
  if (path.isEmpty) return root;
  dynamic current = root;
  final tokenPattern = RegExp(r'([^\.\[\]]+)|\[(\d+)\]');

  for (final match in tokenPattern.allMatches(path)) {
    final key = match.group(1);
    final indexText = match.group(2);

    if (key != null) {
      if (current is! Map || !current.containsKey(key)) return null;
      current = current[key];
      continue;
    }

    if (indexText != null) {
      final index = int.tryParse(indexText);
      if (index == null || current is! List || index >= current.length) {
        return null;
      }
      current = current[index];
    }
  }

  return current;
}

Map<String, dynamic>? _findDeviceSchema(dynamic value, [int depth = 0]) {
  if (value == null || depth > 5) return null;
  if (value is Map) {
    final map = Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
    final type = map['schemaType']?.toString();
    if (type == 'device-ui' || map.containsKey('infoPage')) {
      return map;
    }
    for (final child in map.values) {
      final found = _findDeviceSchema(child, depth + 1);
      if (found != null) return found;
    }
  } else if (value is List) {
    for (final child in value) {
      final found = _findDeviceSchema(child, depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString().trim() ?? '');
}

Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value.cast<dynamic, dynamic>());
  }
  return null;
}

String? _firstText(List<dynamic> values) {
  for (final value in values) {
    final text = value?.toString().trim();
    if (text != null && text.isNotEmpty && text.toLowerCase() != 'null') {
      return text;
    }
  }
  return null;
}

bool _isMeaningful(dynamic value) {
  if (value == null) return false;
  if (value is String) {
    final text = value.trim();
    return text.isNotEmpty && text.toLowerCase() != 'null';
  }
  return true;
}

String _displayValue(dynamic value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  return value.toString();
}

bool _isLoopbackUri(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

Uri? _validLaunchUri(dynamic value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme) return null;
  const allowedSchemes = <String>{'http', 'https', 'mailto', 'tel'};
  if (!allowedSchemes.contains(uri.scheme.toLowerCase())) return null;
  return uri;
}

Future<void> _showMessage(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
