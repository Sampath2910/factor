# Server-Driven UI (SDUI) API Reference

This document specifies the REST API endpoints used by the E-Factor IoE Design Studio editor and mobile app to fetch, design, and configure Server-Driven UI schemas.

---

## Authentication Mechanism
All dashboard and write endpoints require cookie-based session authentication:
- **Cookie**: `ci_session=<session_id>`
- To get this session cookie, developers must authenticate using the dashboard sign-in endpoint.

---

## 1. Get Device UI Schema
Fetches the current Server-Driven UI schema containing colors, layouts, page routing, and registered controls for a given device model.

- **URL Pattern**: `https://efactor.tech/api/device-ui-schema/{modelNo}`  
  *(Alternative URL: `https://efactor.tech/index.php/api/device-ui-schema/{modelNo}`)*
- **HTTP Method**: `GET`
- **Authentication**: None required (public GET endpoint)
- **Parameters**: 
  - `{modelNo}` (string, path parameter): The identifier of the device model (e.g., `STUDIO_9_7`).
- **Response Format**: `application/json`
- **Response Shape**:
  ```json
  {
    "schemaVersion": "4.0.0",
    "schemaType": "device-ui",
    "generatedAt": "2026-07-13T10:36:14.389Z",
    "rendering": { ... },
    "meta": {
      "app": {
        "id": "efactor_studio_9_7",
        "name": "STUDIO_9_7 Control",
        "modelNo": "STUDIO_9_7",
        "modalId": 284,
        "entryWidgetId": "phone_shell"
      },
      "links": {
        "schema": "https://efactor.tech/index.php/api/device-ui-schema/STUDIO_9_7",
        "parameters": "https://efactor.tech/index.php/api/device-ui-schema/STUDIO_9_7/parameters",
        "deviceInfo": "https://efactor.tech/index.php/api/device-ui-info/STUDIO_9_7",
        "editPageLinking": "https://efactor.tech/index.php/items/api_page_linking/284?modelno=STUDIO_9_7"
      }
    },
    "theme": {
      "mode": "light",
      "colors": {
        "background": "#D1FAFF",
        "surface": "#FFFFFF",
        "text": "#102A3A",
        "mutedText": "#5F7482",
        "accent": "#157145",
        "primary": "#157145",
        "success": "#10B981",
        "warning": "#F59E0B",
        "error": "#EF4444",
        "border": "#DCE8EF",
        "topbar": "#123246",
        "toggleOn": "#157145",
        "toggleOff": "#B8C8D0"
      },
      "spacing": { ... },
      "typography": { ... },
      "radius": { ... },
      "shadows": { ... }
    },
    "icons": { ... },
    "components": [ ... ],
    "registerComponents": [ ... ],
    "controls": [ ... ],
    "pages": [ ... ],
    "ui": {
      "widgetTree": { ... }
    }
  }
  ```
- **Observed Status Codes**:
  - `200 OK`: Request succeeded.
  - `404 Not Found` / `500 Internal Server Error`: For invalid model numbers.

---

## 2. Save Device UI Theme & Schema
Updates the visual design (theme settings) and layout (widget tree/controls configuration) for a given device model.

- **URL Pattern**: `https://efactor.tech/index.php/items/save_view_page_ui_theme`
- **HTTP Method**: `POST`
- **Authentication**: Required (`ci_session` cookie)
- **Content-Type**: `application/x-www-form-urlencoded` or `multipart/form-data`
- **Request Body Fields**:
  - `modelno` (string, required): The target device model name (e.g. `STUDIO_9_7`).
  - `theme_json` (string, required): A JSON-stringified representation of the theme settings.
  - `schema_json` (string, required): A JSON-stringified representation of the full SDUI schema.
- **Request Body Shape (theme_json)**:
  ```json
  {
    "themeMode": "light",
    "backgroundType": "solid",
    "backgroundColor": "#D1FAFF",
    "gradientColor": "#F7FDFF",
    "shellColor": "#F7FDFF",
    "cardColor": "#FFFFFF",
    "textColor": "#102A3A",
    "mutedTextColor": "#5F7482",
    "topbarColor": "#123246",
    "accentColor": "#157145",
    "secondaryColor": "#9BD1E5",
    "toggleOnColor": "#157145",
    "toggleOffColor": "#B8C8D0",
    "iconStyle": "signal",
    "parameterIcon": "gauge",
    "parameterIcons": {},
    "fontFamily": "Poppins",
    "fontSize": 14,
    "fontWeight": 700,
    "letterSpacing": 0,
    "lineHeight": 1.35,
    "textAlign": "left",
    "buttonBgColor": "#157145",
    "buttonTextColor": "#FFFFFF",
    "successColor": "#10B981",
    "warningColor": "#F59E0B",
    "errorColor": "#EF4444",
    "iconSize": 20,
    "iconColor": "#157145",
    "headerHeight": 84,
    "headerText": "",
    "headerAlignment": "left",
    "showHeaderIcons": "1",
    "showStatus": "1",
    "borderSize": 1,
    "borderColor": "#DCE8EF",
    "borderRadius": 18,
    "shadowStrength": 70,
    "cardBlur": 0,
    "pagePadding": 18,
    "cardPadding": 16,
    "cardMargin": 0,
    "cardSpacing": 14,
    "buttonText": "Save Changes",
    "buttonSize": 44,
    "buttonRadius": 16,
    "buttonHover": "lift",
    "buttonIconPosition": "left",
    "buttonTarget": "save",
    "brandVisible": "1",
    "heroVisible": "1",
    "footerVisible": "1",
    "deviceMode": "mobile",
    "pageType": "Control Page",
    "headerStyle": "Gradient",
    "componentOverrides": [],
    "controlOrder": []
  }
  ```
- **Request Body Shape (schema_json)**:
  Full widget tree schema JSON matching the GET output.
- **Response Format**: `application/json`
- **Response Shape**:
  ```json
  {
    "success": true,
    "message": "UI created successfully.",
    "api_url": "https://efactor.tech/index.php/api/device-ui-schema/STUDIO_9_7"
  }
  ```
- **Observed Status Codes**:
  - `200 OK`: Request saved successfully.
  - `4xx / 500`: When model is invalid or schema payload is corrupted.

---

## 3. Submit API Page Linking Parameters
Saves page parameter configurations mapping pages to specific device parameter nodes.

- **URL Pattern**: `https://efactor.tech/index.php/items/submit_page_params`
- **HTTP Method**: `POST`
- **Authentication**: Required (`ci_session` cookie)
- **Request Body Fields**:
  - `modelno` (string, required): Target model (e.g. `STUDIO_9_7`).
  - `modal_id` (string, required): Modal identifier (e.g. `284`).
  - `config_keys[]` (array of strings, optional): Config parameters.
  - `config_values[]` (array of strings, optional): Config values.
  - `node_ids` (string, comma-separated list, optional): Associated nodes.
  - `router_id` (string, optional): Gateway router ID.
  - `status` (string, optional): Associated device status.
- **Observed Status Codes**:
  - `200 OK`: Configuration saved successfully.

---

## 4. Device UI Scan Result (QR)

Dedicated API for mobile QR scan values. This is **separate** from the full UI schema API.

### Base URL
```
http://efactor.tech/index.php/api/device-ui-scan/{modelId}/{nodeId}/scan
```

The body is **only the scan-result schema** (not theme / widgetTree / controls).

### 4.1 Save scan (mobile app → server)

- **HTTP Method**: `POST`
- **Authentication**: None required (same as schema GET) unless your server adds it
- **Content-Type**: `application/json`
- **Request Body (scan schema only)**:
  ```json
  {
    "schemaType": "device-ui-scan",
    "schemaVersion": "1.0.0",
    "modelId": "STUDIO_9_7",
    "nodeId": "NODE123",
    "value": "THE_QR_STRING",
    "format": "qr",
    "scannedAt": "2026-07-25T12:00:00.000Z"
  }
  ```
- **Expected Response**:
  ```json
  {
    "success": true,
    "message": "Scan saved.",
    "schemaType": "device-ui-scan",
    "schemaVersion": "1.0.0",
    "modelId": "STUDIO_9_7",
    "nodeId": "NODE123",
    "value": "THE_QR_STRING",
    "format": "qr",
    "scannedAt": "2026-07-25T12:00:00.000Z"
  }
  ```

### 4.2 Get latest scan (web / Studio → server)

- **HTTP Method**: `GET`
- **Authentication**: None required (or session if you prefer)
- **Response** (same scan schema):
  ```json
  {
    "schemaType": "device-ui-scan",
    "schemaVersion": "1.0.0",
    "modelId": "STUDIO_9_7",
    "nodeId": "NODE123",
    "value": "THE_QR_STRING",
    "format": "qr",
    "scannedAt": "2026-07-25T12:00:00.000Z"
  }
  ```

### Web usage example
```js
const modelId = "STUDIO_9_7";
const nodeId = "NODE123";
const res = await fetch(
  `http://efactor.tech/index.php/api/device-ui-scan/${encodeURIComponent(modelId)}/${encodeURIComponent(nodeId)}/scan`
);
const data = await res.json();
console.log(data.value); // QR string only
```

### Backend note
Implement this route on the server. Store the latest scan schema per `modelId` + `nodeId`, overwrite on each POST, return it on GET. Do **not** mix this with the full `device-ui` schema.

