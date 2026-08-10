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

    // ── REL-02: 通道 → manifest URL（反证红线：stable 原 URL 不准动） ──

    @Test
    fun channelManifestUrl_stableLockedToGitHubLatest() {
        // 卡面「不准动」：stable 通道 URL 与语义必须原样——
        // 改了这个 URL，本测试必红（家人设备的更新源）。
        assertEquals(
            "https://github.com/hawkeye-xb/P-Pass/releases/latest/download/manifest.json",
            channelManifestUrl(UpdateChannel.Stable),
        )
    }

    @Test
    fun channelManifestUrl_testGoesThroughWorker() {
        // test 通道走 Cloudflare Worker（GitHub API 未认证限流 60/h/IP，
        // 客户端不直连）；Worker 端解析最新 prerelease。
        assertEquals(
            "https://update.p-pass.hawkeye-xb.com/manifest?channel=test",
            channelManifestUrl(UpdateChannel.Test),
        )
    }

    @Test
    fun channelStore_defaultsToStable() {
        // 通道默认永远 stable（家人设备绝不被 test 构建波及）。
        assertEquals(UpdateChannel.Stable, UpdateChannel.fromId(null))
        assertEquals(UpdateChannel.Stable, UpdateChannel.fromId("garbage"))
        assertEquals(UpdateChannel.Test, UpdateChannel.fromId("test"))
    }
}
