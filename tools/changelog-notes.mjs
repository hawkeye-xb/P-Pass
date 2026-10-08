// UPD-03（#580）：从 CHANGELOG.md 抽出「给用户看的本版说明」，作为更新 manifest 的 notes。
//
// 为什么不用 release 正文：manifest 在 create-draft 写完**开发者骨架**之后就组装了
// （构建自 sha、资产清单、验证步骤……），人工把 changelog 贴进正文发生在 publish 前，
// 永远晚于 manifest。客户端弹窗展示的就是 notes——用户在手机上看到的是构建说明。
//
// 口径：
//   - 只认与 tag 版本号（去 v 前缀，即批次号）**精确相同**的 `## [<version>]` 小节；
//     `[Unreleased]` 永不取。找不到 ⇒ 返回 ""（客户端空 notes 显示默认文案）。
//   - `### Internal` 整段丢弃（按定义不是用户可见变更）。
//   - 小节开头（第一个 `###` 之前）以 `**` 起头的加粗批次摘要行丢弃
//     （如「**Android 0.9.2 · macOS 0.9.1（本版未变更）** —— …」，是给开发者看的）。
//   - 按端过滤（#741）：顶层条目以「Android 端：」「macOS 端：」「Windows 端：」「桌面端：」
//     开头的才算带端前缀（冒号全/半角、前缀加粗都认；正文中间提到某端不算）。
//       android 保留「Android 端」+ 无前缀；macos 保留「macOS 端」「桌面端」+ 无前缀；
//       windows 保留「Windows 端」「桌面端」+ 无前缀。无前缀 = 全平台。
//     被丢条目的缩进续行一起丢。保留下来的条目**去掉前缀再展示**——弹窗本来就只在
//     这一端出现，「Android 端：」是冗余字样，还占旧客户端 take(200) 的字数。
//     不传 platform ⇒ 不按端过滤（只给单测/调试用；make-update-manifest 恒传端）。
//   - 输出是纯文本：去掉小标题行、粗体/行内代码/链接语法、issue 号括注；列表符号换成「· 」。
//     旧版客户端（0.9.7 及以前）直接 take(200) 原样显示 notes，所以清洗必须在这里做，
//     不能只靠客户端兜底。
//
// 过滤后没有内容 ⇒ 返回 ""（不是异常）：发版流水线跑在 set -euo pipefail 下，
// 这里抛错就会拦住资产上传；空 notes 由客户端显示默认文案。
//
// 纯函数，无 I/O：单测见 tools/changelog-notes.test.mjs。

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** 支持的端；值 = 该端保留的前缀端名（不含「端」字）。 */
export const PLATFORM_PREFIXES = Object.freeze({
  android: ["android"],
  macos: ["macos", "桌面"],
  windows: ["windows", "桌面"],
});

// 条目开头的端前缀：「Android 端：」「桌面端:」「**macOS 端**：」……（已去掉列表符与粗体后匹配）
const PREFIX_RE = /^(android|macos|windows|桌面)\s*端\s*[：:]\s*/i;

/** 条目文本（已清洗）→ { tag: 端名小写 | null, text: 去前缀后的文本 }。 */
export function splitPlatformPrefix(text) {
  const m = PREFIX_RE.exec(text);
  if (!m) return { tag: null, text };
  return { tag: m[1].toLowerCase(), text: text.slice(m[0].length) };
}

/** 去掉一行里的 markdown 行内语法，返回纯文本。 */
export function stripInlineMarkdown(line) {
  return (
    line
      // 图片 / 链接：![alt](u) / [t](u) → t
      .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
      // issue 号括注：(#555) / （#667、#732）——用户看不懂，也点不了
      .replace(/\s*[（(]\s*#\d+(?:\s*[、,，]\s*#\d+)*\s*[)）]/g, "")
      // 粗体 / 斜体 / 删除线 / 行内代码 记号
      .replace(/\*\*|__|~~/g, "")
      .replace(/`+/g, "")
      .replace(/(^|[\s(（])[*_](\S(?:.*?\S)?)[*_](?=$|[\s.,;:!?)）。，；：！？])/g, "$1$2")
      // 反斜杠转义：\< → <
      .replace(/\\([\\`*_{}[\]()#+\-.!<>|])/g, "$1")
  );
}

/**
 * 从 CHANGELOG 文本里抽出 `## [version]` 小节，清洗成给用户看的纯文本。
 * @param {string} changelog CHANGELOG.md 全文
 * @param {string} version   版本号（不带 v 前缀），与小节标题方括号内逐字相同
 * @returns {string} 纯文本说明；没有该小节 / 小节里没有用户可见内容 ⇒ ""
 */
export function changelogNotes(changelog, version, platform) {
  if (!version || /^unreleased$/i.test(version)) return "";
  if (platform !== undefined && !Object.hasOwn(PLATFORM_PREFIXES, platform)) {
    throw new Error(`unknown platform ${platform} (expected ${Object.keys(PLATFORM_PREFIXES).join("/")})`);
  }
  const keep = platform === undefined ? null : PLATFORM_PREFIXES[platform];
  const lines = changelog.replace(/\r\n?/g, "\n").split("\n");
  const head = new RegExp(`^##\\s+\\[${escapeRegExp(version)}\\](?:\\s|$)`);
  const start = lines.findIndex((l) => head.test(l));
  if (start < 0) return "";

  const out = [];
  let skipping = false; // 处在 ### Internal 段内
  let preamble = true; // 第一个 ### 之前（批次摘要行所在处）
  let dropBlock = false; // 当前块（摘要段 / 别端条目）连同续行一起丢
  for (const raw of lines.slice(start + 1)) {
    if (/^##\s/.test(raw)) break; // 下一个版本小节
    if (/^\[[^\]]+\]:\s*\S/.test(raw)) break; // 文末链接引用定义
    if (/^###\s/.test(raw)) {
      skipping = /^###\s+internal\b/i.test(raw);
      preamble = false;
      dropBlock = false;
      continue; // 小标题（Fixed / Changed …）本身不展示
    }
    if (skipping) continue;
    if (raw.trim() === "") {
      dropBlock = false;
      out.push("");
      continue;
    }
    const isItem = /^[-*+]\s+/.test(raw); // 顶层条目（列首无缩进）
    const isContinuation = /^\s/.test(raw); // 缩进续行，归属上一个条目
    if (isItem) {
      dropBlock = false;
    } else if (!isContinuation && !dropBlock) {
      // 顶格的非条目行：开新块（被丢块里的顶格行是同段续行，空行才结束）；
      // 小节开头的加粗行 = 批次摘要（#741），整段丢
      dropBlock = preamble && /^\*\*/.test(raw.trim());
    }
    if (dropBlock) continue;
    let line = raw.trim();
    if (/^(?:-{3,}|\*{3,}|_{3,})$/.test(line)) continue; // 分隔线
    line = line.replace(/^>\s?/, ""); // 引用
    if (isItem) {
      const body = stripInlineMarkdown(line.replace(/^[-*+]\s+/, "")).trim();
      const { tag, text } = splitPlatformPrefix(body);
      if (keep && tag !== null && !keep.includes(tag)) {
        dropBlock = true; // 别端条目：连同续行一起丢
        continue;
      }
      out.push(`· ${keep && tag !== null ? text : body}`);
      continue;
    }
    line = stripInlineMarkdown(line).trim();
    out.push(line);
  }

  // 合并连续空行、去首尾空行
  const text = out
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  // 只剩符号（如「·」）也算没有内容
  return /[\p{L}\p{N}]/u.test(text) ? text : "";
}
