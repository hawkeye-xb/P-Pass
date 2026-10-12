#!/usr/bin/env node
// #852：桌面构建的 tauri `--config`（JSON merge patch）——macOS 与 Windows 共用这一份，两端不再分叉。
//
// 更新链路只有清单地址不同（test 通道镜像正式版）：
//   - version：本次构建的版本号（tools/release-version.sh desktop）。外壳的 package_info /
//     getVersion()、Info.plist、updater 的「当前版本」都取它（#809）。
//   - 版本号含 `-test.` ⇒ 把 updater 插件的 endpoints 换成 test-channel 里本端的分端清单
//     （同一套插件、同一把公钥、同一个清单结构）；正式版不覆盖 endpoints，用入库配置里的
//     R2 → GitHub 链（tauri.conf.json / tauri.windows.conf.json）。
//
// 用法：node tools/release/tauri-config.mjs <macos|windows> <version>
//   打印一行 JSON，供 `pnpm tauri build|bundle --config "<这一行>"`。
//   仓库取 GITHUB_REPOSITORY（runner 默认变量），本地构建没有它时用 hawkeye-xb/P-Pass。
import { pathToFileURL } from "node:url";

const MANIFEST = { macos: "manifest-macos.json", windows: "manifest-windows.json" };

export function tauriConfig(platform, version, repo = "hawkeye-xb/P-Pass") {
  const manifest = MANIFEST[platform];
  if (!manifest) throw new Error(`未知平台 ${JSON.stringify(platform)}（只认 macos / windows）`);
  if (!version) throw new Error("版本号为空");
  const c = { version };
  if (version.includes("-test.")) {
    c.plugins = {
      updater: { endpoints: [`https://github.com/${repo}/releases/download/test-channel/${manifest}`] },
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
