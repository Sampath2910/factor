# eFactor SDUI — Complete Setup & Version Report

Use this document when moving the project folder to another Windows laptop and building the Android (or Chrome) app.

**Project path (this machine):** `efactor_sdui_flutter/efactor_sdui`  
**App package:** `com.example.efactor_sdui`  
**App version:** `0.1.0+1`

---

## 1. Version matrix (what this project expects)

| Component | Version in use | Where defined / notes |
|-----------|----------------|------------------------|
| **Flutter SDK** | **3.47.5** (stable) | Installed at `C:\flutter\flutter` on this PC |
| **Dart SDK** | **3.13.4** | Bundled with Flutter |
| **DevTools** | 2.60.0 | Bundled with Flutter |
| **Android Gradle Plugin (AGP)** | **8.9.0** (matches Android Studio 2024.3) | `android/settings.gradle.kts` · Flutter check skipped via `skipDependencyChecks=true` |
| **Gradle Wrapper** | **8.14** | `android/gradle/wrapper/gradle-wrapper.properties` |
| **Kotlin (KGP)** | **2.3.20** | `android/settings.gradle.kts` |
| **compileSdk** | **36** | `android/app/build.gradle.kts` + root `build.gradle.kts` |
| **targetSdk** | Flutter default (typically 35) | `flutter.targetSdkVersion` |
| **minSdk** | **max(flutter.minSdk, 23)** → **23+** | Efactor AAR requires API 23+ |
| **NDK** | **28.2.13676358** (r28c) | `ndkVersion` in `app/build.gradle.kts` |
| **Java / JDK** | **17+ required**; this PC uses **OpenJDK 21.0.5** (Android Studio JBR) | Prefer Studio’s JBR |
| **Android Studio** | Must be **newer than 2024.3** for AGP 8.11.1 | Winget latest: **2026.1.4.7** |
| **Android SDK platform** | **android-36** | Via `sdkmanager` |
| **Android build-tools** | **36.0.0** | Via `sdkmanager` |
| **Git** | 2.x (e.g. 2.55) | Required by Flutter |
| **Chrome** | Any recent | Optional: `flutter run -d chrome` |
| **Windows Developer Mode** | ON | Required for Flutter plugin symlinks on Windows |

### Flutter hard minimums (Flutter 3.47.5)

Flutter **fails the build** if:

- AGP **&lt; 8.11.1**
- Gradle **&lt; 8.14.0**
- Kotlin (KGP) **&lt; 2.2.20**
- Java **&lt; 17**
- minSdk **&lt; 23**

### Important AGP vs Android Studio conflict (resolved for AS 2024.3)

| Tool | What we use |
|------|-------------|
| Android Studio **2024.3** (this PC) | Max AGP **8.9.0** → project uses **AGP 8.9.0** |
| Flutter 3.47.5 | Prefers AGP ≥ 8.11.1 → bypassed with `skipDependencyChecks=true` in `android/gradle.properties` |

**Current fix (already applied in this repo):**
- `android/settings.gradle.kts` → AGP **8.9.0**
- `android/gradle.properties` → `skipDependencyChecks=true`

After changing these, in Android Studio: **File → Invalidate Caches** (optional) → **File → Sync Project with Gradle Files**.

**Optional later upgrade:** Install Android Studio **2026.1.4.7+**, then you may raise AGP to **8.11.1** and remove `skipDependencyChecks=true`. Download: https://developer.android.com/studio

You can still build from CLI:

```powershell
cd efactor_sdui_flutter\efactor_sdui
flutter pub get
flutter build apk
```

---

## 2. Install everything on a new Windows laptop (full command list)

Open **PowerShell as Administrator** where noted. Use a normal PowerShell for the rest.

### Step A — Enable Developer Mode (required on Windows)

```powershell
start ms-settings:developers
```

Turn **Developer Mode** ON (allows Flutter plugin symlinks).

### Step B — Install Git

```powershell
winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements
```

Close and reopen the terminal after install.

### Step C — Install / upgrade Android Studio (required for AGP 8.11.1)

```powershell
winget install --id Google.AndroidStudio -e --accept-package-agreements --accept-source-agreements
# If an older Studio is already installed:
winget upgrade --id Google.AndroidStudio -e --accept-package-agreements --accept-source-agreements
```

After install, open Android Studio once → **More Actions → SDK Manager** and note the SDK path (usually `%LOCALAPPDATA%\Android\Sdk`).

### Step D — Install Flutter SDK 3.47.5 (stable)

```powershell
New-Item -ItemType Directory -Force -Path C:\flutter | Out-Null
curl.exe -L "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.5-stable.zip" -o C:\flutter\flutter_windows_3.47.5-stable.zip
tar -xf C:\flutter\flutter_windows_3.47.5-stable.zip -C C:\flutter
```

Add Flutter to User PATH permanently:

```powershell
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path","User").TrimEnd(';') + ";C:\flutter\flutter\bin",
  "User"
)
$env:Path = "C:\flutter\flutter\bin;" + $env:Path
```

Verify:

```powershell
flutter --version
# Expect: Flutter 3.47.5 · Dart 3.13.4
```

### Step E — Android SDK packages (platform-tools, API 36, build-tools, NDK)

```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"

# If cmdline-tools missing, install from Android Studio SDK Manager
# (SDK Tools → Android SDK Command-line Tools), or download cmdline-tools zip.

$sdkmanager = "$sdk\cmdline-tools\latest\bin\sdkmanager.bat"

cmd /c "echo y| `"$sdkmanager`" --sdk_root=`"$sdk`" --licenses"
cmd /c "`"$sdkmanager`" --sdk_root=`"$sdk`" `"platform-tools`" `"platforms;android-36`" `"build-tools;36.0.0`" `"ndk;28.2.13676358`""
```

Set user env vars (recommended):

```powershell
[Environment]::SetEnvironmentVariable("ANDROID_HOME", "$env:LOCALAPPDATA\Android\Sdk", "User")
[Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", "$env:LOCALAPPDATA\Android\Sdk", "User")
[Environment]::SetEnvironmentVariable("JAVA_HOME", "C:\Program Files\Android\Android Studio\jbr", "User")
```

### Step F — Point Flutter at the JDK & accept licenses

```powershell
flutter config --jdk-dir="C:\Program Files\Android\Android Studio\jbr"
flutter doctor --android-licenses
flutter doctor
```

You want Android toolchain **green**. Visual Studio can stay red if you are not building Windows desktop.

### Step G — Copy the project & configure local paths

Copy the whole folder `efactor_sdui_flutter` (or the repo) to the new laptop.

Edit **`efactor_sdui/android/local.properties`** (machine-specific; do not commit secrets):

```properties
flutter.sdk=C:\\flutter\\flutter
sdk.dir=C:\\Users\\<YOUR_USER>\\AppData\\Local\\Android\\Sdk
flutter.versionCode=1
flutter.versionName=0.1.0
```

Do **not** hardcode `org.gradle.java.home` unless Gradle cannot find a JDK. Prefer `JAVA_HOME` / Android Studio JBR.

### Step H — Fetch packages & build

```powershell
cd "<path-to>\efactor_sdui_flutter\efactor_sdui"
flutter pub get
flutter devices
```

**Android phone (USB debugging ON):**

```powershell
flutter run -d android
# or
flutter build apk --debug
```

**Chrome (UI only; some plugins like path_provider / Wi‑Fi / QR are limited on web):**

```powershell
flutter run -d chrome
```

**Validate Gradle only:**

```powershell
cd android
.\gradlew.bat :app:tasks --group=build
```

---

## 3. One-shot checklist (new laptop)

1. [ ] Windows Developer Mode ON  
2. [ ] Git installed  
3. [ ] Android Studio **2026.1+** installed (not 2024.3)  
4. [ ] Flutter **3.47.5** on PATH  
5. [ ] SDK: platform-tools, platforms;android-36, build-tools;36.0.0, ndk;28.2.13676358  
6. [ ] `flutter doctor` Android toolchain OK  
7. [ ] `local.properties` points to this machine’s Flutter + SDK  
8. [ ] `flutter pub get`  
9. [ ] Device/emulator connected **or** Chrome for web preview  
10. [ ] `flutter run`

---

## 4. Project Gradle / Android files to keep in sync

| File | Critical settings |
|------|-------------------|
| `android/settings.gradle.kts` | AGP `8.11.1`, Kotlin `2.3.20`, Flutter plugins |
| `android/gradle/wrapper/gradle-wrapper.properties` | Gradle `8.14` |
| `android/app/build.gradle.kts` | `compileSdk = 36`, `ndkVersion = "28.2.13676358"`, `minSdk ≥ 23`, JVM 17 |
| `android/build.gradle.kts` | compileSdk 36 for library subprojects |
| `android/gradle.properties` | AndroidX; optional `target-platform=android-arm64` |
| `android/local.properties` | **Per-machine** `flutter.sdk` + `sdk.dir` |
| `pubspec.yaml` | Dart SDK `>=3.5.0 <4.0.0`, path dep `efactor_provisioning` |

---

## 5. Main Dart / Flutter package dependencies (from pubspec.yaml)

| Package | Constraint |
|---------|------------|
| `efactor_provisioning` | path: `packages/efactor_provisioning` |
| `google_fonts` | ^8.2.1 |
| `gauge_indicator` | ^0.5.0 |
| `url_launcher` | ^6.3.1 |
| `cached_network_image` | ^3.4.1 |
| `http` | ^1.2.2 |
| `flutter_secure_storage` | ^9.2.2 |
| `shared_preferences` | ^2.3.2 |
| `path_provider` | ^2.1.2 |
| `connectivity_plus` | ^6.0.3 |
| `network_info_plus` | ^6.0.0 |
| `device_info_plus` | ^10.1.2 |
| `wifi_scan` | ^0.4.1+2 |
| `geolocator` | ^12.0.0 |
| `image_picker` | ^1.1.2 |
| `mobile_scanner` | ^5.2.3 |
| `permission_handler` | ^11.3.1 |
| `webview_flutter` | ^4.14.1 |

Run `flutter pub get` on each machine; versions resolve via `pubspec.lock`.

---

## 6. Common failures & fixes

| Symptom | Fix |
|---------|-----|
| AGP lower than 8.11.1 (Flutter error) | Keep AGP **8.11.1** in `settings.gradle.kts` |
| “Latest supported AGP is 8.9.0” (Android Studio) | **Upgrade Android Studio** to 2026.1+; do not downgrade AGP |
| Symlink / plugin build error on Windows | Enable **Developer Mode** |
| NDK `source.properties` missing | Reinstall: `sdkmanager "ndk;28.2.13676358"` |
| `local.properties` wrong Flutter path | Set `flutter.sdk` to this PC’s Flutter folder |
| Chrome auth / `path_provider` MissingPluginException | Use a real Android device for full auth & IoT features |
| No emulator | Create AVD in Android Studio Device Manager, or plug in a phone |

---

## 7. Recommended daily commands

```powershell
cd "<path>\efactor_sdui_flutter\efactor_sdui"
flutter pub get
flutter clean          # only when builds are corrupted
flutter run -d android
# hot reload: press r   |  hot restart: R   |  quit: q
```

---

*Generated for eFactor SDUI · Flutter 3.47.5 · AGP 8.11.1 · Gradle 8.14 · Kotlin 2.3.20 · compileSdk 36 · NDK 28.2.13676358*
