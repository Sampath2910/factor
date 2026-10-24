# Efactor Backend FCM Push Notification Fix (Circle Connect Calls)

## Executive Summary
Mobile A initiates an outgoing call to Mobile B via `/index.php/grid-chat/api/call/notify`. The server returns `HTTP 200 OK: {"status":"success","message":"Call notify accepted"}`.

However, **Mobile B does not receive any FCM push notification** when the app is in the background or locked.

---

## 1. Root Causes on the Backend

### Cause A: Google Decommissioned Legacy FCM API (`fcm.googleapis.com/fcm/send`)
Google has **permanently disabled** the legacy FCM HTTP API. Any server calling `https://fcm.googleapis.com/fcm/send` with `Authorization: key=...` now receives:
```http
HTTP/2 404 Not Found
<!-- GSE Default Error -->
<H1>Not Found</H1>
<H2>Error 404</H2>
```
All Firebase projects, including `grid-factor` (Project Number `870386246990`), **strictly require the Firebase Cloud Messaging HTTP v1 API**:
```
POST https://fcm.googleapis.com/v1/projects/grid-factor/messages:send
```

---

### Cause B: Token Lookup by User ID
In the database table `user_device_tokens`:
- The client app registers tokens on login with the portal user ID (e.g. `762`, `763`).
- Circle Connect assigns chat user IDs (e.g. `7`, `8`, `2`).
- When `/call/notify` receives `callee_user_id = 8`, the backend query:
  ```sql
  SELECT device_token FROM user_device_tokens WHERE user_id = 8;
  ```
  Returns `0` rows if the token was saved under the portal ID (`763`).

**Backend Fix:** The SQL query must find the token by `user_id = 8` OR by mapping `users.id` to `chat_users.id`, or by recipient phone number:
```sql
SELECT device_token 
FROM user_device_tokens 
WHERE user_id = :callee_user_id 
   OR user_id = (SELECT portal_user_id FROM chat_users WHERE id = :callee_user_id LIMIT 1);
```

---

## 2. Drop-in PHP Implementation for Firebase HTTP v1

Here is a **zero-dependency, native PHP 7.4+ function** using OpenSSL to generate OAuth2 access tokens from the Firebase Service Account JSON and dispatch high-priority data messages.

### Step 1: Download Service Account Key
1. Go to **Firebase Console** -> `grid-factor` -> **Project Settings** -> **Service accounts**.
2. Click **Generate new private key**.
3. Save the JSON file on the server (e.g., `/application/config/firebase-service-account.json`).

### Step 2: PHP Helper Function (`FcmV1Sender.php`)

```php
<?php
class FcmV1Sender
{
    private static $serviceAccountPath = '/application/config/firebase-service-account.json';
    private static $projectId = 'grid-factor';

    /**
     * Obtains an OAuth2 access token using Google Service Account JSON.
     */
    private static function getAccessToken()
    {
        $cacheFile = sys_get_temp_dir() . '/fcm_oauth_token_' . md5(self::$serviceAccountPath) . '.json';
        if (file_exists($cacheFile)) {
            $cached = json_decode(file_get_contents($cacheFile), true);
            if (!empty($cached['access_token']) && !empty($cached['expires_at']) && $cached['expires_at'] > time() + 60) {
                return $cached['access_token'];
            }
        }

        if (!file_exists(self::$serviceAccountPath)) {
            error_log("[FCM] Service account file not found: " . self::$serviceAccountPath);
            return null;
        }

        $sa = json_decode(file_get_contents(self::$serviceAccountPath), true);
        $now = time();
        $jwtHeader = base64_encode(json_encode(['alg' => 'RS256', 'typ' => 'JWT']));
        $jwtPayload = base64_encode(json_encode([
            'iss' => $sa['client_email'],
            'scope' => 'https://www.googleapis.com/auth/firebase.messaging',
            'aud' => 'https://oauth2.googleapis.com/token',
            'iat' => $now,
            'exp' => $now + 3600
        ]));

        $rawSig = '';
        $dataToSign = $jwtHeader . '.' . $jwtPayload;
        openssl_sign($dataToSign, $rawSig, $sa['private_key'], 'sha256WithRSAEncryption');
        $jwtSignature = base64_encode($rawSig);
        $jwt = $dataToSign . '.' . $jwtSignature;

        $ch = curl_init('https://oauth2.googleapis.com/token');
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query([
            'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            'assertion' => $jwt
        ]));
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        $res = curl_exec($ch);
        curl_close($ch);

        $tokenData = json_decode($res, true);
        if (!empty($tokenData['access_token'])) {
            file_put_contents($cacheFile, json_encode([
                'access_token' => $tokenData['access_token'],
                'expires_at' => $now + ($tokenData['expires_in'] ?? 3600)
            ]));
            return $tokenData['access_token'];
        }

        error_log("[FCM] Failed to obtain OAuth2 token: " . $res);
        return null;
    }

    /**
     * Sends a high-priority data-only push notification for an incoming call.
     */
    public static function sendIncomingCallPush($deviceToken, $callData)
    {
        $accessToken = self::getAccessToken();
        if (!$accessToken) {
            return false;
        }

        $url = 'https://fcm.googleapis.com/v1/projects/' . self::$projectId . '/messages:send';

        $payload = [
            'message' => [
                'token' => $deviceToken,
                // CRITICAL: Must be data-only (no "notification" block) so Android background handler wakes up
                'data' => [
                    'type' => 'INCOMING_CALL',
                    'call_id' => (string)($callData['call_id'] ?? ''),
                    'caller_name' => (string)($callData['caller_name'] ?? 'Incoming Call'),
                    'caller_user_id' => (string)($callData['caller_user_id'] ?? ''),
                    'call_type' => (string)($callData['call_type'] ?? 'video'),
                    'room_url' => 'https://efactor.tech/index.php/grid-chat',
                    'timestamp' => (string)time()
                ],
                'android' => [
                    'priority' => 'high'
                ]
            ]
        ];

        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            'Authorization: Bearer ' . $accessToken,
            'Content-Type: application/json; UTF-8'
        ]);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($payload));
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        error_log("[FCM v1] sendIncomingCallPush HTTP $httpCode: $response");
        return $httpCode === 200;
    }
}
```

---

### Step 3: Usage in `call/notify` Controller Method

```php
// Inside Call controller notify() method:
$calleeUserId = $this->input->post('callee_user_id') ?: $this->input->post('user_id');
$callId       = $this->input->post('call_id');
$callType     = $this->input->post('call_type') ?: 'video';

// 1. Fetch token from user_device_tokens
$tokens = $this->db->query("
    SELECT device_token 
    FROM user_device_tokens 
    WHERE user_id = ? 
       OR user_id = (SELECT portal_user_id FROM chat_users WHERE id = ? LIMIT 1)
", [$calleeUserId, $calleeUserId])->result_array();

foreach ($tokens as $row) {
    if (!empty($row['device_token'])) {
        FcmV1Sender::sendIncomingCallPush($row['device_token'], [
            'call_id' => $callId,
            'caller_name' => $this->session->userdata('name') ?: 'Incoming Call',
            'caller_user_id' => $this->session->userdata('user_id'),
            'call_type' => $callType
        ]);
    }
}
```

---

## 3. Verification Command

Once deployed, the backend team can verify FCM push delivery from the server terminal:
```bash
php -r '
require_once "FcmV1Sender.php";
$res = FcmV1Sender::sendIncomingCallPush(
    "RECIPIENT_DEVICE_FCM_TOKEN",
    ["call_id" => "test_1", "caller_name" => "Server Test", "call_type" => "video"]
);
echo $res ? "SUCCESS\n" : "FAILED\n";
'
```
When successful, Mobile B's screen turns on immediately and rings with the full-screen incoming call UI.
