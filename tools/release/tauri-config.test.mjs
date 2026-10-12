// #852：tools/release/tauri-config.mjs 的契约测试（node --test tools/release/tauri-config.test.mjs）。
//
// 判据：test 版本 ⇒ 插件 endpoint 指向 test-channel 里本端的分端清单；正式版本 ⇒ 只有 version，
// 不覆盖 endpoint，且与 #852 之前两处内联写法（macOS 的 VERSION_CONFIG、Windows job 的 node -e）
// 逐字节相同——正式版零变化。
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tauriConfig } from "./tauri-config.mjs";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "tauri-config.mjs");
const CH = "https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel";

test("test 版本：macOS endpoint = test-channel/manifest-macos.json", () => {
  assert.equal(
    tauriConfig("macos", "0.9.12-test.12"),
    `{"version":"0.9.12-test.12","plugins":{"updater":{"endpoints":["${CH}/manifest-macos.json"]}}}`,
  );
});

test("test 版本：Windows endpoint = test-channel/manifest-windows.json", () => {
  assert.equal(
    tauriConfig("windows", "0.9.12-test.12"),
    `{"version":"0.9.12-test.12","plugins":{"updater":{"endpoints":["${CH}/manifest-windows.json"]}}}`,
  );
});

test("正式版本：只有 version，不覆盖 endpoint（与 #852 之前的内联写法逐字节相同）", () => {
  for (const p of ["macos", "windows"]) {
    const got = tauriConfig(p, "0.9.13");
    assert.equal(got, '{"version":"0.9.13"}');
    // macOS 旧写法：VERSION_CONFIG="{\"version\":\"$VERSION\"}"
    assert.equal(got, `{"version":"${"0.9.13"}"}`);
    // Windows 旧写法：JSON.stringify({ version })
    assert.equal(got, JSON.stringify({ version: "0.9.13" }));
  }
});

test("仓库名取调用方给的值（runner 的 GITHUB_REPOSITORY）", () => {
  const c = JSON.parse(tauriConfig("macos", "1.0.0-test.1", "someone/fork"));
  assert.deepEqual(c.plugins.updater.endpoints, [
    "https://github.com/someone/fork/releases/download/test-channel/manifest-macos.json",
  ]);
});

test("未知平台 / 空版本号：报错，不产出半份配置", () => {
  assert.throws(() => tauriConfig("linux", "1.0.0"), /未知平台/);
  assert.throws(() => tauriConfig("macos", ""), /版本号为空/);
});

test("CLI：打印一行 JSON；GITHUB_REPOSITORY 缺省时用 hawkeye-xb/P-Pass", () => {
  const env = { ...process.env };
  delete env.GITHUB_REPOSITORY;
  const out = execFileSync("node", [SCRIPT, "macos", "2.0.0-test.3"], { env, encoding: "utf8" });
  assert.equal(out, `{"version":"2.0.0-test.3","plugins":{"updater":{"endpoints":["${CH}/manifest-macos.json"]}}}\n`);
  const formal = execFileSync("node", [SCRIPT, "windows", "2.0.0"], { env, encoding: "utf8" });
  assert.equal(formal, '{"version":"2.0.0"}\n');
});

test("CLI：参数不对 ⇒ 非零退出", () => {
  assert.throws(() => execFileSync("node", [SCRIPT, "macos"], { stdio: "pipe" }));
});
