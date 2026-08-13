## 卡号 DAE-03  daemon CLI 纪律 + 人话报错  级别 L2

**目标**：堵住 2026-08-06「daemon --help 误接管事故」逼出的三个缺口：
①daemon 支持 --help/--version 参数解析（在一切 daemon 机制之前短路退出）；
②纯新启动（Proceed）绝不装 autostart（只有升级接管 TookOver 才装）；
③异身份实例固定端口冲突报错人话化（用户看得懂 + 给修复指引）。

**范围**：`crates/daemon/src/main.rs`、`crates/daemon/src/lib.rs`、
`crates/daemon/src/cli.rs`（新建，纯函数 + 单测）、
`crates/daemon/tests/cli_flow.rs`（新建，二进制级冒烟）。

**不准动**：transport 绑定逻辑本身（iroh_impl.rs 只读）、claim 裁决逻辑
（ipc.rs 只读）、平台 autostart 实现（platform/ 只读——路径守卫已有，
本卡只做「何时该装」的决策）。

**可执行验收**：
  - 单测：`cargo test -p daemon cli::` 全绿——
    - parse_cli：无参=Run{ephemeral:false}；--ephemeral=Run{true}；
      --help/-h、--version/-V 短路返回；未知参数返回 Err（绝不静默忽略）
    - autostart_install_required：Proceed=false / StandDown=false /
      TookOver=true
    - humanize_bind_error：含 "already in use"/"only one usage of each
      socket" → 人话文案（含端口 + config.toml bind_addr 指引 + 异身份
      提示）；其它错误原样透传
  - 冒烟（真实二进制）：`cargo test -p daemon --test cli_flow` 全绿——
    - `daemon --help` → exit 0，stdout 含「用法」，**不含** IPC:/已启动/
      身份密钥已铸造（证明没走到 claim/bind）
    - `daemon --version` → exit 0，stdout 含 CARGO_PKG_VERSION
    - `daemon --bogus` → exit 2，stderr 含「未知参数」+ 用法
  - 反证：把 parse_cli 的未知参数分支改成静默忽略 → 冒烟③必红；
    autostart_install_required 改成恒 true → 单测必红；
    humanize 的 in_use 匹配改成宽松子串 "use" → 反证单测（合法错误含
    "use" 不误伤）必红
  - 全量：workspace 测试全绿 + `cargo fmt --check` 干净 + clippy 零警告

**证据要求**：报绿附命令 + 输出摘要（单测/冒烟各贴关键断言输出）。

**收尾**：just 全绿 + PROGRESS.md 一行 + ROADMAP.md DAE 行更新 +
NEXT.md 队列状态 + 本卡移 done/ 附验收记录。

---

## 执行记录（Salamira，2026-08-13）

（见卡尾验收记录）

---

## 验收记录（2026-08-13，Salamira 实施）

**实现**：crates/daemon/src/cli.rs（新，纯函数 + 8 单测）；main.rs 最顶接
parse_cli（--help/--version 短路 exit 0、未知参数 exit 2）、TookOver 分支走
autostart_install_required、bind Err 走 humanize_bind_error 后 exit 1；
tests/cli_flow.rs（新，二进制冒烟 3 测试）；lib.rs +pub mod cli。

**可执行验收逐条**：
- `cargo test -p daemon --lib cli` → 8 passed; 0 failed
  （parse_cli 短路/未知拒绝 + autostart 决策 + 占用识别/透传）
- `cargo test -p daemon --test cli_flow` → 3 passed; 0 failed
  （--help exit 0 且 stdout 无 IPC:/身份铸造/已启动；--version 含
  CARGO_PKG_VERSION；--bogus exit 2 + stderr 未知参数 + 用法）
- 反证①：parse_cli 未知分支改静默忽略 → `--bogus` 真把 daemon 拉起常驻
  （复现 8/6 事故：IPC 行 + 「P-Pass daemon 已启动」，测试 spawn 挂死）
- 反证②：autostart_install_required 恒 true → fresh_start_never 红
  （`assertion failed: !autostart_install_required(&Claim::Proceed)`）
- 反证③：in_use 放宽 "use" 子串 → non_in_use_errors_pass_through 红
  （含 "use" 的合法错误被误伤）
- 全量：`cargo test --workspace` → 286 passed; 0 failed（含 daemon 137）
  + `./tools/arch-check.sh` 全绿 + `cargo clippy -p daemon --all-targets`
  零警告 + `cargo fmt --check` 干净
- 偶发观察：subscribe_flow revoke 计时断言在 daemon 全量并发跑时偶发红
  一次，隔离复跑 3/3 ×2 绿——REV-01 既有测试的并发偶发（CI 未复现），
  非本卡引入

**收尾**：PROGRESS.md 新增 2026-08-13 段 + ROADMAP.md DAE-03 行 + NEXT.md
顶部状态。卡移 done/。
