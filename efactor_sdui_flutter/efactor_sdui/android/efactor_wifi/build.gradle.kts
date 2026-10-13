plugins {
    id("com.android.library")
}

android {
    namespace = "tech.efactor.ui"
    compileSdk = 35

    defaultConfig {
        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    /*
     * The Efactor SDK is required by ProvisionLanding.java for:
     *
     * tech.efactor.proto.*
     * EfactorProvisionManager
     * EfactorCloudManager
     * EfactorDevice
     * EfactorConstants
     */
    implementation(
        files("../app/libs/efactorprotov2-5.65.aar")
    )

    // Android UI dependencies
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity:1.10.1")
    implementation("androidx.fragment:fragment:1.8.6")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.recyclerview:recyclerview:1.4.0")

    // MaterialToolbar, Chip, ChipGroup and Snackbar
    implementation("com.google.android.material:material:1.12.0")

    // ProvisionLanding uses EventBus, Subscribe and ThreadMode
    implementation("org.greenrobot:eventbus:3.3.1")
}