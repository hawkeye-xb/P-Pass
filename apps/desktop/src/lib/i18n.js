// I18N-03 (#492): the desktop's single t().
//
// Copy lives only in assets/i18n/{en,zh}.json (crates/diag registers every
// key and its tests keep both languages complete). Imported straight from
// the repo root — zero copies, zero drift. One language per session, picked
// from the system language (the UI is single-language by design); the tray
// menu asks the same question via `trayLocale()` so shell and window agree.
import enDict from "../../../../assets/i18n/en.json";
import zhDict from "../../../../assets/i18n/zh.json";

const DICTS = { en: enDict, zh: zhDict };

/** "zh-CN" / "zh-Hans" / "zh" → zh; anything else → en; unknown → zh. */
export function localeFor(lang) {
  if (!lang) return "zh";
  return String(lang).toLowerCase().startsWith("zh") ? "zh" : "en";
}

let current = localeFor(typeof navigator !== "undefined" ? navigator.language : "");

/** Force a locale (tests; never called by product code). */
export function setLocale(lang) {
  current = localeFor(lang);
}

export function getLocale() {
  return current;
}

export function t(key, vars = {}) {
  let s = DICTS[current][key] ?? key;
  for (const [k, v] of Object.entries(vars)) s = s.replaceAll(`{${k}}`, String(v));
  return s;
}

/** Is `key` a registered dictionary key? */
export function hasKey(key) {
  return typeof key === "string" && Object.prototype.hasOwnProperty.call(DICTS[current], key);
}

/**
 * Render an error coming back from the Rust shell (`invoke` rejection or an
 * event payload) for the user. Three shapes:
 *   - keyed error `{"key":"ui.…","params":{…}}` (JSON string or object) —
 *     rendered via t(); param values may themselves be keyed errors (a shell
 *     error wrapping an IPC error) and are rendered recursively. Low-level
 *     `{e}` details arrive as plain strings and pass through untranslated.
 *   - a bare registered key (the daemon answers with msg_keys like
 *     `err.not_authorized`) — rendered via t().
 *   - anything else — shown as-is.
 */
export function errText(e) {
  const keyed = asKeyed(e);
  if (keyed) {
    const vars = {};
    for (const [k, v] of Object.entries(keyed.params || {})) vars[k] = errText(v);
    return t(keyed.key, vars);
  }
  // String(e), not e.message: same text the call sites showed before.
  const s = String(e);
  return hasKey(s) ? t(s) : s;
}

function asKeyed(e) {
  if (e && typeof e === "object" && typeof e.key === "string") return e;
  if (typeof e === "string" && e.startsWith("{")) {
    try {
      const v = JSON.parse(e);
      if (v && typeof v.key === "string") return v;
    } catch {
      // not ours — fall through and show it raw
    }
  }
  return null;
}
