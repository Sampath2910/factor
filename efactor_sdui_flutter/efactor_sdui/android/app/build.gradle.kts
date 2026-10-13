import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.efactor_sdui"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    compileOptions {
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
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
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
}

// Android Studio Build / Make Project requests :app:testClasses.
// Flutter application modules do not create that task, so the IDE build fails.
tasks.register("testClasses")
