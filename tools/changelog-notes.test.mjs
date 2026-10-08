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

const MD_SYMBOLS = /##|\*\*|`|^>|\]\(|#\d/m;

test("取精确版本小节：去掉小标题 / 粗体 / 反引号 / 引用 / 链接 / issue 号，列表变「· 」", () => {
  const n = changelogNotes(CHANGELOG, "2026.10.3");
  assert.equal(
    n,
    [
      "Android 0.9.8 —— 更新说明更好读。",
      "",
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
  writeFileSync(join(dir, "CHANGELOG.md"), CHANGELOG);
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
  const { r, manifest } = compose((d) => ["--tag", "v2026.10.3", "--notes-from-changelog", join(d, "CHANGELOG.md")]);
  assert.equal(r.status, 0, r.stderr);
  const m = manifest();
  assert.equal(m.version, "0.9.8");
  assert.equal(m.notes, changelogNotes(CHANGELOG, "2026.10.3"));
  assert.doesNotMatch(m.notes, /构建自/);
});

test("CLI --notes-from-changelog：test tag 无小节 ⇒ notes 为空串", () => {
  const { r, manifest } = compose((d) => ["--tag", "v0.9.8-test.1", "--notes-from-changelog", join(d, "CHANGELOG.md")]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(manifest().notes, "");
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
  }
  assert.doesNotMatch(wf, /gh release view "\$TAG" --json body -q \.body > NOTES\.md/);
});
