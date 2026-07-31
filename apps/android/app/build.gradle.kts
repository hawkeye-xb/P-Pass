plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.hawkeyexb.ppass"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.hawkeyexb.ppass"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        // The iroh Maven jar bundles DESKTOP natives (darwin/linux/win)
        // for JVM use; Android gets libiroh_ffi.so from jniLibs. Strip
        // the desktop copies — 50MB of dead weight, and their absence
        // on-device was the T-052 real-phone crash (UnsatisfiedLinkError).
        resources.excludes += listOf(
            "darwin-aarch64/*", "linux-aarch64/*", "linux-x86-64/*", "win32-x86-64/*",
        )
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)

    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")

    // T-052 camera scan: CameraX preview/analysis + ZXing core decode.
    // ZXing is pure Java — no Google Play Services, works on HarmonyOS
    // compatibility layers (卓易通) where GMS is absent.
    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.zxing:core:3.5.3")

    // Wire types mirror crates/proto (JSON over iroh streams).
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // T-053 content hashing — pure-Java BLAKE3, cross-checked against
    // Rust-generated vectors (tests/blake3-vectors.json) in unit tests.
    implementation("io.github.rctcwyvrn:blake3:1.3")

    // iroh-ffi Kotlin bindings — same artifact the S-03 spike proved
    // on-device (T-051 wires it up).
    implementation("computer.iroh:iroh:1.1.0") {
        exclude(group = "net.java.dev.jna", module = "jna")
    }
    implementation("net.java.dev.jna:jna:5.15.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    // Desktop JNA for JVM unit tests — the @aar above only carries
    // Android natives; the iroh jar ships darwin/linux dylibs that JNA
    // loads when tests run on the host (live-daemon hello test).
    testImplementation("net.java.dev.jna:jna:5.15.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
