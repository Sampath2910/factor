# Backend & Schema Issues Report — eFactor SDUI

**Date:** 01 Oct 2026  
**Audience:** Backend Team / Schema Engineers / Protocol Authors  
**Affected Models:** All SDUI Models (e.g., `EF-003FMN03`, single-page devices, and multi-page devices)

---

## Executive Summary

During testing of the Flutter SDUI engine against live backend payloads and video telemetry, critical schema-level gaps were identified that directly impact device interaction, parameter synchronization, page navigation, and terminal console monitoring.

This document details all **Backend / Schema-side issues**, their root causes, and the exact JSON adjustments required from the server.

---

## 1. Major Schema Issues

### 1.1 Incomplete Command Frames for Send Button Text Fields
- **Observed Behavior:** Tapping the Send button on text fields (`NAME` on Page 1, `SEND DATA` on Page 3, `Mortgage_Time` on Page 6) does not execute commands.
- **Root Cause in Backend Schema:**
  1. **Missing Transport Bytes:** The backend publishes `commands` with only a single `Data` entry, omitting the required protocol framing (`CommandId`, `Function Code`, `Terminator`).
     ```json
     // Current Backend Output for "3:Send Data:command-0-enter-text":
     "commands": [
       { "default_name": "SendData", "asperui": "00", "value": "00" }
     ]
     ```
     `DeviceFrameBuilder` cannot construct an executable hexadecimal frame without `CommandId` and `Function Code`.
  2. **Read-Only / Command-0 Naming:** Fields that have Send buttons are assigned IDs such as `command-0-enter-text`. In the protocol hierarchy, `command-0` designates read/telemetry fields. Because no write access contract (`"access": "write"` or `"writable": true`) is published, the client marks the binding as non-writable and disables the send button tap target.
  3. **Empty Values on Remote Address & Mortgage:** In Page 5 (`5:remote_address:command-2-text`) and Page 6 (`6:Mortgage_Time:command-2-text`), the backend publishes empty strings for `CommandId`, `Function Code`, and `Terminator`:
     ```json
     "commands": [
       { "default_name": "CommandId", "value": "" },
       { "default_name": "Function Code", "value": "" },
       { "default_name": "Data", "value": "Mortgage_Time" },
       { "default_name": "Terminator", "value": "" }
     ]
     ```
- **Backend Fix Required:**
  - For every control featuring a Send button, publish complete protocol framing with valid hex codes:
    ```json
    "commands": [
      { "byte_start_position": 1, "no_of_bytes": 1, "default_name": "CommandId", "value": "A1" },
      { "byte_start_position": 2, "no_of_bytes": 1, "default_name": "Function Code", "value": "<FUNC_HEX>" },
      { "byte_start_position": 3, "no_of_bytes": "<LEN>", "default_name": "Data", "asperui": "text" },
      { "byte_start_position": "<LAST>", "no_of_bytes": 1, "default_name": "Terminator", "value": "0A" }
    ],
    "access": "write",
    "writable": true
    ```

---

### 1.2 Generic `"Data"` Default Names on Response Fields
- **Observed Behavior:** The Command Get Status accordion and the Terminal Console either display repeated `"Data"` labels or skip the parameters entirely.
- **Root Cause in Backend Schema:**
  In the `response` array for `3:command_get_status:command-3-button`, all 16 response fields have `default_name: "Data"`.
  The actual parameter identifiers (`Speed`, `Direction`, `Color`, `Lamp`, `Timer`, `DimmingLevel`, `Buzzer`, `Voltage`, `Current`, `Watt`, etc.) are buried inside `response[i]["value"]` or `response[i]["asperui_value"]` rather than being declared in `default_name`.
- **Backend Fix Required:**
  Declare the actual field name in `default_name`:
  ```json
  "response": [
    { "byte_start_position": 1, "no_of_bytes": 1, "default_name": "CommandId", "value": "DE" },
    { "byte_start_position": 2, "no_of_bytes": 1, "default_name": "Function Code", "value": "E7" },
    { "byte_start_position": 3, "no_of_bytes": 1, "default_name": "power", "type": "boolean" },
    { "byte_start_position": 4, "no_of_bytes": 1, "default_name": "Speed", "type": "number" },
    { "byte_start_position": 5, "no_of_bytes": 1, "default_name": "Direction", "type": "number" },
    { "byte_start_position": 6, "no_of_bytes": 1, "default_name": "Color", "type": "number" },
    { "byte_start_position": 7, "no_of_bytes": 1, "default_name": "Lamp", "type": "boolean" },
    { "byte_start_position": 8, "no_of_bytes": 1, "default_name": "Timer", "type": "number" },
    { "byte_start_position": 9, "no_of_bytes": 1, "default_name": "DimmingLevel", "type": "number" },
    { "byte_start_position": 10, "no_of_bytes": 1, "default_name": "Fan_enable/disable", "type": "boolean" },
    { "byte_start_position": 11, "no_of_bytes": 1, "default_name": "Remote_lock/unlock", "type": "boolean" },
    { "byte_start_position": 12, "no_of_bytes": 2, "default_name": "rpm", "type": "number" },
    { "byte_start_position": 14, "no_of_bytes": 4, "default_name": "Watt", "type": "float" },
    { "byte_start_position": 18, "no_of_bytes": 4, "default_name": "Current", "type": "float" },
    { "byte_start_position": 22, "no_of_bytes": 4, "default_name": "Voltage", "type": "float" },
    { "byte_start_position": 26, "no_of_bytes": 4, "default_name": "vacrms", "type": "float" },
    { "byte_start_position": 30, "no_of_bytes": 1, "default_name": "Buzzer", "type": "boolean" },
    { "byte_start_position": 31, "no_of_bytes": 4, "default_name": "Remote Address", "type": "number" },
    { "byte_start_position": 35, "no_of_bytes": 1, "default_name": "Terminator", "value": "0A" }
  ]
  ```

---

### 1.3 Non-Payload Trigger Slot in Command Payloads
- **Observed Behavior:** Frame compilation fails when serializing trigger commands because slot 3 declares `byte_start_position: 0` and `no_of_bytes: 0`.
- **Root Cause in Backend Schema:**
  The backend injects the UI trigger action as a virtual command slot:
  ```json
  {
    "Field_description": "Trigger",
    "default_name": "Trigger",
    "byte_start_position": 0,
    "no_of_bytes": 0,
    "type": "Trigger"
  }
  ```
- **Backend Fix Required:**
  Move UI trigger metadata out of the `commands` byte payload array into a dedicated `triggerMeta` or `protocolMeta` property, or omit `Trigger` from the serialized byte slots.

---

### 1.4 Single-Page Models Omitting Pager Navigation UI
- **Observed Behavior:** For devices with only 1 page, no page number buttons appear at the bottom of the screen.
- **Root Cause in Backend Schema:**
  When generating schema for a 1-page device, `api_schema.php` omits the `page_buttons` ListView container from `schema.ui.children`. The client cannot render a pager bar that is absent from the published tree.
- **Backend Fix Required:**
  Always include the `page_buttons` list view in `ui.children`, even when `pageCount == 1`:
  ```json
  {
    "id": "page_buttons",
    "type": "listView",
    "properties": { "scrollDirection": "horizontal" },
    "children": [
      {
        "id": "page_button_0",
        "type": "button",
        "properties": {
          "events": [
            {
              "event": "onTap",
              "action": { "type": "update", "value": "activePageIndex=0" }
            }
          ]
        },
        "children": [
          { "id": "page_text_1", "type": "text", "properties": { "text": "1" } }
        ]
      }
    ]
  }
  ```

---

### 1.5 Missing Control Icons in Published Schema
- **Observed Behavior:** Parameter cards fail schema validation with `Missing control icon` unless client fallbacks are applied.
- **Root Cause in Backend Schema:**
  The `controls` array omits the mandatory `"icon"` property for all response rows and standard telemetry cards (e.g. `1:rpm:command-0-text`, `1:voltage:command-0-text`, etc.).
- **Backend Fix Required:**
  Publish valid semantic icon names on every control:
  ```json
  { "id": "1:voltage:command-0-text", "icon": "bolt", ... }
  { "id": "1:rpm:command-0-text", "icon": "speed", ... }
  ```

---

## 2. Terminal Log Issues Analysis (`ProcessId: 29568`)

| Terminal Log Entry | Root Cause | Responsible Side |
|-------------------|------------|------------------|
| `[IOT_SDUI][POWER_TOGGLE] device=... online=false` | Backend reports all devices as offline in `/v8/api.php?action=getAllNodes`. | **Backend** |
| `[EfactorCloud] reconnect() requested` | Cloud socket dropped or was unable to establish heartbeat with server. | **Backend / Infrastructure** |
| `[SDUI][REMOTE_SYNC] ignore unset "connected"=null` | Backend endpoint `auto_get_nodes_params` returns `"connected": null` instead of boolean `"connected": false/true`. | **Backend** |
| `[SDUI][LIVE_PARAMS] changed=0` | Polling endpoint returned no state changes for the node. | **Backend** |
| `Lost connection to device` | Flutter debug bridge lost connection (app process terminated / device disconnected). | **Tooling / Environment** |

---

## 3. Summary of Responsibilities

```
+-----------------------------------------------------------+-----------------------------------------------------+
|                  FLUTTER SIDE FIXES                       |                 BACKEND SIDE FIXES                  |
+-----------------------------------------------------------+-----------------------------------------------------+
| 1. Filter out `Trigger` slots with byte_start_position<=0  | 1. Provide CommandId, FunctionCode & Terminator for |
|    in DeviceFrameBuilder (COMPLETED).                     |    all Send-button text fields.                     |
| 2. Decouple accordion toggle from transport failure and   | 2. Mark Send-button controls with "access": "write".|
|    offline rollback (COMPLETED).                          | 3. Set meaningful `default_name` (Speed, Voltage,  |
| 3. Resolve true field labels from value/asperui_value      |    Buzzer, etc.) instead of generic "Data".         |
|    when default_name is "Data" (COMPLETED).               | 4. Always publish `page_buttons` with Page 1 for    |
| 4. Remove artificial pager suppression (`<= 1`) so single |    single-page models.                              |
|    page models show Page 1 button.                        | 5. Return explicit boolean `connected: true/false`  |
| 5. Fix Console widget: prevent header value leakage, add  |    instead of `"connected": null`.                  |
|    dedicated scroll view with proper gesture capture, and | 6. Publish semantic `icon` tokens on all controls.  |
|    append Command Get Status responses to console log.    |                                                     |
+-----------------------------------------------------------+-----------------------------------------------------+
```
