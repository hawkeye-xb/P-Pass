package com.hawkeyexb.ppass.i18n

import android.content.Context
import org.json.JSONObject
import java.util.Locale

/**
 * T-072: resolves diag msg_keys (registry: crates/diag/src/keys.rs) to
 * localized human text.
 *
 * The dictionary is the single source of truth at repo `assets/i18n/`
 * (en.json + zh.json), bundled into app assets; drift against the repo
 * source is enforced by [I18nDriftTest] (JVM unit test). Placeholders use
 * `{name}` syntax.
 */
object DiagText {

    /**
     * Pure resolver — no Android dependencies, directly testable on the JVM.
     * Returns null when the key is unknown (caller falls back to its generic
     * copy, never crashes on a new server-side key).
     */
    fun resolveFromJson(dictJson: String, msgKey: String, vars: Map<String, String> = emptyMap()): String? {
        val dict = JSONObject(dictJson)
        val raw = dict.optString(msgKey)
        if (raw.isEmpty()) return null
        var s = raw
        for ((k, v) in vars) s = s.replace("{$k}", v)
        return s
    }

    /** Resolve against the bundled dictionary for the current locale. */
    fun resolve(context: Context, msgKey: String, vars: Map<String, String> = emptyMap()): String? {
        val lang = Locale.getDefault().language
        val name = if (lang.startsWith("zh")) "i18n/zh.json" else "i18n/en.json"
        val raw = context.assets.open(name).bufferedReader().use { it.readText() }
        return resolveFromJson(raw, msgKey, vars)
    }
}
