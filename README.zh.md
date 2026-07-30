# P-Pass

[English version / 英文版](README.md)

家庭照片的 P2P 备份：手机自动备份到自己家的电脑，全家跨设备浏览。
无云端存储、无账号、无月费——原始文件即真相，索引可随时重建。

**里程碑与状态看板：[docs/ROADMAP.md](docs/ROADMAP.md)**

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
