/// Transport-neutral device command contract.
///
/// Identity and protocol bytes are runtime/schema values. This model contains
/// no device-specific defaults.
library;

class DeviceCommandRequest {
  const DeviceCommandRequest({
    required this.modelId,
    required this.nodeId,
    required this.parameter,
    required this.parameterKey,
    required this.value,
    this.endpointUrl,
    this.accessToken,
    this.commands = const [],
    this.frameName,
    this.commandId,
    this.functionCode,
    this.actionId,
    this.multipleUi = const [],
    this.triggerUi = const [],
    this.binding,
    this.controlId,
    this.transportAdapter,
    this.protocol,
    this.pageName,
    this.finalFrame,
    this.protocolValue,
    this.numericValue,
    this.responseFrame = const [],
    this.errorFrame = const [],
  });

  final String modelId;
  final String nodeId;
  final String parameter;
  final String parameterKey;
  final dynamic value;

  /// REST endpoint when the schema selects an HTTP/REST data source. It is
  /// intentionally nullable because `deviceApi` does not use this URL.
  final String? endpointUrl;
  final String? accessToken;

  final List<dynamic> commands;
  final String? frameName;
  final dynamic commandId;
  final dynamic functionCode;
  final dynamic actionId;
  final List<dynamic> multipleUi;
  final List<dynamic> triggerUi;
  final String? binding;
  final String? controlId;

  /// Schema `dataSources.deviceCommands.adapter` / protocol.
  final String? transportAdapter;
  final String? protocol;

  /// Schema page/parameter metadata required by the native eFactor Data SDK.
  final String? pageName;

  /// Final hexadecimal payload built strictly from `deviceFrame.commands`.
  final String? finalFrame;

  /// Protocol value selected by the schema mapping (for example a mapped
  /// toggle value). Kept separate from the typed UI value.
  final dynamic protocolValue;

  /// Numeric value required by the current native eFactor sendData API.
  final double? numericValue;

  /// Schema response/error frame contracts. They are passed through so a
  /// transport/status layer can interpret them when the schema defines them.
  final List<dynamic> responseFrame;
  final List<dynamic> errorFrame;

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'modelNo': modelId,
      'node_id': nodeId,
      'parameter': parameter,
      'parameterKey': parameterKey,
      'value': value,
      if (protocolValue != null) 'protocolValue': protocolValue,
      if (finalFrame != null) 'data': finalFrame,
      if (pageName != null) 'pageName': pageName,
      if (frameName != null) 'frameName': frameName,
      if (commandId != null) 'commandId': commandId,
      if (functionCode != null) 'functionCode': functionCode,
      if (actionId != null) 'actionId': actionId,
      if (multipleUi.isNotEmpty) 'multipleUi': multipleUi,
      if (triggerUi.isNotEmpty) 'triggerUi': triggerUi,
      if (commands.isNotEmpty) 'commands': commands,
    };
  }
}

enum DeviceCommandStatus {
  accepted,
  delivered,
  rejected,
  authFailure,
  timeout,
  offline,
  invalidCommand,
}

class DeviceCommandResult {
  const DeviceCommandResult({
    required this.status,
    this.httpStatusCode,
    this.message,
    this.responseBody,
    this.rawResponse,
    this.bindingUpdates = const <String, dynamic>{},
  });

  final DeviceCommandStatus status;
  final int? httpStatusCode;
  final String? message;
  final String? responseBody;

  /// Native/cloud response map, when the selected transport exposes one.
  final Map<String, dynamic>? rawResponse;

  /// Optional schema-resolved state updates. AppState applies these only to
  /// explicit bindings; transports must never invent parameter bindings.
  final Map<String, dynamic> bindingUpdates;

  bool get accepted =>
      status == DeviceCommandStatus.accepted ||
      status == DeviceCommandStatus.delivered;

  bool get delivered => status == DeviceCommandStatus.delivered;

  @override
  String toString() =>
      'DeviceCommandResult(status=$status, http=$httpStatusCode, msg=$message)';
}

abstract interface class DeviceCommandTransport {
  Future<DeviceCommandResult> send(DeviceCommandRequest request);
}
