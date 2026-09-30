// UPD-01: 自更新轻实现（脱店 App 无标准库；第三方多失修——自研）。
//
// 设计要点：
//  - manifest 从 GitHub release 资产直链拉取（latest/download 自动指向
//    最新非 draft release；draft/无 release 时 404 → 视为无更新，静默）。
//  - 不嵌入公钥：APK 安装由系统 PackageInstaller 强制同签名校验兜底
//    （与已装 App 签名不一致直接拒装）——manifest 被篡改指向恶意包也
//    装不上（UPD-01 卡面反证由系统侧保证）。
//  - 版本比较：SemVer 三段数字（预发布后缀只影响同主版本内的优先级，
//    跨版本升级只看数字段）。
package com.hawkeyexb.ppass.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** tauri 风格 manifest 的 android 子集（release.yml 由 tools/make-update-manifest.mjs 产出）。 */
@Serializable
data class UpdateManifest(
    val version: String,
    val notes: String = "",
    val platforms: Map<String, PlatformEntry> = emptyMap(),
)

@Serializable
data class PlatformEntry(
    val url: String,
    val signature: String = "",
)

data class UpdateInfo(
    val version: String,
    val notes: String,
    val url: String,
)

private const val MANIFEST_URL =
    "https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest.json"

// REL-07 test 通道：固定的滚动 prerelease `test-channel` 里的 manifest.json
// ——release.yml 每次 test 发布后用已签名的 manifest 覆盖它。静态文件下载，
// 不调 GitHub API（没有匿名限流）。REL-02 时代的 Worker
// （update.p-pass.hawkeye-xb.com/manifest?channel=test）留作旧构建兼容层。
private const val TEST_CHANNEL_URL =
    "https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/manifest.json"

private val json = Json { ignoreUnknownKeys = true }

/**
 * REL-02: 通道 → manifest URL（纯函数，JVM 可测）。
 * 反证红线：stable 必须恒等于 GitHub latest 原 URL（卡面「不准动」——
 * 改动此 URL 本测试必红）；test 走滚动 prerelease 的静态文件（REL-07）。
 */
fun channelManifestUrl(channel: UpdateChannel): String = when (channel) {
    UpdateChannel.Stable -> MANIFEST_URL
    UpdateChannel.Test -> TEST_CHANNEL_URL
}

/** SemVer 三段数字比较：candidate 严格大于 current 才算更新。 */
fun isNewer(candidate: String, current: String): Boolean {
    val c = parseSemVer(candidate)
    val cur = parseSemVer(current)
    for (i in 0..2) {
        val diff = c.first.getOrElse(i) { 0 } - cur.first.getOrElse(i) { 0 }
        if (diff != 0) return diff > 0
    }
    // 同核心：正式 > 预发布（0.3.2 比 0.3.2-test.1 新）；同为预发布按数字段
    // 比较（0.3.2-test.2 > 0.3.2-test.1）——与 daemon version_cmp 同语义，
    // test 通道连续 test tag 才能自动升级（DESK-02 用户手机自动更新链路）。
    val cp = c.second
    val curp = cur.second
    if (cp == null && curp != null) return true
    if (cp != null && curp == null) return false
    if (cp != null && curp != null) {
        return prereleaseNum(cp) > prereleaseNum(curp)
    }
    return false
}

/** "0.3.2-test.1" → (数字段, 预发布后缀或 null)。 */
private fun parseSemVer(v: String): Pair<List<Int>, String?> {
    val parts = v.split('-', '+')
    val nums = parts.first().split('.').map { it.toIntOrNull() ?: 0 }
    return nums to parts.getOrNull(1)
}

/** 预发布后缀的数字段："test.2" → 2、"rc1" → 1；无数字 → 0。 */
private fun prereleaseNum(pre: String): Int =
    pre.filter { it.isDigit() }.toIntOrNull() ?: 0

/**
 * DESK-02①: 更新通道由构建推导——零 UI、零持久化。
 * 版本含 `-test.`（构建期 PPF_BUILD_VERSION 注入完整 tag）→ test 通道，
 * 否则 stable。正式构建永远 stable（家人设备不被 test 构建波及）。
 */
fun channelFromVersion(version: String): UpdateChannel =
    if (version.contains("-test.")) UpdateChannel.Test else UpdateChannel.Stable

/** 解析 manifest body → 更新信息；无 android 条目/版本不更新/解析失败返回 null。 */
fun parseUpdateManifest(body: String, currentVersion: String): UpdateInfo? {
    return try {
        val manifest = json.decodeFromString(UpdateManifest.serializer(), body)
        val entry = manifest.platforms["android-arm64"] ?: return null
        if (!isNewer(manifest.version, currentVersion)) return null
        UpdateInfo(version = manifest.version, notes = manifest.notes, url = entry.url)
    } catch (_: Exception) {
        null
    }
}

/**
 * 拉取并解析 manifest；无更新/不可达返回 null（静默，绝不打断启动）。
 * REL-02: 按通道取源——stable = GitHub latest（原 URL 语义不动）；
 * test = 滚动 prerelease `test-channel` 的 manifest 资产（REL-07）。
 */
suspend fun fetchUpdate(currentVersion: String, channel: UpdateChannel = UpdateChannel.Stable): UpdateInfo? =
    withContext(Dispatchers.IO) {
        try {
            val body = httpGet(channelManifestUrl(channel)) ?: return@withContext null
            parseUpdateManifest(body, currentVersion)
        } catch (_: Exception) {
            null // 网络/解析失败一律静默——更新检查绝不能崩启动
        }
    }

/**
 * REL-07: manifest 拉取的 HTTP 结果分类（纯函数，JVM 可测）。
 * 404 = 真的没有可用 release（指针/正式 release 尚不存在）；
 * 其它非 200（5xx、403/429 限流等）= 检查失败，
 * **不是**「已是最新」——UX 上仍静默（不打断启动），但日志必须分得开。
 */
enum class ManifestFetchOutcome { Ok, NoRelease, CheckFailed }

fun classifyManifestStatus(code: Int): ManifestFetchOutcome = when (code) {
    200 -> ManifestFetchOutcome.Ok
    404 -> ManifestFetchOutcome.NoRelease
    else -> ManifestFetchOutcome.CheckFailed
}

// 诊断：`adb logcat -s PPassUpdate`（鸿蒙真机需先 `adb shell setprop log.tag.PPassUpdate V`）。
private const val LOG_TAG = "PPassUpdate"

/** GET 文本；非 200 / 网络失败返回 null（REL-07：按 classifyManifestStatus 分级打日志）。 */
private fun httpGet(url: String): String? = try {
    val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
    conn.connectTimeout = 8_000
    conn.readTimeout = 8_000
    conn.requestMethod = "GET"
    // GitHub API 要 User-Agent（无 UA 403）。
    conn.setRequestProperty("User-Agent", "P-Pass-UpdateChecker")
    val code = conn.responseCode
    when (classifyManifestStatus(code)) {
        ManifestFetchOutcome.Ok -> conn.inputStream.bufferedReader().use { it.readText() }
        ManifestFetchOutcome.NoRelease -> {
            android.util.Log.i(LOG_TAG, "no release at $url (HTTP 404) — no update")
            null
        }
        ManifestFetchOutcome.CheckFailed -> {
            val detail = runCatching {
                conn.errorStream?.bufferedReader()?.use { it.readText().take(200) }
            }.getOrNull()
            val retryAfter = conn.getHeaderField("Retry-After")
            android.util.Log.w(
                LOG_TAG,
                "update check FAILED at $url: HTTP $code retry-after=$retryAfter body=$detail",
            )
            null
        }
    }
} catch (e: Exception) {
    android.util.Log.w(LOG_TAG, "update check FAILED at $url: $e")
    null
}

/**
 * NET-09: APK 下载的结果分类。原实现 `catch (_: Exception) false` 把所有
 * 失败压成一个 false，日志里分不出「服务器不回字节」「HTTP 非 200」「根本
 * 没连上」。这里按**失败发生的阶段**分类，而不是按异常类型猜：
 * `SocketTimeoutException` 在 connect 阶段是 connectTimeout（连不上），在
 * 等响应头 / 读 body 阶段是 readTimeout（字节停滞）——同一个异常类，两种事实。
 */
sealed interface ApkDownloadResult {
    /** 下载完整落盘（[downloadApk] 的成功值；[downloadAndInstall] 成功时也返回它）。 */
    data class Ok(val bytes: Long) : ApkDownloadResult

    /** 已建立连接，但连续 [readTimeoutMs] 毫秒没有新字节（readTimeout 触发）。 */
    data class Stalled(
        val phase: Phase,
        val receivedBytes: Long,
        val readTimeoutMs: Int,
    ) : ApkDownloadResult

    /** 服务器回了响应，但最终（逐跳跟随重定向后）的状态码不是 200。 */
    data class HttpStatus(val code: Int) : ApkDownloadResult

    /**
     * 连接层失败（readTimeout 之外的网络错误）：在 [Phase.Connect] 是连接
     * 拒绝 / DNS / TLS 握手 / connectTimeout；在其它阶段是中途断开或 body
     * 比 Content-Length 短。
     */
    data class ConnectionFailed(
        val phase: Phase,
        val receivedBytes: Long,
        val cause: String,
    ) : ApkDownloadResult

    /** 本机写盘失败——不是网络问题，不能混进上面三类。 */
    data class LocalWriteFailed(val receivedBytes: Long, val cause: String) : ApkDownloadResult

    /**
     * 不属于上面任何一类的运行时异常（URL 不是 http、缺权限等）。单列出来，
     * 既不让它崩掉调用方的协程，也不把它冒充成网络失败。
     */
    data class Unexpected(val phase: Phase, val cause: String) : ApkDownloadResult

    /** 下载成功，但交给系统安装器这一步失败（FileProvider / startActivity）。 */
    data class InstallLaunchFailed(val bytes: Long, val cause: String) : ApkDownloadResult

    enum class Phase { Connect, Headers, Body }
}

/** 日志用的一行描述（纯函数，JVM 可测）：类别名 + 关键数字，不带 URL 以外的隐私。 */
fun ApkDownloadResult.logLine(url: String): String = when (this) {
    is ApkDownloadResult.Ok -> "apk download OK at $url: $bytes bytes"
    is ApkDownloadResult.Stalled ->
        "apk download STALLED at $url: no bytes for ${readTimeoutMs}ms " +
            "during ${phase.name.lowercase()} (received $receivedBytes bytes)"
    is ApkDownloadResult.HttpStatus -> "apk download FAILED at $url: HTTP $code"
    is ApkDownloadResult.ConnectionFailed ->
        "apk download CONNECTION FAILED at $url during ${phase.name.lowercase()} " +
            "(received $receivedBytes bytes): $cause"
    is ApkDownloadResult.LocalWriteFailed ->
        "apk download LOCAL WRITE FAILED for $url (received $receivedBytes bytes): $cause"
    is ApkDownloadResult.Unexpected ->
        "apk download UNEXPECTED ERROR at $url during ${phase.name.lowercase()}: $cause"
    is ApkDownloadResult.InstallLaunchFailed ->
        "apk downloaded ($bytes bytes) but installer launch FAILED for $url: $cause"
}

// APK 走 HTTPS（GitHub release 资产 → 302 → CDN），不经 iroh relay，没有
// NET-09 下载原图那条 60s 取值依据里的「relay 恢复空窗」。readTimeout 本身是
// per-read，即「连续 N 秒零新字节」的停滞语义，所以沿用原有 30s，只把分类做对。
internal const val APK_CONNECT_TIMEOUT_MS = 15_000
internal const val APK_READ_TIMEOUT_MS = 30_000
private const val APK_COPY_BUFFER = 64 * 1024
internal const val APK_MAX_REDIRECTS = 5

/**
 * NET-09: 下载 [url] 到 [dest] 并分类失败（不含安装；JVM 用假连接可测）。
 * [open] 只负责造出未连接的 HttpURLConnection；超时由本函数设置
 * （[readTimeoutMs] 只为测试缩短，生产恒用默认值）。
 * 任何失败都会删掉 [dest] 的残包，不留半个 APK 给下次误装。
 */
fun downloadApk(
    url: String,
    dest: File,
    open: (String) -> java.net.HttpURLConnection = {
        java.net.URL(it).openConnection() as java.net.HttpURLConnection
    },
    readTimeoutMs: Int = APK_READ_TIMEOUT_MS,
): ApkDownloadResult {
    var current = url
    var redirects = 0
    var phase = ApkDownloadResult.Phase.Connect
    var received = 0L
    var conn: java.net.HttpURLConnection? = null
    var result: ApkDownloadResult? = null
    try {
        // 重定向逐跳手动跟：生产 URL 是 GitHub release 资产，302 到另一个 CDN
        // 主机。若交给 HttpURLConnection 自动跟随，CDN 那一跳的 DNS / TCP /
        // TLS / connectTimeout 都发生在 responseCode 里——阶段已是 Headers，
        // CDN 连不上会被错记成「字节停滞」。逐跳显式 connect 才能把阶段分对。
        while (result == null) {
            phase = ApkDownloadResult.Phase.Connect
            val c = open(current)
            conn = c
            c.instanceFollowRedirects = false
            c.connectTimeout = APK_CONNECT_TIMEOUT_MS
            c.readTimeout = readTimeoutMs
            // 显式 connect：DNS / 拒绝 / TLS 握手 / connectTimeout 都在这一步抛，
            // 与之后的 readTimeout 分开。
            c.connect()
            phase = ApkDownloadResult.Phase.Headers
            // 先看状态码再碰 inputStream：非 2xx 时 inputStream 会直接抛 IOException，
            // 那样 HTTP 404/5xx 就会被误记成网络失败。
            val code = c.responseCode
            val location = if (code in 300..399) c.getHeaderField("Location") else null
            if (location != null && redirects < APK_MAX_REDIRECTS) {
                current = java.net.URL(java.net.URL(current), location).toString()
                redirects++
                runCatching { c.disconnect() }
                conn = null
            } else if (code != 200) {
                // 含：3xx 没带 Location、重定向超过上限——都如实报最后那个状态码。
                result = ApkDownloadResult.HttpStatus(code)
            } else {
                phase = ApkDownloadResult.Phase.Body
                val expected = c.contentLengthLong
                result = copyBody(c.inputStream, dest) { received = it }
                    ?: if (expected >= 0 && received != expected) {
                        ApkDownloadResult.ConnectionFailed(
                            phase, received, "body ended early: $received of $expected bytes",
                        )
                    } else {
                        ApkDownloadResult.Ok(received)
                    }
            }
        }
    } catch (e: java.net.SocketTimeoutException) {
        result = if (phase == ApkDownloadResult.Phase.Connect) {
            ApkDownloadResult.ConnectionFailed(phase, received, e.toString())
        } else {
            ApkDownloadResult.Stalled(phase, received, readTimeoutMs)
        }
    } catch (e: java.io.IOException) {
        result = ApkDownloadResult.ConnectionFailed(phase, received, e.toString())
    } catch (e: RuntimeException) {
        result = ApkDownloadResult.Unexpected(phase, e.toString())
    } finally {
        conn?.let { runCatching { it.disconnect() } }
    }
    val final = result!!
    if (final !is ApkDownloadResult.Ok) dest.delete()
    return final
}

/**
 * 把 body 抄进 [dest]。网络读的异常原样抛给 [downloadApk] 分类；写盘失败在这里
 * 就地转成 [ApkDownloadResult.LocalWriteFailed]（返回非 null）。正常读完返回 null。
 */
private fun copyBody(
    input: java.io.InputStream,
    dest: File,
    onProgress: (Long) -> Unit,
): ApkDownloadResult? {
    var received = 0L
    val output = try {
        dest.outputStream()
    } catch (e: java.io.IOException) {
        input.close()
        return ApkDownloadResult.LocalWriteFailed(0, e.toString())
    }
    input.use {
        output.use { out ->
            val buf = ByteArray(APK_COPY_BUFFER)
            while (true) {
                val n = input.read(buf) // 网络：异常交给调用方分类
                if (n < 0) break
                try {
                    out.write(buf, 0, n)
                } catch (e: java.io.IOException) {
                    return ApkDownloadResult.LocalWriteFailed(received, e.toString())
                }
                received += n
                onProgress(received)
            }
        }
    }
    return null
}

/**
 * 下载 APK → FileProvider → 系统安装器（PackageInstaller 强制同签名校验
 * 兜底）。UPD-01 返工：原实现是普通 fun 在主线程同步下载——Android 直接
 * 抛 NetworkOnMainThreadException，异常被 catch 吞掉，「下载安装」点了
 * 没反应。改为 suspend + Dispatchers.IO。
 *
 * NET-09: 返回分类后的结果，并在 `PPassUpdate` 如实记一行类别与关键数字。
 * 调用方目前不向用户展示失败（对话框照旧关闭），这一点没有变。
 */
/** 更新 APK 的落盘位置：必须在 file_paths.xml 的 `update/` 目录下（见 UpdateApkFileProviderPathTest）。 */
internal fun updateApkFile(cacheDir: File): File = File(File(cacheDir, "update"), "ppass-update.apk")

suspend fun downloadAndInstall(context: Context, url: String): ApkDownloadResult =
    withContext(Dispatchers.IO) {
        val apk = updateApkFile(context.cacheDir).apply { parentFile?.mkdirs() }
        val downloaded = downloadApk(url, apk)
        val result = if (downloaded !is ApkDownloadResult.Ok) {
            downloaded
        } else {
            try {
                val uri: Uri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    apk,
                )
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
                downloaded
            } catch (e: Exception) {
                ApkDownloadResult.InstallLaunchFailed(downloaded.bytes, e.toString())
            }
        }
        if (result is ApkDownloadResult.Ok) {
            android.util.Log.i(LOG_TAG, result.logLine(url))
        } else {
            android.util.Log.w(LOG_TAG, result.logLine(url))
        }
        result
    }
