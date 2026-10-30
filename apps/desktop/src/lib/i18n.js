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

/**
 * "zh-CN" / "zh-Hans" / "zh" → zh; anything else → en, **including an empty or
 * missing language** (#1045: the platform layer answers "can't read it → English"
 * everywhere, so the UI must not pick a different default).
 */
export function localeFor(lang) {
  if (!lang) return "en";
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
 * B13：报错的显示 = 「正文 + 错误代码」两段，原始内容（OS 原文、stderr、JS 异常、
 * params 里的 err / path / dir / reason）只进 console，不进界面。
 *
 * Rust 壳回来的错误形状：
 *   - keyed 错误 `{"key":"ui.…","params":{…}}`（JSON 串或对象）——参数值本身可以
 *     还是 keyed 错误（壳错误包着一条 IPC 错误）；
 *   - 裸的已登记 key；
 *   - 其它（没登记的串、Error 对象）。
 *
 * 正文取嵌套里**最内层**的已登记 key（出路最具体）；`ui.err_generic` 不算，
 * 它只是兜底。找不到时用调用处给的包装句（`ui.stop_failed` 这类），再没有就
 * `ui.err_generic`。错误代码 = 正文所用 key 去掉 `ui.err_` / `err.` / `ui.` 前缀，
 * 用 `ui.err_code` 渲染成小字，只用于对照日志。
 *
 * 字典里个别还带占位符的报错（如 `{err}`）照常替换，嵌套的 keyed 参数渲染成它的正文。
 *
 * @param {unknown} e
 * @param {string} [wrapperKey] 内层不是已登记 key 时显示的包装句
 * @returns {{ key: string, text: string, code: string }}
 */
export function errMessage(e, wrapperKey) {
  const inner = innermostKeyed(e);
  if (inner) {
    // 原始内容（嵌套参数里的 OS 原文等）只进 console；裸 key 没有可记的东西。
    if (inner.key !== e) console.warn("[err]", inner.key, "raw:", e);
    return { key: inner.key, text: t(inner.key, renderVars(inner.params)), code: errCode(inner.key) };
  }
  console.warn("[err] shown as", wrapperKey || "ui.err_generic", "raw:", e);
  const key = wrapperKey && hasKey(wrapperKey) ? wrapperKey : "ui.err_generic";
  return { key, text: t(key), code: errCode(key) };
}

/** 错误代码：key 去掉 `ui.err_` / `err.` / `ui.` 前缀（`ui.err_generic` → `generic`）。 */
export function errCode(key) {
  return String(key).replace(/^(ui\.err_|err\.|ui\.)/, "");
}

/** 「错误代码：…」那行小字。 */
export function errCodeLine(msg) {
  return t("ui.err_code", { code: msg.code });
}

/** 只要正文的地方（例如另一句话里的 `{err}`）。 */
export function errText(e) {
  return errMessage(e).text;
}

/**
 * 窗口与后台服务之间的通信出错（10-30 偏离 1）。这类报错的出路是「重启后台服务」：
 * `restart_daemon_process` 不经过这条通信，后台服务卡死或已退出都能救。
 */
const SERVICE_LINK_ERROR_KEYS = new Set([
  "ui.err_socket_name",
  "ui.err_connect",
  "ui.err_send",
  "ui.err_read_response",
  "ui.err_daemon_unresponsive",
  "ui.err_ipc_thread_spawn",
  "ui.err_ipc_thread_exit",
  "ui.err_not_json",
]);

/** 报错 toast 要不要带「重启后台服务」按钮：按正文所用 key（`errMessage().key`）判断。 */
export function offersServiceRestart(key) {
  return SERVICE_LINK_ERROR_KEYS.has(key);
}

/** keyed 错误的 key（`{"key": "ui.err_…"}` 或其 JSON 串）；不是就 null。 */
export function errKey(e) {
  return asKeyed(e)?.key ?? null;
}

/** 嵌套里最内层的已登记 keyed 错误（`ui.err_generic` 不算）；没有就 null。 */
function innermostKeyed(e) {
  const keyed = asKeyed(e);
  if (keyed) {
    for (const v of Object.values(keyed.params || {})) {
      const deeper = innermostKeyed(v);
      if (deeper) return deeper;
    }
    return isShownKey(keyed.key) ? keyed : null;
  }
  return typeof e === "string" && isShownKey(e) ? { key: e, params: {} } : null;
}

function isShownKey(key) {
  return hasKey(key) && key !== "ui.err_generic";
}

function renderVars(params) {
  const vars = {};
  for (const [k, v] of Object.entries(params || {})) {
    const nested = asKeyed(v);
    vars[k] = nested && hasKey(nested.key) ? t(nested.key, renderVars(nested.params)) : String(v);
  }
  return vars;
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
