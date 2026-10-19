# HRMS Field Tracking & Geofencing System
## Comprehensive Multi-App Enterprise Architecture & Implementation Plan

> **Document Version:** 1.0.0  
> **Status:** Approved for Future Implementation  
> **Target Package:** `packages/efactor_field_tracker`  
> **Supported Platforms:** Android (API 26+) & iOS (iOS 14.0+)  
> **Target Workspaces:** Efactor Mobile App, Future HRMS Field Workforce App, Logistics & Fleet Trackers  

---

## 1. Executive Summary & Vision

Field executives, service engineers, sales representatives, and delivery personnel frequently operate in environments with intermittent, degraded, or zero cellular connectivity (basements, remote client sites, industrial plants, elevator shafts, rural transit corridors).

### Core Architectural Mandates:
1. **Edge-Computed Geofencing (Zero Internet Dependency)**:
   - GPS satellite signals (GNSS) are broadcast globally and received by mobile device chips without requiring cellular reception or mobile data.
   - The device evaluates its own geofence status locally using the high-performance Haversine formula in sub-millisecond execution time.
2. **Offline-First Persistence (Outbox Pattern)**:
   - Telemetry breadcrumbs, check-ins, check-outs, and task status changes are committed immediately to a local encrypted SQLite database on the device before any network call is initiated.
3. **Adaptive Battery-Smart Sampling**:
   - Power consumption is throttled dynamically based on speed and proximity to destination: switching between coarse polling (15–30 min intervals) during stationary/idle states, medium polling (2 min) in transit, and high-frequency GPS (5–10 sec) within 300 meters of an assigned site.
4. **Resilient Batch Synchronization**:
   - When network connectivity is re-established, an asynchronous background sync dispatcher flushes queued records in batches (up to 50 records per payload) with exponential backoff, jitter, and client-side UUID idempotency.
5. **Multi-App Shared Reusability**:
   - The entire tracking, geofencing, local storage, and sync pipeline is encapsulated into an internal shared Flutter package (`packages/efactor_field_tracker`). Any present or future app can import this package with zero duplicate code.

---

## 2. End-to-End System Architecture

```mermaid
graph TD
    subgraph Web_Admin ["HRMS Web Portal / Admin Dispatcher"]
        M1[Create Geofenced Assignment] --> M2[Set Lat/Lng & Radius]
        M2 --> M3[Assign to Field Executive]
        M4[Real-time Live Telemetry Map]
        M5[Attendance & Movement Audit Reports]
    end

    subgraph Cloud_Backend ["HRMS Cloud Backend (PHP/Node/Go + MySQL)"]
        B1[(MySQL Database)]
        B2[GET /assignments API]
        B3[POST /tracking/batch API]
        B4[POST /attendance/event API]
    end

    subgraph Field_Device ["Field Executive Mobile Device (Android / iOS)"]
        subgraph Tracker_Package ["Shared Package: packages/efactor_field_tracker"]
            A1[Local SQLite Outbox DB]
            A2[Geofence & Haversine Engine]
            A3[Adaptive GPS Provider]
            A4[Sync Engine & Connectivity Listener]
            A5[Anti-Tamper & Fake GPS Guard]
        end
        subgraph App_UI ["Host Application (HRMS / Efactor / Fleet)"]
            U1[Geofence Status Card]
            U2[Verified Check-In Button]
            U3[Offline Sync Banner]
        end
    end

    %% Flow interactions
    M3 -->|Publish Assignment| B2
    B2 -->|Download Assigned Sites| A1
    A3 -->|Raw GPS Fixes| A5
    A5 -->|Validated Coordinates| A2
    A2 -->|INSIDE / OUTSIDE Status & Distance| U1 & U2
    U2 -->|Record Verified Event| A1
    A3 -->|Periodic Breadcrumbs| A1
    A4 -->|Watch Network Status| A1
    A4 -->|Batch Upload (HTTP 200)| B3 & B4
    B3 & B4 --> B1
    B1 --> M4 & M5
```

---

## 3. Module 1: Edge Geofencing & Anti-Tamper Engine

Geofencing must compute instantaneously on the client device even in full airplane mode.

### 3.1 Mathematical Derivation (Haversine Formula)
The great-circle distance $d$ between the employee's current position $(\text{lat}_1, \text{lon}_1)$ and the target site $(\text{lat}_2, \text{lon}_2)$ on a spherical Earth of radius $R = 6,371,000\text{ meters}$:

$$\Delta\text{lat} = \text{radians}(\text{lat}_2 - \text{lat}_1), \quad \Delta\text{lon} = \text{radians}(\text{lon}_2 - \text{lon}_1)$$

$$a = \sin^2\left(\frac{\Delta\text{lat}}{2}\right) + \cos(\text{radians}(\text{lat}_1)) \cdot \cos(\text{radians}(\text{lat}_2)) \cdot \sin^2\left(\frac{\Delta\text{lon}}{2}\right)$$

$$c = 2 \cdot \operatorname{atan2}\left(\sqrt{a}, \sqrt{1 - a}\right)$$

$$d = R \cdot c$$

### 3.2 Production Dart Implementation (`geofence_calculator.dart`)
```dart
import 'dart:math' as math;

enum GeofenceState {
  inside,      // Distance <= Radius
  approaching, // Radius < Distance <= Radius + 250m
  outside      // Distance > Radius + 250m
}

class GeofenceResult {
  final GeofenceState state;
  final double distanceMeters;
  final double targetRadiusMeters;
  final bool canCheckIn;
  final bool isMockLocation;

  const GeofenceResult({
    required this.state,
    required this.distanceMeters,
    required this.targetRadiusMeters,
    required this.canCheckIn,
    this.isMockLocation = false,
  });

  String get formattedDistance {
    if (distanceMeters < 1000) {
      return '${distanceMeters.toStringAsFixed(0)} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(2)} km';
  }
}

class GeofenceCalculator {
  static const double earthRadiusMeters = 6371000.0;

  /// High-performance Haversine calculation
  static double computeDistanceMeters({
    required double lat1,
    required double lon1,
    required double lat2,
    required double lon2,
  }) {
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Evaluates proximity and permission to check in
  static GeofenceResult evaluate({
    required double deviceLat,
    required double deviceLon,
    required double siteLat,
    required double siteLon,
    required double radiusMeters,
    bool isMock = false,
  }) {
    final distance = computeDistanceMeters(
      lat1: deviceLat,
      lon1: deviceLon,
      lat2: siteLat,
      lon2: siteLon,
    );

    if (isMock) {
      // Reject spoofed GPS coordinates
      return GeofenceResult(
        state: GeofenceState.outside,
        distanceMeters: distance,
        targetRadiusMeters: radiusMeters,
        canCheckIn: false,
        isMockLocation: true,
      );
    }

    if (distance <= radiusMeters) {
      return GeofenceResult(
        state: GeofenceState.inside,
        distanceMeters: distance,
        targetRadiusMeters: radiusMeters,
        canCheckIn: true,
      );
    } else if (distance <= radiusMeters + 250.0) {
      return GeofenceResult(
        state: GeofenceState.approaching,
        distanceMeters: distance,
        targetRadiusMeters: radiusMeters,
        canCheckIn: false,
      );
    } else {
      return GeofenceResult(
        state: GeofenceState.outside,
        distanceMeters: distance,
        targetRadiusMeters: radiusMeters,
        canCheckIn: false,
      );
    }
  }

  static double _degToRad(double degrees) => degrees * (math.pi / 180.0);
}
```

### 3.3 Anti-Tamper & Fake GPS Protection
1. **Mock Provider Detection**: Inspect `Position.isMocked` (available via `geolocator: ^12.0.0`). If `isMocked == true`, flag the breadcrumb and reject check-in.
2. **Device Time Tampering**: Cross-reference `DateTime.now()` with boot time elapsed (`SystemClock.elapsedRealtime()` on Android via platform channel) to prevent employees from rolling back the phone clock.
3. **Teleportation Anomaly Filter**: If successive points exceed physical speed limits (e.g., distance delta $> 500\text{ meters}$ within $2\text{ seconds}$), flag as anomalous.

---

## 4. Module 2: Adaptive Battery-Smart Location Engine

Field applications running full GPS continuously will exhaust a mobile battery within 3.5 to 4 hours. The adaptive engine adjusts polling dynamically.

### 4.1 Dynamic Power-State Table

| State | Trigger Conditions | Accuracy Setting | Distance Filter | Sampling Rate | Battery Impact |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Idle / Off-Duty** | Outside work shift hours | Low / Coarse | 1,000 meters | 60 minutes | $< 0.2\% / \text{hr}$ |
| **Stationary** | Speed $< 1.5\text{ km/h}$ for $> 15$ mins | Low / Balanced | 200 meters | 15 minutes | $< 0.5\% / \text{hr}$ |
| **In-Transit** | Speed $> 5\text{ km/h}$, distance $> 300\text{m}$ | Medium / Balanced | 50 meters | 2 minutes | $\sim 1.2\% / \text{hr}$ |
| **Proximity Zone** | Distance $\le 300\text{m}$ to destination | High / Fine GPS | 10 meters | 10 seconds | Temporary |
| **On-Site Locked** | Verified Check-In recorded | Medium / Balanced | 100 meters | 10 minutes | $< 0.8\% / \text{hr}$ |

### 4.2 Native Background Configurations

#### Android (`android/app/src/main/AndroidManifest.xml`)
```xml
<!-- Background Location Permissions -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />

<service
    android:name="com.baseflow.geolocator.GeolocatorLocationService"
    android:enabled="true"
    android:exported="false"
    android:foregroundServiceType="location" />
```

#### iOS (`ios/Runner/Info.plist`)
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app requires location access to verify your site attendance and calculate geofences.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Field tracking requires background location access to record verified travel routes and on-site duty.</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>fetch</string>
    <string>processing</string>
</array>
```

---

## 5. Module 3: SQLite Offline Outbox Database Schema

```sql
-- 1. Pre-Downloaded Assigned Sites (Cached for Offline Inspection)
CREATE TABLE IF NOT EXISTS field_assignments (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    customer_name TEXT,
    site_address TEXT,
    destination_lat REAL NOT NULL,
    destination_lng REAL NOT NULL,
    radius_meters REAL DEFAULT 100.0,
    start_time INTEGER NOT NULL,
    end_time INTEGER NOT NULL,
    status TEXT DEFAULT 'PENDING',  -- 'PENDING', 'CHECKED_IN', 'COMPLETED'
    updated_at INTEGER NOT NULL
);

-- 2. Breadcrumbs Outbox (Stores GPS History during dead zones)
CREATE TABLE IF NOT EXISTS field_breadcrumbs_outbox (
    id TEXT PRIMARY KEY,            -- UUID v4
    employee_id TEXT NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    accuracy REAL,
    speed REAL,
    heading REAL,
    is_mocked INTEGER DEFAULT 0,
    captured_at INTEGER NOT NULL,
    is_synced INTEGER DEFAULT 0,
    sync_attempt_count INTEGER DEFAULT 0,
    last_error TEXT
);
CREATE INDEX IF NOT EXISTS idx_breadcrumbs_sync ON field_breadcrumbs_outbox(is_synced, captured_at);

-- 3. Attendance Events Outbox (Check-In & Check-Out Audit Logs)
CREATE TABLE IF NOT EXISTS field_attendance_outbox (
    id TEXT PRIMARY KEY,            -- UUID v4
    assignment_id TEXT NOT NULL,
    employee_id TEXT NOT NULL,
    event_type TEXT NOT NULL,       -- 'CHECK_IN', 'CHECK_OUT'
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    distance_meters REAL NOT NULL,
    verified_geofence INTEGER NOT NULL, -- 1 = inside, 0 = outside
    is_mocked INTEGER DEFAULT 0,
    captured_at INTEGER NOT NULL,
    is_synced INTEGER DEFAULT 0,
    sync_attempt_count INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_attendance_sync ON field_attendance_outbox(is_synced, captured_at);
```

---

## 6. Module 4: Resilient Offline-to-Online Sync Engine

### 6.1 Synchronization Lifecycle

```mermaid
sequenceDiagram
    autonumber
    participant App as Mobile App (SQLite)
    participant Monitor as Connectivity Plus
    participant Sync as Sync Dispatcher
    participant API as HRMS Cloud Server
    participant DB as Cloud MySQL

    Note over App: Field Executive travels through remote offline zone
    App->>App: Insert Breadcrumb & Attendance into SQLite (is_synced = 0)
    Note over App: Internet restored (Cellular 4G/5G / Wi-Fi)
    Monitor->>Sync: onConnectivityChanged (hasInternet = true)
    Sync->>App: Query pending batch (LIMIT 50)
    Sync->>API: POST /api/hrms/tracking/batch (Batch JSON + Bearer Token)
    API->>DB: INSERT IGNORE (Enforce client_uuid idempotency)
    API-->>Sync: HTTP 200 OK { "synced_ids": ["uuid-1", "uuid-2"] }
    Sync->>App: UPDATE field_breadcrumbs_outbox SET is_synced = 1 WHERE id IN (...)
    Note over Sync: Queue flushed; idle until next batch or network event
```

### 6.2 Key Outbox Rules
1. **Batching**: Never send single breadcrumbs individually over the radio. Buffer and batch up to 50 items per payload. This reduces network radio activation by $> 95\%$.
2. **Idempotency**: Every breadcrumb and check-in event generates a client-side UUID (`id: Uuid().v4()`). The backend enforces `UNIQUE KEY (client_uuid)`. If a cellular handshake times out after the server accepted the data, the retry will safely ignore duplicates.
3. **Exponential Backoff**:
   $$\text{retryDelay} = \min(120, 2^{\text{retryCount}} \cdot 3) + \text{jitter}(0, 2)$$

---

## 7. Module 5: Cloud Backend Contracts & MySQL DDL

### 7.1 Backend MySQL Schema
```sql
-- 1. Assigned Work Orders / Sites
CREATE TABLE IF NOT EXISTS hrms_field_assignments (
    id VARCHAR(64) PRIMARY KEY,
    employee_id INT NOT NULL,
    title VARCHAR(255) NOT NULL,
    customer_name VARCHAR(255),
    destination_lat DECIMAL(10, 8) NOT NULL,
    destination_lng DECIMAL(11, 8) NOT NULL,
    radius_meters INT DEFAULT 100,
    start_time DATETIME NOT NULL,
    end_time DATETIME NOT NULL,
    status ENUM('PENDING', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED') DEFAULT 'PENDING',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_emp_time (employee_id, start_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 2. Telemetry Breadcrumb History
CREATE TABLE IF NOT EXISTS hrms_tracking_breadcrumbs (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    client_uuid VARCHAR(64) UNIQUE NOT NULL,
    employee_id INT NOT NULL,
    latitude DECIMAL(10, 8) NOT NULL,
    longitude DECIMAL(11, 8) NOT NULL,
    accuracy FLOAT,
    speed FLOAT,
    heading FLOAT,
    is_mocked TINYINT(1) DEFAULT 0,
    captured_at DATETIME NOT NULL,
    received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_emp_captured (employee_id, captured_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 3. Verified Attendance Logs
CREATE TABLE IF NOT EXISTS hrms_site_attendance (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    client_uuid VARCHAR(64) UNIQUE NOT NULL,
    assignment_id VARCHAR(64) NOT NULL,
    employee_id INT NOT NULL,
    event_type ENUM('CHECK_IN', 'CHECK_OUT') NOT NULL,
    latitude DECIMAL(10, 8) NOT NULL,
    longitude DECIMAL(11, 8) NOT NULL,
    distance_meters FLOAT NOT NULL,
    verified_geofence TINYINT(1) DEFAULT 1,
    is_mocked TINYINT(1) DEFAULT 0,
    captured_at DATETIME NOT NULL,
    received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_assign_emp (assignment_id, employee_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### 7.2 Ingestion REST Endpoints

#### Endpoint 1: Fetch Assigned Sites
- **URL**: `GET https://efactor.tech/index.php/api/hrms/assignments?employee_id=763`
- **Response**:
```json
{
  "status": "success",
  "assignments": [
    {
      "id": "site_blr_204",
      "title": "Client Onsite Inspection",
      "customer_name": "Acme Corp Tech Park",
      "destination_lat": 12.9715987,
      "destination_lng": 77.5945627,
      "radius_meters": 100,
      "start_time": 1729324800,
      "end_time": 1729353600
    }
  ]
}
```

#### Endpoint 2: Batch Breadcrumb Ingestion
- **URL**: `POST https://efactor.tech/index.php/api/hrms/tracking/batch`
- **Headers**: `Authorization: <token>`, `Content-Type: application/json`
- **Request Body**:
```json
{
  "employee_id": "763",
  "batch_count": 2,
  "breadcrumbs": [
    {
      "client_uuid": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
      "latitude": 12.971590,
      "longitude": 77.594550,
      "accuracy": 7.2,
      "speed": 14.5,
      "heading": 182.0,
      "is_mocked": false,
      "captured_at": 1729325400
    },
    {
      "client_uuid": "8c2deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6e",
      "latitude": 12.971595,
      "longitude": 77.594560,
      "accuracy": 5.1,
      "speed": 0.0,
      "heading": 0.0,
      "is_mocked": false,
      "captured_at": 1729325460
    }
  ]
}
```
- **Response Body**:
```json
{
  "status": "success",
  "synced_ids": [
    "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
    "8c2deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6e"
  ],
  "message": "2 breadcrumbs ingested successfully"
}
```

#### Endpoint 3: Verified Attendance Event
- **URL**: `POST https://efactor.tech/index.php/api/hrms/attendance/event`
- **Request Body**:
```json
{
  "client_uuid": "7a3ceb4d-3b7d-4bad-9bdd-2b0d7b3dcb6f",
  "assignment_id": "site_blr_204",
  "employee_id": "763",
  "event_type": "CHECK_IN",
  "latitude": 12.971592,
  "longitude": 77.594558,
  "distance_meters": 14.2,
  "verified_geofence": true,
  "is_mocked": false,
  "captured_at": 1729325500
}
```

---

## 8. Module 6: Reusable Multi-App Package Architecture

To ensure this can be used across **all current and future applications** without copy-pasting code:

```text
efactor_sdui_flutter/
  └── efactor_sdui/
      ├── packages/
      │   ├── efactor_provisioning/        <-- Existing local package
      │   └── efactor_field_tracker/       <-- New Shared Reusable Package
      │       ├── pubspec.yaml
      │       ├── lib/
      │       │   ├── efactor_field_tracker.dart (Public API facade)
      │       │   ├── src/
      │       │   │   ├── engine/
      │       │   │   │   ├── geofence_calculator.dart
      │       │   │   │   ├── anti_tamper_guard.dart
      │       │   │   │   └── adaptive_location_provider.dart
      │       │   │   ├── storage/
      │       │   │   │   ├── tracker_database_helper.dart
      │       │   │   │   └── outbox_repository.dart
      │       │   │   ├── sync/
      │       │   │   │   ├── sync_dispatcher.dart
      │       │   │   │   └── connectivity_watcher.dart
      │       │   │   ├── models/
      │       │   │   │   ├── assignment_model.dart
      │       │   │   │   ├── breadcrumb_model.dart
      │       │   │   │   └── attendance_event_model.dart
      │       │   │   └── widgets/
      │       │   │       ├── live_geofence_card.dart
      │       │   │       └── verified_checkin_button.dart
```

### Public Facade Usage (Single Line of Code in Any App)
```dart
import 'package:efactor_field_tracker/efactor_field_tracker.dart';

// 1. Initialize once in main.dart:
await FieldTracker.instance.initialize(
  apiBaseUrl: 'https://efactor.tech/index.php/api/hrms',
  authToken: userToken,
);

// 2. Start tracking for an employee:
FieldTracker.instance.startDuty(employeeId: '763');

// 3. Listen to live proximity anywhere in your UI:
StreamBuilder<GeofenceResult>(
  stream: FieldTracker.instance.proximityStream(targetSite),
  builder: (context, snapshot) {
    final result = snapshot.data;
    if (result == null) return const CircularProgressIndicator();

    return LiveGeofenceCard(
      result: result,
      onCheckIn: () => FieldTracker.instance.recordCheckIn(targetSite),
    );
  },
);
```

---

## 9. Phased Implementation Roadmap

When you are ready to begin implementation, execute these phases in strict order:

| Phase | Milestone | Deliverables | Verification Criteria |
| :---: | :--- | :--- | :--- |
| **Phase 1** | **Standalone Package & Database** | Create `packages/efactor_field_tracker` directory with `sqflite` DDL and `GeofenceCalculator`. | Run unit tests on Haversine distance math; confirm SQLite tables create and perform local CRUD. |
| **Phase 2** | **Adaptive Location Engine** | Implement `AdaptiveLocationProvider` with stationary vs transit vs proximity state machine. | Validate on physical Android/iOS devices that polling switches to 10-sec only when within 300m. |
| **Phase 3** | **Outbox Batch Sync Engine** | Implement `SyncDispatcher` with `connectivity_plus` and retry backoff. | Enable Airplane mode, record 30 points, disable Airplane mode; verify all 30 points upload automatically. |
| **Phase 4** | **Backend REST Endpoints** | Deploy PHP / MySQL tables on `efactor.tech` server. | Send Postman batch payload; verify records appear in `hrms_tracking_breadcrumbs` with idempotency. |
| **Phase 5** | **UI Components & Multi-App Export** | Integrate `LiveGeofenceCard` and `VerifiedCheckInButton` into SDUI and future HRMS app. | Field tests with field users verifying check-in button enables only when physically inside the geofence. |

---

## 10. File Download & Reference Details

This file is stored directly within your workspace repository for immediate access, offline viewing, and version control:

- **Workspace File Path**: [`file:///Users/efactordev/App/studio%20pavan%2019-09/efactor_sdui_flutter/efactor_sdui/docs/HRMS_FIELD_TRACKING_IMPLEMENTATION_PLAN.md`](file:///Users/efactordev/App/studio%20pavan%2019-09/efactor_sdui_flutter/efactor_sdui/docs/HRMS_FIELD_TRACKING_IMPLEMENTATION_PLAN.md)
- **Artifact Copy**: [`file:///Users/efactordev/.gemini/antigravity-ide/brain/ddeedabd-f156-4f58-beb3-6f006c562108/hrms_field_tracking_architecture_plan.md`](file:///Users/efactordev/.gemini/antigravity-ide/brain/ddeedabd-f156-4f58-beb3-6f006c562108/hrms_field_tracking_architecture_plan.md)

Whenever you are ready to implement, simply say **"Let's proceed with Phase 1"**, and we will begin building the package and core engine!
