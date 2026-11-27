# Circle Connect & Professional Space — App-Side Integration Reference

**Scope:** Everything the **native Flutter host app** (`efactor_sdui`) implements to host the
**Circle Connect** (GRID Chat) and **Professional Space** web builds. These two surfaces are
remote web apps served from `efactor.tech`, embedded in a full-screen `webview_flutter` WebView.
The web teams own the UI inside the WebView; this app owns everything the web cannot do itself:
OS notifications, calls, audio routing, file/media pickers, offline storage, lifecycle, and system
integration.

> Last updated during the session that shipped the app-owned notification banner, the native
> call-audio contract, the picker fixes, and the home route-preservation fix. Items marked
> **⚠ not device-verified** are implemented + unit-tested but not yet confirmed on hardware.

---

## 1. Architecture at a glance

```
            ┌─────────────────────────── Flutter host (this app) ───────────────────────────┐
            │                                                                                │
  Web build │   GridInAppWebViewPage (webview_flutter)                                       │
 (efactor.  │   ├─ 9 JavaScript bridges  (web → native)      api.* capability flags (native → web) │
  tech)  ◄──┼─► ├─ runJavaScript events  (native → web)                                      │
            │   └─ MethodChannel "tech.efactor/circle_connect"  (Dart ↔ Android/iOS native)  │
            │                                                                                │
            │   Services: push/notifications, calls, media/files, offline, location, sounds  │
            │   Native: OngoingCallService, CallAudioController (Android) / AppDelegate (iOS) │
            └────────────────────────────────────────────────────────────────────────────────┘
```

**Three communication layers:**

1. **Web → Native (JavaScript bridges):** 9 `addJavaScriptChannel` bridges on the WebView. The web
   posts JSON `{ action, ... }` messages; the host routes them to services.
2. **Native → Web (events):** the host calls `controller.runJavaScript(...)` to dispatch
   `window.dispatchEvent(new CustomEvent(...))` or call `window.gridChat*` functions, and sets
   `window.CircleConnect*` capability flags so the web knows which native features exist.
3. **Dart ↔ Platform (MethodChannel):** `tech.efactor/circle_connect` carries ~30 methods to the
   Android (`MainActivity` / `CallAudioController` / `OngoingCallService`) and iOS (`AppDelegate` /
   `SceneDelegate`) native layers.

Key host file: **`lib/grid_sdui/grid_in_app_webview_page.dart`** (the WebView host, all bridges,
the native↔web message router).

---

## 2. JavaScript bridges (web → native)

Registered in `grid_in_app_webview_page.dart` (`addJavaScriptChannel`):

| Bridge (`window.*`) | Purpose |
|---|---|
| `CircleConnectPushBridge` | Main control channel: notifications, calls, chat lifecycle, badges, sounds, device/system settings. Handles the bulk of the ~60 actions. |
| `CircleConnectMediaBridge` | Media: resolve cached media URLs, pick from gallery (Photo Picker), save voice notes. |
| `CircleConnectFileBridge` | Documents/files: `pickDocument`, `downloadFile`, `openFile`, `getCachedFile`, `cancelDownload`, `saveFileToDownloads`. |
| `CircleConnectOutboxBridge` | Offline send queue (`enqueue`) — messages composed while offline are stored and replayed. |
| `CircleConnectChannelsBridge` | Offline channel-list persistence (`saveChannelsSnapshot`, `recoverOfflineChannels`). |
| `CircleConnectNavBridge` | In-app navigation requests from the web (`goBack`, `switchTab`). |
| `SnapshotCaptureBridge` | Captures a script-stripped DOM snapshot for offline restore. |
| `ProfessionalSpaceBridge` | Professional-Space-specific host requests. |
| `GridLifecycleBridge` | WebView/page lifecycle signalling (`ready`, visibility). |

### Full action list (web → native)

Routed from the push bridge message handler. Grouped by feature:

- **Device key / security:** `setDeviceKey`
- **Notifications & badges:** `badgeUpdate`, `clearNotifications`, `clearChatNotifications`,
  `setActiveConversation`, `clearActiveConversation`, `activeConversationChanged`,
  `openNotificationSettings`
- **Chat lifecycle / handoff:** `chatUiReady`, `conversationOpened`, `conversationClosed`
- **Incoming calls:** `startRinging`, `stopRinging`, `callUiReady`, `incomingCallDisplayed`,
  `callStarted`, `callConnected`, `callActive`, `callEnded`
- **Outbound call telemetry:** `outboundCallAttempt`, `outboundCallResponse`, `outboundCallError`,
  `callSignalLog`, `callIceLog`
- **Call audio (native-owned):** `startCallAudio`, `endCallAudio`, `getCallAudioRoutes`,
  `setCallAudioRoute`, `callMediaTypeChanged`
- **Media:** `getMedia`, `openGallery`, `saveImage`, `saveVideo`, `saveVoiceNote`, `saveFile`, `share`
- **Files:** `pickDocument`, `openFile`, `downloadFile`, `getCachedFile`, `cancelDownload`,
  `uploadFile`, `cancelUpload`, `saveFileToDownloads`
- **Offline / resilience:** `enqueue`, `saveChannelsSnapshot`, `recoverOfflineChannels`,
  `gridChatOfflineDataCleared`
- **Navigation:** `goBack`, `switchTab`, `ready`
- **Live location:** `startLiveLocation`, `stopLiveLocation`
- **Sounds:** `playAppSound`, `stopAppSound`, `setAppSound`, `pickSystemSound`
- **System integration:** `requestBatteryOptimizationExemption`, `openAutostartSettings`,
  `openNotificationSettings`

---

## 3. Feature areas (detailed)

### A. WebView hosting & lifecycle
- **Host:** `GridInAppWebViewPage` loads the authenticated Circle Connect / Professional Space URL
  (SSO handshake via `grid_sso` token). Pre-paints the correct surface color per theme to avoid a
  flash (Circle Connect `#0B141A` dark / `#FFFFFF` light).
- **Keep-alive hosts:** both Circle Connect and Professional Space can be kept mounted and shown via
  reveal/hide (`onRequestHide`, `revealSignal`) instead of push/pop, so the WebView keeps its JS
  runtime, timers, WebSocket and any active `getUserMedia`. See `dynamic_grid_sdui_page.dart`
  (`_professionalSpaceShell`, `circleConnectKeepAlive`, `professionalSpaceKeepAlive`).
  - **Safety rule:** a live call is never silently hidden (Offstage) — it would orphan the camera/mic.
    `_safeExitToGrid` keeps Circle Connect on top while `OngoingCallService.isCallActive`.
- **Visibility sync:** the host dispatches WebView visibility to the web and keeps foreground markers
  in step with incoming-call behavior.
- **Offline shell & snapshot:** `grid_offline_shell_service.dart`, `grid_web_snapshot.dart`,
  `SnapshotCaptureBridge` — online visits save a script-stripped DOM snapshot; offline opens restore it.
- **WebView contents debugging:** gated behind `--dart-define=WEBVIEW_DEBUG=true`
  (`kWebViewInspectable` → iOS `setInspectable`, Android `enableDebugging`); off in public builds.

### B. Push notifications & message delivery
- **FCM bootstrap:** `push_notification_bootstrap.dart` registers the device token, wires foreground &
  background message handling, and the notification channels.
- **End-to-end device key:** `circle_connect_device_key_store.dart` holds an encrypted device key
  (`setDeviceKey` from web). All notification actions (reply / mark-read / mute) are sent authenticated
  via `POST <base>/notification/action`, with an **offline action queue** replayed when connectivity
  returns, and a legacy cookie fallback.
- **Message notifications:** `grid_chat_message_notification.dart` builds stacked, per-conversation
  message notifications (channels: `messages`, `group_messages`), with duplicate suppression and
  active-conversation suppression.
- **App-owned foreground banner:** `message_banner.dart` — while the app is foreground, shows an
  in-app, Android-heads-up-style banner (theme-adaptive) instead of the OEM system heads-up (which
  self-dismisses in <1s on some devices). Guaranteed dwell (2500ms), pause-while-touched, single-slot
  queue, inline **Reply**, **Mark as read**, **Mute**, body-tap opens the chat. Reply/mark/mute reuse
  the device-key services (no new HTTP) and never navigate the WebView. Mark-as-read also clears the
  in-page badge via `GridInAppWebViewPage.notifyGridChatMarkAsRead` (`gridChatMarkAsRead` JS event).
  **⚠ not device-verified.**
- **Notification actions (system tray):** `reply`, `mark_as_read`, `mute` handled in
  `notificationTapBackground`; multi-device read sync via silent `NOTIFICATION_CLEAR` data pushes.
- **Badges & active conversation:** `badgeUpdate`, `setActiveConversation` / `clearActiveConversation`
  (suppresses notifications for the chat you're reading), `clearChatNotifications`.

### C. Chat handoff (notification tap → chat)
- **Open once per tap:** a notification tap stores a `PendingChatOpen` and opens the conversation
  exactly once. When the web signals `chatUiReady`, the pending open is **consumed before dispatch**,
  so a repeat `chatUiReady` on resume/focus no longer replays it (fixes the cold-launch
  list → chat → list bounce). See `incoming_call_service.dart` `openChatFromNotification` and the
  `chatUiReady` handler.

### D. Voice / video calls
- **Incoming ring:** `startRinging` / `stopRinging` → native `startIncomingRing` / `stopIncomingRing`;
  incoming-call modal via `IncomingCallService`.
- **Ongoing call foreground service (Android):** `OngoingCallService.kt` runs a microphone (and
  camera, for video) foreground service with an "Ongoing call · tap to return" notification, keeping
  WebRTC alive in the background; holds wake/wifi locks and PiP lifecycle.
- **Native-owned call-audio contract** (confirmed with the Circle Connect team): the WebView owns the
  call UI, **native owns OS audio focus, communication mode and physical output routing**
  (earpiece / speaker / Bluetooth / wired). Driven by web messages `startCallAudio`, `endCallAudio`,
  `setCallAudioRoute`, `getCallAudioRoutes`, `callMediaTypeChanged`; native publishes route snapshots
  back as the `circleConnectAudioRoutesChanged` event `{ selectedRouteId, routes[] }`.
  - Android: `CallAudioController.kt` (AudioFocusRequest `GAIN_TRANSIENT` — media pauses, not ducks;
    `setCommunicationDevice` on API 31+, legacy SCO/speaker fallback; `AudioDeviceCallback` publishes
    route changes).
  - iOS: `AppDelegate.swift` (`AVAudioSession` `.playAndRecord`/`.voiceChat`, `overrideOutputAudioPort`,
    route-change observer).
  - **Note:** the old implicit audio-mode setup in `callStarted`/`callEnded` was removed on purpose —
    do **not** re-add it; audio lifecycle is driven solely by `startCallAudio`/`endCallAudio`.
    **⚠ not device-verified.**
- **Telemetry:** `outboundCallAttempt/Response/Error`, `callSignalLog`, `callIceLog`.

### E. Media & files
- **Gallery / Photos & videos:** `openGallery` uses `ImagePicker`. **Fix:** the app forces the Android
  system **Photo Picker** (`useAndroidPhotoPicker = true` in `main.dart`) so it uses
  `ACTION_PICK_IMAGES` instead of the `ACTION_GET_CONTENT`/DocumentsUI fallback that opened the file
  manager on some devices (iQOO/Vivo A14). **⚠ not device-verified.**
- **HTML `<input type=file>`:** `_handleAndroidFileSelection` MIME-branches on `acceptTypes`:
  `audio/*` → `FilePicker(FileType.audio)`, documents/other → `FilePicker(FileType.any)`,
  `image/*`·`video/*`·`*/*` → `ImagePicker` (Photo-Picker-backed). **⚠ not device-verified.**
- **Media cache:** `grid_media_cache_service.dart` resolves renderable media URLs (iOS `data:` URL for
  cached images, Android on-disk path) and saves local media bytes (voice notes).
- **File bridge:** `circle_connect_file_service.dart` — `pickDocument` (currently `FileType.custom`
  allow-list; can be widened to `FileType.any`), `downloadFile` (forwards `ci_session` cookies,
  filename from Content-Disposition, saves + opens), `openFile`, `getCachedFile`, `cancelDownload`,
  `saveFileToDownloads`.
- **Save to gallery / share:** `saveImage`, `saveVideo`, `saveFile`, `share` → native
  `saveImageToGallery` / `saveVideoToGallery` / `saveFileToDownloads` / share sheet.

### F. Offline & resilience
- **Outbox:** `grid_offline_outbox_service.dart` + `CircleConnectOutboxBridge` `enqueue` — queues sends
  made offline and replays on reconnect.
- **Channels snapshot:** `saveChannelsSnapshot` / `recoverOfflineChannels` persist the channel list.
- **Offline shell / snapshot:** DOM snapshot restore when offline (section A).

### G. Live location
- `grid_live_location_service.dart` + `startLiveLocation` / `stopLiveLocation` — shares live location
  into a conversation. (Also `user_location_service.dart` posts `user_currentLocation`.)

### H. Sounds
- `playAppSound` / `stopAppSound` / `setAppSound` / `pickSystemSound` → native sound playback and the
  system ringtone/sound picker (`grid_connect_phone_sounds`-related handling). Capability flags:
  `systemSoundsSupported`, `systemSoundPickerSupported`.

### I. System integration (Android-heavy)
- **Battery optimization:** `requestBatteryOptimizationExemption` → `isIgnoringBatteryOptimizations` /
  `requestIgnoreBatteryOptimizations` (keeps background delivery alive).
- **OEM autostart:** `openAutostartSettings` (Xiaomi/Vivo/etc. autostart managers).
- **Overlay permission:** `canDrawOverlays` / `openOverlaySettings` (full-screen incoming-call intent).
- **Notification settings:** `openNotificationSettings` / `openNotificationChannelSettings` /
  `openFullScreenIntentSettings` / `getActiveNotificationChannels`.
- **Cookies:** `getCookies` (session cookie forwarding for downloads/SSO).
- **Wake/unlock:** `wakeAndUnlock` (wake screen for incoming calls).
- **Device info:** `getDeviceManufacturer` (OEM-specific behavior).

### J. Theming
- `ThemeController` seeds app theme from the backend account appearance (web Profile change applies on
  mobile); the resolved theme word (`dark`/`light`) is sent to the WebViews so all surfaces stay in sync.

### K. Host capability flags (native → web)
Set as `window.CircleConnect*` / `api.*` booleans so the web enables features only when supported:
`messageNotificationsManaged`, `deviceKeySupported`, `hasDeviceKey`, `installationId`,
`openFileSupported`, `saveFileSupported`, `notificationSettingsSupported`,
`overlayPermissionSupported`, `batteryOptimizationSupported`, `autostartSettingsSupported`,
`systemSoundsSupported`, `systemSoundPickerSupported`.

---

## 4. Professional Space — app-side specifics

Professional Space reuses the same `GridInAppWebViewPage` host and most bridges, with these
Professional-Space-specific behaviors:

- **Keep-alive fullscreen host:** `dynamic_grid_sdui_page.dart` lazily mounts a single
  `GridInAppWebViewPage` for Professional Space (`_professionalSpaceShell`,
  `ValueKey('professional_space_keepalive')`) and **reveals/hides** it (`onRequestHide`,
  `revealSignal`) rather than pushing/popping — so the session, sockets and media persist across
  navigations. Fullscreen: the app bar and bottom navigation are cleared for Professional Space.
- **`GridShellPool.isProfessionalSpaceUri`** detects Professional Space URLs to route them to the
  keep-alive host.
- **`ProfessionalSpaceBridge`** handles Professional-Space-only host requests.
- **Visibility synchronization** between the host shell and the Professional Space / team WebView
  (covered by the `grid_team_webview_visibility` tests and the webview visibility sync feature).
- Shares: media cache, file bridge, offline shell, theming, system integration with Circle Connect.

---

## 5. Native method channel — `tech.efactor/circle_connect`

Dart calls these; implemented on both platforms unless noted.

| Method | Android | iOS | Purpose |
|---|---|---|---|
| `startCallAudio` / `endCallAudio` | ✅ | ✅ | Acquire/release call audio focus + routing |
| `getCallAudioRoutes` / `setCallAudioRoute` / `callMediaTypeChanged` | ✅ | ✅ | Query/switch output route; voice↔video |
| `startIncomingRing` / `stopIncomingRing` | ✅ | ✅ | Incoming-call ringtone |
| `startOngoingCallService` / `stopOngoingCallService` | ✅ | ✅ (no-op audio) | Foreground service (Android); iOS session |
| `isOngoingCallActive` | ✅ | ✅ | Query call state |
| `getCookies` | ✅ | ✅ | Session cookies for downloads/SSO |
| `getDeviceManufacturer` | ✅ | ✅ | OEM-specific behavior |
| `openFile` / `saveFileToDownloads` / `saveImageToGallery` / `saveVideoToGallery` | ✅ | ✅ | Files & gallery |
| `pickSystemSound` / `playAppSound` / `stopAppSound` / `setAppSound` | ✅ | ✅ | Sounds |
| `openNotificationSettings` / `openNotificationChannelSettings` | ✅ | ✅ | Settings deep-links |
| `openFullScreenIntentSettings` / `getActiveNotificationChannels` | ✅ | — | Android notification config |
| `canDrawOverlays` / `openOverlaySettings` | ✅ | ✅ | Overlay permission |
| `isIgnoringBatteryOptimizations` / `requestIgnoreBatteryOptimizations` | ✅ | — | Background delivery |
| `openAutostartSettings` | ✅ | — | OEM autostart |
| `wakeAndUnlock` | ✅ | ✅ | Wake screen for calls |
| `getPendingNotificationTap` | — | ✅ | iOS FCM-tap redirect (see below) |

### iOS FCM notification-tap redirect
Because the app uses `UIScene` + `FlutterImplicitEngineDelegate`, `FLTFirebaseMessagingPlugin` misses
tap callbacks. `AppDelegate` / `SceneDelegate` capture the tap natively and forward it to Dart via
`getPendingNotificationTap` so notification-to-chat navigation works in all app states.
(Committed on branch `fix/ios-fcm-notification-tap-redirect`.)

---

## 6. File map (where to look)

| Area | Files |
|---|---|
| WebView host & all bridges | `lib/grid_sdui/grid_in_app_webview_page.dart` |
| Grid/Professional-Space shell | `lib/grid_sdui/dynamic_grid_sdui_page.dart`, `grid_shell_pool.dart` |
| Push & notifications | `lib/services/push_notification_bootstrap.dart`, `grid_chat_message_notification.dart`, `grid_notifications_service.dart`, `grid_unread_counts_service.dart` |
| Foreground banner | `lib/services/message_banner.dart` |
| Device key / auth actions | `lib/services/circle_connect_device_key_store.dart` |
| Calls | `lib/services/incoming_call_service.dart`, `ongoing_call_service.dart`, `call_lifecycle_tracker.dart`, `call_permission_helper.dart` |
| Media & files | `lib/grid_sdui/grid_media_cache_service.dart`, `circle_connect_file_service.dart` |
| Offline | `lib/grid_sdui/grid_offline_outbox_service.dart`, `grid_offline_shell_service.dart`, `grid_web_snapshot.dart` |
| Live location | `lib/grid_sdui/grid_live_location_service.dart`, `lib/services/user_location_service.dart` |
| Android native | `android/app/src/main/kotlin/com/example/efactor_sdui/` — `MainActivity.kt`, `OngoingCallService.kt`, `CallAudioController.kt` |
| iOS native | `ios/Runner/AppDelegate.swift`, `SceneDelegate.swift` |
| Home shell / routing | `lib/home_sdui/dynamic_home_sdui_page.dart`, `home_sdui_state.dart` |

---

## 7. Recent app-side work & open items

**Shipped this cycle (on branch `fix/ios-fcm-notification-tap-redirect`):**
- App-owned foreground notification banner + Reply/Mark/Mute + inline reply (`message_banner.dart`).
- Open-chat-once (no replay on resume/focus).
- Native call-audio contract (CallAudioController / AppDelegate).
- Picker fixes: force Android Photo Picker + audio/document MIME branching.
- Home **route preservation**: a live schema refresh no longer resets the shell to Home — the user
  stays on Circle Connect / their current tab (`HomeSduiState.restoreActiveRoute` in `_applyHomeSchema`).
- iOS FCM notification-tap redirect.

**Open / pending verification:**
- Call-audio, banner, pickers, and route-preservation are **not yet device-verified** (hardware test
  pending — the test device kept dropping off adb).
- `CircleConnectFileBridge.pickDocument` filters to a document extension allow-list; widen to
  `FileType.any` if the web needs arbitrary types.
- Backend-side trigger for the route-reset (home schema hash changing mid-session) is not controlled by
  this app; the client fix makes it harmless either way.

**Cross-team ownership reminder:** the web UI, the GRID Chat/Professional Space web builds, and the
schema backend are **other teams**. This app is the native host. Audio, notifications, pickers and
lifecycle live here; message rendering, call UI, and schemas live on their side.
