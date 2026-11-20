/// Deep-copies a JSON-shaped value (maps, lists, and primitives) in a single
/// pass. Replaces the `jsonDecode(jsonEncode(x))` round-trip that serialized
/// multi-MB schemas to a string and parsed them back on the UI thread.
///
/// Inputs here always originate from `jsonDecode`, so map keys are already
/// strings and values are JSON primitives; keys are coerced to `String` to
/// match what the old round-trip produced.
dynamic deepCopyJson(dynamic value) {
  if (value is Map) {
    final out = <String, dynamic>{};
    value.forEach((key, v) => out['$key'] = deepCopyJson(v));
    return out;
  }
  if (value is List) {
    return List<dynamic>.generate(value.length, (i) => deepCopyJson(value[i]));
  }
  return value;
}
