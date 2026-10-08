// UPD-03（#580）：manifest notes 取自 CHANGELOG 本版小节（纯文本）的契约测试。
// 运行：node --test tools/changelog-notes.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { changelogNotes } from "./changelog-notes.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

const CHANGELOG = `# Changelog

All notable changes to P-Pass are documented in this file.

## [Unreleased]

### Fixed
- 未发布的修复，不能出现在任何版本的 notes 里。

## [2026.10.3] - 2026-10-08

**Android 0.9.8** —— 更新说明更好读。

### Fixed
- 更新弹窗不再把 \`manifest-android.json\` 和**粗体**这类 markdown 原文露出来。(#580)
- 修复一处 [链接](https://example.com/x) 问题（#667、#732）。
  > 引用的补充说明。

### Internal
- 发布流水线改用 \`CHANGELOG.md\` 生成 notes，开发者才关心。

## [2026.10.2] - 2026-10-05

### Internal
- 无用户可见变更。

## [2026.10.1] - 2026-10-04

### Changed
- 2026.10.1 的条目。

## [2026.10.10] - 2026-10-20

### Added
- 2026.10.10 的条目。

[2026.10.1]: https://github.com/hawkeye-xb/P-Pass/releases/tag/v2026.10.1
`;

// #741：一节里混着各端条目
const MIXED = `## [2026.10.4] - 2026-10-09

**Android 0.9.9 · macOS 0.9.3 · Windows 0.9.0** —— 分端说明过滤验证，
摘要段第二行同样不该出现。

### Fixed
- Android 端：安卓专属修复。(#741)
  续行：安卓专属修复的补充说明。
- macOS 端：mac 专属修复。
  续行：mac 专属修复的补充说明。
- Windows端:Windows 专属修复（半角冒号、无空格）。
- **桌面端**：桌面通用修复（前缀加粗）。
- 通用修复：所有端都该看到；正文里提到 macOS 端也不算前缀。

### Changed
- macOS 端：只属于 mac 的 Changed 条目。

### Internal
- Android 端：内部条目，哪端都不该看到。

## [2026.10.5] - 2026-10-10

**Android 1.0.0 · macOS 0.9.3（本版未变更）** —— 只有安卓变更。

### Fixed
- Android 端：只有安卓的修复。

### Internal
- 无用户可见变更。
`;

const MD_SYMBOLS = /##|\*\*|`|^>|\]\(|#\d/m;

test("取精确版本小节：去掉批次摘要行 / 小标题 / 粗体 / 反引号 / 引用 / 链接 / issue 号，列表变「· 」", () => {
  const n = changelogNotes(CHANGELOG, "2026.10.3");
  assert.equal(
    n,
    [
      "· 更新弹窗不再把 manifest-android.json 和粗体这类 markdown 原文露出来。",
      "· 修复一处 链接 问题。",
      "引用的补充说明。",
    ].join("\n"),
  );
});

test("输出不含 markdown 记号（##、**、反引号、行首 >、链接语法、issue 号）", () => {
  assert.doesNotMatch(changelogNotes(CHANGELOG, "2026.10.3"), MD_SYMBOLS);
});

test("### Internal 整段丢弃；只有 Internal 的版本 ⇒ 空串", () => {
  assert.doesNotMatch(changelogNotes(CHANGELOG, "2026.10.3"), /流水线|CHANGELOG\.md/);
  assert.equal(changelogNotes(CHANGELOG, "2026.10.2"), "");
});

test("版本号精确匹配：2026.10.1 不吃 2026.10.10，反之亦然；不越过文末链接引用", () => {
  assert.equal(changelogNotes(CHANGELOG, "2026.10.1"), "· 2026.10.1 的条目。");
  assert.equal(changelogNotes(CHANGELOG, "2026.10.10"), "· 2026.10.10 的条目。");
});

test("没有该小节 / test tag / Unreleased / 空版本 ⇒ 空串", () => {
  assert.equal(changelogNotes(CHANGELOG, "9.9.9"), "");
  assert.equal(changelogNotes(CHANGELOG, "2026.10.3-test.1"), "");
  assert.equal(changelogNotes(CHANGELOG, "Unreleased"), "");
  assert.equal(changelogNotes(CHANGELOG, ""), "");
});

test("#741 android：保留 Android 端 + 无前缀，去掉前缀；别端条目连同续行丢；摘要段整段丢", () => {
  assert.equal(
    changelogNotes(MIXED, "2026.10.4", "android"),
    [
      "· 安卓专属修复。",
      "续行：安卓专属修复的补充说明。",
      "· 通用修复：所有端都该看到；正文里提到 macOS 端也不算前缀。",
    ].join("\n"),
  );
});

test("#741 macos：保留 macOS 端 + 桌面端 + 无前缀", () => {
  assert.equal(
    changelogNotes(MIXED, "2026.10.4", "macos"),
    [
      "· mac 专属修复。",
      "续行：mac 专属修复的补充说明。",
      "· 桌面通用修复（前缀加粗）。",
      "· 通用修复：所有端都该看到；正文里提到 macOS 端也不算前缀。",
      "",
      "· 只属于 mac 的 Changed 条目。",
    ].join("\n"),
  );
});

test("#741 windows：保留 Windows 端（半角冒号/无空格也认）+ 桌面端 + 无前缀", () => {
  assert.equal(
    changelogNotes(MIXED, "2026.10.4", "windows"),
    [
      "· Windows 专属修复（半角冒号、无空格）。",
      "· 桌面通用修复（前缀加粗）。",
      "· 通用修复：所有端都该看到；正文里提到 macOS 端也不算前缀。",
    ].join("\n"),
  );
});

test("#741 批次摘要行（含多行摘要段）任何端都不出现", () => {
  for (const p of [undefined, "android", "macos", "windows"]) {
    const n = changelogNotes(MIXED, "2026.10.4", p);
    assert.doesNotMatch(n, /0\.9\.9|分端说明过滤验证|摘要段第二行/, String(p));
  }
});

test("#741 过滤后为空 ⇒ 空串（不抛错）", () => {
  assert.equal(changelogNotes(MIXED, "2026.10.5", "macos"), "");
  assert.equal(changelogNotes(MIXED, "2026.10.5", "windows"), "");
  assert.equal(changelogNotes(MIXED, "2026.10.5", "android"), "· 只有安卓的修复。");
});

test("#741 未知端名 ⇒ 抛错（参数错，不是数据问题）", () => {
  assert.throws(() => changelogNotes(MIXED, "2026.10.4", "ios"), /unknown platform/);
});

test("反斜杠转义还原：\\< → <", () => {
  const c = "## [1.0.0]\n\n- 资产名 P-Pass_\\<版本\\>_android.apk\n";
  assert.equal(changelogNotes(c, "1.0.0"), "· 资产名 P-Pass_<版本>_android.apk");
});

test("CRLF 换行同样能抽取", () => {
  assert.equal(changelogNotes(CHANGELOG.replace(/\n/g, "\r\n"), "2026.10.1"), "· 2026.10.1 的条目。");
});

test("版本号里的 . 不当正则通配：2026x10x1 不命中 2026.10.1", () => {
  assert.equal(changelogNotes(CHANGELOG, "2026x10x1"), "");
});

// ── CLI：make-update-manifest.mjs 端到端 ──
function compose(extraArgs) {
  const dir = mkdtempSync(join(tmpdir(), "ppass-notes-"));
  writeFileSync(join(dir, "CHANGELOG.md"), CHANGELOG + "\n" + MIXED);
  writeFileSync(join(dir, "NOTES.md"), "## P-Pass 2026.10.3\n\n构建自 `abc1234`\n");
  writeFileSync(join(dir, "P-Pass_0.9.8_android.apk"), "apk-bytes");
  const r = spawnSync(
    process.execPath,
    [
      join(HERE, "make-update-manifest.mjs"),
      "--asset",
      `android-arm64=${join(dir, "P-Pass_0.9.8_android.apk")}`,
      "--version",
      "0.9.8",
      "--out",
      join(dir, "m.json"),
      ...extraArgs(dir),
    ],
    { cwd: dir, encoding: "utf8" },
  );
  return { r, manifest: () => JSON.parse(readFileSync(join(dir, "m.json"), "utf8")) };
}

test("CLI --notes-from-changelog：键是 tag 批次号（不是 --version 分端号）", () => {
  const { r, manifest } = compose((d) => [
    "--tag", "v2026.10.3", "--notes-from-changelog", join(d, "CHANGELOG.md"), "--only", "android-arm64",
  ]);
  assert.equal(r.status, 0, r.stderr);
  const m = manifest();
  assert.equal(m.version, "0.9.8");
  assert.equal(m.notes, changelogNotes(CHANGELOG, "2026.10.3"));
  assert.doesNotMatch(m.notes, /构建自/);
});

test("CLI --notes-from-changelog：test tag 无小节 ⇒ notes 为空串", () => {
  const { r, manifest } = compose((d) => [
    "--tag", "v0.9.8-test.1", "--notes-from-changelog", join(d, "CHANGELOG.md"), "--notes-platform", "android",
  ]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(manifest().notes, "");
});

test("#741 CLI --only android-arm64 ⇒ notes 按 android 过滤", () => {
  const { r, manifest } = compose((d) => [
    "--tag", "v2026.10.4", "--notes-from-changelog", join(d, "CHANGELOG.md"), "--only", "android-arm64",
  ]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(manifest().notes, changelogNotes(MIXED, "2026.10.4", "android"));
  assert.doesNotMatch(manifest().notes, /mac 专属|桌面通用|Windows 专属|0\.9\.9/);
});

test("#741 CLI 过滤后为空 ⇒ 退出码 0、notes 为空串（发版流水线 set -euo pipefail 不被拦）", () => {
  const { r, manifest } = compose((d) => [
    "--tag", "v2026.10.5", "--notes-from-changelog", join(d, "CHANGELOG.md"), "--notes-platform", "macos",
  ]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(manifest().notes, "");
  assert.match(r.stdout, /has nothing for macos/);
});

test("#741 CLI 推不出端（无 --only 也无 --notes-platform）/ 端名非法 ⇒ 报错退出", () => {
  const none = compose((d) => ["--tag", "v2026.10.4", "--notes-from-changelog", join(d, "CHANGELOG.md")]);
  assert.notEqual(none.r.status, 0);
  assert.match(none.r.stderr, /needs a platform/);
  const bad = compose((d) => [
    "--tag", "v2026.10.4", "--notes-from-changelog", join(d, "CHANGELOG.md"), "--notes-platform", "ios",
  ]);
  assert.notEqual(bad.r.status, 0);
});

test("CLI --notes 仍原样读入（repair-manifests.yml 兼容）", () => {
  const { r, manifest } = compose((d) => ["--tag", "v2026.10.3", "--notes", join(d, "NOTES.md")]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(manifest().notes, /^## P-Pass 2026\.10\.3/);
});

test("CLI 两个 notes 来源都给 / 都不给 ⇒ 报错退出", () => {
  const both = compose((d) => [
    "--tag", "v2026.10.3", "--notes", join(d, "NOTES.md"), "--notes-from-changelog", join(d, "CHANGELOG.md"),
  ]);
  assert.notEqual(both.r.status, 0);
  const none = compose(() => ["--tag", "v2026.10.3"]);
  assert.notEqual(none.r.status, 0);
});

test("release.yml 不再把 release 正文喂给 manifest（全部改走 CHANGELOG）", () => {
  const wf = readFileSync(join(HERE, "..", ".github", "workflows", "release.yml"), "utf8");
  const calls = wf.match(/make-update-manifest\.mjs[^\n]*\n(?:[^\n]*\\\n)*[^\n]*/g) ?? [];
  const composeCalls = calls.filter((c) => c.includes("--tag"));
  assert.ok(composeCalls.length >= 6, `compose 调用点应 ≥6，实际 ${composeCalls.length}`);
  for (const c of composeCalls) {
    assert.match(c, /--notes-from-changelog CHANGELOG\.md/, c);
    assert.doesNotMatch(c, /--notes NOTES\.md/, c);
    // #741：每处都要能定端——分端清单靠 --only；无 --only 的（test 通道 manifest.json，
    // 只有 Android 展示 notes）必须显式 --notes-platform android
    if (!/--only /.test(c)) assert.match(c, /--notes-platform android\b/, c);
  }
  assert.doesNotMatch(wf, /gh release view "\$TAG" --json body -q \.body > NOTES\.md/);
});
