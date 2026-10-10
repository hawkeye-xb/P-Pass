// UPD-01: 自更新轻实现（脱店 App 无标准库；第三方多失修——自研）。
// UPD-02: 标准化返工——依赖倒置更新源 / Range 断点续传 / 下载进度回调 /
//         手动检查的诚实结果分类。
//
// 设计要点：
//  - 更新源经 [UpdateSource] 依赖倒置：stable/test 的 URL 语义不动
//    （URL-lock 测试钉死），将来切 R2 只改 [defaultUpdateSource] 一处。
//  - 版本比较：SemVer 三段数字（预发布后缀只影响同主版本内的优先级，
//    跨版本升级只看数字段）。
//  - 下载完整性由 [ApkVerifier] 在下载后、安装前把关（sha256 + minisign），
//    本文件只负责「把字节正确搬下来」。
package com.hawkeyexb.ppass.update

import com.hawkeyexb.ppass.log.PLog
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** tauri 风格 manifest 的 android 子集（release.yml 由 tools/make-update-manifest.mjs 产出）。 */
@Serializable
data class UpdateManifest(
    val version: String,
    /** 中文说明（#741 起取自手写说明文件）；旧客户端只读这一个字段。 */
    val notes: String = "",
    /**
     * #741：按语言的说明 `{"zh": "...", "en": "..."}`。旧清单没有这个键。
     * 宽松读成 [JsonElement]：形状不对（null / 数组 / 值不是字符串）只当它不存在，
     * 绝不让整份清单解析失败——那样更新弹窗就不出了。
     */
    @SerialName("notes_i18n")
    val notesI18n: JsonElement? = null,
    val platforms: Map<String, PlatformEntry> = emptyMap(),
)

/** notes_i18n → 语言到文本的映射；只收字符串值，其余形状一律忽略。 */
internal fun notesI18nMap(element: JsonElement?): Map<String, String> =
    (element as? JsonObject)?.mapNotNull { (lang, v) ->
        (v as? JsonPrimitive)?.takeIf { it.isString }?.let { lang to it.content }
    }?.toMap() ?: emptyMap()

@Serializable
data class PlatformEntry(
    val url: String,
    val signature: String = "",
    /** UPD-02: APK 的 sha256（hex）。旧工具产出的 manifest 无此字段 → 空串过渡。 */
    val sha256: String = "",
)

data class UpdateInfo(
    val version: String,
    val notes: String,
    val url: String,
    val sha256: String = "",
    val signature: String = "",
    /** #741：按语言的说明；显示时按 App 当前语言选取（[displayUpdateNotes]）。 */
    val notesI18n: Map<String, String> = emptyMap(),
)

private val json = Json { ignoreUnknownKeys = true }

/**
 * REL-02: 通道 → manifest URL（纯函数，JVM 可测）。
 * 反证红线：stable 必须恒等于 GitHub latest 原 URL（卡面「不准动」——
 * 改动此 URL 本测试必红）；test 走滚动 prerelease 的静态文件（REL-07）。
 * UPD-02: URL 不再硬编码在本文件，由 [UpdateSource] 供给；默认源
 * [GitHubUpdateSource] 持有与原来完全相同的两个 URL。
 */
fun channelManifestUrl(channel: UpdateChannel): String =
    channelManifestUrl(channel, defaultUpdateSource())

fun channelManifestUrl(channel: UpdateChannel, source: UpdateSource): String =
    source.manifestUrl(channel)

/**
 * #650：有序候选列表（链式的载体）。逐项尝试，前一项不给出结论才落到下一项。
 * 单项源退化成单元素列表，行为与 #624 时完全一致。
 */
fun channelManifestUrls(
    channel: UpdateChannel,
    source: UpdateSource = defaultUpdateSource(),
): List<String> = source.manifestUrls(channel)

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
        UpdateInfo(
            version = manifest.version,
            notes = manifest.notes,
            url = entry.url,
            sha256 = entry.sha256,
            signature = entry.signature,
            notesI18n = notesI18nMap(manifest.notesI18n),
        )
    } catch (_: Exception) {
        null
    }
}

/**
 * UPD-02: 更新检查的诚实结果分类。自动检查照旧静默（失败不打断启动）；
 * 手动检查（设置页「检查更新」）必须把「已是最新」与「检查失败」分开告诉
 * 用户——REL-07 已在日志层分开，这里把它抬到 UI 层。
 */
sealed interface UpdateCheckOutcome {
    data class Available(val info: UpdateInfo) : UpdateCheckOutcome
    /** manifest 可达，但没有更新的版本（含 404 无 release、版本不更新）。 */
    data object UpToDate : UpdateCheckOutcome
    /** 检查本身失败（网络不通 / 限流 403·429 / 5xx / body 解析失败）。 */
    data object Failed : UpdateCheckOutcome
}

/**
 * 拉取并解析 manifest，返回分类结果。绝不抛异常——更新检查不能崩启动。
 */
suspend fun checkUpdate(
    currentVersion: String,
    channel: UpdateChannel = channelFromVersion(currentVersion),
    source: UpdateSource = defaultUpdateSource(),
): UpdateCheckOutcome = withContext(Dispatchers.IO) {
    checkUpdateWith(source.manifestUrls(channel), ::httpGet, currentVersion)
}

/**
 * #650 链式决策（纯函数，JVM 可测）——`checkUpdate` 的网络壳只负责把 [httpGet] 传进来。
 *
 * 逐项尝试候选 URL，**前一项给出确定答案就停**：
 *  - 200 + 能解析出新版本 ⇒ [UpdateCheckOutcome.Available]
 *  - 200 + 能解析但版本不比当前新 ⇒ [UpdateCheckOutcome.UpToDate]（这个源说了算，不再往下试）
 *  - 404 =「**这个源**没有」⇒ 继续试下一项（镜像没跟上 ≠ 官方没有新版本）
 *  - 其他失败 / 拿到 body 却解析不了 ⇒ 记下失败、继续试下一项
 *
 * 全部走完：出现过任何失败 ⇒ [UpdateCheckOutcome.Failed]（诚实报「检查失败」）；
 * 全是 404 ⇒ [UpdateCheckOutcome.UpToDate]。**空候选列表是配置错误，不是「已是最新」。**
 */
internal fun checkUpdateWith(
    urls: List<String>,
    fetch: (String) -> ManifestReply,
    currentVersion: String,
): UpdateCheckOutcome {
    if (urls.isEmpty()) return UpdateCheckOutcome.Failed

    var sawFailure = false
    for (url in urls) {
        val reply = try {
            fetch(url)
        } catch (_: Exception) {
            sawFailure = true
            continue
        }
        when (reply) {
            is ManifestReply.Body -> {
                val info = parseUpdateManifest(reply.text, currentVersion)
                if (info != null) return UpdateCheckOutcome.Available(info)
                val parsed = runCatching {
                    json.decodeFromString(UpdateManifest.serializer(), reply.text)
                }.getOrNull()
                return if (parsed != null) {
                    UpdateCheckOutcome.UpToDate
                } else {
                    // 拿到 body 却解析不了：可能是镜像上写了一半的对象 ⇒ 继续试下一项。
                    sawFailure = true
                    continue
                }
            }
            ManifestReply.NoRelease -> Unit
            ManifestReply.Failed -> sawFailure = true
        }
    }
    return if (sawFailure) UpdateCheckOutcome.Failed else UpdateCheckOutcome.UpToDate
}

/**
 * 拉取并解析 manifest；无更新/不可达返回 null（静默，绝不打断启动）。
 * UPD-02: 保留为 [checkUpdate] 的静默包装，供不需要区分类型的调用方使用。
 */
suspend fun fetchUpdate(
    currentVersion: String,
    channel: UpdateChannel = UpdateChannel.Stable,
): UpdateInfo? = when (val outcome = checkUpdate(currentVersion, channel)) {
    is UpdateCheckOutcome.Available -> outcome.info
    else -> null
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

/** UPD-02: httpGet 的三分返回，让 [checkUpdate] 能把失败如实上报。 */
internal sealed interface ManifestReply {
    data class Body(val text: String) : ManifestReply
    data object NoRelease : ManifestReply
    data object Failed : ManifestReply
}

// 诊断：`adb logcat -s PPassUpdate`（鸿蒙真机需先 `adb shell setprop log.tag.PPassUpdate V`）。
private const val LOG_TAG = "PPassUpdate"

internal const val UPDATE_LOG_TAG = LOG_TAG

/** GET 文本，按 classifyManifestStatus 分类返回（日志分级同 REL-07）。 */
private fun httpGet(url: String): ManifestReply = try {
    val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
    conn.connectTimeout = 8_000
    conn.readTimeout = 8_000
    conn.requestMethod = "GET"
    // GitHub API 要 User-Agent（无 UA 403）。
    conn.setRequestProperty("User-Agent", "P-Pass-UpdateChecker")
    val code = conn.responseCode
    when (classifyManifestStatus(code)) {
        ManifestFetchOutcome.Ok ->
            ManifestReply.Body(conn.inputStream.bufferedReader().use { it.readText() })
        ManifestFetchOutcome.NoRelease -> {
            PLog.i(LOG_TAG, "no release at $url (HTTP 404) — no update")
            ManifestReply.NoRelease
        }
        ManifestFetchOutcome.CheckFailed -> {
            val detail = runCatching {
                conn.errorStream?.bufferedReader()?.use { it.readText().take(200) }
            }.getOrNull()
            val retryAfter = conn.getHeaderField("Retry-After")
            PLog.w(
                LOG_TAG,
                "update check FAILED at $url: HTTP $code retry-after=$retryAfter body=$detail",
            )
            ManifestReply.Failed
        }
    }
} catch (e: Exception) {
    PLog.w(LOG_TAG, "update check FAILED at $url: $e")
    ManifestReply.Failed
}

/**
 * NET-09: APK 下载的结果分类。原实现 `catch (_: Exception) false` 把所有
 * 失败压成一个 false，日志里分不出「服务器不回字节」「HTTP 非 200」「根本
 * 没连上」。这里按**失败发生的阶段**分类，而不是按异常类型猜：
 * `SocketTimeoutException` 在 connect 阶段是 connectTimeout（连不上），在
 * 等响应头 / 读 body 阶段是 readTimeout（字节停滞）——同一个异常类，两种事实。
 */
sealed interface ApkDownloadResult {
    /** 下载完整落盘（[downloadApk] 的成功值）。 */
    data class Ok(val bytes: Long) : ApkDownloadResult

    /** 已建立连接，但连续 [readTimeoutMs] 毫秒没有新字节（readTimeout 触发）。 */
    data class Stalled(
        val phase: Phase,
        val receivedBytes: Long,
        val readTimeoutMs: Int,
    ) : ApkDownloadResult

    /** 服务器回了响应，但最终（逐跳跟随重定向后）的状态码不是 200/206。 */
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
}

// APK 走 HTTPS（GitHub release 资产 → 302 → CDN），不经 iroh relay，没有
// NET-09 下载原图那条 60s 取值依据里的「relay 恢复空窗」。readTimeout 本身是
// per-read，即「连续 N 秒零新字节」的停滞语义，所以沿用原有 30s，只把分类做对。
internal const val APK_CONNECT_TIMEOUT_MS = 15_000
internal const val APK_READ_TIMEOUT_MS = 30_000
private const val APK_COPY_BUFFER = 64 * 1024
internal const val APK_MAX_REDIRECTS = 5

/**
 * UPD-02: HTTP Range 断点续传计划（纯函数，JVM 可测）。
 * 本地已有 [existingBytes] 字节时，请求头 `Range: bytes=N-` 只取剩余部分：
 *  - 206 → 追加写入；
 *  - 200 → 服务器不理会 Range → 从头重下（截断）；
 *  - 416 → 本地残包比远端还大/错位 → 删残包从头重下（[downloadApk] 内处理）；
 *  - 206 但 Content-Range 起点 ≠ N → 服务端给的不是我们要的那段，拼上去必坏，
 *    与 416 同样处理（UPD-19）。没带 Content-Range 的 206 照旧接受。
 */
internal data class ResumePlan(val existingBytes: Long) {
    val rangeHeader: String? get() = if (existingBytes > 0) "bytes=$existingBytes-" else null
}

internal fun resumePlanFor(existingBytes: Long): ResumePlan =
    ResumePlan(existingBytes.coerceAtLeast(0L))

/**
 * UPD-19: 206 响应的 Content-Range 起点（`bytes START-END/TOTAL`）。
 * 头缺失或格式不认识 = null（调用方按「不校验」放行）。纯函数，JVM 可测。
 */
internal fun contentRangeStartOf(header: String?): Long? {
    val spec = header?.trim()?.removePrefix("bytes")?.trim() ?: return null
    return spec.substringBefore('-', missingDelimiterValue = "").trim().toLongOrNull()
}

/**
 * UPD-19: 失败后残包还值不值得留给下一跑续传（纯函数，JVM 可测）。
 * 停滞 / 断连 / 5xx / 429 = 瞬时故障，已落盘的前缀字节仍是对的，下一跑带
 * `Range: bytes=N-` 接着要；其余（4xx、写盘失败、未知异常）重试也是同样结果，
 * 残包没有续传价值，删掉。[retryVerdictOf] 用同一个判定，两边不会说法不一。
 * 注意：残包不会被误装——只有完成标记在且校验通过才进安装（见 UpdateDownloadWorker）。
 */
internal fun isTransientDownloadFailure(result: ApkDownloadResult): Boolean = when (result) {
    is ApkDownloadResult.Stalled, is ApkDownloadResult.ConnectionFailed -> true
    is ApkDownloadResult.HttpStatus -> result.code >= 500 || result.code == 429
    else -> false
}

/**
 * NET-09: 下载 [url] 到 [dest] 并分类失败（JVM 用假连接可测）。
 * [open] 只负责造出未连接的 HttpURLConnection；超时由本函数设置
 * （[readTimeoutMs] 只为测试缩短，生产恒用默认值）。
 * UPD-02: [resumeFromBytes] > 0 时按 [ResumePlan] 发 Range 请求追加下载；
 * [onProgress] 以「含断点的总已收 / 总大小（未知为 -1）」回调，供 UI 进度条。
 * UPD-19: 瞬时失败（[isTransientDownloadFailure]）保留 [dest] 的残包给下一跑续传——
 * 原先任何失败都删，WorkManager 的退避重试于是次次从 0 字节重下；其余失败照旧删。
 */
fun downloadApk(
    url: String,
    dest: File,
    open: (String) -> java.net.HttpURLConnection = {
        java.net.URL(it).openConnection() as java.net.HttpURLConnection
    },
    readTimeoutMs: Int = APK_READ_TIMEOUT_MS,
    resumeFromBytes: Long = 0L,
    onProgress: (received: Long, total: Long) -> Unit = { _, _ -> },
): ApkDownloadResult {
    var resume = resumePlanFor(resumeFromBytes)
    var rangeRetried = false
    while (true) {
        val result = downloadOnce(url, dest, open, readTimeoutMs, resume, onProgress)
        // 416 = 本地残包与远端对不上（含 206 起点错位，见 downloadOnce）：
        // 删残包、摘掉 Range 头，完整重试一次。
        if (result is ApkDownloadResult.HttpStatus && result.code == 416 &&
            resume.rangeHeader != null && !rangeRetried
        ) {
            rangeRetried = true
            dest.delete()
            resume = resumePlanFor(0)
            continue
        }
        if (result !is ApkDownloadResult.Ok && !isTransientDownloadFailure(result)) dest.delete()
        return result
    }
}

private fun downloadOnce(
    url: String,
    dest: File,
    open: (String) -> java.net.HttpURLConnection,
    readTimeoutMs: Int,
    resume: ResumePlan,
    onProgress: (received: Long, total: Long) -> Unit,
): ApkDownloadResult {
    var current = url
    var redirects = 0
    var phase = ApkDownloadResult.Phase.Connect
    var received = resume.existingBytes
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
            resume.rangeHeader?.let { c.setRequestProperty("Range", it) }
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
            } else if (code == 416 && resume.rangeHeader != null) {
                result = ApkDownloadResult.HttpStatus(416) // 交给外层删残包重试
            } else if (code == 206 && resume.rangeHeader != null &&
                contentRangeStartOf(c.getHeaderField("Content-Range"))
                    .let { it != null && it != resume.existingBytes }
            ) {
                // 206 但给的不是从残包末尾开始的那段：追加就是把错位字节拼进包里。
                // 当 416 处理（外层删残包、不带 Range 完整重下一次）。
                result = ApkDownloadResult.HttpStatus(416)
            } else if (code != 200 && code != 206) {
                // 含：3xx 没带 Location、重定向超过上限——都如实报最后那个状态码。
                result = ApkDownloadResult.HttpStatus(code)
            } else {
                phase = ApkDownloadResult.Phase.Body
                // 206 = 服务端接受 Range → 追加；200 = 忽略 Range → 从头重来。
                val appending = code == 206 && resume.rangeHeader != null
                if (!appending) received = 0L
                val base = if (appending) resume.existingBytes else 0L
                val expected = c.contentLengthLong.let { if (it >= 0) it + base else -1L }
                var bodyReceived = 0L
                result = copyBody(
                    c.inputStream, dest, appending,
                    { n -> bodyReceived = n; received = base + n },
                ) { done ->
                    onProgress(base + done, expected)
                } ?: if (expected >= 0 && base + bodyReceived != expected) {
                    ApkDownloadResult.ConnectionFailed(
                        phase, base + bodyReceived,
                        "body ended early: ${base + bodyReceived} of $expected bytes",
                    )
                } else {
                    ApkDownloadResult.Ok(base + bodyReceived)
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
    return result!!
}

/**
 * 把 body 抄进 [dest]（[append] = true 时追加在已有残包后面）。
 * 网络读的异常原样抛给 [downloadOnce] 分类；写盘失败在这里就地转成
 * [ApkDownloadResult.LocalWriteFailed]（返回非 null）。正常读完返回 null。
 * [onBodyBytes] 汇报本次 body 已收字节数（不含断点基数）；[onProgress] 用于 UI。
 */
private fun copyBody(
    input: java.io.InputStream,
    dest: File,
    append: Boolean,
    onBodyBytes: (Long) -> Unit,
    onProgress: (Long) -> Unit,
): ApkDownloadResult? {
    var received = 0L
    val output = try {
        if (append) java.io.FileOutputStream(dest, true) else dest.outputStream()
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
                    onBodyBytes(received)
                    return ApkDownloadResult.LocalWriteFailed(received, e.toString())
                }
                received += n
                onBodyBytes(received)
                onProgress(received)
            }
        }
    }
    return null
}

/** 更新 APK 的落盘位置：必须在 file_paths.xml 的 `update/` 目录下（见 UpdateApkFileProviderPathTest）。 */
internal fun updateApkFile(cacheDir: File): File = File(File(cacheDir, "update"), "ppass-update.apk")
