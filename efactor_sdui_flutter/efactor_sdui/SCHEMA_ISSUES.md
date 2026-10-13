# eFactor SDUI — Schema issues for Backend (precise)

**Date:** 22 Sep 2026  
**Audience:** Backend / schema authors  
**Client policy:** Flutter renders **schema only**. Missing fields show an on-screen **Schema error** (path named below).  

**Client hardcodes that stay (do not ask backend to own these):**
- API host defaults (`String.fromEnvironment`)
- Scanner UI (`scanner_page.dart`)
- Device loader branding (`efactor_device_loader.dart`: orange `#F15A24`, track `#D1D5DB`, dark screen `#0B1220`)
- Location permission gate UI (`location_startup_gate.dart`: `#F7F8FA` / `#2563EB` / `#B91C1C`)
- Schema-error chrome (Theme / error widgets)

---

## How to use this file

Each item is something the **app will show as a schema error** if the field is missing or invalid. Fix the listed JSON path / shape so the error disappears.

---

## 1. App shell / live Device schema (`main.dart`)

| Error title | Exact field(s) to provide |
|-------------|---------------------------|
| Schema typography missing | `theme.typography.fontFamily` **or** `extensions.serverDrivenUi.theme.fontFamilies.body.family` |
| Schema color missing | `theme.colors.background` **and** `theme.colors.primary` (valid colors) |
| Schema typography unsupported | Font family string that Google Fonts can resolve |
| Schema meta missing | `meta.app.name` |
| Schema color missing (device frame) | `theme.colors.background` |
| Schema entry missing | Valid schema entry / root for the loaded screen |
| Live schema could not be loaded | API must return a successful schema payload (network/auth/signature) |

---

## 2. Auth schema

| Error title | Exact field(s) to provide |
|-------------|---------------------------|
| Current page missing | `pages[]` must include the current page |
| Auth layout missing | Layout definition for the current auth page |
| Schema color missing | `desktop.phone.backgroundColor` |
| Schema color missing | `components.<id>.style.color` |
| Schema color missing | `components.<id>.style.backgroundColor` / related style colors used by that component |
| Schema color missing | `components.<id>.style.iconColor` |
| Schema color missing | `components.<id>.trailingAction.style.textColor` |
| Schema color missing | `components.<id>.levels[].color` (password strength / level UI) |
| Auth icon / Password icon missing | Icon name/asset fields on the component |
| Style colors missing | All colors listed in the error detail (path printed as `style.<name>`) |

---

## 3. Home schema

### 3.1 Responsive metro / grid layouts (phones)

**Symptom:** Schema issue naming `layouts.<breakpoint>`.

**Fix:** For every `responsiveGrid` / metro component, for **each** breakpoint the client can select (`narrow`, `compact`, `medium`, `expanded`, …), publish:

```json
"layouts": {
  "narrow":  { "columns": 2, "columnGap": 8, "rowGap": 8, "rowHeight": 88 },
  "compact": { "columns": 4, "columnGap": 10, "rowGap": 10, "rowHeight": 96 }
}
```

Also publish responsive policy (recommended):

```json
"responsive": {
  "grid": {
    "narrowScreenThresholdDp": 360,
    "narrowScreenMaxColumns": 2,
    "minimumCellWidthDp": 140,
    "clampColumnSpanToColumns": true,
    "preserveMetroColumnsOnNarrow": false
  },
  "overflowPolicy": { "headerText": "ellipsis", "default": "ellipsis" }
}
```

### 3.2 Design tokens / visual contracts

| Error / message pattern | Provide |
|-------------------------|---------|
| `Schema token missing: components.<id>.…` | Named token path in the message |
| `Schema visual contract missing for components.<id>` | Colors, radii, gaps, typography listed in the detail |
| `components.<id>.title is required` | Non-empty title |
| `logo requires imageUrl, width and height` | All three |
| `profileHeader` / `profileMenu` / `avatar` contracts | Full visual + value fields the error lists |
| `items[] is required` | Non-empty `items` array |
| `options[]` / option label fields | Options list + required option properties |
| `layouts.<name> …` | Complete layout object for that breakpoint |
| `faces[]` / device faces | At least one face with required content |
| `itemsSource did not resolve` / empty list | Binding that resolves offline, or empty-state component |
| `loginForm requires …` | Fields listed in the error |
| `Page rootComponentId is missing` | `page.rootComponentId` pointing at an existing component |
| Image card overlay | Per-item `imageOverlayColor` when a dark scrim over the image is desired (client will **not** invent black) |

---

## 4. Grid schema

| Error title | Exact field(s) to provide |
|-------------|---------------------------|
| Schema color missing (page) | `designTokens.colors.pageBackground` **and** `designTokens.colors.textPrimary` |
| Schema layout missing (page) | `layout.padding` and `layout.gap` **or** `layout.responsive.<bp>.*` |
| Schema typography missing | `designTokens.typography.pageTitle` / `pageSubtitle` (size + `colors.textPrimary` / `textSecondary`) |
| Schema layout missing | `appearance.logoHeight` |
| Schema color missing (action) | `action.color` **or** `designTokens.colors.accent` |
| Schema token missing | `designTokens.colors.surface` (or `onAccent`) **and** `action.fontSize` |
| Schema color missing | `designTokens.colors.surface` **and** `colors.textSecondary` |
| Schema layout missing (grid) | `layout.columns`, `layout.columnGap`, `layout.rowGap` (or responsive equivalents) |
| Schema tokens missing (cards/lists) | `appearance.borderRadius`, `layout.minHeight`, `textColor` or `colors.textPrimary`, backgrounds via `appearance.backgroundColor` or `colors.surface`, gaps as named in the error |
| Schema color missing (accent blocks) | `designTokens.colors.accent`, `surface`, `textSecondary` / `textPrimary` |
| Missing Grid component / unsupported type | Component id exists; type supported by Grid renderer |
| `.items[] is required` | Non-empty items |

### 4.1 Grid navigation (in-app)

Every in-app `open-url` must include:

```json
{
  "type": "open-url",
  "url": "https://…",
  "openIn": "inAppWebView",
  "title": "…"
}
```

Home → Grid must use host action `open-grid` / `open-grid-module`, not `external-navigate`, unless opening an external browser is intentional.

### 4.2 Grid QR (offline)

Provide **one of**:

- `shareQr.qrImageUrl`
- `shareQr.qrImageUrlsByMode.<mode>`
- `shareQr.qrImageUrlTemplate` with `{data}` / `{mode}` (your host only)

Client will **not** invent a third-party QR CDN.

### 4.3 Grid API shape

Response must unwrap to an object with **`page`** and **`components`**.

---

## 5. IoT schema

Errors name the missing path directly, e.g.:

| Path shown in UI | Fix |
|------------------|-----|
| `page.header.action/icon` | Header action + icon |
| `icons.<name>` | Icon registry entry |
| `summaryCard.zones[]` / `….fields[]` | Zones and fields |
| `summaryCard icon field.icon` | Icon on that field |
| `deviceGrid.columns` / `layout.grid.columns` | Column count |
| `deviceGrid.card` | Card template |
| `card.zones[].fields[]` / `card.fields.<id>` | Field definitions |
| `card.fields.<id> fallback iconSize` | `iconSize` on fallback |
| `Image URL uses localhost` | Use public HTTPS asset URL (not `localhost`) |
| `statusPill.dot.diameter` | Numeric diameter |

---

## 6. Wi‑Fi provisioning schema

| Error title | Exact field(s) to provide |
|-------------|---------------------------|
| Schema color missing (screen) | `screens.<screenId>.style.backgroundColor`, `textColor`, `accentColor` |
| Schema color missing (component) | Paths listed in details (e.g. `component.style.iconBox.iconColor`) |
| Schema color missing (button text) | `component.style.textColor` **or** `theme.colors.buttonText` |
| Required Wi‑Fi schema path missing | `$.wifiProvisioning` (and nested paths named in the error) |
| Required Wi‑Fi screen missing | Screen id referenced by flow must exist under `screens` |
| Unsupported component / action type | Use types the client implements |

---

## 7. Device / generic SDUI renderer

| Error title | Exact field(s) to provide |
|-------------|---------------------------|
| Schema color missing | `pagerControls.parts.arrowDisabled` `backgroundColor` / `foregroundColor` / `opacity` |
| Schema color missing (fills) | `style.fill.stops[].color` **or** `style.fill.fallbackColor` |
| Schema icon not found | Icon name present in schema icon map / Font Awesome set used by client |
| Other `SchemaIssueWidget` details | Follow the path printed in the red/error banner |

---

## 8. Images / offline data

1. **Stable HTTPS** image URLs (avoid rotating query strings if offline cache should hit).  
2. Prefer hosts declared in `security.allowedAssetDomains` (or equivalent).  
3. Bound lists (`childrenBinding` / `itemsSource`): either cacheable dataSources, or a schema empty-state — do not leave templates that require live data with no offline path.

---

## 9. Acceptance checklist (backend)

- [ ] Device/live schema: `theme.colors.background` + `primary`, font family, `meta.app.name`  
- [ ] Auth: every rendered component has required style colors / icons  
- [ ] Home: full `layouts` for **narrow + compact** (and any other used breakpoints)  
- [ ] Home/Grid/IoT: complete `designTokens` / visual contracts used by each screen  
- [ ] Grid: `openIn: inAppWebView` on in-app links; QR image URL(s); `page` + `components`  
- [ ] IoT: no localhost image URLs; columns + card/zone/field paths complete  
- [ ] Wi‑Fi: screen styles + `wifiProvisioning` tree complete  
- [ ] QA: intentional omission shows **schema error with path**, not a purple/grey invented UI  

---

## 10. Related docs

- `BACKEND_SCHEMA_REQUEST.md` — navigation / offline / QR narrative  
- `SETUP_REPORT.md` — engineer install versions  

Confirm field names if your schema uses different keys so Flutter parsers can be aligned without inventing values.
