# Backend SDUI Global Contract (Flutter client)

Apply these rules to **every model / every device**, not one product.
Flutter already has defensive fixes; the schema generator must publish correct shapes so all apps stay consistent.

Observed failures (example: cooker page-1) came from generator output that breaks **any** model with the same patterns.

---

## 1. Control UI type must match interaction

| If the control is… | Publish as | Do **not** publish as |
|---|---|---|
| On/off or false/true with 2 protocol values | `switch` / `toggle` / `segmented` / `buttonGroup` | `trigger` + `elevatedButton` |
| One-shot command with no lasting state | `trigger` / `elevatedButton` | enum with options |
| Choose-one list (recipe, mode, color, …) | `dropdown` / `enum` | `textField` when options exist |
| Read-only status label with enum map | `text` / read-only display + options | editable text pretending to be state |

### Required fields for every enum-like control

```json
{
  "id": "<page>:<name>:<role>",
  "binding": "device.parameters.<stable_key>",
  "componentType": "dropdown | switch | segmented",
  "valueType": "enum | boolean",
  "value": "<canonical protocol value, never the field name>",
  "options": [
    { "label": "Human Label", "value": "<canonical>" }
  ],
  "protocolMeta": {
    "items": ["[LabelA][LabelB]"],
    "item_values": ["[00][01]"],
    "sno_asperui": ["[00][01]"]
  }
}
```

**Global rules**
- Seed `value` / binding with a **real protocol value** (`00`, `01`, …), never the parameter name (`Skipmode`, `Cookermode`, `Recipee`).
- `options[].value` must be the **same canonical space** used by live status / get_status echoes.
- Keep full TX frame payloads in `deviceFrame` / `asperui_values` only — **not** as dropdown option values when status returns short indices.

---

## 2. One canonical value space per logical parameter

For any choose-one parameter (recipe, color, mode, fan speed, …):

1. Pick **one** canonical option value space for UI + live sync, preferably short protocol index / sno (`00`…`0F`).
2. Command control options and matching get_status / response controls **must share the same labels and the same values**.
3. If the wire frame needs a long hex payload, map it only in frame builders:

```text
UI / live binding  →  sno "02"
Frame builder      →  asperui "FRY" / asperui_values "<full hex>"
```

**Anti-pattern (breaks every model that does this)**
- Command dropdown `value` = 46-char hex
- Status dropdown `value` = `02`
- Same label `FRY` → Flutter cannot keep selection stuck after status update

**Required generator check**
- For each logical parameter, `command.options[].value` ≡ `status.options[].value` ≡ `protocolMeta.sno_asperui` (or shared `item_values` if that is the chosen canonical space).
- Never ship one concatenated option map as a single `{label:"[A][B]", value:"[00][01]"}` without also ensuring Flutter-facing `options` are expanded — prefer already-expanded arrays from the generator.

---

## 3. Info page / gateway details — light payload only

### Do

```json
{
  "infoPage": {
    "entryScreen": "gatewayDetails",
    "dataSource": "deviceInfo",
    "dataUrl": "https://efactor.tech/<light-info-endpoint>?model_no={{device.model_no}}&node_id={{device.node_id}}",
    "responsePath": "node_details[0].config",
    "infoPath": "info",
    "fieldBindings": {
      "network": "info.SSID|info.ssid",
      "firmware": "info.fw_version|info.firmware_version",
      "name": "info.name|devices[0].name"
    }
  },
  "dataSources": {
    "deviceInfo": {
      "type": "rest",
      "method": "GET",
      "url": "https://efactor.tech/<light-info-endpoint>?model_no={{device.model_no}}&node_id={{device.node_id}}",
      "responsePath": "node_details[0].config",
      "load": "onAction"
    }
  }
}
```

### Do **not**

- Point `infoPage.dataUrl` / `dataSources.deviceInfo.url` at full `api_schema.php` (tens of MB).
- Hardcode a single `node_id` or `model_no` in the URL.
- Omit `{{device.model_no}}` / `{{device.node_id}}` templates.

### Preferred light response shape (any model)

```json
{
  "success": true,
  "node_details": [
    {
      "node_id": "<node>",
      "config": {
        "node_id": "<node>",
        "info": {
          "name": "...",
          "SSID": "...",
          "Access_Point": "...",
          "fw_version": "...",
          "type": "...",
          "Guarantee_Card": "...",
          "Video": "...",
          "Need_Help": "...",
          "Auto_Test": "..."
        }
      }
    }
  ]
}
```

Target size: **&lt; 5 KB** (info object alone is enough). Flutter caches this locally; full device UI schemas must not be the Info datasource.

If no dedicated endpoint yet: still embed `deviceConfig.info` / `node_details[0].config.info` in the device schema (already done for many models) and stop forcing a second full-schema download for Info.

---

## 4. Templates and identity (global)

Every URL / body that is device-specific must use placeholders Flutter already resolves:

| Placeholder | Meaning |
|---|---|
| `{{device.model_no}}` / `{{device.model_number}}` | Active model |
| `{{device.node_id}}` / `{{node_id}}` | Active node |
| `$runtime.modelId` / `$runtime.nodeId` | Same, runtime form |
| Bearer / `$secureState` session token | Auth |

No model name, no fixed node id, no product-specific branch in the generator for these three issues.

---

## 5. Acceptance checklist (run on every generated schema)

- [ ] No control `value` equals its parameter/display name when options/protocol values exist.
- [ ] Every `dropdown` / enum has expanded `options[{label,value}]` with one canonical value space.
- [ ] Command + status mirrors for the same parameter use identical option values.
- [ ] Long frame hex lives only under frame / `asperui_values`, not as the UI option value (unless UI and status both use hex exclusively).
- [ ] Boolean-like 2-value controls are switch/segmented, not trigger buttons.
- [ ] `infoPage` / `deviceInfo` URL is a light endpoint with `{{device.model_no}}` + `{{device.node_id}}`.
- [ ] `responsePath` points at config (or config.info), not the full UI schema root.
- [ ] No hardcoded node/model in Info or command URLs.

---

## 6. Flutter behavior (schema-driven only)

Flutter will **not** invent labels, colors, radii, paddings, model names, or URL denylists.

It **will**:
- Resolve captions / options / protocol aliases only from control + `protocolMeta` fields
- Theme tokens: `theme.radius.button`, `theme.spacing.cardPadding`, `theme.colors.*`
- Slice Info cache only via schema `responsePath` / `infoPath`
- Refuse oversized cache payloads (platform size guard)

If the schema omits required tokens or paths, Flutter shows `SchemaIssueWidget` or skips cache — **fix the generator**, do not ask Flutter to hardcode defaults.

---

## 7. Who owns what

| Item | Owner |
|---|---|
| Schema generator: UI type, options, seed values, command/status parity | Backend / schema team |
| Light device-info API (or stop using `api_schema.php` for Info) | Backend API |
| Template URLs with model/node | Backend / schema team |
| Client matching + local Info slice cache | Flutter (done) |
