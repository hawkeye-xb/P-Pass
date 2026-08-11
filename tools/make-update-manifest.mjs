#!/usr/bin/env node
// UPD-01: build the tauri-style update manifest from release artifacts.
//
// Modes:
//   compose (default): scan --asset <target>=<path> pairs, emit manifest.json
//     with sha256 per platform and empty signatures (untrusted until signed).
//   sign:   --sign manifest.json --sig-dir <dir>  — for each platform entry,
//     read <dir>/<basename>.sig (produced by `tauri signer sign`), fill the
//     base64 signature into the manifest. Signing itself stays in the tauri
//     signer (minisign/rsign format); this script only wires files in.
//
// Manifest shape (tauri-plugin-updater compatible):
//   { version, notes, pub_date, platforms: { <target>: { url, signature } } }
//   url points at the GitHub release asset download link for TAG, unless
//   --asset-base overrides it (CI-01: R2 mirror domain dl.p-pass.hawkeye-xb.com
//   for mainland download reachability — signature is over the asset bytes,
//   so changing the download URL never invalidates verification).
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";

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
} else {
  // ── compose mode ──
  const tag = need("--tag");
  const notesFile = need("--notes");
  const assets = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--asset") {
      const [target, path] = args[i + 1].split("=");
      if (!target || !path || !existsSync(path)) throw new Error(`bad --asset: ${args[i + 1]}`);
      assets[target] = path;
    }
  }
  if (Object.keys(assets).length === 0) throw new Error("no --asset target=path pairs");
  const notes = readFileSync(notesFile, "utf8");
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
    };
    console.log(`composed ${target}: ${basename(path)} sha256=${createHash("sha256").update(data).digest("hex").slice(0, 16)}…`);
  }

  const manifest = {
    version: tag.replace(/^v/, ""),
    notes,
    pub_date: new Date().toISOString(),
    platforms,
  };
  writeFileSync("manifest.json", JSON.stringify(manifest, null, 2) + "\n");
  console.log("manifest.json written (signatures empty — sign with UPDATE_SIGNING_KEY)");
}
