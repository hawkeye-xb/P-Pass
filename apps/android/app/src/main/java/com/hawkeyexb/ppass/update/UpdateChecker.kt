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

// REL-02 test 通道：Cloudflare Worker 代理（infra/workers/update）——
// 「最新 prerelease 的 manifest」解析在 Worker 端（GitHub API 未认证
// 限流 60/h/IP，客户端直连迟早撞墙）；客户端只 fetch 静态 URL，命中
// Worker 缓存（300s）不碰 GitHub。路由/DNS 配置在 ppf-ops（隔离方案 §2）。
private const val WORKER_TEST_URL =
    "https://update.p-pass.hawkeye-xb.com/manifest?channel=test"

private val json = Json { ignoreUnknownKeys = true }

/**
 * REL-02: 通道 → manifest URL（纯函数，JVM 可测）。
 * 反证红线：stable 必须恒等于 GitHub latest 原 URL（卡面「不准动」——
 * 改动此 URL 本测试必红）；test 走 Worker 静态 URL。
 */
fun channelManifestUrl(channel: UpdateChannel): String = when (channel) {
    UpdateChannel.Stable -> MANIFEST_URL
    UpdateChannel.Test -> WORKER_TEST_URL
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
 * test = GitHub API 最新 prerelease 的 manifest 资产。
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

/** GET 文本；非 200 / 网络失败返回 null。 */
private fun httpGet(url: String): String? = try {
    val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
    conn.connectTimeout = 8_000
    conn.readTimeout = 8_000
    conn.requestMethod = "GET"
    // GitHub API 要 User-Agent（无 UA 403）。
    conn.setRequestProperty("User-Agent", "P-Pass-UpdateChecker")
    if (conn.responseCode != 200) null
    else conn.inputStream.bufferedReader().use { it.readText() }
} catch (_: Exception) {
    null
}

/**
 * 下载 APK → FileProvider → 系统安装器（PackageInstaller 强制同签名校验
 * 兜底）。UPD-01 返工：原实现是普通 fun 在主线程同步下载——Android 直接
 * 抛 NetworkOnMainThreadException，异常被 catch 吞掉，「下载安装」点了
 * 没反应。改为 suspend + Dispatchers.IO。
 */
suspend fun downloadAndInstall(context: Context, url: String): Boolean =
    withContext(Dispatchers.IO) {
        try {
            val apk = File(context.cacheDir, "ppass-update.apk")
            val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.inputStream.use { input ->
                apk.outputStream().use { output -> input.copyTo(output) }
            }
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
            true
        } catch (_: Exception) {
            false
        }
    }
