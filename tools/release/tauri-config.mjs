#!/usr/bin/env node
// #852：桌面构建的 tauri `--config`（JSON merge patch）——macOS 与 Windows 共用这一份，两端不再分叉。
//
// 更新链路只有清单地址不同（test 通道镜像正式版）：
//   - version：本次构建的版本号（tools/release-version.sh desktop）。外壳的 package_info /
//     getVersion()、Info.plist、updater 的「当前版本」都取它（#809）。
//   - 版本号含 `-test.` ⇒ 把 updater 插件的 endpoints 换成 test-channel 里本端的分端清单
//     （同一套插件、同一个清单结构）；正式版不覆盖 endpoints，用入库配置里的
//     R2 → GitHub 链（tauri.conf.json / tauri.windows.conf.json）。
//   - #1121：test 版本同时把 updater 公钥换成 test 通道那一把（release/update-keys/test.pub）。
//     test 与正式各用一把密钥：test 包只认 test 签名，正式包只认正式签名。文件不在就报错，
//     不退回正式公钥。
//
// 用法：node tools/release/tauri-config.mjs <macos|windows> <version>
//   打印一行 JSON，供 `pnpm tauri build|bundle --config "<这一行>"`。
//   仓库取 GITHUB_REPOSITORY（runner 默认变量），本地构建没有它时用 hawkeye-xb/P-Pass。
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const MANIFEST = { macos: "manifest-macos.json", windows: "manifest-windows.json" };

const TEST_PUBKEY = join(dirname(fileURLToPath(import.meta.url)), "../../release/update-keys/test.pub");

/** #1121：test 通道公钥（tauri 格式，与 tauri.conf.json 的 pubkey 同形）。 */
export function readTestPubkey() {
  let text;
  try {
    text = readFileSync(TEST_PUBKEY, "utf8").trim();
  } catch {
    text = "";
  }
  if (!text) {
    throw new Error("test 通道公钥 release/update-keys/test.pub 不存在（见 docs/runbook/update-signing-keys.md）");
  }
  return text;
}

export function tauriConfig(platform, version, repo = "hawkeye-xb/P-Pass", readPubkey = readTestPubkey) {
  const manifest = MANIFEST[platform];
  if (!manifest) throw new Error(`未知平台 ${JSON.stringify(platform)}（只认 macos / windows）`);
  if (!version) throw new Error("版本号为空");
  const c = { version };
  if (version.includes("-test.")) {
    c.plugins = {
      updater: {
        endpoints: [`https://github.com/${repo}/releases/download/test-channel/${manifest}`],
        pubkey: readPubkey(),
      },
    };
  }
  return JSON.stringify(c);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const [platform, version] = process.argv.slice(2);
  try {
    console.log(tauriConfig(platform, version, process.env.GITHUB_REPOSITORY || undefined));
  } catch (e) {
    console.error(`tauri-config: ${e.message}\n用法：node tools/release/tauri-config.mjs <macos|windows> <version>`);
    process.exit(1);
  }
}
