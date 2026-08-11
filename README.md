# P-Pass

[中文版 / Chinese version](README.zh.md)

Peer-to-peer photo backup for families: phones back up automatically to
a computer in your own home; everyone in the family browses across
devices. No cloud storage, no accounts, no subscription — original
files are the source of truth and the index can be rebuilt from them at
any time.

**Roadmap & status: [docs/ROADMAP.md](docs/ROADMAP.md)**

## Get started in 10 minutes (no technical knowledge needed)

> **Who this is for**: you are not a developer, you don't care about any of
> the engineering below — you just want your phone photos to back up to
> your home computer. Follow these steps in order and you're done.

> 写给谁：你不是开发者，下面的工程细节一概不用看——你只想让手机照片
> 自动备份到家里的电脑。按顺序照做即可。

### 1. Download & install on your computer / 电脑上装

1. Go to the latest [release page](https://github.com/hawkeye-xb/P-Pass/releases)
   and download **P-Pass-macos-arm64.dmg** (macOS). If a security popup
   blocks you, follow
   [Blocked by AV / SmartScreen](docs/troubleshooting/blocked-by-av.md) — it
   tells you exactly how to verify the file and let it run.
   打开最新 [Release 页面](https://github.com/hawkeye-xb/P-Pass/releases)，
   下载 **P-Pass-macos-arm64.dmg**（macOS）。如果安全弹窗拦截，按
   [被拦截了怎么办](docs/troubleshooting/blocked-by-av.md)处理——里面有
   验证和放行的具体步骤。
2. Open the downloaded file and drag **P-Pass** into your Applications
   folder.
   打开下载的文件，把 **P-Pass** 拖进「应用程序」文件夹。

   > **Windows?** The Windows desktop app is in development — current
   > Windows releases contain command-line tools only (daemon.exe /
   > testclient.exe), not a GUI installer, so there is nothing to install
   > yet. Please check back later.
   > **Windows 呢？** Windows 桌面版开发中——当前 Windows 发布只有命令行
   > 工具（daemon.exe / testclient.exe），没有图形安装包，暂时无可安装
   > 内容，请过段时间再来。

   > **Can't see any files on the release page?** We're in the testing
   > phase — releases may be marked as drafts (visible to maintainers
   > only). If the page shows no downloads, the stable release is not out
   > yet: check back later, or open an issue on GitHub.
   > **Release 页面看不到文件？** 目前是测试阶段——发布可能还是草稿（仅
   > 维护者可见）。如果页面没有可下载文件，说明正式版尚未发布：过段时间
   > 再来，或到 GitHub 提 issue。
3. Double-click **P-Pass** to open it. macOS first time: right-click the
   app → Open (one-time; see the AV guide above if Gatekeeper complains).
   双击 **P-Pass** 打开。macOS 首次：右键点 App → 打开（一次性；Gatekeeper
   拦截见上面的拦截指南）。

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

1. On the same [release page](https://github.com/hawkeye-xb/P-Pass/releases),
   download the phone app (**app-release.apk**, Android). Android may warn
   about installing from an unknown source — that's normal for a direct
   download; allow it. (iPhone version is coming later.)
   在同一个 [Release 页面](https://github.com/hawkeye-xb/P-Pass/releases)
   下载手机 App（**app-release.apk**，Android）。Android 会提示"未知来源
   安装"——直接下载的正常提示，允许即可。（iPhone 版后续推出。）
2. Open the P-Pass app on your phone and scan the QR code on your computer
   screen. Your computer will ask you to approve the pairing — tap
   **Allow**. / 打开手机上的 P-Pass，扫电脑屏幕上的二维码。电脑会弹出配对
   确认——点**允许**。
3. Done — your phone now backs up automatically (when charging and on
   Wi-Fi). Open the app any time to browse the family photo timeline.
   完成——手机从此自动备份（充电 + Wi-Fi 时）。随时打开 App 就能浏览全家
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
                  local IPC, telemetry
  diag/           Diagnostic state machine + msg_key dictionary + i18n
apps/         Per-platform applications (thin skins; logic lives in crates)
  desktop/        Tauri tray shell (talks to the daemon over local IPC only)
  android/        Android app (iroh-ffi + generated proto types)
infra/        Cloud & self-hosting (everything self-hostable)
  workers/        rendezvous / telemetry / update (Cloudflare Workers)
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
- **Binary distribution**: every push to main builds Linux binaries and
  force-pushes them to the `bin-linux-x64` orphan branch — deploy boxes
  run `git clone -b bin-linux-x64` instead of compiling.
- **Android** (future): Gradle incremental + build cache.
- **Frontend/Workers** (future): pnpm workspace; turborepo only if the JS
  task graph ever warrants it — not introduced today.
- Single task entry point: `just` (`just ci` = fmt + clippy + tests +
  architecture checks).

## Development

```bash
just ci                    # all gates (must be green before committing)
cargo nextest run          # full test suite
tools/dogfood-smoke.sh     # production-shape end-to-end smoke, agent-runnable
```

## Contribution rules

- **Bilingual docs**: user- and contributor-facing documents ship in
  English with a Chinese sibling (`*.zh.md`), or as clearly-sectioned
  bilingual files for short READMEs. Internal engineering logs may be
  Chinese-first; commit messages are English.
- **Agent-first interfaces**: every feature must be drivable and
  verifiable through the testclient CLI / daemon IPC without a human —
  GUIs are skins over those interfaces.
- **Architecture gates**: `iroh` imports only in `transport`; platform
  `#[cfg]` only in `platform`; enforced by `tools/arch-check.sh` in CI.

## License

P-Pass is licensed under the **GNU Affero General Public License v3**
(AGPL-3.0) — see [LICENSE](LICENSE) for the full text. All crates,
the Android app, the desktop shell and the website (`site/`) are covered.
Copyright (C) 2026 Hawkeye XB.
