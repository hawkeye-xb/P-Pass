#!/usr/bin/env node
// REL-12（#711）：独立校验更新清单里的签名（tauri signer / minisign 格式），给发布链 dry-run 用。
//
// 不经 tauri CLI：按 minisign 规范自己验，这样「签名器坏了」与「校验器坏了」不会互相掩盖。
//   公钥  = base64("untrusted comment: …\n" + base64("Ed" ‖ keyid[8] ‖ pk[32]))
//   签名  = base64("untrusted comment: …\n" + base64(alg[2] ‖ keyid[8] ‖ sig[64]) + "\n"
//                  + "trusted comment: <tc>\n" + base64(global_sig[64]))
//   alg "ED" = 预哈希（对 BLAKE2b-512(文件) 签名，tauri 默认）；"Ed" = 对原文签名。
//   global_sig 是对 sig[64] ‖ tc 的签名（防 trusted comment 被改）。
//
// 用法：node tools/release/verify-update-sig.mjs <公钥文件> <资产文件> <签名(base64 文本)>
//   签名参数可以是 @<文件>。通过 ⇒ 退出 0；任何不符 ⇒ 打印原因、退出 1。
import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";

const [pubFile, assetFile, sigArg] = process.argv.slice(2);
if (!pubFile || !assetFile || !sigArg) {
  console.error("usage: verify-update-sig.mjs <pubkey-file> <asset> <signature|@file>");
  process.exit(2);
}

const b64text = (s) => Buffer.from(s.trim(), "base64").toString("utf8");
const lines = (s) => s.split("\n").map((l) => l.replace(/\r$/, ""));
function die(msg) {
  console.error(`signature check failed: ${msg}`);
  process.exit(1);
}

const pubLines = lines(b64text(readFileSync(pubFile, "utf8")));
const pubRaw = Buffer.from(pubLines[1] ?? "", "base64");
if (pubRaw.length !== 42 || pubRaw.subarray(0, 2).toString() !== "Ed") die("public key is not a minisign Ed25519 key");
const keyId = pubRaw.subarray(2, 10);
const key = createPublicKey({
  key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), pubRaw.subarray(10)]),
  format: "der",
  type: "spki",
});

const sigText = sigArg.startsWith("@") ? readFileSync(sigArg.slice(1), "utf8") : sigArg;
if (!sigText.trim()) die("signature is empty");
const sl = lines(b64text(sigText));
const sigRaw = Buffer.from(sl[1] ?? "", "base64");
const tcLine = sl[2] ?? "";
const globalSig = Buffer.from(sl[3] ?? "", "base64");
if (sigRaw.length !== 74) die(`signature blob has ${sigRaw.length} bytes, want 74`);
if (!tcLine.startsWith("trusted comment: ")) die("missing trusted comment");
const alg = sigRaw.subarray(0, 2).toString();
if (!sigRaw.subarray(2, 10).equals(keyId)) die("key id mismatch (signed by another key)");
const sig = sigRaw.subarray(10);

const data = readFileSync(assetFile);
const msg = alg === "ED" ? createHash("blake2b512").update(data).digest() : alg === "Ed" ? data : die(`unknown algorithm ${alg}`);
if (!verify(null, msg, key, sig)) die("file signature does not verify");
const tc = Buffer.from(tcLine.slice("trusted comment: ".length), "utf8");
if (!verify(null, Buffer.concat([sig, tc]), key, globalSig)) die("trusted comment signature does not verify");
console.log(`ok: ${assetFile} (${alg}, key ${Buffer.from(keyId).reverse().toString("hex").toUpperCase()})`);
