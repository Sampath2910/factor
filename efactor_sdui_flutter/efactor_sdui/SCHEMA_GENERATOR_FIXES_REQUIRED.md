# Schema Generator Fixes Specification

**Document Version:** 1.0  
**Target Audience:** Backend API & SDUI Schema Generator Developers  
**Target Services:** `grid_api_creation.php`, `api_schema.php`, `iot_api_creation.php`, `api_creation.php`  
**Host:** `https://efactor.tech`

---

## 1. Executive Summary & Action Checklist

The mobile application utilizes Server-Driven UI (SDUI) contracts retrieved from the server. Several schema formatting and protocol discrepancies have been identified that directly affect UI responsiveness, hardware protocol decoding, and WebView behavior on Android and iOS devices.

### Summary Checklist for Backend Developers:

| Priority | Endpoint / Service | Field / JSON Path | Required Action |
| :---: | :--- | :--- | :--- |
| **P0** | `api_schema.php` | `data.schema_json.deviceConfig.devices[0].pages` | Add configurations for Pages 2 through 6 (currently only Page 1 is returned). |
| **P0** | `api_schema.php` | `controls[id="3:Send Data:..."].deviceFrame.commands[0].value` | Change string `"00"` to explicit 2-byte hexadecimal `"0x0000"` or integer `0`. |
| **P0** | `iot_api_creation.php` | `components["iot-device-grid"].responsiveLayout.narrow.columns` | Change from `1` to `2` to prevent single-column stretching on standard 360dp phones. |
| **P1** | `grid_api_creation.php` | `layoutPolicy.responsive.grid.narrowScreenMaxColumns` | Change from `1` to `2`; set `statusSummary` narrow columns to `3`; set `responsiveGrid` narrow columns to `2`. |
| **P1** | `grid_api_creation.php` | Actions `url` / `route` properties | Strip duplicate `/index.php/index.php/` path fragments. |
| **P1** | `grid_api_creation.php` | `grid-open-professional-space` & `grid-open-circle-connect` | Set `openIn: "inAppWebView"` with `showAppBar: false` and `sharedCookies: true`. |
| **P2** | `api_schema.php` | `data.schema_json.controls[*]` | Provide non-null values for `name`, `type`, and `commands`. |
| **P2** | `api_creation.php` | `schema.responsive.breakpoints` | Merge smartphone tiers so $0\text{dp} - 599\text{dp}$ is uniformly `compact`. |

---

## 2. Detailed Issue Breakdown & Required Code Changes

---

### Issue 1: Device Hardware Schema Generator (`api_schema.php`)

**Live Endpoint Tested:**  
`https://efactor.tech/v8/api_schema.php?model_no=EF-003FMN03&node_id=1`  
`https://efactor.tech/v8/api_schema.php?model_no=EF-001FMN01&node_id=7E0003A6`

#### 1.1 Multi-Page Configurations Missing from `deviceConfig.devices[0].pages` (P0)
* **JSON Path:** `data.schema_json.deviceConfig.devices[0].pages`
* **Current Server Output:**  
  For model `EF-003FMN03`, root `schema_json.pages` declares 6 pages (`page_1` through `page_6`), but `deviceConfig.devices[0].pages` only sends **Page 1**:
  ```json
  "deviceConfig": {
    "devices": [
      {
        "model": "EF-003FMN03",
        "pages": {
          "Page1.Operation": { ... }
        }
      }
    ]
  }
  ```
* **Impact on App:**  
  When users swipe or tap to navigate to Page 2, Page 3, etc., hardware protocol frame parsing fails because the backend omitted the hardware packet maps for those pages.
* **Required Fix:**  
  Include the configuration for all pages inside `deviceConfig.devices[0].pages`:
  ```json
  "deviceConfig": {
    "devices": [
      {
        "model": "EF-003FMN03",
        "pages": {
          "Page1.Operation": { ... },
          "Page2": { ... },
          "Page3": { ... },
          "Page4": { ... },
          "Page5": { ... },
          "Page6": { ... }
        }
      }
    ]
  }
  ```

---

#### 1.2 Two-Byte Command Encoding for "Send Data" Control (P0)
* **JSON Path:** `controls[id="3:Send Data:command-0-enter-text"].deviceFrame.commands[0].value`
* **Observed App Error:**
  ```
  Control: 3:Send Data:command-0-enter-text
  controls[id="3:Send Data:command-0-enter-text"].deviceFrame.commands[0].value
  cannot be encoded safely as exactly 2 protocol byte(s): "00".
  Supply an explicit hexadecimal value/mapping in the schema.
  ```
* **Current Server Output:**
  ```json
  {
    "id": "3:Send Data:command-0-enter-text",
    "deviceFrame": {
      "commands": [
        {
          "byteLength": 2,
          "value": "00"
        }
      ]
    }
  }
  ```
* **Impact on App:**  
  The string `"00"` is a single ASCII byte / ambiguous length string, but the protocol specification expects exactly 2 raw bytes.
* **Required Fix:**  
  Provide an unambiguous 2-byte hexadecimal string or integer value:
  ```json
  {
    "id": "3:Send Data:command-0-enter-text",
    "deviceFrame": {
      "commands": [
        {
          "byteLength": 2,
          "value": "0x0000"
        }
      ]
    }
  }
  ```

---

#### 1.3 Null Control Values in `schema_json.controls[*]` (P2)
* **JSON Path:** `data.schema_json.controls[*]`
* **Current Server Output:**
  ```json
  {
    "id": "1:power:command-2-toggle-switch",
    "name": null,
    "type": null,
    "icon": "gauge",
    "commands": null
  }
  ```
* **Required Fix:**  
  Populate semantic names and control types (e.g., `"name": "Power"`, `"type": "toggle-switch"`).

---

### Issue 2: IoT Dashboard Schema Generator (`iot_api_creation.php`)

**Live Endpoint Tested:**  
`https://efactor.tech/v8/iot_api_creation.php?action=get_iot_schema`

#### 2.1 Hardcoded `columns: 1` under `narrow` Breakpoint (P0)
* **JSON Path:** `schema.components["iot-device-grid"].responsiveLayout.narrow.columns`
* **Current Server Output:**
  ```json
  "responsiveLayout": {
    "narrow": {
      "columns": 1,
      "gap": 10
    },
    "compact": {
      "columns": 2,
      "gap": 12
    }
  }
  ```
* **Impact on App:**  
  Over 60% of modern Android smartphones have a screen width of $360\text{dp}$ (Samsung Galaxy S25, Vivo, Oppo, Xiaomi). When $24\text{dp}$ of horizontal padding is subtracted, available width is $336\text{dp}$, dropping them into `narrow`. As a result, device cards stretch into giant, 1-column full-width banners instead of a clean 2-column grid.
* **Required Fix:**  
  Change `narrow.columns` to **`2`**:
  ```json
  "responsiveLayout": {
    "narrow": {
      "columns": 2,
      "gap": 10
    },
    "compact": {
      "columns": 2,
      "gap": 12
    }
  }
  ```

---

### Issue 3: Grid Schema Generator (`grid_api_creation.php` / `grid.json`)

**Live Endpoint Tested:**  
`https://efactor.tech/v8/grid_api_creation.php?action=get_grid&user_id=655`

#### 3.1 Duplicate `/index.php/index.php/` in Generated Action URLs (P1)
* **JSON Path:** `components[*].actions[*].url` and `components[*].actions[*].route`
* **Current Server Output:**  
  In some live environments, URLs were generated as:
  `https://efactor.tech/index.php/index.php/grid`
* **Required Fix:**  
  Normalize URLs to single root prefixes:
  - Professional Space: `https://efactor.tech/index.php/grid`
  - Circle Connect: `https://efactor.tech/index.php/grid-chat`

---

#### 3.2 Ensure Full-Screen In-App WebView Configuration (P1)
* **JSON Path:** `actions["grid-open-professional-space"]` and `actions["grid-open-circle-connect"]`
* **Required Schema Configuration:**
  ```json
  "grid-open-professional-space": {
    "type": "open-url",
    "url": "https://efactor.tech/index.php/grid",
    "route": "https://efactor.tech/index.php/grid",
    "title": "Professional Space",
    "openIn": "inAppWebView",
    "webView": {
      "javaScriptEnabled": true,
      "sharedCookies": true,
      "clearCache": false,
      "showAppBar": false,
      "showToolbar": false,
      "hideAppBar": true,
      "displayMode": "fullscreen"
    }
  },
  "grid-open-circle-connect": {
    "type": "open-url",
    "url": "https://efactor.tech/index.php/grid-chat",
    "route": "https://efactor.tech/index.php/grid-chat",
    "title": "Circle Connect",
    "openIn": "inAppWebView",
    "webView": {
      "javaScriptEnabled": true,
      "sharedCookies": true,
      "clearCache": false,
      "showAppBar": false,
      "showToolbar": false,
      "hideAppBar": true,
      "displayMode": "fullscreen"
    }
  }
  ```

---

#### 3.3 Status Metric Row & Explore Cards Collapsing to 1 Column on 360dp Phones (P1)
* **JSON Path:** `layoutPolicy.responsive.grid` and components `grid-status-row`, `grid-explore-row`
* **Current Server Output:**
  ```json
  "layoutPolicy": {
    "responsive": {
      "grid": {
        "narrowScreenThresholdDp": 340,
        "narrowScreenMaxColumns": 1
      }
    }
  }
  ```
* **Required Fix:**
  - In `layoutPolicy.responsive.grid`, set `"narrowScreenMaxColumns": 2`.
  - In `grid-status-row.layout.responsive.narrow`, set `"columns": 3`.
  - In `grid-explore-row.layouts.narrow`, set `"columns": 2`.

---

### Issue 4: Home Dashboard Schema Generator (`api_creation.php`)

**Live Endpoint Tested:**  
`https://efactor.tech/v8/api_creation.php?action=get_schema&user_id=655`

#### 4.1 Boundary Split at 359/360dp Fracturing Layouts (P2)
* **JSON Path:** `schema.responsive.breakpoints`
* **Current Server Output:**
  ```json
  "breakpoints": {
    "narrow": { "minimumWidth": 0, "maximumWidth": 359 },
    "compact": { "minimumWidth": 360, "maximumWidth": 599 }
  }
  ```
* **Required Fix:**  
  Align mobile breakpoints so all handheld smartphones ($0\text{dp} - 599\text{dp}$) are uniformly treated as `compact`:
  ```json
  "breakpoints": {
    "compact": {
      "minimumWidth": 0,
      "maximumWidth": 599,
      "description": "Smartphones"
    },
    "medium": {
      "minimumWidth": 600,
      "maximumWidth": 1023,
      "description": "Tablets"
    },
    "expanded": {
      "minimumWidth": 1024,
      "description": "Desktop"
    }
  }
  ```
