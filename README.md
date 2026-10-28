# P-Pass

[中文版 / Chinese version](README.zh.md)

Photo backup for families: phones back up automatically to a computer
in your own home; everyone in the family browses across devices. No
cloud storage, no accounts. Original files are the source of truth and
the index can be rebuilt from them at any time.

**Roadmap & status: [docs/ROADMAP.md](docs/ROADMAP.md)**

Follow the project: [Bluesky](https://bsky.app/profile/p-pass.hawkeye-xb.com) · [YouTube](https://www.youtube.com/@p-pass-photos)

## Get started in 10 minutes (no technical knowledge needed)

> **Who this is for**: you are not a developer, you don't care about any of
> the engineering below — you just want your phone photos to back up to
> your home computer. Follow these steps in order and you're done.

> 写给谁：你不是开发者，下面的工程细节一概不用看——你只想让手机照片
> 自动备份到家里的电脑。按顺序照做即可。

### 1. Download & install on your computer / 电脑上装

1. Go to the latest [release page](https://github.com/hawkeye-xb/P-Pass/releases)
   and download **P-Pass_<版本>_macos-arm64.dmg** (macOS) or
   **P-Pass_<版本>_x64-setup.exe** (64-bit Windows). If a security popup
   blocks you, follow
   [Blocked by AV / SmartScreen](docs/troubleshooting/blocked-by-av.md) — it
   tells you exactly how to verify the file and let it run.
   打开最新 [Release 页面](https://github.com/hawkeye-xb/P-Pass/releases)，
   下载 **P-Pass_<版本>_macos-arm64.dmg**（macOS）或
   **P-Pass_<版本>_x64-setup.exe**（64 位 Windows）。如果安全弹窗拦截，按
   [被拦截了怎么办](docs/troubleshooting/blocked-by-av.md)处理——里面有
   验证和放行的具体步骤。
2. macOS: open the downloaded file and drag **P-Pass** into your
   Applications folder.
   macOS：打开下载的文件，把 **P-Pass** 拖进「应用程序」文件夹。

   Windows: run the downloaded `.exe` and follow the installer. The installer
   is not code-signed, so SmartScreen shows "Windows protected your PC";
   choose **More info → Run anyway**.
   Windows：运行下载的 `.exe`，按安装向导完成安装。安装包未做代码签名，
   SmartScreen 会提示「Windows 已保护你的电脑」，点**更多信息 → 仍要运行**。

   > **Which file should I download?** The releases page also lists two
   > rolling test channels (`dogfood`, `test-channel`); those are for
   > development, not for everyday use. For normal use, download
   > **P-Pass_<版本>_macos-arm64.dmg** or **P-Pass_<版本>_x64-setup.exe** (computer)
   > and **P-Pass_<版本>_android.apk** (phone) from the newest versioned release.
   > **该下哪个文件？** Release 页面上还会列出 `dogfood`、`test-channel`
   > 两个滚动测试通道——那是开发用的，日常使用请从最新正式版本里下
   > **P-Pass_<版本>_macos-arm64.dmg** 或 **P-Pass_<版本>_x64-setup.exe**（电脑）和
   > **P-Pass_<版本>_android.apk**（手机）。
3. Open **P-Pass**. macOS first time: right-click the app → Open (one-time;
   see the AV guide above if Gatekeeper complains). Windows: open it from the
   Start menu.
   打开 **P-Pass**。macOS 首次：右键点 App → 打开（一次性；Gatekeeper
   拦截见上面的拦截指南）。Windows：从开始菜单打开。

[截图: 应用打开后的主界面（含配对二维码）]

### 2. Follow the 3-step wizard / 三步向导

The app walks you through it — just click through:

1. Choose where your photos will live on this computer (the folder P-Pass
   will keep them in). / 选择照片要存放的文件夹
2. It starts the background service (your computer will keep P-Pass
   running quietly). / 启动后台服务
3. A QR code appears on screen. / 屏幕上出现配对二维码

[截图: 向导三步的界面（选文件夹 → 启动服务 → 显示二维码）]

### 3. Install the app on your phone and scan / 手机装 App 并扫码

1. **Android 8.0+**: on the same [release page](https://github.com/hawkeye-xb/P-Pass/releases),
   download **P-Pass_<版本>_android.apk**. Android may warn about installing
   from an unknown source — that's normal for a direct download; allow it.
   (iPhone version is coming later; iOS limits background backup, so its
   experience will differ — we'll spell that out when it ships.)
   **Android 8.0 以上**：在同一个 [Release 页面](https://github.com/hawkeye-xb/P-Pass/releases)
   下载 **P-Pass_<版本>_android.apk**。Android 会提示"未知来源安装"——直接下载
   的正常提示，允许即可。（iPhone 版后续推出。）
2. Open the P-Pass app on your phone and scan the QR code on your computer
   screen. The phone shows a 6-digit code; enter it on the computer and click
   **Allow**. / 打开手机上的 P-Pass，扫电脑屏幕上的二维码。手机会显示 6 位
   验证码，在电脑上输入后点**允许加入**。
3. Done — your phone now backs up automatically (on Wi-Fi when the
   battery isn't low). Open the app any time to browse the family photo timeline.
   完成——手机从此自动备份（连接 Wi-Fi 且电量不低时）。随时打开 App 就能浏览全家
   照片时间线。

[截图: 手机扫码配对成功的界面（时间线视图）]

> **Trouble?** Most first-run issues are the security popups — see
> [Blocked by AV / SmartScreen](docs/troubleshooting/blocked-by-av.md).
> Everything else: open an issue on GitHub.
> 遇到问题？多数是安全弹窗——见[被拦截了怎么办](docs/troubleshooting/blocked-by-av.md)。
> 其他问题到 GitHub 提 issue。

---

## Monorepo layout (every client lives in this one repo)

```
crates/       Rust core (Cargo workspace, 9 crates)
  proto/          Wire format: message types + JSON codec + golden snapshots
  transport/      Transport trait + iroh impl (the ONLY crate importing iroh)
  storage/        SQLite index + migrations + repositories
  core-index/     Ingest / dedup / timeline / rebuild (pure domain logic)
  core-media/     EXIF metadata (pure parsing)
  media-codec/    HEIC/JPEG decode, thumbnails, ffmpeg frame extraction
  platform/       Platform adapter trait (the ONLY crate with platform #[cfg])
  daemon/         Assembly: authz router, pairing, backup intake, queries,
                  local IPC, local stats logging
  diag/           Diagnostic state machine + msg_key dictionary + i18n
apps/         Per-platform applications (thin skins; logic lives in crates)
  desktop/        Tauri tray shell (talks to the daemon over local IPC only)
  android/        Android app (shared Rust transport core via uniffi + generated proto types)
infra/        Cloud & self-hosting (everything self-hostable)
  workers/        rendezvous / update (Cloudflare Workers)
  relay/          Official relay deployment templates (placeholders only)
  selfhost/       One-command compose for self-hosters
  website/        One-page site
tools/        testclient (agent-drivable scenario CLI), arch-check,
              gen-kotlin, dogfood-smoke.sh
tests/        Cross-module failure scenarios
docs/         Engineering docs: ROADMAP, PROGRESS (log & decisions),
              network matrix, runbooks
```

## Build & caching (native incremental per toolchain, no extra framework)

- **Rust**: Cargo workspace gives incremental builds + a shared `target/`
  cache; CI caches the registry and build artifacts keyed on `Cargo.lock`.
- **Binary distribution**: every push to main builds Linux/macOS
  binaries and uploads them to the fixed `dogfood` release (prerelease,
  tag created once, assets clobbered) — deploy boxes run
  `gh release download dogfood` instead of compiling.
- **Android** (future): Gradle incremental + build cache.
- **Frontend/Workers** (future): pnpm workspace; turborepo only if the JS
  task graph ever warrants it — not introduced today.
- Single task entry point: `just` (`just ci` = fmt + clippy + tests +
  architecture checks).

## Development

The JDK for local Android tooling is pinned once in `.java-version` at the
repo root (CI reads the same file). Install it locally with:
`brew install openjdk@$(cat .java-version)`.

```bash
just ci                    # all gates (must be green before committing)
cargo nextest run          # full test suite
tools/dogfood-smoke.sh     # production-shape end-to-end smoke, agent-runnable
```

**On Windows**: the `just` recipes are POSIX shell, so `bash` must be on
`PATH`. Git for Windows ships it but only puts its `cmd` directory on `PATH`,
so a plain PowerShell session fails on the first recipe with
`could not find the shell bash`. Either run `just` from Git Bash, or add Git's
`bin` directory to `PATH`:

```powershell
$env:PATH = "C:\Program Files\Git\bin;$env:PATH"   # this session only
```

`powershell -NoProfile -ExecutionPolicy Bypass -File tools\windows\env-check.ps1`
reports whether this machine is set up (look for the `just.shell` line).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution rules,
including the DCO sign-off every commit needs. Report security
vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

P-Pass is licensed under the **GNU Affero General Public License v3**
(AGPL-3.0) — see [LICENSE](LICENSE) for the full text. All crates,
the Android app, the desktop shell and the website (`site/`) are covered.
Copyright (C) 2026 Hawkeye XB.

Distribution through app stores such as Apple's App Store is covered by
an additional statement from the copyright holders: see
[APP_STORE_EXCEPTION.md](APP_STORE_EXCEPTION.md).
