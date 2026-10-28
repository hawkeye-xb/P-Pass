import com.android.build.api.variant.impl.VariantOutputImpl
import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val irohBlobsJniLibs = layout.buildDirectory.dir("generated/jniLibs")
// #1124：同一个 libtransport.so 里还带着与 iOS 共用的 uniffi 导出（控制面、取原图、关闭码）；
// 它们的 Kotlin 绑定由同一个任务生成（包名见 crates/transport/uniffi.toml），不入库。
val transportKotlinBindings = layout.buildDirectory.dir("generated/source/uniffi/kotlin")
val buildIrohBlobsProviderBridge = tasks.register<Exec>("buildIrohBlobsProviderBridge") {
    val repoRoot = rootProject.projectDir.resolve("../..").canonicalFile
    val ndkHome = providers.environmentVariable("ANDROID_NDK_HOME").orNull
        ?: error("ANDROID_NDK_HOME must be set to build the native iroh-blobs provider")
    workingDir(repoRoot)
    commandLine(
        "bash",
        "tools/build-android-iroh-blobs-bridge.sh",
        irohBlobsJniLibs.get().asFile.absolutePath,
        transportKotlinBindings.get().asFile.absolutePath,
    )
    environment("ANDROID_NDK_HOME", ndkHome)
    inputs.files(
        fileTree(repoRoot) {
            // #1124：mobile-ffi 经 crates/proto 编解码帧、登记关闭码；#1118：经 crates/pair-pake 做配对验证码。
            include("Cargo.toml", "Cargo.lock", "crates/transport/**", "crates/proto/**", "crates/pair-pake/**")
        }
    )
    outputs.file(irohBlobsJniLibs.map { it.file("arm64-v8a/libtransport.so") })
    outputs.dir(transportKotlinBindings)
}

android {
    namespace = "com.hawkeyexb.ppass"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.hawkeyexb.ppass"
        minSdk = 26
        targetSdk = 35
        versionCode = 67
        // DESK-02①: 构建期注入完整版本串（release tag = "v0.3.2-test.2"，
        // 去前导 v）——Android 端靠它推导更新通道（含 -test. → test）并
        // 让连续 test tag 能自动升级（isNewer 预发布段比较）。本地/非 tag
        // 构建回退固定版本号。
        versionName =
            System.getenv("PPF_BUILD_VERSION")
                ?.takeIf { it.isNotBlank() }
                ?.removePrefix("v")
                ?: "0.10.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // #1121：更新验签公钥，按通道各一把，构建期从仓库里唯一的来源读：
        //   stable = 桌面 tauri.conf.json 的 updater pubkey（两端同一把）；
        //   test   = release/update-keys/test.pub，没有就留空——test 包拒收一切更新
        //            （宁可装不上，也不拿正式密钥去验 test 包）。
        // 值是 tauri 格式：base64("untrusted comment: …\n<minisign 公钥>")。
        buildConfigField("String", "UPDATE_PUBKEY_STABLE", "\"${updatePubkeyStable()}\"")
        buildConfigField("String", "UPDATE_PUBKEY_TEST", "\"${updatePubkeyTest()}\"")
    }

    sourceSets {
        getByName("main").jniLibs.srcDir(irohBlobsJniLibs)
        getByName("main").java.srcDir(transportKotlinBindings)
        // #420: JVM 单测与设备测试共用的测试辅助（例如 addrOf）。只放两边都要的，
        // 生产代码看不到这里。
        getByName("test").java.srcDir("src/sharedTest/java")
        getByName("androidTest").java.srcDir("src/sharedTest/java")
    }

    buildFeatures {
        compose = true
        // UPD-01: 更新检查拿当前版本（BuildConfig.VERSION_NAME）
        buildConfig = true
    }

    // #1151：BouncyCastle 与 jspecify 各带一份只含清单的 META-INF/versions/9/OSGI-INF/MANIFEST.MF，
    // mergeJavaResource 遇到重名直接失败。OSGi 清单在 Android 上没有用处，排除即可。
    packaging {
        resources {
            excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        }
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

    // LINT-01: lint 在 CI 里门禁——真报当场修（本卡已修：BucketScreen/
    // PhotosScreen/VideoScreen 的 ProduceStateDoesNotAssignValue 误报显式
    // @Suppress 并写理由；AndroidManifest 的 camera uses-feature 真错误已
    // 修）。首次开门禁时顶出的存量告警（GradleDependency 依赖版本落后、
    // Recycle 游标/流未显式 close、PluralsCandidate 复数格式等——修复需要
    // 碰业务代码，本卡范围明确不含业务逻辑改动）逐条记录进
    // lint-baseline.xml，理由见该文件顶部注释与本卡「备注」。baseline 只
    // 冻结存量，新增的同类违规仍会让 CI 变红。
    lint {
        baseline = file("lint-baseline.xml")
    }
}

// UPD-15（#685）：**产物名 = P-Pass_<该端版本号>_android.apk**（与 tools/artifact-names.sh 同规则）。
// 版本号取自上面同一个 `versionName`（PPF_BUILD_VERSION → tools/release-version.sh →
// release/versions.json）⇒ 单一来源派生，不是 CI 里手工改名；本地构建同样得到正确名字。
// 无凭据路径（keystore secrets 未设置）保持 `-unsigned` 后缀：CI 的
// Detect signing 靠文件名区分「有签名产物」与「只有 unsigned」，去掉后缀会让
// 它去验一个未签的包（REL-09 #631 的红线）。
val androidSigned = !System.getenv("ANDROID_KEYSTORE_BASE64").isNullOrEmpty()
androidComponents {
    onVariants { variant ->
        variant.outputs.forEach { output ->
            // AGP 8.x 的新 VariantOutput 接口不暴露 outputFileName，改名要走 impl
            // （Android 生态里公认的做法；AGP 大版本升级时这里是第一个要看的地方）。
            val impl = output as? VariantOutputImpl ?: return@forEach
            // release 走发布名（无凭据加 -unsigned）；debug 等其它 variant 带上自己的
            // buildType 后缀，避免与 release 名字撞车（ci 的 debug 产物断言也按 glob 找）。
            val suffix = if (variant.buildType == "release") {
                if (androidSigned) "" else "-unsigned"
            } else {
                "-${variant.buildType}"
            }
            impl.outputFileName.set("P-Pass_${output.versionName.get()}_android$suffix.apk")
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(buildIrohBlobsProviderBridge)
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

    // MOB-47: 成熟播放器替代 VideoView——Media3 ExoPlayer（官方标准）。
    // PlayerView 自带播放/暂停/进度条/seek/错误态；Compose 用 AndroidView
    // 桥接 + DisposableEffect 释放。media3-ui 提供 PlayerView，media3-exoplayer
    // 提供 ExoPlayer 本体（media3-common 由其传递）。
    // 版本钉 1.9.4：1.10+ 要求 compileSdk 36，而本仓钉 compileSdk 35
    // （AGP 8.7.3 上限 35）——升 compileSdk 是独立卡的范围，不在本卡动。
    implementation("androidx.media3:media3-exoplayer:1.9.4")
    implementation("androidx.media3:media3-ui:1.9.4")

    // MOB-26: Telephoto handles image pan/zoom and cooperates with nested scrolling.
    // Only the gesture module is used: current thumbnails stay in the single in-memory
    // cache, so no Coil/Glide loader or disk cache is introduced on the phone.
    implementation("me.saket.telephoto:zoomable:0.19.0")

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
    // org.json:json:20190722 是它的传递依赖（公告 GHSA-3vqj-43w4-2q58 / GHSA-4jq9-2xhw-jpx7）；
    // Android 系统自带 org.json，blake3 本身也不用它，exclude 掉避免进 APK（#1194）。
    implementation("io.github.rctcwyvrn:blake3:1.3") {
        exclude(group = "org.json", module = "json")
    }


    // UPD-02 / #1151: 更新包 minisign 验签——Ed25519 与 BLAKE2b-512 都用在维护的
    // BouncyCastle（轻量 API，不经 JCA、不注册 provider）。原先的 net.i2p eddsa 0.3.0
    // 已停更且有无修复版的公告，BLAKE2b 也不再手写。代价：release 未开 R8，整个 jar
    // 进 APK（约 +3MB，APK 58MB 量级）。
    implementation("org.bouncycastle:bcprov-jdk18on:1.86")

    // #1124：uniffi 生成的 Kotlin 绑定经 JNA 调 libtransport.so（控制面不再用 iroh-ffi）。
    implementation("net.java.dev.jna:jna:5.15.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // T-054b background scheduling: periodic work under charging+WiFi
    // constraints, promoted to a dataSync FGS while a batch runs (S-04
    // verdict: FGS segmented sessions survive Doze).
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    testImplementation("junit:junit:4.13.2")
    // 本地 JVM 单测里 android.jar 的 org.json 只是 stub，要真实现；只进测试类路径，不进 APK。
    testImplementation("org.json:json:20250517")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    // #1119：断开后 unique work 的状态要查 WorkManager 自己的（在设备上跑，lane 只编译）。
    androidTestImplementation("androidx.work:work-testing:2.10.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    // Desktop JNA for JVM unit tests — the @aar above only carries Android natives. Tests that
    // touch the generated bindings load a host build of libtransport (live-daemon tests only;
    // `jna.library.path` below).
    testImplementation("net.java.dev.jna:jna:5.15.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
}

// #1121：见 defaultConfig 里的 UPDATE_PUBKEY_* 注释。
fun updatePubkeyStable(): String {
    val conf = rootProject.file("../desktop/src-tauri/tauri.conf.json")
    @Suppress("UNCHECKED_CAST")
    val json = groovy.json.JsonSlurper().parse(conf) as Map<String, Any?>
    val plugins = json["plugins"] as Map<String, Any?>
    val updater = plugins["updater"] as Map<String, Any?>
    return (updater["pubkey"] as String).trim()
}

fun updatePubkeyTest(): String {
    val f = rootProject.file("../../release/update-keys/test.pub")
    return if (f.isFile) f.readText().trim() else ""
}

// #1124：对着真 daemon 跑的 JVM 单测（PPF_DAEMON_QR 等，默认跳过）经 uniffi 绑定调宿主机版的
// libtransport（`cargo build -p transport --features mobile-ffi`，见 `just android-pair`）。
tasks.withType<Test>().configureEach {
    val cargoTarget = System.getenv("CARGO_TARGET_DIR") ?: rootProject.projectDir.resolve("../../target").path
    systemProperty("jna.library.path", "$cargoTarget/debug")
}
