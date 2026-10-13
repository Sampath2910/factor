# Live Server SDUI Schema Issues Report

**Document Version:** 1.0  
**Date:** October 8, 2026  
**Audience:** Backend Engineering Team, SDUI Schema Authors, API Developers  
**Host Tested:** `https://efactor.tech`  
**Purpose:** Formal defect report of live schema contracts retrieved directly from production server endpoints, detailing exact JSON paths, observed behavior on mobile devices, and required schema fixes.

---

## Executive Summary

Live schema payloads fetched directly from `https://efactor.tech` were analyzed against mobile rendering requirements. Several backend-side schema defects were identified that directly impact device navigation, command serialization, and responsive UI rendering on standard smartphones:

1. **Device Schema (`api_schema.php`)**: Multi-page devices (e.g., `EF-003FMN03`, `EF-001FMN01`) declare multi-page structures in `schema.pages`, but the server omits secondary pages from `deviceConfig.devices[0].pages`, breaking hardware frame serialization beyond Page 1. Furthermore, all 21 controls in `schema.controls` return `null` for `name`, `type`, and `commands`.
2. **IoT Schema (`iot_api_creation.php`)**: The server explicitly forces `"columns": 1` under the `narrow` breakpoint. Because 360dp smartphones (such as Samsung Galaxy S25) have horizontal padding subtracted, they fall below 360dp and collapse into single-column vertical banners instead of the intended 2-column grid.
3. **Grid Schema (`grid_api_creation.php`)**: Declares `narrowScreenMaxColumns: 1` and `"narrow": {"columns": 1}`, collapsing status cards and explore grids into single-column layouts on standard 360dp phones.
4. **Home Schema (`api_creation.php`)**: Defines an artificial breakpoint boundary at 359/360dp, causing standard 360dp phones with container padding to lose their `compact` rules.

---

## Detailed Defects by Server Endpoint

### 1. Device Schema Endpoint: `api_schema.php`

* **Live URL Tested:**  
  * `https://efactor.tech/v8/api_schema.php?model_no=EF-003FMN03&node_id=1`
  * `https://efactor.tech/v8/api_schema.php?model_no=EF-001FMN01&node_id=7E0003A6`

#### Defect 1.1: Missing Multi-Page Configurations in `deviceConfig.devices[0].pages`
* **JSON Path:** `data.schema_json.deviceConfig.devices[0].pages`
* **Current Live Response:**
  * For model `EF-003FMN03`: The root `schema_json.pages` declares **6 pages** (`page_1` through `page_6`), but `deviceConfig.devices[0].pages` lists **only Page 1**:
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
  * For model `EF-001FMN01`: Root `schema_json.pages` declares **3 pages** (`Page1.Operation`, `Page0`, `Page3`), but `deviceConfig.devices[0].pages` lists only `"Page1.Operation"`. Pages 0 and 3 are missing.
* **Impact on Mobile App:**  
  When users swipe or tap to navigate to Page 2, 3, etc., hardware protocol frame parsing fails because the backend omitted the hardware definitions for those pages.
* **Required Backend Fix:**  
  Publish all page definitions inside `deviceConfig.devices[0].pages`:
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

#### Defect 1.2: All Controls in `schema_json.controls` Return `null`
* **JSON Path:** `data.schema_json.controls[*]`
* **Current Live Response:**  
  Every control in the live array returns `null` for `name`, `type`, and `commands`:
  ```json
  {
    "id": "1:power:command-2-toggle-switch",
    "name": null,
    "type": null,
    "icon": "gauge",
    "commands": null
  }
  ```
* **Impact on Mobile App:**  
  The app must execute defensive fallbacks to deduce types and bindings, rather than relying on clean schema declarations.
* **Required Backend Fix:**  
  Populate semantic names, valid control types (e.g., `"toggle-switch"`, `"slider"`), and protocol commands.

---

#### Defect 1.3: Missing `icon` on Live Status Controls
* **JSON Path:** `data.schema_json.controls[id="1:get_status:..."]`
* **Current Live Response:**  
  Controls `1:get_status:command-3-auto-trigger-with-timer` and `1:get_status:response-2-toggle-switch` through `response-6-toggle-switch` return `"icon": null`.
* **Required Backend Fix:**  
  Provide semantic icon tokens (e.g., `"gauge"`, `"bolt"`, `"timer"`).

---

### 2. IoT Schema Endpoint: `iot_api_creation.php`

* **Live URL Tested:**  
  `https://efactor.tech/v8/iot_api_creation.php?action=get_iot_schema`  
  *(Header: `X-IOT-Access-Token: <token>`)*

#### Defect 2.1: Hardcoded `columns: 1` on `narrow` Breakpoint in `deviceGrid`
* **JSON Path:** `schema.components[id="iot-device-grid"].responsiveLayout.narrow.columns`
* **Current Live Response:**
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
  Combined with:
  ```json
  "breakpoints": {
    "narrow": { "minimumWidth": 0, "maximumWidth": 359 },
    "compact": { "minimumWidth": 360, "maximumWidth": 599 }
  }
  ```
* **Impact on Mobile App:**  
  Over 60% of Android phones have a screen width of $360\text{dp}$. When horizontal page padding ($12\text{dp} + 12\text{dp} = 24\text{dp}$) is deducted, available width is **$336\text{dp}$**.  
  Because $336\text{dp} < 360\text{dp}$, the backend schema automatically demotes standard phones (Samsung Galaxy S25, Vivo, Oppo, Redmi) into `narrow`, collapsing device cards into a **single vertical column** of stretched banners. Only phones $\ge 384\text{dp}$ (such as Realme Narzo 30 at $392\text{dp}$) displayed the 2-column grid.
* **Required Backend Fix:**  
  IoT device cards easily fit in 2 columns on all mobile screens down to $320\text{dp}$. Set `narrow.columns` to **`2`**:
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

### 3. Grid Schema Endpoint: `grid_api_creation.php`

* **Live URL Tested:**  
  `https://efactor.tech/v8/grid_api_creation.php?action=get_grid&user_id=655`

#### Defect 3.1: Server Sets `narrowScreenMaxColumns: 1` and Collapses Status Summaries
* **JSON Path:** `layoutPolicy.responsive` and `components[*].layouts.narrow`
* **Current Live Response:**
  ```json
  "layoutPolicy": {
    "responsive": {
      "breakpoints": {
        "narrow": { "maxWidth": 359 },
        "compact": { "minWidth": 360, "maxWidth": 599 }
      },
      "grid": {
        "narrowScreenThresholdDp": 340,
        "narrowScreenMaxColumns": 1
      }
    }
  }
  ```
  And in components:
  * `grid-status-row` (`statusSummary`):  
    `"narrow": { "columns": 1 }`, `"compact": { "columns": 3 }`
  * `grid-feature-row` and `grid-explore-row` (`responsiveGrid`):  
    `"narrow": { "columns": 1 }`, `"compact": { "columns": 2 }`
* **Impact on Mobile App:**  
  On standard $360\text{dp}$ phones, status metrics collapse from 3 horizontal chips into a tall 1-column stack, and explore cards collapse into full-width vertical cards.
* **Required Backend Fix:**
  * In `layoutPolicy.responsive.grid`, set `"narrowScreenMaxColumns": 2`.
  * In `grid-status-row.layout.responsive.narrow`, set `"columns": 3`.
  * In `grid-explore-row.layouts.narrow`, set `"columns": 2`.

---

### 4. Home Schema Endpoint: `api_creation.php`

* **Live URL Tested:**  
  `https://efactor.tech/v8/api_creation.php?action=get_schema&user_id=655`

#### Defect 4.1: Flawed Breakpoint Boundary at 359/360dp
* **JSON Path:** `schema.responsive.breakpoints`
* **Current Live Response:**
  ```json
  "breakpoints": {
    "narrow": {
      "minimumWidth": 0,
      "maximumWidth": 359,
      "description": "Small phones"
    },
    "compact": {
      "minimumWidth": 360,
      "maximumWidth": 599,
      "description": "Phones"
    }
  }
  ```
* **Impact on Mobile App:**  
  Splitting `narrow` and `compact` at $359 / 360\text{dp}$ fractures layout consistency across smartphones because any internal margin or padding drops a $360\text{dp}$ phone into `narrow`.
* **Required Backend Fix:**  
  Align mobile breakpoints so all handheld smartphones ($0\text{dp} - 599\text{dp}$) belong to the **`compact`** tier:
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

---

## Action Items Summary for Backend Team

| Priority | Endpoint | Location in JSON | Required Action |
| :---: | :--- | :--- | :--- |
| **P0** | `api_schema.php` | `data.schema_json.deviceConfig.devices[0].pages` | Add definitions for Pages 2 through 6 (currently only Page 1 is sent). |
| **P0** | `iot_api_creation.php` | `deviceGrid.responsiveLayout.narrow.columns` | Change from `1` to `2`. |
| **P1** | `grid_api_creation.php` | `layoutPolicy.responsive.grid.narrowScreenMaxColumns` & component layouts | Change `narrowScreenMaxColumns` to `2`; set `statusSummary` narrow columns to `3`; set `responsiveGrid` narrow columns to `2`. |
| **P1** | `api_schema.php` | `data.schema_json.controls[*]` | Provide non-null `name`, `type`, `commands`, and `icon` values. |
| **P2** | `api_creation.php` | `schema.responsive.breakpoints` | Merge phone tiers so $0\text{dp} - 599\text{dp}$ is uniformly `compact`. |
