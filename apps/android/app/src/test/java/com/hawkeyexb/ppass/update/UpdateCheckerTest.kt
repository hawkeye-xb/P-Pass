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

    // ── REL-02: test 通道——最新 prerelease 的 manifest URL（纯函数） ──

    @Test
    fun latestPrerelease_picksPrereleaseOverStable() {
        // 列表里有正式 release + prerelease → 取 prerelease（GitHub API
        // 按时间倒序返回；latest 忽略 prerelease，test 通道必须自己找）。
        val body = """
            [
              {"tag_name": "v0.3.1", "prerelease": false, "draft": false},
              {"tag_name": "v0.3.1-test.4", "prerelease": true, "draft": false},
              {"tag_name": "v0.3.1-test.3", "prerelease": true, "draft": false}
            ]
        """.trimIndent()
        assertEquals(
            "https://github.com/hawkeye-xb/P-Pass/releases/download/v0.3.1-test.4/manifest.json",
            latestPrereleaseManifestUrl(body),
        )
    }

    @Test
    fun latestPrerelease_none_returnsNull() {
        // 反证：test 通道包故意不 publish（留 draft）→ 无 prerelease →
        // 必须返回 null（test 通道检查不到更新）。
        val body = """
            [
              {"tag_name": "v0.3.1", "prerelease": false, "draft": false},
              {"tag_name": "v0.3.1-draft", "prerelease": false, "draft": true}
            ]
        """.trimIndent()
        assertNull(latestPrereleaseManifestUrl(body))
        // 空列表 / 垃圾输入同样 null。
        assertNull(latestPrereleaseManifestUrl("[]"))
        assertNull(latestPrereleaseManifestUrl("not json"))
    }

    @Test
    fun latestPrerelease_draftPrereleaseStillCounts() {
        // GitHub API 里 prerelease 与 draft 独立——test tag 自动 publish
        // 为 prerelease 后 draft=false；这里验证只认 prerelease 标志。
        val body = """
            [{"tag_name": "v0.4.0-test.1", "prerelease": true, "draft": false}]
        """.trimIndent()
        assertEquals(
            "https://github.com/hawkeye-xb/P-Pass/releases/download/v0.4.0-test.1/manifest.json",
            latestPrereleaseManifestUrl(body),
        )
    }
}
