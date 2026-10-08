#!/usr/bin/env node
// UPD-01: build the tauri-style update manifest from release artifacts.
//
// Modes:
//   compose (default): scan --asset <target>=<path> pairs, emit manifest.json
//     with sha256 per platform and empty signatures (untrusted until signed).
//     notes 二选一：--notes <file>（原样读入）或 --notes-from-changelog
//     <CHANGELOG.md>（UPD-03 #580：取 tag 版本号对应小节、清洗成纯文本，没有该
//     小节就是 ""——客户端空 notes 显示默认文案。release.yml 用这个）。
//   sign:   --sign manifest.json --sig-dir <dir>  — for each platform entry,
//     read <dir>/<basename>.sig (produced by `tauri signer sign`), fill the
//     base64 signature into the manifest. Signing itself stays in the tauri
//     signer (minisign/rsign format); this script only wires files in.
//   rebase (#650): --rebase manifest.json --asset-base <base>
//     --mirror <target>=<object> [--out <path>] — 把指定条目的下载 URL
//     改写成镜像域直链（给 R2 上的 manifest.json 用；只动 url，
//     signature/sha256 是对资产字节的，换下载域名不影响校验）。
//
// Manifest shape (tauri-plugin-updater compatible):
//   { version, notes, pub_date, platforms: { <target>: { url, signature } } }
//   url points at the GitHub release asset download link for TAG, unless
//   --asset-base overrides it (CI-01: R2 mirror domain p-pass-dl.hawkeye-xb.com
//   for mainland download reachability — signature is over the asset bytes,
//   so changing the download URL never invalidates verification).
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";
import { changelogNotes } from "./changelog-notes.mjs";

const args = process.argv.slice(2);

function need(name) {
  const i = args.indexOf(name);
  if (i < 0 || !args[i + 1]) throw new Error(`missing ${name}`);
  return args[i + 1];
}

if (args[0] === "--sign") {
  // ── sign mode: fill signature fields from tauri signer .sig files ──
  const manifestPath = need("--sign");
  const sigDir = need("--sig-dir");

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  for (const [target, entry] of Object.entries(manifest.platforms)) {
    const name = basename(new URL(entry.url).pathname);
    const sigFile = join(sigDir, `${name}.sig`);
    if (!existsSync(sigFile)) throw new Error(`signature missing for ${target}: ${sigFile}`);
    entry.signature = readFileSync(sigFile, "utf8").trim();
    console.log(`filled ${target} <- ${name}.sig`);
  }
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`manifest signed: ${manifestPath}`);
} else if (args[0] === "--rebase") {
  // ── rebase mode (#650): 把已签名 manifest 里指定条目的下载 URL 改写成镜像域直链 ──
  // 用法：--rebase <manifest> --asset-base <base> --mirror <target>=<object> [--out <path>]
  // 只动 url 字段：signature 与 sha256 都是对**资产字节**的，换下载域名不影响校验
  // （R2 只是搬运工，被篡改的包照样在校验闸被拒）。
  const manifestPath = need("--rebase");
  const base = need("--asset-base").replace(/\/+$/, "");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const mirrors = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--mirror") {
      const [target, object] = args[i + 1].split("=");
      if (!target || !object) throw new Error(`bad --mirror: ${args[i + 1]}`);
      mirrors[target] = object;
    }
  }
  if (Object.keys(mirrors).length === 0) throw new Error("no --mirror target=object pairs");
  for (const [target, object] of Object.entries(mirrors)) {
    const entry = manifest.platforms?.[target];
    if (!entry) throw new Error(`manifest has no platform ${target}`);
    entry.url = `${base}/${object}`;
    console.log(`rebased ${target} -> ${entry.url}`);
  }
  const out = args.indexOf("--out") >= 0 ? need("--out") : manifestPath;
  writeFileSync(out, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`manifest rebased: ${out}`);
} else {
  // ── compose mode ──
  // UPD-13: --only <target> 可重复，只收这些平台条目；--out 指定输出文件名；
  // --version 覆盖顶层 version（分端 manifest 用它填**该端自己的版本号**，
  // 默认仍是 tag 去 v 前缀）。
  const tag = need("--tag");
  const hasNotes = args.indexOf("--notes") >= 0;
  const hasChangelog = args.indexOf("--notes-from-changelog") >= 0;
  if (hasNotes === hasChangelog) {
    throw new Error("exactly one of --notes <file> / --notes-from-changelog <CHANGELOG.md> is required");
  }
  const only = new Set();
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--only") {
      const t = args[i + 1];
      if (!t) throw new Error("bad --only: missing target");
      only.add(t);
    }
  }
  const outPath = args.indexOf("--out") >= 0 ? need("--out") : "manifest.json";
  const version = args.indexOf("--version") >= 0 ? need("--version") : tag.replace(/^v/, "");
  const assets = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--asset") {
      const [target, path] = args[i + 1].split("=");
      if (!target || !path || !existsSync(path)) throw new Error(`bad --asset: ${args[i + 1]}`);
      if (only.size > 0 && !only.has(target)) {
        console.log(`skipped ${target} (not in --only)`);
        continue;
      }
      assets[target] = path;
    }
  }
  if (Object.keys(assets).length === 0) {
    throw new Error(only.size > 0 ? `no assets matched --only ${[...only].join(",")}` : "no --asset target=path pairs");
  }
  let notes;
  if (hasChangelog) {
    // UPD-03（#580）：notes = CHANGELOG 里**批次号**（tag 去 v）那一节的用户可见内容。
    // 不用 --version：分端号（如 android 0.9.7）不是 CHANGELOG 的小节键。
    const key = tag.replace(/^v/, "");
    notes = changelogNotes(readFileSync(need("--notes-from-changelog"), "utf8"), key);
    console.log(
      notes
        ? `notes <- CHANGELOG [${key}] (${notes.length} chars)`
        : `notes empty: CHANGELOG has no user-facing [${key}] section (client shows its default text)`,
    );
  } else {
    notes = readFileSync(need("--notes"), "utf8");
  }
  // CI-01③a: --asset-base 覆盖下载前缀（默认 GitHub release 直链）。
  // R2 镜像域（dl.p-pass.hawkeye-xb.com/releases/<tag>）给国内下载可达性；
  // url 只是下载地址，签名是对资产字节的，换域名验签零变化。
  const base =
    (args.indexOf("--asset-base") >= 0
      ? need("--asset-base")
      : `https://github.com/hawkeye-xb/P-Pass/releases/download/${tag}`);

  const platforms = {};
  for (const [target, path] of Object.entries(assets)) {
    const data = readFileSync(path);
    platforms[target] = {
      url: `${base}/${basename(path)}`,
      signature: "", // filled by --sign when UPDATE_SIGNING_KEY is present
      // UPD-02: Android 端下载后先对 sha256（传输完整性），再验 minisign
      // （真实性）。tauri 桌面端忽略未知字段，桌面验签链零变化。
      sha256: createHash("sha256").update(data).digest("hex"),
    };
    console.log(`composed ${target}: ${basename(path)} sha256=${platforms[target].sha256.slice(0, 16)}…`);
  }

  const manifest = {
    version,
    notes,
    pub_date: new Date().toISOString(),
    platforms,
  };
  writeFileSync(outPath, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`${outPath} written (version=${version}; signatures empty — sign with UPDATE_SIGNING_KEY)`);
}
