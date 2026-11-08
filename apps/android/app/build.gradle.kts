plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "studio.roast.app"
    compileSdk = 37
    defaultConfig {
        applicationId = "studio.roast.app"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}
dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-service:2.9.4")
    implementation("androidx.camera:camera-camera2:1.5.0")
    implementation("androidx.camera:camera-lifecycle:1.5.0")
    implementation("androidx.media3:media3-exoplayer:1.9.4")
    implementation("androidx.media3:media3-transformer:1.9.4")
    // Latest published bundled selfie-streaming release in Google's Maven registry (checked 2026-11-04).
    implementation("com.google.mlkit:segmentation-selfie:16.0.0-beta6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // Official stable release, Maven metadata and upstream changelog checked 2026-11-05.
    implementation("com.squareup.okhttp3:okhttp:5.5.1")
    // Official stable Android identity/browser releases; checked 2026-11-05.
    implementation("androidx.credentials:credentials:1.6.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0")
    // 1.2.1 requires Kotlin metadata2.4; 1.2.0 is the compatible stable release for this toolchain.
    implementation("com.google.android.libraries.identity.googleid:googleid:1.2.0")
    implementation("androidx.browser:browser:1.10.0")
    // Official upstream Android CPU runtime; SHA256 recorded in README.
    implementation(files("libs/sherpa-onnx-2.0.1.aar"))
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
