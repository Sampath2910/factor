import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Apply only when Firebase config is present so local builds still work.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Release signing (audit 5.2): load a real keystore from android/key.properties
// when present. When it is absent (local/dev), release falls back to the debug
// signing config so builds keep working with no change.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.example.efactor_sdui"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    compileOptions {
        // Required by flutter_local_notifications (and modern AndroidX).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.efactor_sdui"

        // Efactor AAR requires Android SDK 23 or later.
        minSdk = maxOf(flutter.minSdkVersion, 23)

        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Match target-platform=android-arm64. Avoids the blocked 32-bit
        // gen_snapshot.exe used by a full release ABI set.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        getByName("debug") {
            val projectKeystore = file("debug.keystore")
            if (projectKeystore.exists()) {
                storeFile = projectKeystore
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the real release keystore when android/key.properties exists,
            // otherwise fall back to debug signing (unchanged dev behavior).
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Audit 5.2: enable R8 code shrinking/obfuscation for release. NOTE:
            // resource shrinking is intentionally left OFF — this is a
            // schema-driven (SDUI) app that can reference resources dynamically
            // by name, which resource shrinking could strip. R8 affects RELEASE
            // builds only (debug is untouched); a release build must be tested
            // on-device before shipping, and proguard-rules.pro extended if any
            // reflection-based code is stripped.
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

/*
 * Kotlin 2.x compiler configuration.
 *
 * Keep this outside android { }.
 * This makes Kotlin generate JVM 17 bytecode while Gradle itself
 * continues running with Android Studio's Java 21 JBR.
 */
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Android Studio Build / Make Project requests :app:testClasses.
// Flutter application modules do not create that task, so the IDE build fails.
tasks.register("testClasses")
