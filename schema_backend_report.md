# Schema Analysis Report — EF-003PA (Schema v4.0.0)
**Model:** EF-003PA  
**Node ID:** FFFFFFFFFFFFFFFF7EC2000000049200  
**Schema Generated At:** 2026-08-25T10:44:07+05:30  
**Report Generated:** 2026-08-25  
**Reported By:** Flutter App Team  

---

> [!IMPORTANT]
> This report was produced by cross-checking the schema JSON against the **actual Flutter app source code** (`app_state.dart`, `device_frame_builder.dart`, `renderer.dart`, `schema_repositorydynamic.dart`). Each issue below is backed by a specific code path that reads or validates that exact field. **None of these are false positives.**

---

## Summary

| # | Severity | Category | Issue |
|---|---|---|---|
| 1 | 🔴 CRITICAL | Missing Block | `extensions` block entirely absent |
| 2 | 🟠 HIGH | Data Inconsistency | `protocolMeta.command_id` and `function_code` are empty strings |
| 3 | 🟠 HIGH | Missing Field | `dataSources.deviceCommands` is absent |
| 4 | 🟡 MEDIUM | Self-Reported | Schema self-reports `productionReady: false` and `flutterValidation.valid: false` |
| 5 | 🟡 MEDIUM | Field Mismatch | `meta.app.modalId` vs `meta.app.modelNo` — integer vs string naming inconsistency |
| 6 | 🟡 MEDIUM | Layout Overflow | `controls[0]` row layout causes 1.2px overflow on narrow screens |
| 7 | ✅ NOT AN ISSUE | Verified OK | `node_id` block — correctly present and correctly structured |
| 8 | ✅ NOT AN ISSUE | Verified OK | `deviceFrame` for control `1:power:command-2-toggle-switch` — values are present |
| 9 | ✅ NOT AN ISSUE | Verified OK | All `controls[].binding`, `events`, `options`, `constraints` — correctly populated |

---

## 🔴 ISSUE 1 — CRITICAL: `extensions` block is entirely missing

### What the Flutter app needs
The app reads **all of the following paths** from the schema at runtime:

```
extensions.serverDrivenUi.state.parameters     ← initial parameter values (app_state.dart:156)
extensions.universalUi.data.state.online       ← device online status (app_state.dart:205)
extensions.universalUi.data.parameters         ← universal parameter map (app_state.dart:377)
extensions.universalUi.interactions.controls   ← debounce settings (app_state.dart:665)
extensions.universalUi.actions                 ← action dispatch map (app_state.dart:745)
extensions.universalUi.designSystem            ← component styles, icon sizes (renderer.dart:68+)
extensions.universalUi.designSystem.componentStyles.parameterCard  ← card layout (parameter_card.dart:221+)
extensions.universalUi.designSystem.componentStyles.pagerControls  ← navigation arrows (renderer.dart:1299)
extensions.serverDrivenUi.accessibility        ← accessibility config (schema_runtime.dart:192)
extensions.serverDrivenUi.responsive           ← responsive breakpoints (schema_runtime.dart:236)
```

### What the schema currently has
The entire `extensions` key **does not exist** in the schema JSON. Searching the full schema confirms there is no `"extensions"` key at the root level.

### Evidence from the schema itself
```json
"meta": {
  "renderHint": "Flutter document missing at extensions.serverDrivenUi.",
  "flutterValidation": {
    "valid": false,
    "errors": [
      "EfactorSdui core library is not loaded; extensions.serverDrivenUi was not generated."
    ]
  }
}
```
The schema itself acknowledges this block is missing.

### Impact
- App cannot load initial parameter state from `extensions.serverDrivenUi`
- App cannot read design system (fallbacks to hardcoded defaults, causing layout inconsistencies)
- App cannot read pager navigation styles → navigation arrows may be invisible/broken
- `ParameterCard` layout reads **required** column widths from `extensions.universalUi.designSystem.componentStyles.parameterCard.layout.columns` — if missing this causes the 1.2px overflow error seen at runtime

### Required Fix
Backend must generate the `extensions` block. The minimum required structure is:

```json
"extensions": {
  "serverDrivenUi": {
    "state": {
      "parameters": {
        "1_power_command_2_toggle_switch": { "value": false }
      }
    }
  },
  "universalUi": {
    "data": {
      "state": {
        "online": false
      }
    },
    "designSystem": {
      "componentStyles": {
        "parameterCard": {
          "layout": {
            "type": "row",
            "columns": [
              { "flex": 1 },
              { "flex": 0 }
            ],
            "gap": 8,
            "alignItems": "center"
          }
        }
      }
    }
  }
}
```

---

## 🟠 ISSUE 2 — HIGH: `protocolMeta.command_id` and `function_code` are empty strings

### What the Flutter app does
In `device_frame_builder.dart` (lines 104–113), when building the device command frame, if a command field's `value` is blank, the builder falls back to `protocolMeta.command_id` and `protocolMeta.function_code`:

```dart
if (_isBlank(rawValue)) {
  if (_looksLikeCommandId(normalizedName)) {
    rawValue = protocolMeta['command_id'];   // fallback to this
  } else if (_looksLikeFunctionCode(normalizedName)) {
    rawValue = protocolMeta['function_code']; // fallback to this
  }
}
```

### What the schema has
In `controls[0].protocolMeta`:
```json
"protocolMeta": {
  "command_id": "",        ← EMPTY STRING
  "function_code": "",     ← EMPTY STRING
  "action_id": null,
  ...
}
```

In `controls[0].protocolMeta.frame.commands`:
```json
{ "default_name": "CommandId", "value": "" },    ← also EMPTY
{ "default_name": "Function Code", "value": "" } ← also EMPTY
```

In `controls[0].deviceFrame.commands` (these are CORRECT):
```json
{ "default_name": "CommandId", "value": "A1" },    ← CORRECT
{ "default_name": "Function Code", "value": "C2" } ← CORRECT
```

### Why this matters
The `deviceFrame` has the correct values (`A1`, `C2`), so the command frame **can** be built using `deviceFrame` directly. However:

1. The Flutter validation error `"writable control deviceFrame is missing CommandId value"` is triggered by checking `protocolMeta.frame.commands[0].value`, not `deviceFrame.commands[0].value`
2. If the app ever needs to fall back to `protocolMeta.frame` instead of `deviceFrame`, the frame will be built with empty bytes → device receives malformed command

### Required Fix
Populate `protocolMeta.command_id` and `protocolMeta.function_code` with the same values as in `deviceFrame`:

```json
"protocolMeta": {
  "command_id": "A1",    ← fill this
  "function_code": "C2", ← fill this
  ...
  "frame": {
    "commands": [
      { "default_name": "CommandId", "value": "A1" },    ← fill this too
      { "default_name": "Function Code", "value": "C2" } ← fill this too
    ]
  }
}
```

---

## 🟠 ISSUE 3 — HIGH: `dataSources.deviceCommands` block is absent

### What the Flutter app reads
`app_state.dart` line 1426:
```dart
final dataSource = _schema['dataSources']?['deviceCommands'];
```
This controls the device communication adapter and protocol configuration.

### What the schema has
The schema has **no `dataSources` key** at the root level. The schema JSON was reviewed in full — `dataSources` does not appear anywhere.

### Impact
- The Flutter app cannot determine the device communication adapter (WiFi/UART/BLE)
- The app defaults to its built-in transport with no schema-provided configuration
- API routing, protocol version, and endpoint cannot be customized per device

### Required Fix
Add a `dataSources` block at the schema root:

```json
"dataSources": {
  "deviceCommands": {
    "adapter": "efactor_wifi",
    "protocol": "efactor_v1",
    "endpoint": "https://efactor.tech/v8/api_scan.php",
    "model_no": "EF-003PA",
    "node_id": "FFFFFFFFFFFFFFFF7EC2000000049200"
  }
}
```

---

## 🟡 ISSUE 4 — MEDIUM: Schema self-reports as invalid and not production-ready

### Evidence
```json
"meta": {
  "productionReady": false,
  "flutterValidation": {
    "valid": false,
    "errors": [
      "EfactorSdui core library is not loaded; extensions.serverDrivenUi was not generated.",
      "1:power:command-2-toggle-switch: writable control deviceFrame is missing CommandId value."
    ]
  }
}
```

### Required Fix
After fixing Issues 1 and 2 above:
- Set `meta.productionReady` to `true`
- Re-validate and ensure `meta.flutterValidation.valid` becomes `true`
- `meta.flutterValidation.errors` should be an empty array `[]`

---

## 🟡 ISSUE 5 — MEDIUM: `meta.app.modalId` is integer 300 but should be cross-checked against model identifiers

### Current Schema
```json
"meta": {
  "app": {
    "id": "efactor_ef_003pa",
    "name": "EF-003PA Control",
    "modelNo": "EF-003PA",      ← string, correct
    "model_id": "EF-003PA",     ← string, correct
    "nodeId": "FFFFFFFFFFFFFFFF7EC2000000049200",
    "modalId": 300,             ← integer "modalId" (note: 'modal', not 'model')
    "entryWidgetId": "phone_shell"
  }
}
```

### Observations
1. There is a **key name inconsistency**: `modelNo`, `model_id` (model-related) exist alongside `modalId` (integer 300). The key `modalId` appears to be a database row ID or dialog identifier that is different from the model number.
2. The Flutter app reads `meta.app.modelNo` (string "EF-003PA") for identity — this is correctly populated.
3. The `modalId: 300` field is **not read by the Flutter app** in any code path reviewed. It may be a backend internal field accidentally leaked into the public schema.

### Required Fix (Optional but recommended)
Either:
- Remove `modalId` from the public schema if it is a backend-internal database ID, OR
- Rename to `dbId: 300` or `internalId: 300` to avoid confusion with `modelNo`

---

## 🟡 ISSUE 6 — MEDIUM: `controls[0]` row layout causes 1.2px RenderFlex overflow

### Runtime Error
```
A RenderFlex overflowed by 1.2 pixels on the right.
  constraints: BoxConstraints(0.0<=w<=132.8, 0.0<=h<=Infinity)
  at renderer.dart:848 (Flex/Row widget)
```

### Root Cause in Schema
The `power` control uses layout `"row"` with:
```json
"cardStyle": {
  "iconBubble": { "size": 38 },    ← 38px icon bubble
  "padding": 14,
  "minHeight": 66
}
```
With a Switch widget (fixed ~50px) + icon bubble (38px) + label text + padding, the total exceeds 132.8px of available width on this device.

### Required Fix
Either change the layout:
```json
"layout": "stacked"    ← instead of "row"
```
Or reduce the icon bubble:
```json
"iconBubble": { "size": 28 }   ← reduce from 38 to 28
```

---

## ✅ VERIFIED OK — Fields the backend team said are correct

### node_id block — CORRECT ✅
The schema has a proper `node_id` block at the root:
```json
"node_id": {
  "id": "FFFFFFFFFFFFFFFF7EC2000000049200",
  "modelNo": "EF-003PA",
  "model_id": "EF-003PA",
  "value": "FFFFFFFFFFFFFFFF7EC2000000049200",
  "source": "studio",
  "binding": "node_id.id",
  "schemaApi": "https://efactor.tech/v8/api_schema.php?..."
}
```
The Flutter app (`schema_repositorydynamic.dart:440-452`) reads `schema['node_id']` and falls back to `schema['meta']['app']['nodeId']`. **Both are correctly populated in this schema.**

### meta.app identity fields — CORRECT ✅
```json
"meta.app.nodeId": "FFFFFFFFFFFFFFFF7EC2000000049200"  ← matches node_id.id ✅
"meta.app.modelNo": "EF-003PA"                         ← correct ✅
"meta.app.model_id": "EF-003PA"                        ← correct ✅
```

### controls[0].deviceFrame — CORRECT ✅
The `deviceFrame` for control `1:power:command-2-toggle-switch` has correctly populated values:
- `CommandId: "A1"` ✅
- `Function Code: "C2"` ✅  
- `Terminator: "0A"` ✅
- `asperui: ["false", "true"]` with `asperui_values: ["00", "01"]` ✅

The Flutter's `DeviceFrameBuilder` uses `deviceFrame` first and can successfully build the command frame for this control.

### controls[0].binding and events — CORRECT ✅
```json
"binding": "device.parameters.1_power_command_2_toggle_switch"  ✅
"events": [
  { "event": "onChanged", "action": { "type": "update", ... } },
  { "event": "onChanged", "action": { "type": "send", ... } }
]
```

### meta.links — CORRECT ✅
All API links (`schema`, `scan`, `wifiStatus`, etc.) are present and use correct URL patterns with `model_no` and `node_id` query parameters.

### meta.wifiProvisioning — CORRECT ✅
The Wi-Fi provisioning block is correctly configured with `entry`, `plugin`, `methodChannel`, `eventChannel`, and `qrScanner` settings.

---

## Action Items for Backend Team

| Priority | Action |
|---|---|
| 🔴 P0 | Generate and include `extensions.serverDrivenUi` and `extensions.universalUi` blocks |
| 🔴 P0 | Set `meta.productionReady: true` after fixing above |
| 🟠 P1 | Populate `protocolMeta.command_id: "A1"` and `protocolMeta.function_code: "C2"` |
| 🟠 P1 | Populate `protocolMeta.frame.commands[CommandId].value: "A1"` and `[FunctionCode].value: "C2"` |
| 🟠 P1 | Add `dataSources.deviceCommands` block with adapter and endpoint config |
| 🟡 P2 | Fix `controls[0]` layout overflow: change to `"layout": "stacked"` or reduce `iconBubble.size` to 28 |
| 🟡 P3 | Clarify and clean up `meta.app.modalId: 300` — rename or remove if internal DB field |

---

*This report was generated by cross-referencing schema JSON against Flutter source code. All Flutter code references are from the `efactor_sdui` project.*
