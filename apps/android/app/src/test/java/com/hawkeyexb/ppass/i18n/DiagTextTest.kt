package com.hawkeyexb.ppass.i18n

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/**
 * T-072: DiagText resolution + the UI layer's half of the dictionary
 * coverage ("assert_all_keys_translated 覆盖 UI 层新 key").
 *
 * Pure-JVM: loads the repo-source dictionaries (same files the Rust
 * `assert_all_keys_translated` test validates) and asserts:
 *  1. every msg_key resolves to non-empty text in BOTH languages
 *  2. en/zh key sets are identical (no unilateral additions)
 *  3. placeholder formatting works
 *  4. unknown keys return null (UI falls back, never crashes)
 *  5. the app's bundled assets never drift from the repo source
 */
class DiagTextTest {

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "assets/i18n").isDirectory) {
            dir = dir.parentFile ?: error("assets/i18n not found above ${System.getProperty("user.dir")}")
        }
        return dir
    }

    private fun dict(lang: String): String =
        File(repoRoot(), "assets/i18n/$lang.json").readText()

    /** Key list via names()——Android 框架的 org.json 是老版本：没有 keySet()，
     *  keys() 返回的 Iterator 的 toList() 扩展在此 stdlib 配置下不解析。 */
    private fun keysOf(dictJson: String): List<String> {
        val arr = org.json.JSONObject(dictJson).names() ?: org.json.JSONArray()
        return (0 until arr.length()).map { arr.getString(it) }
    }

    @Test
    fun every_diag_key_resolves_in_both_languages() {
        val enKeys = keysOf(dict("en"))
        val zhKeys = keysOf(dict("zh"))
        assertEquals("en/zh 字典 key 集必须一致", enKeys.sorted(), zhKeys.sorted())

        for (key in enKeys) {
            val enText = DiagText.resolveFromJson(dict("en"), key)
            val zhText = DiagText.resolveFromJson(dict("zh"), key)
            assertFalse("en 翻译缺失或为空: $key", enText.isNullOrBlank())
            assertFalse("zh 翻译缺失或为空: $key", zhText.isNullOrBlank())
        }
    }

    @Test
    fun placeholder_formatting_works() {
        val en = dict("en")
        val withVars = DiagText.resolveFromJson(en, "diag.storage_offline", mapOf("last_seen" to "2 小时前"))
        assertEquals("The storage computer is offline. Last seen 2 小时前.", withVars)
        // 无变量时占位符原样保留（调用方负责传参）
        val raw = DiagText.resolveFromJson(en, "diag.storage_offline")
        assertEquals("The storage computer is offline. Last seen {last_seen}.", raw)
    }

    @Test
    fun unknown_key_returns_null_not_crash() {
        assertNull(DiagText.resolveFromJson(dict("en"), "err.brand_new_from_future_server"))
        assertNull(DiagText.resolveFromJson(dict("zh"), "err.unknown"))
    }

    @Test
    fun bundled_assets_never_drift_from_repo_source() {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found above ${System.getProperty("user.dir")}")
        }
        for (lang in listOf("en", "zh")) {
            val bundled = File(dir, "apps/android/app/src/main/assets/i18n/$lang.json").readText()
            val source = File(dir, "assets/i18n/$lang.json").readText()
            assertEquals("捆绑的 $lang.json 与仓库源发生漂移——重新拷贝 assets/i18n/", source, bundled)
        }
    }
}
