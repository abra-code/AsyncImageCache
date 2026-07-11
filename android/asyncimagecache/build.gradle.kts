// The AsyncImageCache library module. A 1:1 semantic port of Sources/AsyncImageCache (Swift). Runtime
// dependencies are limited to the AndroidX/Compose baseline + kotlinx-coroutines; graphics come from the OS
// SDK (android.graphics.ImageDecoder / Bitmap / Canvas). No third-party image libraries.

plugins {
    // AGP 9.2 ships built-in Kotlin support (it registers the `kotlin` extension), so the standalone
    // org.jetbrains.kotlin.android plugin is neither applied nor needed - only the Compose compiler plugin.
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.abracode.asyncimagecache"
    compileSdk = 36

    defaultConfig {
        minSdk = 31
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    // Graphics-touching tests run instrumented on an emulator; pure-logic tests run on the JVM. Return default
    // values from android.* stubs is off - JVM tests here never touch android.graphics (that is androidTest).
    testOptions {
        unitTests.isReturnDefaultValues = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)

    // JVM unit tests (pure logic: keys, codecs, models, eviction order).
    testImplementation(libs.junit)

    // Instrumented tests (Bitmap / ImageDecoder / Canvas / network / threads).
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
