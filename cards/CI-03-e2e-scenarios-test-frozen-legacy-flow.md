# CI-03 `e2e.yml` 的 e2e/scenarios 两个 job 在验证已冻结的 legacy 备份路径　级别 L2

> 🆕 状态：待接 · 发现记录：2026-09-15 用户与 agent 联合排查会话
> （对话记录见本卡"排查过程"节，非真机，纯代码+文档核实）
> 级别：L2 · 阻塞：无，可直接接 · 协同分支：待接单人开

## 问题

`.github/workflows/e2e.yml` 里 `e2e` 和 `scenarios` 两个 job，加起来**没有
一行在验证当前生产核心（Flow / REBUILD-00~04）**。它们跑的是已经被本仓
自己的边界文档正式宣判"冻结、不再作为门禁"的旧协议：

- **`e2e` job**（`tools/android-hello.sh` / `android-pair.sh` /
  `android-backup.sh` → `DaemonBackupTest`）：走 `manifest→push→commit`
  批次协议（T-054，2026-07-31）。`docs/design/2026-08-29-arch01-backup-core/
  05-legacy-flow-boundary.zh-CN.md` 的"Legacy 机制：冻结，不再作为新 Flow
  门禁"表格里，`DaemonBackupTest` 被明确列在其中。
- **`scenarios` job**（`tools/scenarios/huge_file.sh` /
  `crash_recovery.sh` / `disk_full.sh` → `testclient backup`）：走的协议更
  旧——T-032（2026-07-30）的"daemon 反向 pull"语义，`testclient` 的
  `backup` 子命令自己开 `Blobs::serve()` 假扮一个"能被反向拉取"的手机，
  而真实 Android 客户端从 T-054 那天起就只会发 `provider = null`（推送
  型会话，见 `crates/daemon/src/backup.rs` 里 MOB-32 那段注释）。这条路径
  对真实设备**从未可达**，现在更是彻底的双重过时。

**当前生产核心是什么**（REBUILD-00~04，2026-09-01/02 已合入、REBUILD-04
三星真机通过）：手机侧原生 iroh-blobs provider bridge（REBUILD-01，
`libtransport.so`+`libiroh_ffi.so`）+ 桌面侧原生 fetch/resume
（REBUILD-02，`crates/daemon/src/flow_delivery.rs` 的
`fetch_from_observing_path`）+ `FlowRunner` 触发/严格队头/完成凭据
（REBUILD-03/04）。旧 `backup/`（legacy）目录明确标记"仅维持可编译，
不得新增功能、不得成为新 Flow 依赖"。

**核实到的关键缺口**：翻遍 `tools/` 和 `.github/workflows/`，**没有任何
一条 CI 脚本用真实 daemon + 真实 Android native provider bridge，端到端
跑过新 Flow 的 offer/fetch/cancel/suspend**。新架构目前只有两类覆盖：
① `crates/daemon` 内的单测/集成测试（`flow_delivery.rs` 里的
`blobs_resume`、24MB kill-race 等，真实 iroh-blobs 但同进程模拟两端）；
② Android JVM 测试（`REBUILD03FlowRunnerTest`、`FlowBoundaryTest`），用
`RecordingDiscovery`/fake transport 纯内存模拟，不连真 daemon、不过真实
网络。**没有黑盒剧本级（多文件、磁盘满、进程崩溃、断网重连）验证覆盖新
核心**，而这恰恰是 `huge_file.sh`/`crash_recovery.sh`/`disk_full.sh`
当初想做但现在做错了对象的事。

## 影响

- CI 全绿给出"备份链路很健壮"的假信号：真正会被用户遇到的故障模式
  （Flow fetch 断线重传是否真走 iroh-blobs 断点续传、崩溃后 pending
  Flow 是否正确恢复、磁盘满时 Flow 状态机是否损坏）完全没有剧本级验证。
- `nightly` + 每个 release tag 都在烧 CI 分钟数运行两个不代表任何当前
  事实的 job。
- 后续维护者可能误读："scenarios job 绿 = 大文件/崩溃恢复已验证"，
  与 CLAUDE.md「设计纪律：禁止最小能跑通」第 1 条"止血必须同时开根治卡"
  的精神相悖——现状是止血都没有，直接是验证对象错位。

## 期望行为（三选一，需先拍板，不是本卡默认动工）

标注/砍/换三个选项都合法，取决于"要不要现在就投入新 Flow 的黑盒剧本级
验证"这一个更高层的产品决策（用户已表态：暂不做自动化 CI 校验、成本高、
还没稳定——本卡不擅自决定要不要建新剧本，只处理"两个已失去意义的 job
该怎么办"）：

1. **最小止血：标注 + 移出常规判读**——job 名和 workflow 注释里明确写
   "验证 legacy 路径，非当前生产核心的信号"，不改变触发频率，只消除
   "CI 绿=新核心健壮"的误读风险。零工程成本，但不解决 CI 分钟数浪费。
2. **砍掉**——直接删 `e2e`/`scenarios` 两个 job（含 `tools/android-hello.sh`
   `android-pair.sh` `android-backup.sh` `tools/scenarios/*.sh`
   `tools/dogfood-smoke.sh` 引用链），因为它们不再验证任何当前会被使用
   的代码路径。省 CI 时间，但如果 legacy `backup/` 目录仍需保持可编译
   （它目前确实还在仓库里），这些脚本可能是唯一验证它没在编译期腐化的
   手段——需先确认 legacy 目录的退场计划（是否有 REBUILD-05+ 打算彻底
   删除 `backup/`）。
3. **换成新 Flow 的黑盒剧本**——把三个故障剧本改造成走
   `flow.offer/fetch/status/suspend/cancel`（真实 daemon + 真实 Android
   native provider bridge，而不是 fake transport），让"验证故障恢复"
   这件事名副其实。这是唯一真正补上黑盒覆盖缺口的选项，但工程量最大，
   且与用户"暂不做自动化 CI 校验"的当前立场冲突——除非用户单独拍板
   这块例外投入。

## 排查过程摘要（供接手人快速复核，非重新排查依据）

1. 确认生产方向：`crates/daemon/src/backup.rs` MOB-32 注释"手机永远发
   provider=null（推送型会话，手机不提供拉取）"——旧 T-032 pull 分支对
   真实设备不可达。
2. 确认核心已换代：`docs/design/2026-08-29-arch01-backup-core/
   05-legacy-flow-boundary.zh-CN.md` 明文冻结 `DaemonBackupTest` 等；
   `docs/PROGRESS.md` REBUILD-00~04 记录 2026-09-01/02 生产纵切完成，
   REBUILD-04 三星真机通过。
3. 确认 CI 现状：`.github/workflows/e2e.yml` 的 `e2e`/`scenarios` job
   调用链（`tools/android-*.sh` → `testDebugUnitTest --tests
   '*Daemon{Hello,Pair,Backup}Test'`；`tools/scenarios/*.sh` →
   `testclient backup`）未变，仍指向 legacy 路径；未找到任何脚本调用
   `flow.offer`/`flow.fetch` 等新 RPC 走真实网络。
4. 确认新核心测试覆盖边界：`crates/daemon/tests/flow_delivery.rs`
   （真实 iroh-blobs，同进程）+ `apps/android/.../backup/flow/
   REBUILD03FlowRunnerTest.kt`（`RecordingDiscovery` fake，非真实网络）
   ——两者都不是黑盒剧本级。

## 阻塞与依赖

无编码阻塞；需要人类先在选项 1/2/3 之间拍板（尤其选项 2 需要先确认
legacy `backup/` 目录的退场时间表，选项 3 需要用户额外批准投入，与当前
"暂不做自动化 CI 校验"立场核对）。
