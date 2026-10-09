#!/usr/bin/env node
// #741：手写的用户更新说明——读取、校验（lint）、缺失告警。
//
// 约定（规则全文见 docs/release-notes-rules.md）：
//   release/notes/<platform>/<version>.<lang>.txt
//     platform ∈ android / macos / windows；version = 该端版本号（release/versions.json）；
//     lang ∈ zh / en。纯文本 UTF-8，每行一条，不写 markdown。
//   某端某版本没有文件 ⇒ 清单里说明为空 ⇒ 客户端显示默认文案（test tag 天然没有文件）。
//
// 本模块是唯一一份校验口径：CI lint（ci-docs）与 tools/make-update-manifest.mjs 共用。
//
// CLI：
//   node tools/release-notes.mjs lint [<dir>]
//     校验目录下全部说明文件（默认 release/notes）。目录不存在 / 为空 ⇒ 绿。有错 ⇒ 退出 1。
//   node tools/release-notes.mjs warn-missing --prev-versions <json> --versions <json> [--dir <dir>]
//     正式 tag 用：某端版本号相对上一版涨了、却没有该版本的说明文件 ⇒ 打 `::warning::`。
//     **永远退出 0**（允许「无用户可见变更」；发版流水线跑在 set -euo pipefail 下，告警不能拦发布）。
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_NOTES_DIR = join(HERE, "..", "release", "notes");

export const PLATFORMS = Object.freeze(["android", "macos", "windows"]);
export const LANGS = Object.freeze(["zh", "en"]);
/** 每种语言最多几条（= 几行）。 */
export const MAX_ITEMS = 3;
/**
 * 每种语言总长上限。量的是**写进清单的那一整串**（各行以 \n 拼接，换行也算），
 * 单位是 JS 字符串长度（UTF-16 码元）——与 Android 客户端 String.length / 截断口径一致，
 * 中文一字算 1、英文一个字符算 1。这样写满 3 条也不会被客户端截断。
 */
export const MAX_CHARS = 200;

const VERSION_RE = /^\d+\.\d+\.\d+$/;
const FILE_RE = /^(\d+\.\d+\.\d+)\.(zh|en)\.txt$/;

// ── 禁止模式：每条 = [代号, 说明, 正则]。正则全部带 g 以便取出命中片段。 ──
// 正例（不该报）由 release-notes.test.mjs 一并钉住：版本号 0.9.10、时间 12:30、英文单词 defaced。
export const FORBIDDEN = Object.freeze([
  ["url", "网址", /\b[a-z][a-z0-9+.-]*:\/\/|\bwww\.|\b(?:mailto|tel|sms|market|intent|javascript|file):/gi],
  ["email", "邮箱", /[a-z0-9._%+-]+[@＠][a-z0-9-]+(?:\.[a-z0-9-]+)*/gi],
  [
    "ip",
    "IP 地址",
    /(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])|(?<![0-9a-f:])(?:(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}|[0-9a-f]{0,4}::[0-9a-f:]*)(?![0-9a-f:])/gi,
  ],
  // 域名：至少一个点、顶级段至少 2 个字母（版本号 0.9.10、e.g. 不会命中）。文件名（x.json）同样命中——
  // 文件路径本来也在禁止之列。
  ["domain", "域名（或带扩展名的文件名）", /(?<![a-z0-9-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?![a-z0-9-])/gi],
  // 电话样式：7 位及以上数字，中间可夹空格 / 连字符 / 括号（日期 2026-10-09 同样命中——说明里不写日期）。
  ["phone", "电话号码样式（7 位以上连续数字）", /[+＋]?\d(?:[\s\-()]*\d){6,}/g],
  ["issue", "issue / PR 编号（#数字）", /[#＃]\s*\d+/g],
  // 提交号：7–40 位十六进制，且同时含数字与 a-f（纯字母的英文单词如 defaced 不算；纯数字归电话规则）。
  ["commit", "提交号", /(?<![0-9a-z])(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![0-9a-z])/gi],
  // 内部代号：UPD-13、SEC-14……（UTF-8 这类写法同样命中，说明里改用描述性措辞）
  ["codename", "内部代号（如 UPD-13）", /(?<![A-Za-z0-9])[A-Z]{2,}-\d+/g],
  [
    "markdown",
    "markdown 记号",
    /^[ \t]*(?:#{1,6}|[-*+>]|\d+[.)]|\|)(?=[ \t])|`|\*\*|__|~~|\]\(|!\[|<\/?[a-z][^>]*>/gim,
  ],
]);

/** Unicode 双向控制符（Trojan Source 类显示欺骗）。 */
export const BIDI_RE = /[‪-‮⁦-⁩‎‏؜]/g;
/** 零宽 / 不可见字符（含 BOM）。 */
export const ZERO_WIDTH_RE = /[​-‍⁠-⁤﻿᠎]/g;
/** 其它控制字符（换行 \n 是分条符，不算）。 */
export const CONTROL_RE = /[\u0000-\u0009\u000B-\u001F\u007F-\u009F]/g;

const hex = (s) => [...s].map((c) => "U+" + c.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")).join(" ");

/** 文件原文 → 条目数组（去掉末尾换行；不做其它清洗，交给 lintText 判）。 */
export function splitItems(text) {
  return text.replace(/\n+$/, "").split("\n");
}

/** 写进清单的那一串：各条去首尾空白、以 \n 拼接。 */
export function manifestText(text) {
  return splitItems(text)
    .map((l) => l.trim())
    .join("\n");
}

/**
 * 单个文件内容的规则检查。
 * @returns {string[]} 错误列表（空 = 通过）
 */
export function lintText(text) {
  const errs = [];
  const take = (re) => [...new Set(text.match(re) ?? [])];
  const bidi = take(BIDI_RE);
  if (bidi.length) errs.push(`含 Unicode 双向控制符（${hex(bidi.join(""))}）`);
  const zw = take(ZERO_WIDTH_RE);
  if (zw.length) errs.push(`含零宽/不可见字符（${hex(zw.join(""))}）`);
  const ctl = take(CONTROL_RE);
  if (ctl.length) errs.push(`含控制字符（${hex(ctl.join(""))}；换行请用 LF，不要 CRLF / 制表符）`);

  const items = splitItems(text);
  if (items.length === 1 && items[0].trim() === "") {
    errs.push("文件为空（没有用户可见变更就不要建这个文件）");
    return errs;
  }
  if (items.some((l) => l.trim() === "")) errs.push("含空行（每行一条，条目之间不留空行）");
  if (items.length > MAX_ITEMS) errs.push(`条数 ${items.length} > ${MAX_ITEMS}`);
  const out = manifestText(text);
  if (out.length > MAX_CHARS) errs.push(`总长 ${out.length} > ${MAX_CHARS}（各条以换行拼接后计，换行也算）`);

  for (const [, label, re] of FORBIDDEN) {
    const hits = take(re).map((h) => h.trim()).filter(Boolean);
    if (hits.length) errs.push(`含${label}：${hits.map((h) => JSON.stringify(h)).join("、")}`);
  }
  return errs;
}

/** 严格按 UTF-8 解码；非法字节序列直接报错（不许静默替换成 U+FFFD）。 */
function decodeUtf8(buf, path) {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(buf);
  } catch {
    throw new Error(`${path}: 不是合法的 UTF-8`);
  }
}

/**
 * 校验整个说明目录。目录不存在 / 为空 ⇒ 没有错误。
 * @returns {{ files: number, errors: string[] }}
 */
export function lintDir(dir) {
  const errors = [];
  let files = 0;
  if (!existsSync(dir)) return { files, errors };
  const rel = (p) => {
    const r = relative(process.cwd(), p);
    return r && !r.startsWith("..") ? r : p;
  };
  for (const entry of readdirSync(dir)) {
    const pdir = join(dir, entry);
    if (!statSync(pdir).isDirectory()) {
      errors.push(`${rel(pdir)}: 说明目录下只放 <platform>/ 子目录`);
      continue;
    }
    if (!PLATFORMS.includes(entry)) {
      errors.push(`${rel(pdir)}: 未知的端「${entry}」（只认 ${PLATFORMS.join(" / ")}）`);
      continue;
    }
    const byVersion = new Map();
    for (const name of readdirSync(pdir)) {
      const p = join(pdir, name);
      const m = FILE_RE.exec(name);
      if (!m || !statSync(p).isFile()) {
        errors.push(`${rel(p)}: 文件名必须是 <version>.<zh|en>.txt（version 形如 0.9.10）`);
        continue;
      }
      files++;
      const [, version, lang] = m;
      let text;
      try {
        text = decodeUtf8(readFileSync(p), rel(p));
      } catch (e) {
        errors.push(e.message);
        continue;
      }
      for (const err of lintText(text)) errors.push(`${rel(p)}: ${err}`);
      if (!byVersion.has(version)) byVersion.set(version, {});
      byVersion.get(version)[lang] = text;
    }
    for (const [version, langs] of byVersion) {
      const missing = LANGS.filter((l) => !(l in langs));
      if (missing.length) {
        errors.push(`${rel(join(pdir, version))}: 缺 ${missing.map((l) => `${version}.${l}.txt`).join("、")}（中英必须成对）`);
        continue;
      }
      const [zh, en] = LANGS.map((l) => splitItems(langs[l]).length);
      if (zh !== en) errors.push(`${rel(join(pdir, version))}: 中英条数不一致（zh ${zh} 条 / en ${en} 条，应一一对应）`);
    }
  }
  return { files, errors };
}

/**
 * 读某端某版本的说明，给 make-update-manifest 用。
 *   - 两种语言都没有文件 ⇒ null（说明为空，客户端显示默认文案）
 *   - 只有一种语言 / 内容不合规 ⇒ 抛错（只有绕过 CI lint 才会走到这里，宁可红也不带病发布）
 * @returns {null | { zh: string, en: string }}
 */
export function readNotes(dir, platform, version) {
  if (!PLATFORMS.includes(platform)) {
    throw new Error(`unknown platform ${platform} (expected ${PLATFORMS.join("/")})`);
  }
  const paths = Object.fromEntries(LANGS.map((l) => [l, join(dir, platform, `${version}.${l}.txt`)]));
  const present = LANGS.filter((l) => existsSync(paths[l]));
  if (present.length === 0) return null;
  if (present.length !== LANGS.length) {
    const miss = LANGS.filter((l) => !present.includes(l));
    throw new Error(`release notes for ${platform} ${version}: missing ${miss.map((l) => paths[l]).join(", ")} (zh/en must come in pairs)`);
  }
  const out = {};
  const errs = [];
  for (const l of LANGS) {
    const text = decodeUtf8(readFileSync(paths[l]), paths[l]);
    for (const e of lintText(text)) errs.push(`${paths[l]}: ${e}`);
    out[l] = manifestText(text);
  }
  if (errs.length) throw new Error(`release notes failed lint:\n  ${errs.join("\n  ")}`);
  return out;
}

/** versions.json 的键 → 该版本号对应的说明端。desktop 号只对应 macOS（正式 tag 不发 Windows）。 */
export const VERSION_KEY_PLATFORMS = Object.freeze({ android: ["android"], desktop: ["macos"] });

/**
 * 正式 tag：版本号涨了却没有说明文件的端。
 * @returns {string[]} 告警行（不含 ::warning:: 前缀）
 */
export function missingNotes(prevVersions, curVersions, dir) {
  const out = [];
  for (const [key, platforms] of Object.entries(VERSION_KEY_PLATFORMS)) {
    const cur = curVersions?.[key];
    if (typeof cur !== "string" || !VERSION_RE.test(cur)) continue;
    if (prevVersions?.[key] === cur) continue; // 没涨：沿用上一版的说明（或本来就没有），不告警
    for (const p of platforms) {
      const miss = LANGS.filter((l) => !existsSync(join(dir, p, `${cur}.${l}.txt`)));
      if (miss.length) {
        out.push(
          `${p} 版本涨到 ${cur}（上一版 ${prevVersions?.[key] ?? "未知"}），但没有 release/notes/${p}/${cur}.{${miss.join(",")}}.txt` +
            "——更新弹窗将显示默认文案。确认本版没有用户可见变更即可忽略。",
        );
      }
    }
  }
  return out;
}

// ── CLI ──
function argValue(args, name) {
  const i = args.indexOf(name);
  if (i < 0 || !args[i + 1]) throw new Error(`missing ${name}`);
  return args[i + 1];
}

function main(args) {
  const cmd = args[0];
  if (cmd === "lint") {
    const dir = args[1] ?? DEFAULT_NOTES_DIR;
    const { files, errors } = lintDir(dir);
    if (errors.length) {
      for (const e of errors) console.error(`::error::${e}`);
      console.error(`release notes lint: ${errors.length} error(s) in ${files} file(s)`);
      return 1;
    }
    const shown = relative(process.cwd(), dir);
    console.log(`release notes lint: ok (${files} file(s) under ${shown && !shown.startsWith("..") ? shown : dir})`);
    return 0;
  }
  if (cmd === "warn-missing") {
    // 告警不拦发布：任何意外（参数缺失、JSON 坏）都降级成告警、退出 0。
    try {
      const prev = JSON.parse(readFileSync(argValue(args, "--prev-versions"), "utf8"));
      const cur = JSON.parse(readFileSync(argValue(args, "--versions"), "utf8"));
      const dir = args.includes("--dir") ? argValue(args, "--dir") : DEFAULT_NOTES_DIR;
      const lines = missingNotes(prev, cur, dir);
      for (const l of lines) console.log(`::warning::${l}`);
      if (!lines.length) console.log("release notes: 涨了版本号的端都有说明文件");
    } catch (e) {
      console.log(`::warning::release notes 检查没跑成（不阻断发布）：${e.message}`);
    }
    return 0;
  }
  console.error("usage: release-notes.mjs lint [<dir>] | warn-missing --prev-versions <json> --versions <json> [--dir <dir>]");
  return 2;
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  process.exitCode = main(process.argv.slice(2));
}
