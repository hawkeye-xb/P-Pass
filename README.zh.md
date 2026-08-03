# P-Pass

[English version / 英文版](README.md)

家庭照片的 P2P 备份：手机自动备份到自己家的电脑，全家跨设备浏览。
无云端存储、无账号、无月费——原始文件即真相，索引可随时重建。

**里程碑与状态看板：[docs/ROADMAP.md](docs/ROADMAP.md)**

## 10 分钟上手（不需要任何技术知识）

> **写给谁**：你不是开发者，下面的工程细节一概不用看——你只想让手机
> 照片自动备份到家里的电脑。按顺序照做即可。

> **Who this is for**: you are not a developer — you just want your phone
> photos to back up to your home computer. Follow these steps in order.

### 1. 电脑上装 / Install on your computer

1. 打开最新 [Release 页面](https://github.com/hawkeye-xb/P-Pass/releases)，
   下载对应你电脑的文件（macOS 选 `.dmg`，Windows 选 `.zip`）。如果安全
   弹窗拦截，按[被拦截了怎么办](docs/troubleshooting/blocked-by-av.md)
   处理——里面有验证和放行的具体步骤。
   Go to the latest [release page](https://github.com/hawkeye-xb/P-Pass/releases)
   and download the file for your computer (macOS: `.dmg`; Windows: `.zip`).
   Security popup? See
   [Blocked by AV / SmartScreen](docs/troubleshooting/blocked-by-av.md).
2. 打开下载的文件，把 **P-Pass** 拖进「应用程序」文件夹（macOS），或
   解压后运行安装程序（Windows）。
   Open the downloaded file, drag **P-Pass** into Applications (macOS), or
   unzip and run the installer (Windows).
3. 双击 **P-Pass** 打开。macOS 首次：右键点 App → 打开（一次性；Gatekeeper
   拦截见上面的拦截指南）。
   Double-click **P-Pass**. macOS first time: right-click → Open.

[截图: 应用打开后的主界面（含配对二维码）]

### 2. 三步向导 / Follow the 3-step wizard

跟着 App 提示点下去就行：

1. 选择照片要存放的文件夹 / Choose where photos will live
2. 启动后台服务（电脑会安静地保持 P-Pass 运行）/ Start the background service
3. 屏幕上出现配对二维码 / A QR code appears on screen

[截图: 向导三步的界面（选文件夹 → 启动服务 → 显示二维码）]

### 3. 手机装 App 并扫码 / Install on your phone and scan

1. 在同一个 [Release 页面](https://github.com/hawkeye-xb/P-Pass/releases)
   下载手机 App（Android 选 `.apk`）。Android 会提示"未知来源安装"——直接
   下载的正常提示，允许即可。（iPhone 版后续推出。）
   Download the phone app on the same release page (Android: `.apk`).
   Android's "unknown source" warning is normal for a direct download; allow
   it. (iPhone version later.)
2. 打开手机上的 P-Pass，扫电脑屏幕上的二维码。电脑会弹出配对确认——点
   **允许**。
   Open P-Pass on your phone, scan the QR on your computer screen, tap
   **Allow** on the pairing prompt.
3. 完成——手机从此自动备份（充电 + Wi-Fi 时）。随时打开 App 就能浏览全家
   照片时间线。
   Done — your phone backs up automatically (charging + Wi-Fi). Open the app
   any time to browse the family photo timeline.

[截图: 手机扫码配对成功的界面（时间线视图）]

> **遇到问题？** 多数是安全弹窗——见
> [被拦截了怎么办](docs/troubleshooting/blocked-by-av.md)。其他问题到
> GitHub 提 issue。
> **Trouble?** Most first-run issues are security popups — see
> [Blocked by AV / SmartScreen](docs/troubleshooting/blocked-by-av.md).

---

## Monorepo 布局（所有端在同一仓库）

```
crates/       Rust 核心（Cargo workspace，9 个 crate）
  proto/          线格式：消息类型 + JSON codec + golden 快照
  transport/      Transport trait + iroh 实现（唯一允许 import iroh 的 crate）
  storage/        SQLite 索引 + 迁移 + 仓储
  core-index/     入库/去重/时间线/重建（纯领域逻辑）
  core-media/     EXIF 元数据（纯解析）
  media-codec/    HEIC/JPEG 解码、缩略图、ffmpeg 抽帧
  platform/       平台适配 trait（唯一允许平台 #[cfg] 的 crate）
  daemon/         组装：authz 路由、配对、备份接收、查询、本地 IPC、遥测
  diag/           诊断状态机 + msg_key 字典 + i18n
apps/         各端应用（皮肤层，业务都在 crates）
  desktop/        Tauri 托盘壳（只经本地 IPC 调 daemon）
  android/        Android App（iroh-ffi + 生成的 proto 类型）
infra/        云端与自建（全部可自托管）
  workers/        rendezvous / telemetry / update（Cloudflare Workers）
  relay/          官方 relay 部署模板（只含占位符）
  selfhost/       自建者一键 compose
  website/        官网一页
tools/        testclient（agent 可驱动的接口剧本 CLI）、arch-check、
              gen-kotlin、dogfood-smoke.sh
tests/        跨模块故障剧本
docs/         工程文档：ROADMAP、PROGRESS（日志与决策）、网络矩阵、runbook
```

## 构建与缓存（各生态原生增量，无额外框架）

- **Rust**：Cargo workspace 天然增量构建 + 共享 `target/` 缓存；
  CI 以 `Cargo.lock` 为键缓存 registry 与构建产物。
- **产物分发**：push 到 main 自动构建 Linux 二进制并强推
  `bin-linux-x64` 孤儿分支——部署机 `git clone -b bin-linux-x64`
  秒级取货，不再编译。
- **Android**（未来）：Gradle 自带增量 + build cache。
- **前端/Workers**（未来）：pnpm workspace；JS 任务图规模需要时再评估
  turborepo——当前不引入。
- 顶层任务入口统一为 `just`：`just ci` = fmt + clippy + test + arch-check。

## 开发

```bash
just ci                    # 全部门禁（提交前必绿）
cargo nextest run          # 全部测试
tools/dogfood-smoke.sh     # 生产形态端到端冒烟（agent 可无人执行）
```

## 贡献规则

- **文档双语**：面向用户与贡献者的文档以英文为主、配中文姊妹篇
  （`*.zh.md`）；短 README 可单文件双语分节。内部工程记录可中文优先；
  提交信息用英文。
- **接口 agent 优先**：所有功能必须可经 testclient CLI / daemon IPC
  无人化驱动与验证——GUI 只是这些接口上的皮肤。
- **架构门禁**：`iroh` 只准出现在 `transport`；平台 `#[cfg]` 只准出现在
  `platform`；由 `tools/arch-check.sh` 在 CI 强制。
