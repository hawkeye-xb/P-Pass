# P-Pass

家庭照片的 P2P 备份：手机自动备份到自己家的电脑，全家跨设备浏览。
无云端存储、无账号、无月费——原始文件即真相，索引可随时重建。

## Monorepo 布局（单仓库管理所有端）

```
crates/       Rust 核心（Cargo workspace，9 个 crate）
  proto/          线格式：消息类型 + JSON codec + golden 快照
  transport/      Transport trait + iroh 实现（唯一允许 import iroh 的 crate）
  storage/        SQLite 索引 + 迁移 + 仓储
  core-index/     入库/去重/时间线/重建（纯领域逻辑）
  core-media/     EXIF 元数据（纯解析）
  media-codec/    HEIC/JPEG 解码、缩略图、ffmpeg 抽帧
  platform/       平台适配 trait（唯一允许平台 #[cfg] 的 crate）
  daemon/         组装：authz 路由、配对、备份接收、查询、IPC、遥测
  diag/           诊断状态机 + msg_key 字典 + i18n
apps/         各端应用（皮肤层，业务都在 crates）
  desktop/        Tauri 托盘壳（只调 daemon IPC）
  android/        Android App（iroh-ffi + 生成的 proto 类型）
infra/        云端与自建（全部可自托管）
  workers/        rendezvous / telemetry / update（Cloudflare Workers）
  relay/          官方 relay 部署模板（占位符，无真实端点）
  selfhost/       自建者一键 compose
  website/        官网一页
tools/        testclient（agent 可驱动的接口剧本）、arch-check、
              gen-kotlin、dogfood-smoke.sh
tests/        跨模块故障剧本
docs/         工程文档：PROGRESS（进度与决策）、网络矩阵、runbook
```

## 构建与缓存（各生态用原生增量，无额外框架）

- **Rust**：Cargo workspace 天然增量构建 + 共享 `target/` 缓存；
  CI 以 `Cargo.lock` 为键缓存 registry 与构建产物。
- **产物分发**：push 到 main 自动构建 Linux 二进制并推送
  `bin-linux-x64` 孤儿分支——部署机 `git clone -b bin-linux-x64`
  秒级取货，不在小机器上编译。
- **Android**（未来）：Gradle 自带增量 + build cache。
- **前端/Workers**（未来）：pnpm workspace；任务规模需要时再评估
  turborepo——当前不引入。
- 顶层任务入口统一为 `just`：`just ci` = fmt + clippy + test + arch-check。

## 开发

```bash
just ci                    # 全部门禁（提交前必绿）
cargo nextest run          # 全部测试
tools/dogfood-smoke.sh     # 生产形态全接口冒烟（agent 可无人执行）
```

接口契约：所有功能必须可经 testclient CLI / daemon IPC 无人化驱动与
验证（agent-first，2026-07-30 裁决）；GUI 只是这些接口上的人类皮肤。
