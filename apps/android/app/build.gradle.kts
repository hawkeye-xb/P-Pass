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
        versionCode = 17
        // DESK-02①: 构建期注入完整版本串（release tag = "v0.3.2-test.2"，
        // 去前导 v）——Android 端靠它推导更新通道（含 -test. → test）并
        // 让连续 test tag 能自动升级（isNewer 预发布段比较）。本地/非 tag
        // 构建回退固定版本号。
        versionName =
            System.getenv("PPF_BUILD_VERSION")
                ?.takeIf { it.isNotBlank() }
                ?.removePrefix("v")
                ?: "0.3.5"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
        // UPD-01: 更新检查拿当前版本（BuildConfig.VERSION_NAME）
        buildConfig = true
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

    // H-10c: release 签名（Android 拒绝安装未签名 APK——"允许未知来源"
    // 只管非 Play 商店安装，管不了 APK 没签名）。keystore 经 CI secrets
    // 注入（base64 解码到文件 + 密码 + alias）；无凭据路径（env 未设置）
    // 保持 unsigned 行为不变。
    signingConfigs {
        if (!System.getenv("ANDROID_KEYSTORE_BASE64").isNullOrEmpty()) {
            create("release") {
                storeFile = file(System.getenv("ANDROID_KEYSTORE_FILE") ?: "release.keystore")
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEYSTORE_ALIAS")
                keyPassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            if (signingConfigs.findByName("release") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)

    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    // DOG-02: LocalLifecycleOwner (ON_RESUME 电池白名单刷新)
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    // ICON-02: 功能小图标走开源图标库，不再手抄 Material 的 pathData。
    // core 集（49 个常用图标 × 5 种风格）本来就随 material3 传递进
    // APK，显式声明只是把隐式依赖写明，体积零增量。**故意不引
    // material-icons-extended**：release 没开 minifyEnabled（无 R8
    // 裁剪），extended 会实打实往 APK 里塞几 MB——照片备份 App 体积
    // 敏感，为一两个图标不划算。若将来开了 R8 可重新评估。
    implementation("androidx.compose.material:material-icons-core")

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

    // T-054b background scheduling: periodic work under charging+WiFi
    // constraints, promoted to a dataSync FGS while a batch runs (S-04
    // verdict: FGS segmented sessions survive Doze).
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    // Desktop JNA for JVM unit tests — the @aar above only carries
    // Android natives; the iroh jar ships darwin/linux dylibs that JNA
    // loads when tests run on the host (live-daemon hello test).
    testImplementation("net.java.dev.jna:jna:5.15.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
