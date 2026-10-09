// #741：手写用户更新说明——lint 规则、清单工具（make-update-manifest --notes-dir）、
// 缺失告警、release.yml 口径的契约测试。
// 运行：node --test tools/release-notes.test.mjs
//
// 夹具一律在临时目录现场生成；不可见字符用 \u 转义拼出来，仓库里不提交任何不可见字符。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { lintText, lintDir, readNotes, missingNotes, MAX_CHARS, MAX_ITEMS } from "./release-notes.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, "release-notes.mjs");
const MANIFEST_TOOL = join(HERE, "make-update-manifest.mjs");

const ZH = "更新弹窗按 App 语言显示说明。\n修复了一处安全问题，建议尽快更新。\n";
const EN = "The update dialog now follows the app language.\nFixed a security issue. Please update soon.\n";

function notesDir(files) {
  const dir = mkdtempSync(join(tmpdir(), "ppass-relnotes-"));
  for (const [rel, body] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, rel)), { recursive: true });
    writeFileSync(join(dir, rel), body);
  }
  return dir;
}

/** 断言 lintText 命中且错误信息含 label。 */
function rejects(text, label) {
  const errs = lintText(text);
  assert.ok(errs.some((e) => e.includes(label)), `应因「${label}」被拒：${JSON.stringify(text)} → ${JSON.stringify(errs)}`);
}

// ── 正例：合规文本零错误（防误报） ──
test("合规中英文本：零错误（版本号 0.9.10、时间 12:30、英文单词 defaced 不误报）", () => {
  assert.deepEqual(lintText(ZH), []);
  assert.deepEqual(lintText(EN), []);
  assert.deepEqual(lintText("升级到 0.9.10 后，12:30 的定时备份不再跳过。\n"), []);
  assert.deepEqual(lintText("Thumbnails are no longer defaced after rotation, e.g. in albums.\n"), []);
  assert.deepEqual(lintText("照片数量 100 万张以上时不再卡顿。\n"), []);
});

// ── 每条规则一个反例 ──
test("长度：超过 200（含换行）⇒ 红", () => {
  rejects("字".repeat(MAX_CHARS + 1), "总长");
  // 3 条各 66 字 + 2 个换行 = 200 正好通过；再加 1 字即红（换行也算长度）
  const ok = ["字".repeat(66), "字".repeat(66), "字".repeat(66)].join("\n");
  assert.equal(ok.length, 200);
  assert.deepEqual(lintText(ok), []);
  rejects(ok + "字", "总长");
});

test(`条数：超过 ${MAX_ITEMS} 条 ⇒ 红`, () => rejects("一\n二\n三\n四\n", "条数"));
test("空文件 ⇒ 红", () => rejects("\n", "文件为空"));
test("空行 ⇒ 红", () => rejects("一\n\n二\n", "空行"));
test("网址 ⇒ 红", () => rejects("详情见 https://p-pass.example/notes\n", "网址"));
test("网址紧贴中文（无空格）⇒ 红（与安卓客户端口径一致）", () => {
  for (const t of ["请到https://10.0.0.1下载\n", "打开http://localhost:8080\n", "去market://details?id=x\n"]) rejects(t, "网址");
});
test("www 网址（无协议）⇒ 红", () => rejects("访问 www.example 了解\n", "网址"));
test("域名 ⇒ 红", () => rejects("到 example.com 下载新版\n", "域名"));
test("邮箱 ⇒ 红", () => rejects("问题请反馈至 support＠example\n", "邮箱"));
test("IPv4 ⇒ 红", () => rejects("连接 192.168.1.10 更稳定\n", "IP 地址"));
test("IPv6 ⇒ 红", () => rejects("支持 fe80::1 链路地址\n", "IP 地址"));
test("电话 ⇒ 红", () => rejects("客服电话 400-123-4567\n", "电话"));
test("#数字（issue/PR 编号）⇒ 红", () => rejects("修复了闪退问题（#555）\n", "issue / PR 编号"));
test("提交号 ⇒ 红", () => rejects("包含修复 9a19b9e\n", "提交号"));
test("内部代号 ⇒ 红", () => rejects("完成 UPD-13 的收尾\n", "内部代号"));
test("markdown：行首列表符 ⇒ 红", () => rejects("- 修复了闪退\n", "markdown"));
test("markdown：粗体 ⇒ 红", () => rejects("**更快**的备份\n", "markdown"));
test("markdown：行内代码 ⇒ 红", () => rejects("修复 `sync` 卡住\n", "markdown"));
test("markdown：链接语法 ⇒ 红", () => rejects("见[说明](说明页)\n", "markdown"));
test("markdown：标题 ⇒ 红", () => rejects("## 新功能\n", "markdown"));
test("双向控制符（U+202E）⇒ 红", () => rejects("修复了‮一处问题\n", "双向控制符"));
test("双向控制符（U+2066 / U+200F / U+061C）⇒ 红", () => {
  for (const c of ["⁦", "‏", "؜"]) rejects(`修复${c}问题\n`, "双向控制符");
});
test("零宽字符（U+200B）⇒ 红", () => rejects("修复了​一处问题\n", "零宽"));
test("BOM（U+FEFF）⇒ 红", () => rejects("﻿修复了一处问题\n", "零宽"));
test("CRLF / 控制字符 ⇒ 红", () => rejects("修复一\r\n修复二\r\n", "控制字符"));

// ── 目录级：成对、命名、条数对应 ──
test("lintDir：目录不存在 / 合规成对 ⇒ 无错", () => {
  assert.deepEqual(lintDir(join(tmpdir(), "ppass-no-such-dir-741")).errors, []);
  const d = notesDir({ "android/0.9.10.zh.txt": ZH, "android/0.9.10.en.txt": EN });
  assert.deepEqual(lintDir(d), { files: 2, errors: [] });
});

test("lintDir：只有一种语言 ⇒ 红（中英必须成对）", () => {
  const d = notesDir({ "android/0.9.10.zh.txt": ZH });
  assert.ok(lintDir(d).errors.some((e) => /中英必须成对/.test(e)));
});

test("lintDir：中英条数不一致 ⇒ 红", () => {
  const d = notesDir({ "android/0.9.10.zh.txt": ZH, "android/0.9.10.en.txt": "Only one line.\n" });
  assert.ok(lintDir(d).errors.some((e) => /条数不一致/.test(e)));
});

test("lintDir：命名不合约定（未知端 / .md / zh-CN / 非 x.y.z）⇒ 红", () => {
  for (const bad of ["ios/0.9.10.zh.txt", "android/0.9.10.zh.md", "android/0.9.10.zh-CN.txt", "android/v0.9.10.zh.txt"]) {
    const d = notesDir({ [bad]: ZH });
    assert.ok(lintDir(d).errors.length > 0, `${bad} 应被拒`);
  }
});

test("lintDir：非法 UTF-8 ⇒ 红", () => {
  const d = notesDir({});
  mkdirSync(join(d, "android"));
  writeFileSync(join(d, "android", "0.9.10.zh.txt"), Buffer.from([0xe4, 0xbf, 0x0a]));
  writeFileSync(join(d, "android", "0.9.10.en.txt"), EN);
  assert.ok(lintDir(d).errors.some((e) => /UTF-8/.test(e)));
});

test("CLI lint：合规 ⇒ 0；违规 ⇒ 1 且输出 ::error::", () => {
  const good = notesDir({ "macos/0.9.6.zh.txt": ZH, "macos/0.9.6.en.txt": EN });
  assert.equal(spawnSync(process.execPath, [TOOL, "lint", good], { encoding: "utf8" }).status, 0);
  const bad = notesDir({ "macos/0.9.6.zh.txt": "见 https://x.example\n", "macos/0.9.6.en.txt": "See it.\n" });
  const r = spawnSync(process.execPath, [TOOL, "lint", bad], { encoding: "utf8" });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /::error::.*网址/);
});

test("仓库里的 release/notes/** 本身通过 lint", () => {
  const r = spawnSync(process.execPath, [TOOL, "lint"], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
});

// ── readNotes ──
test("readNotes：有文件 ⇒ 各行 trim、以 \\n 拼接；无文件 ⇒ null；只有一种语言 ⇒ 抛错", () => {
  const d = notesDir({ "android/0.9.10.zh.txt": "  第一条  \n第二条\n", "android/0.9.10.en.txt": "One\nTwo\n" });
  assert.deepEqual(readNotes(d, "android", "0.9.10"), { zh: "第一条\n第二条", en: "One\nTwo" });
  assert.equal(readNotes(d, "android", "0.9.11"), null);
  assert.equal(readNotes(d, "macos", "0.9.10"), null);
  const half = notesDir({ "android/0.9.10.en.txt": EN });
  assert.throws(() => readNotes(half, "android", "0.9.10"), /pairs/);
  assert.throws(() => readNotes(d, "ios", "0.9.10"), /unknown platform/);
});

// ── CLI：make-update-manifest.mjs 端到端 ──
function compose(files, extraArgs, { shell = false } = {}) {
  const dir = notesDir(files);
  writeFileSync(join(dir, "NOTES.md"), "## P-Pass 2026.10.3\n\n构建自 `abc1234`\n");
  writeFileSync(join(dir, "P-Pass_0.9.10_android.apk"), "apk-bytes");
  const argv = [
    MANIFEST_TOOL,
    "--asset",
    `android-arm64=${join(dir, "P-Pass_0.9.10_android.apk")}`,
    "--out",
    join(dir, "m.json"),
    ...extraArgs(dir),
  ];
  const q = (s) => `'${s.replaceAll("'", "'\\''")}'`;
  // shell 模式：与发版流水线相同，跑在 bash `set -euo pipefail` 下
  const r = shell
    ? spawnSync("bash", ["-c", `set -euo pipefail\n${q(process.execPath)} ${argv.map(q).join(" ")}\necho PIPELINE_CONTINUES`], {
        cwd: dir,
        encoding: "utf8",
      })
    : spawnSync(process.execPath, argv, { cwd: dir, encoding: "utf8" });
  return { r, dir, manifest: () => JSON.parse(readFileSync(join(dir, "m.json"), "utf8")) };
}

const PAIR = { "android/0.9.10.zh.txt": ZH, "android/0.9.10.en.txt": EN };

test("CLI 有文件：notes = 中文、notes_i18n = {zh,en}，键是 --version（该端版本号）", () => {
  const { r, manifest } = compose(PAIR, (d) => [
    "--tag", "v2026.10.4", "--version", "0.9.10", "--notes-dir", d, "--only", "android-arm64",
  ]);
  assert.equal(r.status, 0, r.stderr);
  const m = manifest();
  assert.equal(m.version, "0.9.10");
  assert.equal(m.notes, ZH.trimEnd());
  assert.deepEqual(m.notes_i18n, { zh: ZH.trimEnd(), en: EN.trimEnd() });
});

test("CLI 无文件（test tag）：set -euo pipefail 下退出 0、notes 为空、notes_i18n 为 {}", () => {
  const { r, manifest } = compose(PAIR, (d) => [
    "--tag", "v0.9.10-test.1", "--notes-dir", d, "--notes-platform", "android",
  ], { shell: true });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /PIPELINE_CONTINUES/);
  assert.match(r.stdout, /no release notes for android 0\.9\.10-test\.1/);
  assert.equal(manifest().notes, "");
  assert.deepEqual(manifest().notes_i18n, {});
});

test("CLI 无文件（正式 tag、该端本版没写说明）：退出 0、notes 为空", () => {
  const { r, manifest } = compose({}, (d) => [
    "--tag", "v2026.10.4", "--version", "0.9.10", "--notes-dir", d, "--only", "android-arm64",
  ], { shell: true });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(manifest().notes, "");
});

test("CLI 只有一种语言 ⇒ 报错退出（lint 红的情形，不带病发布）", () => {
  const { r } = compose({ "android/0.9.10.zh.txt": ZH }, (d) => [
    "--tag", "v2026.10.4", "--version", "0.9.10", "--notes-dir", d, "--only", "android-arm64",
  ]);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /zh\/en must come in pairs/);
});

test("CLI 内容不合规（绕过 CI 的篡改）⇒ 报错退出", () => {
  const { r } = compose({ "android/0.9.10.zh.txt": "见 https://x.example\n", "android/0.9.10.en.txt": "See it.\n" }, (d) => [
    "--tag", "v2026.10.4", "--version", "0.9.10", "--notes-dir", d, "--only", "android-arm64",
  ]);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /failed lint/);
});

test("CLI 端：--only 推端（darwin → macos 读 macos/ 目录）", () => {
  const files = { "macos/0.9.6.zh.txt": "桌面专属说明。\n", "macos/0.9.6.en.txt": "Desktop only.\n", ...PAIR };
  const dir = notesDir(files);
  writeFileSync(join(dir, "P-Pass_0.9.6_macos-arm64.app.tar.gz"), "tar");
  const r = spawnSync(process.execPath, [
    MANIFEST_TOOL, "--tag", "v2026.10.4", "--version", "0.9.6", "--notes-dir", dir,
    "--asset", `darwin-aarch64=${join(dir, "P-Pass_0.9.6_macos-arm64.app.tar.gz")}`,
    "--only", "darwin-aarch64", "--out", join(dir, "m.json"),
  ], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(readFileSync(join(dir, "m.json"), "utf8")).notes, "桌面专属说明。");
});

test("CLI 推不出端 / 端名非法 ⇒ 报错退出", () => {
  const none = compose(PAIR, (d) => ["--tag", "v2026.10.4", "--notes-dir", d]);
  assert.notEqual(none.r.status, 0);
  assert.match(none.r.stderr, /needs a platform/);
  const bad = compose(PAIR, (d) => ["--tag", "v2026.10.4", "--notes-dir", d, "--notes-platform", "ios"]);
  assert.notEqual(bad.r.status, 0);
});

test("CLI --notes 仍原样读入、不写 notes_i18n（工具兼容；workflow 已全部改走 --notes-dir，见下方口径门禁）", () => {
  const { r, manifest } = compose({}, (d) => ["--tag", "v2026.10.3", "--notes", join(d, "NOTES.md")]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(manifest().notes, /^## P-Pass 2026\.10\.3/);
  assert.equal("notes_i18n" in manifest(), false);
});

test("CLI 两个 notes 来源都给 / 都不给 ⇒ 报错退出", () => {
  const both = compose(PAIR, (d) => ["--tag", "v2026.10.3", "--notes", join(d, "NOTES.md"), "--notes-dir", d]);
  assert.notEqual(both.r.status, 0);
  const none = compose(PAIR, () => ["--tag", "v2026.10.3"]);
  assert.notEqual(none.r.status, 0);
});

// ── 缺失告警（正式 tag） ──
test("missingNotes：涨了号且无文件 ⇒ 告警；涨了号有文件 / 没涨号 ⇒ 不告警", () => {
  const d = notesDir(PAIR);
  assert.deepEqual(missingNotes({ android: "0.9.9", desktop: "0.9.5" }, { android: "0.9.10", desktop: "0.9.5" }, d), []);
  const w = missingNotes({ android: "0.9.9", desktop: "0.9.5" }, { android: "0.9.11", desktop: "0.9.6" }, d);
  assert.equal(w.length, 2);
  assert.match(w[0], /android 版本涨到 0\.9\.11/);
  assert.match(w[1], /macos 版本涨到 0\.9\.6/);
  // 上一版没有 versions.json（{}）⇒ 视为涨了
  assert.equal(missingNotes({}, { android: "0.9.10", desktop: "0.9.5" }, d).length, 1);
});

test("CLI warn-missing：set -euo pipefail 下恒退出 0（缺文件 / 参数坏都只告警）", () => {
  const d = notesDir({});
  writeFileSync(join(d, "prev.json"), JSON.stringify({ android: "0.9.9", desktop: "0.9.5" }));
  writeFileSync(join(d, "cur.json"), JSON.stringify({ android: "0.9.10", desktop: "0.9.5" }));
  const run = (args) =>
    spawnSync("bash", ["-c", `set -euo pipefail\n"$0" "$@"\necho PIPELINE_CONTINUES`, process.execPath, TOOL, ...args], {
      encoding: "utf8",
    });
  const r = run(["warn-missing", "--prev-versions", join(d, "prev.json"), "--versions", join(d, "cur.json"), "--dir", d]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /::warning::android 版本涨到 0\.9\.10/);
  assert.match(r.stdout, /PIPELINE_CONTINUES/);
  const broken = run(["warn-missing", "--prev-versions", join(d, "nope.json"), "--versions", join(d, "cur.json")]);
  assert.equal(broken.status, 0, broken.stderr);
  assert.match(broken.stdout, /::warning::release notes 检查没跑成/);
});

// ── release.yml 口径（原 #580 的 release.yml 源文本门禁迁移至此，意图不变） ──
test("release.yml：compose 全部走 --notes-dir release/notes，不再喂 release 正文 / CHANGELOG", () => {
  const wf = readFileSync(join(HERE, "..", ".github", "workflows", "release.yml"), "utf8");
  const calls = wf.match(/make-update-manifest\.mjs[^\n]*\n(?:[^\n]*\\\n)*[^\n]*/g) ?? [];
  const composeCalls = calls.filter((c) => c.includes("--tag"));
  assert.ok(composeCalls.length >= 6, `compose 调用点应 ≥6，实际 ${composeCalls.length}`);
  for (const c of composeCalls) {
    assert.match(c, /--notes-dir release\/notes\b/, c);
    assert.doesNotMatch(c, /--notes NOTES\.md/, c);
    assert.doesNotMatch(c, /CHANGELOG/, c);
    // 每处都要能定端——分端清单靠 --only；无 --only 的（test 通道 manifest.json，
    // 只有 Android 展示 notes）必须显式 --notes-platform android
    if (!/--only /.test(c)) assert.match(c, /--notes-platform android\b/, c);
  }
  assert.doesNotMatch(wf, /gh release view "\$TAG" --json body -q \.body > NOTES\.md/);
});

// ── 全部 workflow 的口径（#740）：所有生成清单的路径 notes 同源，release 正文进不了清单 ──
// 扫 .github/workflows/*.yml 与 .github/actions/**/action.yml 里**每一处** compose 调用
// （make-update-manifest.mjs + --tag；--sign / --rebase 不产出 notes，不在此列）。
/** 收集仓库内全部 workflow / composite action 文件，或用 overrides 替换某些文件的内容（反证用）。 */
function workflowSources() {
  const root = join(HERE, "..", ".github");
  const out = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const p = join(dir, name);
      if (statSync(p).isDirectory()) walk(p);
      else if (/\.ya?ml$/.test(name)) out.push([p.slice(root.length + 1), readFileSync(p, "utf8")]);
    }
  };
  walk(join(root, "workflows"));
  if (existsSync(join(root, "actions"))) walk(join(root, "actions"));
  return out;
}

/** 某份 workflow 源文本里违反口径的地方（空数组 = 合规）。 */
function manifestNotesViolations(src) {
  const bad = [];
  // 调用 = make-update-manifest.mjs 那一行 + 反斜杠续行
  const calls = src.match(/make-update-manifest\.mjs[^\n]*\n(?:[^\n]*\\\n)*[^\n]*/g) ?? [];
  for (const c of calls.filter((x) => /--tag\b/.test(x))) {
    if (!/--notes-dir\s+(?:\.\.\/)*release\/notes\b/.test(c)) bad.push(`compose 调用没带 --notes-dir release/notes：${c}`);
    if (/--notes(?![-\w])/.test(c)) bad.push(`compose 调用仍用 --notes <file>（原样读入，会把 release 正文 / 任意文件喂进清单）：${c}`);
    if (/CHANGELOG/.test(c)) bad.push(`compose 调用仍从 CHANGELOG 推导：${c}`);
  }
  // release 正文被读出来（gh release view … --json body）就是往清单里喂正文的前奏
  if (/gh release view[^\n]*--json\s+body/.test(src)) bad.push("读取了 release 正文（gh release view --json body）");
  return bad;
}

test("全部 workflow：make-update-manifest 的 compose 一律 --notes-dir release/notes，不读 release 正文（#740）", () => {
  const files = workflowSources();
  const composing = files.filter(([, s]) => /make-update-manifest\.mjs[^\n]*--tag|make-update-manifest\.mjs[^\n]*\\\n(?:[^\n]*\\\n)*[^\n]*--tag/.test(s));
  // 至少 release.yml 与 repair-manifests.yml 两处生成清单——少了说明扫描本身失效
  const names = composing.map(([n]) => n);
  assert.ok(names.includes("workflows/release.yml") && names.includes("workflows/repair-manifests.yml"), `生成清单的 workflow：${names}`);
  for (const [name, src] of files) assert.deepEqual(manifestNotesViolations(src), [], name);
});

test("口径检查本身会抓：--notes 旧写法 / 缺 --notes-dir / 读 release 正文 ⇒ 判违规", () => {
  const old = [
    '          gh release view "$TAG" -R "$GITHUB_REPOSITORY" --json body -q .body > NOTES.md',
    '          node ../tools/make-update-manifest.mjs --tag "$TAG" --notes ../NOTES.md \\',
    '            --asset-base "$BASE" --asset "android-arm64=$APK_L" \\',
    '            --version "$A" --only android-arm64 --out manifest-android.json',
  ].join("\n");
  const v = manifestNotesViolations(old);
  assert.ok(v.some((e) => /没带 --notes-dir/.test(e)), v.join("\n"));
  assert.ok(v.some((e) => /--notes <file>/.test(e)), v.join("\n"));
  assert.ok(v.some((e) => /release 正文/.test(e)), v.join("\n"));
  // 合规写法不误报（--notes-dir / --notes-platform 不算 --notes）
  const ok = 'node tools/make-update-manifest.mjs \\\n  --tag "$TAG" --notes-dir release/notes --notes-platform android \\\n  --asset x=y';
  assert.deepEqual(manifestNotesViolations(ok), []);
});

test("release.yml：正式 tag 有缺失说明告警步骤，且不阻断（continue-on-error + 只在非 test tag）", () => {
  const wf = readFileSync(join(HERE, "..", ".github", "workflows", "release.yml"), "utf8");
  const i = wf.indexOf("- name: Release notes presence (#741, warn only)");
  assert.ok(i > 0, "缺少 Release notes presence 步骤");
  const step = wf.slice(i, wf.indexOf("\n      - ", i + 1));
  assert.match(step, /continue-on-error: true/);
  assert.match(step, /!contains\(steps\.tag\.outputs\.tag, '-test\.'\)/);
  assert.match(step, /release-notes\.mjs warn-missing/);
});
