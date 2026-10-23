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

const PUB = "dGVzdC1wdWJrZXk="; // 测试用假公钥：不依赖仓库里有没有 test.pub
const pub = () => PUB;

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "tauri-config.mjs");
const CH = "https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel";

test("test 版本：macOS endpoint = test-channel/manifest-macos.json", () => {
  assert.equal(
    tauriConfig("macos", "0.9.12-test.12", undefined, pub),
    `{"version":"0.9.12-test.12","plugins":{"updater":{"endpoints":["${CH}/manifest-macos.json"],"pubkey":"${PUB}"}}}`,
  );
});

test("test 版本：Windows endpoint = test-channel/manifest-windows.json", () => {
  assert.equal(
    tauriConfig("windows", "0.9.12-test.12", undefined, pub),
    `{"version":"0.9.12-test.12","plugins":{"updater":{"endpoints":["${CH}/manifest-windows.json"],"pubkey":"${PUB}"}}}`,
  );
});

test("正式版本：只有 version，不覆盖 endpoint 和公钥（与 #852 之前的内联写法逐字节相同）", () => {
  for (const p of ["macos", "windows"]) {
    const got = tauriConfig(p, "0.9.13", undefined, () => assert.fail("正式版不许读 test 公钥"));
    assert.equal(got, '{"version":"0.9.13"}');
    // macOS 旧写法：VERSION_CONFIG="{\"version\":\"$VERSION\"}"
    assert.equal(got, `{"version":"${"0.9.13"}"}`);
    // Windows 旧写法：JSON.stringify({ version })
    assert.equal(got, JSON.stringify({ version: "0.9.13" }));
  }
});

test("仓库名取调用方给的值（runner 的 GITHUB_REPOSITORY）", () => {
  const c = JSON.parse(tauriConfig("macos", "1.0.0-test.1", "someone/fork", pub));
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
  // test 版本的 CLI 输出依赖 release/update-keys/test.pub 是否入库，由下面两条单独覆盖。
  const formal = execFileSync("node", [SCRIPT, "windows", "2.0.0"], { env, encoding: "utf8" });
  assert.equal(formal, '{"version":"2.0.0"}\n');
});

test("CLI：参数不对 ⇒ 非零退出", () => {
  assert.throws(() => execFileSync("node", [SCRIPT, "macos"], { stdio: "pipe" }));
});

test("#1121：test 版本内置 test 公钥；读不到就报错，不退回正式公钥", () => {
  const c = JSON.parse(tauriConfig("macos", "1.0.0-test.1", undefined, pub));
  assert.equal(c.plugins.updater.pubkey, PUB);
  assert.throws(
    () => tauriConfig("windows", "1.0.0-test.1", undefined, () => {
      throw new Error("test 通道公钥 release/update-keys/test.pub 不存在");
    }),
    /test\.pub 不存在/,
  );
});
