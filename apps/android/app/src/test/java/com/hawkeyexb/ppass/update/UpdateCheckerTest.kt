// UPD-01: update checker pure-logic tests — semver comparison + manifest
// parsing (network/install are device-side, covered by real-device check).
package com.hawkeyexb.ppass.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateCheckerTest {

    @Test
    fun isNewer_basicSemver() {
        assertTrue(isNewer("0.2.0", "0.1.0"))
        assertTrue(isNewer("1.0.0", "0.9.9"))
        assertTrue(isNewer("0.1.1", "0.1.0"))
        assertTrue(isNewer("0.2.0-test.7", "0.1.0")) // 预发布后缀跨主版本仍算更新
    }

    @Test
    fun isNewer_notNewer() {
        assertEquals(false, isNewer("0.1.0", "0.1.0"))
        assertEquals(false, isNewer("0.1.0", "0.2.0"))
        assertEquals(false, isNewer("0.0.9", "0.1.0"))
        assertEquals(false, isNewer("0.1.0-test.3", "0.1.0")) // 同主版本预发布不视为升级
    }

    // ── DESK-02①: 同核心预发布按数字段比较（test 通道连续 tag 自动升级） ──

    @Test
    fun isNewer_prereleaseSameCore() {
        // 用户手机自动更新链路：test.1 → test.2 必须判定为更新。
        assertTrue(isNewer("0.3.2-test.2", "0.3.2-test.1"))
        assertEquals(false, isNewer("0.3.2-test.1", "0.3.2-test.2"))
        assertEquals(false, isNewer("0.3.2-test.1", "0.3.2-test.1"))
        // 正式 > 预发布（同核心）：已装正式 0.3.2 不该被拉回 test.1。
        assertEquals(false, isNewer("0.3.2-test.1", "0.3.2"))
        assertTrue(isNewer("0.3.2", "0.3.2-test.1"))
        // 跨核心仍以数字段优先。
        assertTrue(isNewer("0.3.3-test.1", "0.3.2-test.9"))
    }

    // ── DESK-02①: 更新通道由构建推导（零 UI、零持久化） ──

    @Test
    fun channelFromVersion_derivesFromVersionString() {
        // 正式构建（无 -test. 后缀）→ stable，家人设备不被 test 波及。
        assertEquals(UpdateChannel.Stable, channelFromVersion("0.3.2"))
        assertEquals(UpdateChannel.Stable, channelFromVersion("0.3.1"))
        // 构建期 PPF_BUILD_VERSION 注入完整 tag → test。
        assertEquals(UpdateChannel.Test, channelFromVersion("0.3.2-test.1"))
        assertEquals(UpdateChannel.Test, channelFromVersion("0.3.2-test.2"))
        assertEquals(UpdateChannel.Test, channelFromVersion("v0.3.2-test.1"))
    }

    @Test
    fun parseManifest_returnsUpdateWhenNewer() {
        val body = """
            {
              "version": "0.3.0",
              "notes": "bug fixes",
              "pub_date": "2026-08-04T00:00:00Z",
              "platforms": {
                "darwin-aarch64": {"url": "https://x/dmg", "signature": ""},
                "android-arm64": {"url": "https://x/app-release.apk", "signature": "abc"}
              }
            }
        """.trimIndent()
        val info = parseUpdateManifest(body, "0.1.0")
        assertTrue(info != null)
        assertEquals("0.3.0", info!!.version)
        assertEquals("https://x/app-release.apk", info.url)
        assertEquals("bug fixes", info.notes)
    }

    @Test
    fun parseManifest_noAndroidEntry_returnsNull() {
        val body = """
            {"version": "0.3.0", "notes": "", "platforms": {"darwin-aarch64": {"url": "https://x/dmg", "signature": ""}}}
        """.trimIndent()
        assertNull(parseUpdateManifest(body, "0.1.0"))
    }

    @Test
    fun parseManifest_notNewer_returnsNull() {
        val body = """
            {"version": "0.1.0", "notes": "", "platforms": {"android-arm64": {"url": "https://x/a.apk", "signature": ""}}}
        """.trimIndent()
        assertNull(parseUpdateManifest(body, "0.1.0"))
        assertNull(parseUpdateManifest(body, "0.2.0"))
    }

    @Test
    fun parseManifest_garbage_returnsNull() {
        assertNull(parseUpdateManifest("not json at all", "0.1.0"))
        assertNull(parseUpdateManifest("", "0.1.0"))
    }

    // ── REL-02 / UPD-12 (#650): 通道 → manifest 候选列表（反证红线：顺序与每一项都不准动） ──

    @Test
    fun channelManifestUrls_stableLockedToOrderedChain() {
        // 红线（#650 改写为更强形式）：不是「锁一个 URL」，而是「锁**有序候选列表** +
        // 每一项的确切 URL」——增删、重排、换域名都必须同时改本测试，不允许静默漂移。
        // 1st = R2（国内可达，与官网下载同链路）；2nd = GitHub（兜底，旧客户端一直打的它）。
        assertEquals(
            listOf(
                "https://p-pass-dl.hawkeye-xb.com/manifest-android.json",
                "https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest-android.json",
            ),
            channelManifestUrls(UpdateChannel.Stable),
        )
        // 首选项（兼容旧调用方：`channelManifestUrl` 返回第一项）。
        assertEquals(
            "https://p-pass-dl.hawkeye-xb.com/manifest-android.json",
            channelManifestUrl(UpdateChannel.Stable),
        )
    }

    @Test
    fun channelManifestUrls_testIsGitHubOnly() {
        // REL-07 + #650：test 通道的对象只在 GitHub 上（滚动 prerelease）⇒ 候选里**不许**
        // 出现 R2，否则每次检查都白打一次 404。
        assertEquals(
            listOf("https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/manifest.json"),
            channelManifestUrls(UpdateChannel.Test),
        )
    }

    // ── #650 链式决策（纯函数，fetch 注入 ⇒ 确定性，且不碰 android.util.Log） ──

    private val newerManifest =
        """{"version":"0.9.0","notes":"n","platforms":{"android-arm64":{"url":"https://example/apk","signature":"s","sha256":"h"}}}"""
    private val currentManifest = """{"version":"0.8.4","notes":"n","platforms":{}}"""

    private class FakeFetch(private val byUrl: Map<String, ManifestReply>) {
        val calls = mutableListOf<String>()
        fun fetch(url: String): ManifestReply {
            calls += url
            return byUrl[url] ?: ManifestReply.Failed
        }
    }

    @Test
    fun chain_firstSourceWinsWhenItHasAnAnswer() {
        val f = FakeFetch(
            mapOf(
                "r2" to ManifestReply.Body(newerManifest),
                "gh" to ManifestReply.Body(newerManifest),
            ),
        )
        val out = checkUpdateWith(listOf("r2", "gh"), f::fetch, "0.8.4")
        assertTrue("$out", out is UpdateCheckOutcome.Available)
        assertEquals(listOf("r2"), f.calls) // 第一项给出答案就停，不再打第二项
    }

    @Test
    fun chain_fallsBackWhenFirstSourceIs404() {
        // 镜像还没跟上（R2 404）≠ 官方没有新版本 ⇒ 必须继续落到 GitHub 那一项。
        val f = FakeFetch(
            mapOf(
                "r2" to ManifestReply.NoRelease,
                "gh" to ManifestReply.Body(newerManifest),
            ),
        )
        val out = checkUpdateWith(listOf("r2", "gh"), f::fetch, "0.8.4")
        assertTrue("$out", out is UpdateCheckOutcome.Available)
        assertEquals(listOf("r2", "gh"), f.calls)
    }

    @Test
    fun chain_fallsBackWhenFirstSourceFails() {
        val f = FakeFetch(mapOf("gh" to ManifestReply.Body(newerManifest)))
        val out = checkUpdateWith(listOf("r2", "gh"), f::fetch, "0.8.4")
        assertTrue("$out", out is UpdateCheckOutcome.Available)
        assertEquals(listOf("r2", "gh"), f.calls)
    }

    @Test
    fun chain_fallsBackWhenFirstSourceThrows() {
        val calls = mutableListOf<String>()
        val out = checkUpdateWith(listOf("r2", "gh"), { url ->
            calls += url
            if (url == "r2") throw java.io.IOException("boom") else ManifestReply.Body(newerManifest)
        }, "0.8.4")
        assertTrue("$out", out is UpdateCheckOutcome.Available)
        assertEquals(listOf("r2", "gh"), calls)
    }

    @Test
    fun chain_upToDateFromFirstSourceStopsThere() {
        // 第一项能解析、但版本不比当前新 = 它给出了**确定答案**（已是最新）⇒ 不该再打第二项
        // （否则每次自动检查都白打一遍所有源）。
        val f = FakeFetch(
            mapOf(
                "r2" to ManifestReply.Body(currentManifest),
                "gh" to ManifestReply.Body(newerManifest),
            ),
        )
        assertEquals(UpdateCheckOutcome.UpToDate, checkUpdateWith(listOf("r2", "gh"), f::fetch, "0.8.4"))
        assertEquals(listOf("r2"), f.calls)
    }

    @Test
    fun chain_corruptBodyContinuesToNextSource() {
        val f = FakeFetch(
            mapOf(
                "r2" to ManifestReply.Body("{\"half\":"), // 镜像上写了一半的对象
                "gh" to ManifestReply.Body(newerManifest),
            ),
        )
        val out = checkUpdateWith(listOf("r2", "gh"), f::fetch, "0.8.4")
        assertTrue("$out", out is UpdateCheckOutcome.Available)
        assertEquals(listOf("r2", "gh"), f.calls)
    }

    @Test
    fun chain_allSources404IsUpToDate() {
        val f = FakeFetch(mapOf("r2" to ManifestReply.NoRelease, "gh" to ManifestReply.NoRelease))
        assertEquals(UpdateCheckOutcome.UpToDate, checkUpdateWith(listOf("r2", "gh"), f::fetch, "0.8.4"))
    }

    @Test
    fun chain_failureWithoutAnyAnswerIsHonestFailure() {
        // 一个 404 + 一个失败 = 我们**没法确认**有没有新版本 ⇒ 如实报「检查失败」，
        // 不许装成「已是最新」（REL-07 的抬到 UI 的那条）。
        val f = FakeFetch(mapOf("r2" to ManifestReply.NoRelease)) // gh 默认 Failed
        assertEquals(UpdateCheckOutcome.Failed, checkUpdateWith(listOf("r2", "gh"), f::fetch, "0.8.4"))
    }

    @Test
    fun chain_emptyCandidateListIsFailureNotUpToDate() {
        // 空候选 = 配置错误（该源不服务这个通道），不是「已是最新」。
        val f = FakeFetch(emptyMap())
        assertEquals(UpdateCheckOutcome.Failed, checkUpdateWith(emptyList(), f::fetch, "0.8.4"))
        assertEquals(emptyList<String>(), f.calls)
    }

    // ── REL-07: 404 = 无 release；5xx（Worker 上游故障/限流）= 检查失败，不是「已是最新」 ──

    @Test
    fun classifyManifestStatus_separatesNoReleaseFromUpstreamFailure() {
        assertEquals(ManifestFetchOutcome.Ok, classifyManifestStatus(200))
        assertEquals(ManifestFetchOutcome.NoRelease, classifyManifestStatus(404))
        assertEquals(ManifestFetchOutcome.CheckFailed, classifyManifestStatus(502))
        assertEquals(ManifestFetchOutcome.CheckFailed, classifyManifestStatus(503))
        assertEquals(ManifestFetchOutcome.CheckFailed, classifyManifestStatus(403))
        assertEquals(ManifestFetchOutcome.CheckFailed, classifyManifestStatus(500))
    }

    @Test
    fun channelStore_defaultsToStable() {
        // 通道默认永远 stable（家人设备绝不被 test 构建波及）。
        assertEquals(UpdateChannel.Stable, UpdateChannel.fromId(null))
        assertEquals(UpdateChannel.Stable, UpdateChannel.fromId("garbage"))
        assertEquals(UpdateChannel.Test, UpdateChannel.fromId("test"))
    }
}
