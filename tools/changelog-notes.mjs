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
//   - 输出是纯文本：去掉小标题行、粗体/行内代码/链接语法、issue 号括注；列表符号换成「· 」。
//     旧版客户端（0.9.7 及以前）直接 take(200) 原样显示 notes，所以清洗必须在这里做，
//     不能只靠客户端兜底。
//
// 纯函数，无 I/O：单测见 tools/changelog-notes.test.mjs。

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
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
export function changelogNotes(changelog, version) {
  if (!version || /^unreleased$/i.test(version)) return "";
  const lines = changelog.replace(/\r\n?/g, "\n").split("\n");
  const head = new RegExp(`^##\\s+\\[${escapeRegExp(version)}\\](?:\\s|$)`);
  const start = lines.findIndex((l) => head.test(l));
  if (start < 0) return "";

  const out = [];
  let skipping = false; // 处在 ### Internal 段内
  for (const raw of lines.slice(start + 1)) {
    if (/^##\s/.test(raw)) break; // 下一个版本小节
    if (/^\[[^\]]+\]:\s*\S/.test(raw)) break; // 文末链接引用定义
    if (/^###\s/.test(raw)) {
      skipping = /^###\s+internal\b/i.test(raw);
      continue; // 小标题（Fixed / Changed …）本身不展示
    }
    if (skipping) continue;
    let line = raw.trim();
    if (/^(?:-{3,}|\*{3,}|_{3,})$/.test(line)) continue; // 分隔线
    line = line.replace(/^>\s?/, ""); // 引用
    line = line.replace(/^[-*+]\s+/, "· "); // 列表项
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
