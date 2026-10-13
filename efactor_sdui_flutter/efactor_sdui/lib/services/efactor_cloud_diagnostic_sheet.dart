import 'dart:async';
import 'package:flutter/material.dart';
import 'package:efactor_provisioning/efactor_provisioning.dart';
import 'efactor_cloud_service.dart';

/// Interactive diagnostic sheet for testing and verifying the Cloud WebSocket
/// and Local Discovery streams, replicating the controls from `efactor_aar_test`.
///
/// DEV panel only — colors come from [ThemeData.colorScheme], never invented
/// product brand hex values.
class EfactorCloudDiagnosticSheet extends StatefulWidget {
  const EfactorCloudDiagnosticSheet({
    super.key,
    this.initialApiKey,
    this.initialNodeId,
  });

  final String? initialApiKey;
  final String? initialNodeId;

  static Future<void> show(
    BuildContext context, {
    String? initialApiKey,
    String? initialNodeId,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => EfactorCloudDiagnosticSheet(
          initialApiKey: initialApiKey,
          initialNodeId: initialNodeId,
        ),
      ),
    );
  }

  @override
  State<EfactorCloudDiagnosticSheet> createState() =>
      _EfactorCloudDiagnosticSheetState();
}

class _EfactorCloudDiagnosticSheetState
    extends State<EfactorCloudDiagnosticSheet> {
  final EfactorCloudService _cloudService = EfactorCloudService.instance;
  final EfactorDiscovery _discovery = EfactorDiscovery.instance;
  final EfactorData _data = EfactorData.instance;

  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _nodeIdController = TextEditingController();
  final TextEditingController _pageController =
      TextEditingController(text: 'page1');
  final TextEditingController _paramController =
      TextEditingController(text: 'temp');
  final TextEditingController _valueController =
      TextEditingController(text: '23.5');
  final TextEditingController _dataController =
      TextEditingController(text: 'A1B2C3');
  final ScrollController _consoleScroll = ScrollController();

  final List<String> _logs = <String>[];
  StreamSubscription<EfCloudEvent>? _cloudEventsSub;
  StreamSubscription<String>? _rawMessagesSub;
  StreamSubscription<EfDiscoveryEvent>? _discoverySub;

  @override
  void initState() {
    super.initState();
    _apiKeyController.text = widget.initialApiKey ??
        _cloudService.activeAccessToken ??
        '';
    _nodeIdController.text = widget.initialNodeId ?? '';

    _cloudEventsSub = _cloudService.cloudEvents.listen((ev) {
      _addLog('[CloudEvent] ${ev.type.name}: ${ev.message ?? ""}');
    });

    _rawMessagesSub = _cloudService.rawMessages.listen((msg) {
      _addLog('[WebSocket RECV] $msg');
    });

    _discoverySub = _discovery.events.listen((ev) {
      _addLog('[Discovery] ${ev.found ? "FOUND" : "LOST"} nodeId=${ev.nodeId}');
    });

    _addLog('[Diagnostic] Initialized. Status: ${_cloudService.cloudStatusText.value}');
  }

  @override
  void dispose() {
    _cloudEventsSub?.cancel();
    _rawMessagesSub?.cancel();
    _discoverySub?.cancel();
    _apiKeyController.dispose();
    _nodeIdController.dispose();
    _pageController.dispose();
    _paramController.dispose();
    _valueController.dispose();
    _dataController.dispose();
    _consoleScroll.dispose();
    super.dispose();
  }

  void _addLog(String entry) {
    if (!mounted) return;
    setState(() {
      _logs.add('${DateTime.now().toIso8601String().substring(11, 19)} $entry');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_consoleScroll.hasClients) {
        _consoleScroll.jumpTo(_consoleScroll.position.maxScrollExtent);
      }
    });
  }

  String get _key => _apiKeyController.text.trim();
  String get _node => _nodeIdController.text.trim();

  Future<void> _doInitialize() async {
    _addLog('[Action] initialize(apiKey=${_key.isEmpty ? "EMPTY" : "***"})');
    await _cloudService.initialize(accessToken: _key);
  }

  Future<void> _doGetAllNodesStatus() async {
    _addLog('[Action] getAllNodesStatus()');
    await _cloudService.getAllNodesStatus(apiKey: _key);
  }

  Future<void> _doGetAllNodes() async {
    _addLog('[Action] getAllNodes(nodeId=$_node)');
    await _cloudService.getAllNodes(apiKey: _key, nodeId: _node.isNotEmpty ? _node : null);
  }

  Future<void> _doGetDevices() async {
    _addLog('[Action] getDevices(nodeId=$_node)');
    await _cloudService.getDevices(apiKey: _key, nodeId: _node.isNotEmpty ? _node : null);
  }

  Future<void> _doReconnect() async {
    _addLog('[Action] reconnect()');
    await _cloudService.reconnect();
  }

  Future<void> _doDisconnect() async {
    _addLog('[Action] disconnect()');
    await _cloudService.disconnect();
  }

  Future<void> _doSendData() async {
    _addLog('[Action] sendData(node=$_node, page=${_pageController.text}, param=${_paramController.text})');
    try {
      final res = await _data.sendData(
        apiKey: _key,
        nodeId: _node,
        deviceId: _node,
        pageName: _pageController.text.trim(),
        paramName: _paramController.text.trim(),
        value: double.tryParse(_valueController.text.trim()) ?? 0.0,
        data: _dataController.text.trim(),
        latitude: '17.38',
        longitude: '78.48',
      );
      _addLog('[sendData Result] ok=${res.ok}, raw=${res.raw}');
    } catch (e) {
      _addLog('[sendData Error] $e');
    }
  }

  ButtonStyle _actionStyle(ColorScheme scheme, {bool destructive = false}) {
    return ElevatedButton.styleFrom(
      backgroundColor: destructive ? scheme.error : scheme.primary,
      foregroundColor: destructive ? scheme.onError : scheme.onPrimary,
      visualDensity: VisualDensity.compact,
    );
  }

  ButtonStyle _secondaryActionStyle(ColorScheme scheme) {
    return ElevatedButton.styleFrom(
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      visualDensity: VisualDensity.compact,
    );
  }

  ButtonStyle _tertiaryActionStyle(ColorScheme scheme) {
    return ElevatedButton.styleFrom(
      backgroundColor: scheme.tertiaryContainer,
      foregroundColor: scheme.onTertiaryContainer,
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onSurface = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_sync, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'Cloud WebSocket Diagnostic',
                style: TextStyle(
                  color: onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              ValueListenableBuilder<String>(
                valueListenable: _cloudService.cloudStatusText,
                builder: (_, status, __) => Chip(
                  label: Text(status, style: const TextStyle(fontSize: 11)),
                  backgroundColor: status == 'connected'
                      ? scheme.primaryContainer
                      : scheme.tertiaryContainer,
                  labelStyle: TextStyle(
                    color: status == 'connected'
                        ? scheme.onPrimaryContainer
                        : scheme.onTertiaryContainer,
                    fontSize: 11,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: muted),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _apiKeyController,
                  style: TextStyle(color: onSurface, fontSize: 12),
                  decoration: InputDecoration(
                    labelText: 'Access Token / API Key',
                    labelStyle: TextStyle(color: muted, fontSize: 11),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _nodeIdController,
                  style: TextStyle(color: onSurface, fontSize: 12),
                  decoration: InputDecoration(
                    labelText: 'Node ID',
                    labelStyle: TextStyle(color: muted, fontSize: 11),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ElevatedButton(
                onPressed: _doInitialize,
                style: _actionStyle(scheme),
                child: const Text('initialize', style: TextStyle(fontSize: 12)),
              ),
              ElevatedButton(
                onPressed: _doGetAllNodesStatus,
                style: _secondaryActionStyle(scheme),
                child: const Text('getAllNodesStatus', style: TextStyle(fontSize: 12)),
              ),
              ElevatedButton(
                onPressed: _doGetAllNodes,
                style: _tertiaryActionStyle(scheme),
                child: const Text('getAllNodes', style: TextStyle(fontSize: 12)),
              ),
              ElevatedButton(
                onPressed: _doGetDevices,
                style: _secondaryActionStyle(scheme),
                child: const Text('getDevices', style: TextStyle(fontSize: 12)),
              ),
              ElevatedButton(
                onPressed: _doReconnect,
                style: _tertiaryActionStyle(scheme),
                child: const Text('reconnect', style: TextStyle(fontSize: 12)),
              ),
              ElevatedButton(
                onPressed: _doDisconnect,
                style: _actionStyle(scheme, destructive: true),
                child: const Text('disconnect', style: TextStyle(fontSize: 12)),
              ),
              ElevatedButton(
                onPressed: _doSendData,
                style: _actionStyle(scheme),
                child: const Text('sendData', style: TextStyle(fontSize: 12)),
              ),
              ElevatedButton(
                onPressed: () => _cloudService.ensureDiscoveryStarted(),
                style: _secondaryActionStyle(scheme),
                child: const Text('mDNS start', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              ValueListenableBuilder<Map<String, dynamic>>(
                valueListenable: _cloudService.liveNodes,
                builder: (_, nodes, __) => Text(
                  'Known Nodes: ${nodes.length}',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ),
              const SizedBox(width: 12),
              ValueListenableBuilder<List<String>>(
                valueListenable: _cloudService.discoveredNodeIds,
                builder: (_, discovered, __) => Text(
                  'LAN Discovered: ${discovered.length}',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(_logs.clear),
                child: const Text('Clear', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(8),
              child: ListView.builder(
                controller: _consoleScroll,
                itemCount: _logs.length,
                itemBuilder: (_, i) {
                  final log = _logs[i];
                  final isRecv = log.contains('[WebSocket RECV]') ||
                      log.contains('[CloudEvent]');
                  final isError = log.contains('Error') || log.contains('error');
                  return Text(
                    log,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: isError
                          ? scheme.error
                          : isRecv
                              ? scheme.primary
                              : muted,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
