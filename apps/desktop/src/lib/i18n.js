// I18N-03 (#492): the desktop's single t().
//
// Copy lives only in assets/i18n/{en,zh}.json (crates/diag registers every
// key and its tests keep both languages complete). Imported straight from
// the repo root — zero copies, zero drift. One language per session (the UI
// is single-language by design): the user's choice from Settings (#557) if
// there is one, else the system language. The tray menu is told the same
// answer via `set_tray_locale`, so shell and window agree.
import enDict from "../../../../assets/i18n/en.json";
import zhDict from "../../../../assets/i18n/zh.json";

const DICTS = { en: enDict, zh: zhDict };

/** "zh-CN" / "zh-Hans" / "zh" → zh; anything else → en; unknown → zh. */
export function localeFor(lang) {
  if (!lang) return "zh";
  return String(lang).toLowerCase().startsWith("zh") ? "zh" : "en";
}

// #557: the Settings language choice. "system" = follow navigator.language.
// Stored in localStorage (a per-machine UI preference, like the tray-hint
// flag — the daemon's config.toml is library config, not UI state).
export const LANG_PREF_KEY = "ppass.ui_language";
export const LANG_PREFS = ["system", "zh", "en"];

function systemLang() {
  return typeof navigator !== "undefined" ? navigator.language : "";
}

/** Only "zh" / "en" are real choices; missing, garbage or "system" → "system". */
export function normalizePref(v) {
  return v === "zh" || v === "en" ? v : "system";
}

/** Saved choice; storage missing or throwing (private mode) → "system". */
export function readLangPref(storage = globalThis.localStorage) {
  try {
    return normalizePref(storage?.getItem(LANG_PREF_KEY));
  } catch {
    return "system";
  }
}

/** The locale a preference resolves to right now. */
export function localeForPref(pref) {
  const p = normalizePref(pref);
  return p === "system" ? localeFor(systemLang()) : p;
}

let current = localeForPref(readLangPref());

/** Force a locale (tests, and applyLangPref below). */
export function setLocale(lang) {
  current = localeFor(lang);
}

/**
 * #557: switch language from Settings. Persist first — a choice that cannot
 * be saved would silently revert on the reload, so a write failure throws
 * (the caller shows it) and nothing else happens. Then tell the tray (its
 * failure only affects the tray, so it is swallowed like at startup), then
 * reload so every t() call — NAV included — re-evaluates in the new language.
 */
export async function applyLangPref(pref, { storage = globalThis.localStorage, invoke, reload }) {
  const p = normalizePref(pref);
  if (p === "system") storage.removeItem(LANG_PREF_KEY);
  else storage.setItem(LANG_PREF_KEY, p);
  setLocale(localeForPref(p));
  await Promise.resolve(invoke("set_tray_locale", { lang: getLocale() })).catch(() => {});
  reload();
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
