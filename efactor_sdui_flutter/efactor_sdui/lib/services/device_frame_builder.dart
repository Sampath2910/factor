import 'dart:math' as math;

/// Result of converting a schema control + runtime value into the final
/// hexadecimal payload expected by the eFactor device transport.
class DeviceFrameBuildResult {
  const DeviceFrameBuildResult._({
    required this.ok,
    this.frameHex,
    this.protocolValue,
    this.numericValue,
    this.error,
  });

  const DeviceFrameBuildResult.success({
    required String frameHex,
    required dynamic protocolValue,
    required double numericValue,
  }) : this._(
          ok: true,
          frameHex: frameHex,
          protocolValue: protocolValue,
          numericValue: numericValue,
        );

  const DeviceFrameBuildResult.failure(String error)
      : this._(ok: false, error: error);

  final bool ok;
  final String? frameHex;
  final dynamic protocolValue;
  final double? numericValue;
  final String? error;
}

/// Schema-only frame compiler.
///
/// No model, node, parameter, command, function-code or ON/OFF values live in
/// this class. Every byte comes from `control.deviceFrame`, `protocolMeta`, or
/// the runtime value mapping declared by the control itself.
class DeviceFrameBuilder {
  const DeviceFrameBuilder._();

  /// Resolves only the schema-declared UI -> protocol mapping. Useful for
  /// diagnostics even when another required frame byte is missing.
  static dynamic resolveProtocolValue(
    Map<String, dynamic> control,
    dynamic runtimeValue,
  ) =>
      _protocolValueFromControl(control, runtimeValue);

  static DeviceFrameBuildResult build({
    required Map<String, dynamic> control,
    required dynamic runtimeValue,
  }) {
    final controlId = control['id']?.toString() ?? '<unknown>';
    final frame = Map<String, dynamic>.from(
      control['deviceFrame'] as Map? ??
          control['protocolMeta']?['frame'] as Map? ??
          const <String, dynamic>{},
    );
    final commands = List<Map<String, dynamic>>.from(
      (frame['commands'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .where((field) => !_isEmptyCommandSlot(field) && !_isNonPayloadTriggerSlot(field)),
    );
    if (commands.isEmpty) {
      return DeviceFrameBuildResult.failure(
        'controls[id="$controlId"].deviceFrame.commands is empty; '
        'a physical command frame cannot be built.',
      );
    }

    final protocolMeta = Map<String, dynamic>.from(
      control['protocolMeta'] as Map? ?? const <String, dynamic>{},
    );

    var frameSize = 0;
    for (var index = 0; index < commands.length; index++) {
      final field = commands[index];
      final start = _positiveInt(field['byte_start_position'] ??
          field['start_byte'] ??
          field['byte_start'] ??
          field['start_position']);
      final count = _positiveInt(field['no_of_bytes'] ??
          field['number_of_bytes'] ??
          field['bytes_count'] ??
          field['byte_count'] ??
          field['length']);
      if (start == null || count == null) {
        return DeviceFrameBuildResult.failure(
          'controls[id="$controlId"].deviceFrame.commands[$index] must '
          'declare positive byte_start_position and no_of_bytes.',
        );
      }
      frameSize = math.max(frameSize, start + count - 1);
    }

    final bytes = List<int?>.filled(frameSize, null);
    dynamic mappedProtocolValue;
    double? mappedNumericValue;

    for (var index = 0; index < commands.length; index++) {
      final field = commands[index];
      final start = _positiveInt(field['byte_start_position'] ??
          field['start_byte'] ??
          field['byte_start'] ??
          field['start_position'])!;
      final count = _positiveInt(field['no_of_bytes'] ??
          field['number_of_bytes'] ??
          field['bytes_count'] ??
          field['byte_count'] ??
          field['length'])!;
      final name = (field['default_name'] ?? field['Field_description'])
          ?.toString()
          .trim();
      final normalizedName = name?.toLowerCase() ?? '';

      dynamic rawValue = field['value'];
      if (_isBlank(rawValue)) {
        if (_looksLikeCommandId(normalizedName)) {
          rawValue = protocolMeta['command_id'] ??
              protocolMeta['commandId'] ??
              protocolMeta['CommandId'] ??
              control['command_id'] ??
              control['commandId'];
        } else if (_looksLikeFunctionCode(normalizedName)) {
          rawValue = protocolMeta['function_code'] ??
              protocolMeta['functionCode'] ??
              protocolMeta['FunctionCode'] ??
              control['function_code'] ??
              control['functionCode'];
        } else if (_looksLikeActionId(normalizedName)) {
          rawValue = protocolMeta['action_id'] ??
              protocolMeta['actionId'] ??
              protocolMeta['ActionId'] ??
              control['action_id'] ??
              control['actionId'];
        } else if (_looksLikeTerminator(normalizedName)) {
          rawValue = protocolMeta['terminator'] ??
              protocolMeta['end_byte'] ??
              control['terminator'];
        }
        rawValue ??= field['default'] ??
            field['default_value'] ??
            field['initial_value'];
      }

      final mapping = _mapRuntimeValue(
        control: control,
        field: field,
        runtimeValue: runtimeValue,
      );
      if (mapping.matched) {
        rawValue = mapping.value;
        mappedProtocolValue ??= mapping.value;
        mappedNumericValue ??= _numericTransportValue(
          runtimeValue,
          protocolValue: mapping.value,
        );
      } else if (!_looksLikeCommandId(normalizedName) &&
          !_looksLikeFunctionCode(normalizedName) &&
          !_looksLikeActionId(normalizedName) &&
          !_looksLikeTerminator(normalizedName)) {
        mappedProtocolValue ??= rawValue;
        mappedNumericValue ??= _numericTransportValue(
          runtimeValue,
          protocolValue: rawValue,
        );
      }

      if (_isBlank(rawValue)) {
        final path =
            'controls[id="$controlId"].deviceFrame.commands[$index].value';
        final metaHint = _looksLikeCommandId(normalizedName)
            ? ' (protocolMeta.command_id is also blank)'
            : _looksLikeFunctionCode(normalizedName)
                ? ' (protocolMeta.function_code is also blank)'
                : '';
        return DeviceFrameBuildResult.failure(
          '$path is blank$metaHint. Flutter cannot infer protocol bytes.',
        );
      }

      final encoded = _encodeExplicitProtocolBytes(rawValue, byteCount: count);
      if (encoded == null) {
        return DeviceFrameBuildResult.failure(
          'controls[id="$controlId"].deviceFrame.commands[$index].value '
          'cannot be encoded safely as exactly $count protocol byte(s): '
          '"$rawValue". Supply an explicit hexadecimal value/mapping in the '
          'schema; Flutter will not invent encoding or endianness.',
        );
      }

      for (var offset = 0; offset < encoded.length; offset++) {
        final target = start - 1 + offset;
        if (bytes[target] != null) {
          return DeviceFrameBuildResult.failure(
            'controls[id="$controlId"].deviceFrame.commands[$index] overlaps '
            'another field at byte position ${target + 1}.',
          );
        }
        bytes[target] = encoded[offset];
      }
    }

    final firstGap = bytes.indexWhere((byte) => byte == null);
    if (firstGap >= 0) {
      return DeviceFrameBuildResult.failure(
        'controls[id="$controlId"].deviceFrame.commands leaves byte position '
        '${firstGap + 1} undefined. Flutter cannot fill unspecified frame bytes.',
      );
    }

    mappedProtocolValue ??= _protocolValueFromControl(control, runtimeValue);
    mappedNumericValue ??= _numericTransportValue(
      runtimeValue,
      protocolValue: mappedProtocolValue,
    );
    mappedNumericValue ??= 1.0;

    final frameHex = bytes
        .cast<int>()
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();

    return DeviceFrameBuildResult.success(
      frameHex: frameHex,
      protocolValue: mappedProtocolValue ?? runtimeValue,
      numericValue: mappedNumericValue,
    );
  }

  static _MappedValue _mapRuntimeValue({
    required Map<String, dynamic> control,
    required Map<String, dynamic> field,
    required dynamic runtimeValue,
  }) {
    final labels = _bracketTokens(field['asperui']);
    final values = _bracketTokens(field['asperui_values']);
    if (labels.isNotEmpty && labels.length == values.length) {
      final index = labels.indexWhere(
        (label) => _schemaValuesEquivalent(label, runtimeValue),
      );
      if (index >= 0) return _MappedValue(true, values[index]);
      // Runtime may already be the protocol byte (for example "08") rather
      // than the UI label ("0" / "1"). Reuse that mapping instead of the
      // stale static field.value snapshot.
      final protocolIndex = values.indexWhere(
        (value) => _schemaValuesEquivalent(value, runtimeValue),
      );
      if (protocolIndex >= 0) return _MappedValue(true, values[protocolIndex]);
    }

    final fieldName = (field['default_name'] ?? field['Field_description'])
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';
    final normalizedFieldName = fieldName.replaceAll(RegExp(r'[^a-z0-9]'), '');

    // Control-level mappings describe the runtime Data/Trigger value. They
    // must never replace fixed frame structure such as CommandId, Function
    // Code, ActionId or Terminator.
    if (_looksLikeCommandId(normalizedFieldName) ||
        _looksLikeFunctionCode(normalizedFieldName) ||
        _looksLikeActionId(normalizedFieldName) ||
        _looksLikeTerminator(normalizedFieldName)) {
      return const _MappedValue(false, null);
    }

    final options = control['options'];
    if (options is List) {
      for (final item in options.whereType<Map>()) {
        final label = item['label'];
        final optionRuntime = item['runtimeValue'];
        final optionValue = item['value'];
        if (_schemaValuesEquivalent(optionRuntime, runtimeValue) ||
            _schemaValuesEquivalent(label, runtimeValue) ||
            _schemaValuesEquivalent(optionValue, runtimeValue)) {
          if (!_isBlank(optionValue)) return _MappedValue(true, optionValue);
        }
      }
    }

    final byteCount = _positiveInt(field['no_of_bytes']) ?? 1;
    if (_isLiveSliderField(field, control)) {
      final encoded = _unsignedIntProtocolHex(runtimeValue, byteCount);
      if (encoded != null) return _MappedValue(true, encoded);
    }

    final runtimeHex = _explicitProtocolHex(runtimeValue, byteCount: byteCount);
    if (runtimeHex != null) return _MappedValue(true, runtimeHex);

    final numericHex = _unsignedIntProtocolHex(runtimeValue, byteCount);
    if (numericHex != null) return _MappedValue(true, numericHex);

    if (_isTriggerField(field, control) && values.isNotEmpty) {
      final unique = values.toSet();
      if (unique.length == 1 && !_isBlank(unique.first)) {
        return _MappedValue(true, unique.first);
      }
    }

    return const _MappedValue(false, null);
  }

  static dynamic _protocolValueFromControl(
    Map<String, dynamic> control,
    dynamic runtimeValue,
  ) {
    final meta = Map<String, dynamic>.from(
      control['protocolMeta'] as Map? ?? const <String, dynamic>{},
    );
    final labels = _bracketTokens(meta['items']);
    final values = _bracketTokens(meta['item_values']);
    if (labels.isNotEmpty && labels.length == values.length) {
      final index = labels.indexWhere(
        (label) => _schemaValuesEquivalent(label, runtimeValue),
      );
      if (index >= 0) return values[index];
      final protocolIndex = values.indexWhere(
        (value) => _schemaValuesEquivalent(value, runtimeValue),
      );
      if (protocolIndex >= 0) return values[protocolIndex];
    }

    final options = control['options'];
    if (options is List) {
      for (final item in options.whereType<Map>()) {
        if (_schemaValuesEquivalent(item['label'], runtimeValue) ||
            _schemaValuesEquivalent(item['runtimeValue'], runtimeValue) ||
            _schemaValuesEquivalent(item['value'], runtimeValue)) {
          return item['value'];
        }
      }
    }

    final commands = (control['deviceFrame']?['commands'] as List?) ??
        (meta['frame'] is Map ? (meta['frame'] as Map)['commands'] as List? : null);
    if (commands is List) {
      for (final raw in commands.whereType<Map>()) {
        final mapping = _mapRuntimeValue(
          control: control,
          field: Map<String, dynamic>.from(raw),
          runtimeValue: runtimeValue,
        );
        if (mapping.matched) return mapping.value;
      }
    }
    return null;
  }

  static List<String> _bracketTokens(dynamic raw) {
    final output = <String>[];
    void collect(dynamic value) {
      if (value is List) {
        for (final item in value) {
          collect(item);
        }
        return;
      }
      if (value == null) return;
      final text = value.toString().trim();
      if (text.isEmpty || text == '[]') return;
      final matches = RegExp(r'\[([^\]]*)\]').allMatches(text).toList();
      if (matches.isNotEmpty) {
        var addedAny = false;
        for (final match in matches) {
          final token = match.group(1)?.trim() ?? '';
          if (token.isNotEmpty && token != '[]') {
            output.add(token);
            addedAny = true;
          }
        }
        if (addedAny) return;
      }
      if (text != '[]') {
        output.add(text);
      }
    }

    collect(raw);
    return output;
  }

  static bool _schemaValuesEquivalent(dynamic a, dynamic b) {
    if (a == b) return true;
    final left = a?.toString().trim().toLowerCase();
    final right = b?.toString().trim().toLowerCase();
    if (left == right) return true;
    if (b is bool) return left == (b ? 'true' : 'false');
    if (a is bool) return right == (a ? 'true' : 'false');
    final leftNum = _asComparableNumber(a);
    final rightNum = _asComparableNumber(b);
    return leftNum != null && rightNum != null && leftNum == rightNum;
  }

  static double? _asComparableNumber(dynamic value) {
    if (value is num) return value.toDouble();
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  static bool _isLiveSliderField(
    Map<String, dynamic> field,
    Map<String, dynamic> control,
  ) {
    final uiType = field['ui_type']?.toString().trim().toLowerCase() ?? '';
    if (uiType == 'slider') return true;
    final component =
        (control['componentType'] ?? control['controlType'] ?? control['valueType'])
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';
    return component == 'slider';
  }

  static bool _isTriggerField(
    Map<String, dynamic> field,
    Map<String, dynamic> control,
  ) {
    final uiType = field['ui_type']?.toString().trim().toLowerCase() ?? '';
    final controlType =
        (control['valueType'] ?? control['componentType'] ?? control['variant'])
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';
    return uiType == 'trigger' ||
        controlType == 'trigger' ||
        controlType == 'elevatedbutton';
  }

  static String? _unsignedIntProtocolHex(dynamic runtimeValue, int byteCount) {
    final number = _asComparableNumber(runtimeValue);
    if (number == null || !number.isFinite) return null;
    final value = number.round();
    final max = (1 << (byteCount * 8)) - 1;
    if (value < 0 || value > max) return null;
    return value.toRadixString(16).padLeft(byteCount * 2, '0').toUpperCase();
  }

  static String? _explicitProtocolHex(
    dynamic raw, {
    required int byteCount,
  }) {
    final encoded = _encodeExplicitProtocolBytes(raw, byteCount: byteCount);
    if (encoded == null) return null;
    return encoded
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
  }

  static List<int>? _encodeExplicitProtocolBytes(
    dynamic raw, {
    required int byteCount,
  }) {
    if (raw is int) {
      if (raw < 0 || raw >= (BigInt.one << (byteCount * 8)).toInt()) {
        return null;
      }
      return List<int>.generate(
        byteCount,
        (index) => (raw >> ((byteCount - index - 1) * 8)) & 0xFF,
      );
    }

    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    final normalized = text
        .replaceFirst(RegExp(r'^0x', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\s:_-]'), '');
    if (!RegExp(r'^[0-9A-Fa-f]+$').hasMatch(normalized)) return null;
    if (normalized.length > byteCount * 2) return null;
    final padded = normalized.padLeft(byteCount * 2, '0');

    return List<int>.generate(
      byteCount,
      (index) =>
          int.parse(padded.substring(index * 2, index * 2 + 2), radix: 16),
    );
  }

  static double? _numericTransportValue(
    dynamic runtimeValue, {
    dynamic protocolValue,
  }) {
    if (runtimeValue is num) return runtimeValue.toDouble();
    if (runtimeValue is bool) return runtimeValue ? 1.0 : 0.0;
    final text = runtimeValue?.toString().trim().toLowerCase() ?? '';
    if (text == 'on' || text == 'true' || text == 'yes' || text == '01' || text == '1') return 1.0;
    if (text == 'off' || text == 'false' || text == 'no' || text == '00' || text == '0') return 0.0;
    final direct = double.tryParse(runtimeValue?.toString() ?? '');
    if (direct != null) return direct;

    final protocol = protocolValue?.toString().trim() ?? '';
    if (protocol.isEmpty) return null;
    final normalized = protocol.replaceFirst(
      RegExp(r'^0x', caseSensitive: false),
      '',
    );
    if (RegExp(r'^[0-9A-Fa-f]+$').hasMatch(normalized)) {
      return int.tryParse(normalized, radix: 16)?.toDouble();
    }
    return null;
  }

  static bool _isEmptyCommandSlot(Map<String, dynamic> field) {
    final name = (field['default_name'] ?? field['Field_description'])
            ?.toString()
            .trim() ??
        '';
    final value = field['value']?.toString().trim() ?? '';
    final start = _positiveInt(field['byte_start_position']);
    final count = _positiveInt(field['no_of_bytes']);
    return name.isEmpty && value.isEmpty && start == null && count == null;
  }

  static bool _isNonPayloadTriggerSlot(Map<String, dynamic> field) {
    final desc = (field['Field_description'] ?? field['default_name'] ?? field['type'])
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';
    final type = field['type']?.toString().trim().toLowerCase() ?? '';
    final isTrigger = desc == 'trigger' || type == 'trigger';
    final start = _positiveInt(field['byte_start_position']);
    return isTrigger && (start == null || start <= 0);
  }

  static bool _isBlank(dynamic value) =>
      value == null || (value is String && value.trim().isEmpty);

  static int? _positiveInt(dynamic raw) {
    final value =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
    return value != null && value > 0 ? value : null;
  }

  static bool _looksLikeCommandId(String name) {
    final clean = name.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return clean == 'commandid' || clean == 'cmdid' || clean == 'command';
  }

  static bool _looksLikeFunctionCode(String name) {
    final clean = name.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return clean == 'functioncode' || clean == 'fncode' || clean == 'function';
  }

  static bool _looksLikeActionId(String name) {
    final clean = name.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return clean == 'actionid' || clean == 'actid' || clean == 'action';
  }

  static bool _looksLikeTerminator(String name) {
    final clean = name.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return clean == 'terminator' || clean == 'endbyte' || clean == 'end';
  }
}

class _MappedValue {
  const _MappedValue(this.matched, this.value);

  final bool matched;
  final dynamic value;
}
