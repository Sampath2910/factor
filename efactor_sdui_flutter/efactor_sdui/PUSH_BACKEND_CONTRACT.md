# Push / Incoming Call Backend Contract (P0-A)

Flutter now registers device tokens and expects the payloads below.
This repo has **no PHP backend source** — implement these endpoints on `efactor.tech`.

## 1. Register device token

`POST /api/register_device_token`

Headers:
- `Content-Type: application/json`
- `Authorization: Bearer <access_token>`

Body:
```json
{
  "action": "register_device_token",
  "user_id": "707",
  "device_token": "<fcm_or_apns_token>",
  "platform": "android",
  "token_type": "fcm",
  "timestamp": 1710000000
}
```

`token_type`: `fcm` (Android / iOS FCM) or `apns_voip` (iOS VoIP PushKit).

Persist: `user_id`, `device_token`, `platform`, `token_type`, `updated_at`.
Replace older tokens for the same user+platform when a new token arrives.

Unregister uses the same URL with `"action": "unregister_device_token"`.

## 2. Incoming call push (app may be killed)

When user A calls user B, look up B's tokens and send a **high-priority data** message:

```json
{
  "type": "INCOMING_CALL",
  "call_id": "uuid",
  "caller_id": "123",
  "caller_name": "Alice",
  "caller_avatar": "https://...",
  "call_type": "video",
  "room_url": "https://efactor.tech/index.php/grid-chat",
  "timestamp": 1710000000
}
```

Android FCM: `priority: high`, data-only (or data + notification).
iOS: VoIP push if `apns_voip` token exists; otherwise APNs alert with same data keys.

On miss / cancel / hangup send:
```json
{ "type": "CALL_CANCELLED", "call_id": "uuid" }
```
(`CALL_MISSED` / `HANGUP` also accepted by the client.)

## 3. Call action (decline)

`POST /api/call_action`

```json
{
  "action": "call_rejected",
  "call_id": "uuid",
  "caller_id": "123",
  "user_id": "707",
  "timestamp": 1710000000
}
```

## 4. Message notification (app may be killed)

When a Circle Connect chat message is sent to an offline user:

```json
{
  "type": "MESSAGE",
  "title": "Alice",
  "body": "Hello",
  "sender_id": "123",
  "sender_name": "Alice",
  "url": "https://efactor.tech/index.php/grid-chat",
  "deep_link": "https://efactor.tech/index.php/grid-chat"
}
```

Use FCM notification + data (or APNs alert) so the OS shows a banner when the app is backgrounded/killed.

## 5. Acceptance checks

- [ ] Token saved after Flutter login (`syncDeviceTokenOnLogin`)
- [ ] Kill app → incoming call shows CallKit / full-screen UI
- [ ] Decline hits `/api/call_action`
- [ ] Accept opens Circle Connect WebView
- [ ] Kill app → chat message shows OS notification; tap opens grid-chat

## Flutter wiring (already done)

- Token: `IncomingCallService.setDeviceToken` via `PushNotificationBootstrap`
- Register: `POST /api/register_device_token` after login (`ensureTokenSynced`)
- Foreground: in-app call UI + local notification
- Background / killed: FCM background handler shows local call/message notification
- Tap notification → opens Circle Connect WebView
- Android 13+ `POST_NOTIFICATIONS` requested at runtime
- iOS: `registerForRemoteNotifications` + `aps-environment` entitlements

## Flutter blockers (mobile team — not Backend)

1. Place real Firebase files (do **not** commit secrets to public repos if policy forbids):
   - `android/app/google-services.json` (from Firebase console; package `com.example.efactor_sdui`)
   - `ios/Runner/GoogleService-Info.plist`
   - Examples: `google-services.json.example`, `GoogleService-Info.plist.example`
2. Rebuild / reinstall the app, allow notification permission, log in once.
3. Until those files exist, push bootstrap no-ops and no FCM token is registered.
