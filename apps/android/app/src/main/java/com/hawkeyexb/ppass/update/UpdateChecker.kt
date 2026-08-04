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

private val json = Json { ignoreUnknownKeys = true }

/** SemVer 三段数字比较：candidate 严格大于 current 才算更新（预发布后缀忽略）。 */
fun isNewer(candidate: String, current: String): Boolean {
    val c = candidate.split('-', '+').first().split('.').map { it.toIntOrNull() ?: 0 }
    val cur = current.split('-', '+').first().split('.').map { it.toIntOrNull() ?: 0 }
    for (i in 0..2) {
        val diff = c.getOrElse(i) { 0 } - cur.getOrElse(i) { 0 }
        if (diff != 0) return diff > 0
    }
    return false
}

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

/** 拉取并解析 manifest；无更新/不可达返回 null（静默，绝不打断启动）。 */
suspend fun fetchUpdate(currentVersion: String): UpdateInfo? = withContext(Dispatchers.IO) {
    try {
        val conn = java.net.URL(MANIFEST_URL).openConnection() as java.net.HttpURLConnection
        conn.connectTimeout = 8_000
        conn.readTimeout = 8_000
        conn.requestMethod = "GET"
        if (conn.responseCode != 200) return@withContext null // draft/无 release = 无更新
        val body = conn.inputStream.bufferedReader().use { it.readText() }
        parseUpdateManifest(body, currentVersion)
    } catch (_: Exception) {
        null // 网络/解析失败一律静默——更新检查绝不能崩启动
    }
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
