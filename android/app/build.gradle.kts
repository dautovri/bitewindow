plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.dautovri.bitecurve"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.dautovri.bitecurve"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "1.2.0"
        // The same deployed worker the iOS app uses (backend/).
        buildConfigField("String", "API_BASE", "\"https://bitewindow-wx.dautov.workers.dev\"")
    }

    // Play upload key: lives outside the repo; path and password come from the environment.
    val uploadKeystore = System.getenv("BITECURVE_UPLOAD_KEYSTORE")
    signingConfigs {
        if (uploadKeystore != null) {
            create("upload") {
                storeFile = file(uploadKeystore)
                storePassword = System.getenv("BITECURVE_UPLOAD_PASSWORD")
                keyAlias = "upload"
                keyPassword = System.getenv("BITECURVE_UPLOAD_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Without the upload key (any machine but the one that publishes) a release build is
            // signed with the debug key, so it can be installed and tried. Play refuses such a build.
            signingConfig = signingConfigs.getByName(if (uploadKeystore != null) "upload" else "debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    androidResources {
        localeFilters += listOf("en", "da", "de", "es", "fi", "fr", "it", "ja", "ko", "nb", "nl", "pl", "pt-rBR", "ru", "sv", "tr", "uk", "zh")
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(project(":core"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.core.ktx)
    implementation(libs.appcompat)
    implementation(libs.coroutines.android)
    implementation(libs.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.maplibre)
    implementation(libs.work.runtime)
    implementation(libs.billing)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
}
