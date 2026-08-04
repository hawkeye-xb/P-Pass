#!/usr/bin/env node
// UPD-01: build the tauri-style update manifest from release artifacts.
//
// Modes:
//   compose (default): scan --asset <target>=<path> pairs, emit manifest.json
//     with sha256 per platform and empty signatures (untrusted until signed).
//   sign:   --sign manifest.json --asset-dir <dir>  — for each platform entry,
//     find the asset file by basename inside <dir>, Ed25519-sign its bytes
//     with UPDATE_SIGNING_KEY (base64 secret key, 32-byte seed), write the
//     base64 signature back into the manifest. Refuses to run without the key.
//
// Manifest shape (tauri-plugin-updater compatible):
//   { version, notes, pub_date, platforms: { <target>: { url, signature } } }
//   url points at the GitHub release asset download link for TAG.
//
// Output: manifest.json in CWD (compose) or in place (sign).
import { createHash, sign as ed25519Sign, createPrivateKey } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";

const args = process.argv.slice(2);

function need(name) {
  const i = args.indexOf(name);
  if (i < 0 || !args[i + 1]) throw new Error(`missing ${name}`);
  return args[i + 1];
}

if (args[0] === "--sign") {
  // ── sign mode: fill signature fields for existing manifest.json ──
  const manifestPath = need("--sign");
  const assetDir = need("--asset-dir");
  const keyB64 = process.env.UPDATE_SIGNING_KEY;
  if (!keyB64) throw new Error("UPDATE_SIGNING_KEY not set — refusing to sign");
  const key = Buffer.from(keyB64, "base64");
  if (key.length !== 32) throw new Error(`key must be 32 bytes, got ${key.length}`);
  // 32-byte ed25519 seed → PKCS8 DER (RFC 8410) → KeyObject.
  // Node cannot sign with a bare seed buffer ("Invalid digest"); the DER
  // prefix is the standard wrapper (also what @tauri-apps/cli signer uses).
  const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), key]);
  const privateKey = createPrivateKey({ key: der, format: "der", type: "pkcs8" });

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  for (const [target, entry] of Object.entries(manifest.platforms)) {
    const file = join(assetDir, basename(new URL(entry.url).pathname));
    if (!existsSync(file)) throw new Error(`asset not found for ${target}: ${file}`);
    const data = readFileSync(file);
    const sig = ed25519Sign(null, data, privateKey);
    entry.signature = sig.toString("base64");
    console.log(`signed ${target} (${data.length} bytes) <- ${basename(file)}`);
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
  const base = `https://github.com/hawkeye-xb/P-Pass/releases/download/${tag}`;

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
