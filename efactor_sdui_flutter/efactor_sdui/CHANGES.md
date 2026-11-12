# CHANGES.md — Project Context & Change Log

> **Purpose.** This file is the single source of truth an AI agent (or developer) should read **before analyzing the codebase**, to understand the architecture, the non-obvious constraints, and the recent changes — without re-scanning the whole project. Keep it updated whenever a meaningful change is made. It is safe to export to another AI agent as a project primer.
>
> **How to use it (for AI agents):** Read this file first. Only open the specific files it points to for the task at hand. When you change behavior, add an entry to the **Change Log** and update the relevant **Subsystem** / **Cross-team contract** section.

---

## 1. Project overview

- **App:** `efactor_sdui` — a Flutter **Server-Driven UI (SDUI)** app. Most screens are rendered from JSON schemas fetched from the backend (`https://efactor.tech`), not hardcoded.
- **Package / bundle id:** `com.example.efactor_sdui` (Android namespace + applicationId). iOS bundle id used in builds: `com.efactor.sdui`.
- **Version:** `0.1.0+4` (`pubspec.yaml`).
- **Backend base URL:** `https://efactor.tech`.
- **Key plugins (pinned):** `webview_flutter ^4.14.1`, `webview_flutter_android ^4.14.1`, `webview_flutter_wkwebview ^3.26.1`, `connectivity_plus ^6.0.3`, `crypto ^3.0.7`, `shared_preferences ^2.3.2`, `path_provider ^2.1.2`, `http ^1.2.2`, `firebase_messaging ^15.2.10`, `cached_network_image ^3.4.1`, `permission_handler ^11.3.1`.

### Directory map (`lib/`)
| Dir | Responsibility |
|---|---|
| `main.dart` | App entry; `MaterialApp` wired to `ThemeController` (theme) |
| `core/` | Cross-cutting singletons, incl. `theme_controller.dart` (app-wide light/dark/system) |
| `sdui/` | Core SDUI engine: `component_registry.dart`, image cache, shared renderers |
| `home_sdui/` | Home surface (IoT/Grid/Profile tabs): schema state, renderer, adapter, validator |
| `grid_sdui/` | GRID + **Circle Connect / Professional Space** WebView + offline engine |
| `iot_sdui/` | IoT dashboard SDUI |
| `wifi_sdui/` | Wi-Fi provisioning SDUI |
| `auth_sdui/` | Auth gate / login |
| `device_sdui/`, `data/`, `services/`, `state/`, `utils/` | Supporting SDUI, services (cache, push, outbox), shared state, helpers |

---

## 2. Subsystems & non-obvious facts

### 2.1 Circle Connect & Professional Space (WebView)
- **Both are the SAME widget**: `lib/grid_sdui/grid_in_app_webview_page.dart` (`GridInAppWebViewPage`) loading a React web app inside a `webview_flutter` WebView.
  - **Circle Connect (chat)** = `https://efactor.tech/index.php/grid-chat` → detected by `_isCircleConnect` (path/title contains `chat`/`circle`/`grid-chat`).
  - **Professional Space** = `https://efactor.tech/index.php/grid` → `_isProfessionalSpace`.
- SSO: URLs carry a one-time `grid_sso` token; the server consumes it and redirects to the clean path.
- **Native ↔ web bridges** (JS channels, must be preserved): `CircleConnectPushBridge`, `CircleConnectMediaBridge`, `CircleConnectFileBridge`, `CircleConnectOutboxBridge`, `CircleConnectChannelsBridge`, `CircleConnectNavBridge`, `SnapshotCaptureBridge`. Web-facing shims: `window.CircleConnectMedia/Files/Outbox/Push`.
- Android native file/media: `android/app/src/main/kotlin/com/example/efactor_sdui/MainActivity.kt` channel `tech.efactor/circle_connect` (saveImageToGallery/saveVideoToGallery/openFile/saveFileToDownloads via MediaStore).

### 2.2 Offline architecture (WhatsApp-style) — **per-platform hybrid**
Flag: `_restoreDomSnapshotOffline` in `grid_in_app_webview_page.dart` (currently **`false`** = use the web engine, not DOM snapshots).

- **Android (offline Circle Connect):** reload the **live origin URL**; the web app's **Service Worker** (`/index.php/grid-chat/sw.js`) serves the cached shell + assets and React reads **IndexedDB `CircleConnectDB`**. (Android WebView runs Service Workers.)
- **iOS (offline Circle Connect):** WKWebView **cannot run Service Workers**, so it loads the web team's **self-contained offline shell** (one ~11.4 MB inlined HTML) via `loadHtmlString(..., baseUrl: https://efactor.tech/index.php/grid-chat)`. Managed by `lib/grid_sdui/grid_offline_shell_service.dart` (fetch manifest → compare `buildId` → download → SHA-256 verify → atomic user-scoped store). Synced online in `onPageFinished` via `_syncOfflineShellIfIOS()`.
- **Professional Space / non-chat offline:** clean "Internet Connection Required" screen (no in-page offline engine). **Do NOT load the live URL offline for these.**
- **CRITICAL constraint:** IndexedDB/Cache are **origin-scoped**. Offline rendering MUST keep the real `efactor.tech` origin (live URL on Android; `loadHtmlString` with `baseUrl=origin` on iOS). Switching to `file://` would orphan `CircleConnectDB`.
- **First-sync rule:** offline only shows data cached during a prior **online** session (a chat caches after being opened once online). Live features (calls, presence, new inbound msgs) need a connection; offline sends are queued via the **offline outbox** and synced on reconnect.
- **Legacy DOM-snapshot path** (only when `_restoreDomSnapshotOffline=true`): captures script-stripped `document.documentElement.outerHTML` via `SnapshotCaptureBridge` (JS channel — avoids Android's `runJavaScriptReturningResult` truncation on >1 MB), stored by `grid_web_snapshot.dart` (account-scoped, cleared on logout). Kept as a fallback only.

### 2.3 Theme / appearance (app-wide light/dark/system)
- **Single source of truth:** `lib/core/theme_controller.dart` (`ThemeController.instance`). Drives `MaterialApp.themeMode`. Persists to SharedPreferences. **Never changes the phone OS theme** (in-app only).
- **Server-driven:** `lib/home_sdui/dynamic_home_sdui_page.dart` `_syncAppearanceFromSchema()` reads `state.global.themeMode` ?? `themes.activeMode` and calls `ThemeController.applyServerMode()`.
  - Precedence: `followSystem`/`watchOsAppearance` **or** `themeMode==system` → follow OS; else `light`/`dark` forces that mode (ignores OS). `overrideSystemBrightness` is a helper only — ignored when `themeMode`/`followSystem` present.
  - `applyServerMode` has a **5-second guard** so a background schema refetch cannot revert a theme the user just changed.
- **Brightness-aware rendering** (`lib/home_sdui/home_sdui_renderer.dart`):
  - Home header logo swaps by resolved brightness: `logo.imageUrl`/`imageUrlDark` and `appearanceLight`/`appearanceDark.logoUrl` (dark → `efactor-logo_light.png`).
  - `_inlineTypography` prefers `colorLight`/`colorDark` over a baked single `color` (fixes invisible dark-navy title on dark bg).
  - Bottom nav reads `backgroundColor/active/inactiveColor{Light,Dark}` (fixes white nav bar in dark mode), falling back to brightness-aware design tokens (`themes.presets.{light,dark}.colors.*`). Active icon AND label share ONE `activeColor`.
- **No route reset on theme save/schema refresh:** `apply-theme-preset` host action is a no-op; `save-profile-preferences` only calls `setMode`; schema refresh preserves `activeRouteId` (only changes if the route was removed).

### 2.4 SDUI schema fetch & refresh
- Home schema: `GET https://efactor.tech/v8/api_creation.php?action=get_schema&user_id=<id>`. GRID schema: `grid_api_creation.php?action=get_grid`.
- Schemas are disk-cached (`SchemaDiskCache` / `files/efactor/schema_cache/v1/`) and have an **offline fallback to the last saved schema**.
- Background `DIRECT_UPDATE` poll (~10s) applies deltas without a full reload and **preserves the current tab**.

---

## 3. Cross-team server contracts & dependencies (app can't fix these)

| Area | Endpoint / contract | Owner | Status note |
|---|---|---|---|
| Circle Connect SW (Android offline) | `GET /index.php/grid-chat/sw.js` + the page must call `navigator.serviceWorker.register(...)` **unconditionally** (was gated behind Web-Push `PushManager`, which WebViews lack) | Web/Circle Connect team | Fix confirmed shipping; verify `registrations>0` after deploy |
| iOS offline shell | `GET /index.php/grid-chat/offline-shell/manifest` (`{buildId, sha256, shellUrl, minimumHostVersion}`, may be wrapped in `{success,data}` or flat — app accepts both) + `GET /index.php/grid-chat/offline-shell` (ETag=sha256, If-None-Match 304, gzip) | Web/Circle Connect team | Endpoints deployed |
| Professional Space | `GET /index.php/grid` crashes server-side → returns a "GRID error" page (`[GRID page crash] /grid/index`); set `grid_debug` cookie to see cause | GRID / Professional Space backend | **Open bug — app renders exactly what server returns** |
| Theme schema | Home schema sends explicit `*Light/*Dark` keys + `themes.presets`; `profile-preferences`/`apply-theme-preset` carry `reloadSchema:false, preserveNavigation:true, keepCurrentRoute:true` | Backend | Confirmed aligned |

**Diagnosing a WebView "blank/not opening" page:** pull the saved snapshot from the device to see the exact DOM the server returned:
`adb exec-out run-as com.example.efactor_sdui cat files/efactor/schema_cache/v1/web_snapshot_professional_space_user_<id>.html`

---

## 4. Build / run / test

```bash
# from efactor_sdui_flutter/efactor_sdui
flutter pub get
flutter analyze lib/<path>                 # fast per-file analysis
flutter run -d <device-id> --debug         # build+install+logstream (may drop "Lost connection")
flutter build apk --debug                  # build APK only (ready to install later)
adb -s <id> logcat -v brief flutter:I '*:S'  # stable device logs independent of `flutter run`
```
- **Release build:** `isMinifyEnabled` NOT set → R8/ProGuard shrinking OFF (release ≈ debug code-wise); release uses debug signing.
- **iOS log streaming** via `flutter run` can fail with a macOS **Local Network** permission error (`No route to host`) — grant it to Terminal, or test the installed app directly.
- **Device gotchas:** Android devices used in testing drop off USB intermittently; prefer `adb logcat` over `flutter run` for log capture. Signature-mismatch on install → Flutter auto-uninstalls + reinstalls (wipes app data incl. cached SW/IndexedDB — a fresh online visit is then required before offline works).

---

## 5. Conventions & gotchas
- **Don't disturb working behavior.** All offline/theme changes are additive and fall back to prior behavior when a schema key is absent.
- **Theme is schema-driven, not hardcoded.** Add colors/logos via schema keys/tokens, not literals.
- Large JS→Dart returns on Android truncate: use a **JavaScript channel** (`postMessage`), not `runJavaScriptReturningResult`, for payloads >1 MB.
- Logout clears account-scoped offline data: snapshots (`GridWebSnapshot.clearUserSnapshots`), offline shell (`GridOfflineShellService.clear`), media cache — see `lib/services/app_cache_manager.dart`.
- Related architecture doc: `docs/OFFLINE_FIRST_ARCHITECTURE_GUIDE.md`.

---

## 6. Change Log (newest first)

> Add an entry per meaningful change: commit, what/why, and any key files.

### 2026-11-12
- **`eb5ac7f` feat(theme): brightness-aware home header, bottom nav, inline text colors.**
  - Home header logo swaps by resolved brightness (`logo.imageUrl`/`imageUrlDark`, `appearanceLight`/`appearanceDark.logoUrl`).
  - `_inlineTypography` prefers `colorLight`/`colorDark` over baked `color` (fixed invisible title in dark mode).
  - Bottom nav reads `backgroundColor/active/inactiveColor{Light,Dark}` (fixed white nav bar in dark mode).
  - `_syncAppearanceFromSchema` honors `followSystem`/`watchOsAppearance`.
  - Files: `lib/home_sdui/home_sdui_renderer.dart`, `lib/home_sdui/dynamic_home_sdui_page.dart`. Verified on-device; aligned with backend contract.
- **`4935708` fix(circle-connect): accept flat or wrapped offline-shell manifest.** `grid_offline_shell_service.dart` manifest parser reads `data` if present else the top-level body.
- **`8b79973` Merge: restore per-platform Circle Connect offline flow** (`5525787` + `6640f47` + `b48d0f0`). Android = Service Worker; iOS = self-contained shell (`grid_offline_shell_service.dart`, new); Professional Space = clean offline screen. Adds `crypto` dep + logout clearing.
- **`025090c` / `53f31b8` / `0809c95`** earlier Circle Connect offline work: snapshot capture via JS channel (Android-safe, iOS too), early offline marker injection, iOS local saving restore.

### Known-open (not app-side)
- Professional Space `/grid/index` server crash (GRID backend team).
- Circle Connect Android offline depends on the web team's SW registration deploy going live.
