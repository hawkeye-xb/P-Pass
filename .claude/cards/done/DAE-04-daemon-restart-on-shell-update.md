# DAE-04 手动按钮：桌面壳更新后杀旧 daemon，靠 launchd 拉起新版本　级别 L1【发现于 2026-08-13 用户提问，无依赖，可随时做】

背景：2026-08-13 用户问"desktop/mobile 自动更新时，能不能自动更新这个
常驻后台服务？"——查代码发现真实缺口：`tauri-plugin-updater` 的
`downloadAndInstall()` 只替换 `.app` 包内容（daemon 的 sidecar 二进制
也在包里，**路径不变、内容被换掉**），装完只提示"请重启应用生效"，
**不会自动 `relaunch()`**；即使用户重启了桌面壳，`App.svelte` 的
`onMount` 里也没有任何代码会重新拉起 daemon——已经在跑的旧版 daemon
进程（launchd 常驻，`RunAtLoad`+`KeepAlive` 复活）会带着旧代码一直跑
下去，直到电脑重启，或用户手动点一个平时根本不会出现的"启动服务"
按钮（这个按钮只在检测到服务离线时才显示，而旧 daemon 这时是"在线"
的）。

行业调研（2026-08-13，详见对话记录，不复述）：Docker Desktop 的
`vmnetd` helper、Tailscale 的 `tailscaled`、Clash Verge Rev 的 core
都踩过"GUI 更新了、常驻服务没跟上"这同一类坑，没有更巧的行业标准
解法——唯一靠谱的办法就是让运行中的旧进程被换成新进程。

**本卡范围经过讨论收窄为纯手动、最简方案**（自动定时检测/空闲窗口
检测放到后续卡，不在本卡范围）：

## 目标

桌面壳提供一个手动按钮。点击后完成：杀掉当前运行的旧 daemon 进程 →
（不碰任何 launchd 注册，注册从头到尾没被动过）→ launchd 的
`KeepAlive` 发现这个任务"非正常退出"，按现有规则自动把它重新拉起来 →
这次拉起来执行的是磁盘上已经是新版本的那个文件 → 轮询回读一次
`status`，确认版本号真的变了，成功/失败都要明确告诉用户。

**关键设计澄清（避免实施时踩坑）**：这次**不需要、也不能用**
`crates/daemon/src/ipc.rs` 里的 `daemon.step_down`/`claim_single_instance`
那套版本协商机制——那套是让旧进程"体面 `exit(0)`"，而 `KeepAlive.
SuccessfulExit=false`（`crates/platform/src/macos.rs` 第 36~37 行注释：
"崩溃/被杀（非零退出或信号）照样复活"）的语义决定了**体面退出反而
不会被自动复活**。本卡刚好要反过来的效果——杀掉它、指望它被复活——
所以必须是真的"杀"（信号终止），不能走 step_down 那条体面退出的路径。
`claim_single_instance` 那套机制解决的是另一个问题（防止不同路径/版本
的两个实例打架），跟"同路径原地换内容、靠 KeepAlive 复活"完全是两回事，
不要混在一起实施。

## 范围

只准动：
- `apps/desktop/src-tauri/src/lib.rs`：新增一个 Tauri 命令（如
  `restart_daemon_process`）——**只做"杀掉当前运行的 daemon 进程"这
  一件事**，杀法照抄 `stop_daemon`（第 184~204 行）里已经在用的同款
  `pkill -f ppf-daemon`（Windows 对应 `taskkill /F /IM ppf-daemon.exe`）。
  **不调用 `install_autostart`/`uninstall_autostart`，不碰 launchd
  注册**——这是本卡设计的关键，注册全程不动。杀掉之后轮询
  `daemon_online()`/`status`（合理超时，比如 10~15 秒，超时则报错，
  不能无限等），确认进程复活且版本号确实变了才算成功。
- `apps/desktop/src/App.svelte`：新增按钮（放哪里、叫什么名字由实施
  时定，功能等价即可——比如"更新后台服务"/复用"更新已安装"提示旁挂
  一个动作）；按钮的显示/高亮时机：桌面壳自己编译时已知的版本号，跟
  当前 `status` 返回的 daemon 版本号**不一致**时才出现，一致时不显示
  （避免用户瞎点误杀正常运行的进程）。
- i18n（如涉及新增文案）：`assets/i18n/zh.json`/`en.json` 对称。

## 不准动

- `crates/daemon/src/ipc.rs` 的 `claim_single_instance`/`step_down`/
  `Claim` 枚举——本卡不使用、不修改这套机制（上面"设计澄清"已经说明
  为什么不能用）。
- `crates/platform/src/macos.rs`/`windows.rs` 的 `install_autostart`/
  `agent_plist`/`KeepAlive` 语义——本卡完全不碰 launchd/服务注册，这
  正是设计要点，不是遗漏。
- `start_daemon`/`stop_daemon` 两个既有命令的行为（向导流程、"停止
  后台服务"按钮逻辑不变，本卡是第三个独立命令，不复用/魔改这两个——
  `stop_daemon` 会 `uninstall_autostart`，那是真正想关掉服务时用的，
  跟本卡"杀了指望它自己复活"的意图相反）。

## 设计要点

- 新命令**只杀进程，不做任何注册相关操作**——依赖 launchd 已经在跑、
  从未被改过的 `KeepAlive` 规则自动复活。这条"非正常退出会复活"的
  行为不是新引入的，历史上已经实测过（signal 杀 → 数秒内复活）。
- 杀了之后必须**验证**，不能假设成功：轮询 `status`，读 `version`
  字段，确认变成了预期的新版本号。验证失败要给用户明确的错误提示
  （比如"服务没能正常重启，请重启电脑"），不能沉默假装成功——这是
  Clash Verge Rev #5451（"报告升级成功但实际没换好"）的教训，具体
  讨论见本次对话记录，不复述。
- 按钮显示时机只需要比较"桌面壳自己的版本号"和"当前 `status` 报的
  daemon 版本号"——两者本来就是同一次发布出的（版本号历来是双端一起
  bump，参见既有出包流程），不需要额外去探测磁盘上 sidecar 文件的
  版本。
- Windows 侧：`stop_daemon` 里已经区分好平台的 kill 逻辑（`taskkill`）
  直接复用，不需要额外 `#[cfg]` 分叉。Windows 的 autostart 是普通
  `Run` key（`crates/platform/src/windows.rs`），没有 launchd 那种
  `KeepAlive` 崩溃复活语义——**这意味着本卡这套"杀了指望复活"的机制
  在 Windows 上可能不成立**（杀掉之后没人会自动重新拉起）。实施时需要
  先确认 Windows 下杀掉进程后是否真的会被复活；如果不会，Windows 侧
  需要在杀进程之后**显式重新拉起一次**（沿用 `start_daemon` 里已有的
  一次性 spawn fallback 分支），不能假设两个平台行为一致。

## 可执行验收

- 单测：新命令在找不到匹配进程时不 panic，返回明确、可读的结果（照抄
  `start_daemon` 已有的错误处理风格）。
- 手动验收（挂用户，agent 无法自测跨版本升级场景）：
  1. 本机手工造一个"版本不一致"的场景（比如临时改一份 daemon 的版本
     常量编译安装）→ 桌面壳显示/高亮更新按钮 → 点击 → 观察旧进程被杀
     （`ps` 前后对照）→ 数秒内 launchd 自动拉起 → 桌面壳验证步骤读回
     新版本号确认成功。
  2. 反证：临时让"验证"步骤形同虚设（比如故意破坏 sidecar 路径让复活
     失败）→ 确认按钮流程能捕获这个失败并明确提示用户，不是无论如何
     都显示"成功"。
  3. 正常场景点这个按钮（daemon 版本已是最新，按钮本不该出现，强制
     调用命令验证也不出问题）→ 确认不产生数据损坏，且不会误伤正在
     进行的手机连接/传输之外的场景（本卡不要求处理"传输中点击"这个
     边界——按钮本身杀进程就是会打断进行中的传输，这是已知代价，
     用户主动点击即视为接受这个代价，不需要额外拦截逻辑）。

## 证据要求

新命令单测输出 + 上述三条手动验收的实际操作记录（进程 PID 前后对照、
`status` 版本号读数、`ps`/`launchctl`/Windows 对应工具输出）。

## 跨卡声明禁令

不许写"daemon 更新按钮已验证有效"，除非三条手动验收都有用户确认的
实际操作记录——单测绿只覆盖"找不到进程时不崩"这一角，不能代表整套
杀进程→复活→验证的链路真的走得通。

## 收尾

桌面壳全量测试绿（如涉及 Rust 测试）+ PROGRESS.md 一行 + ROADMAP.md
状态行 + 三条手动验收挂用户确认。

---

## 验收记录（2026-08-13）

**实施**：@salamira（Hermes）。单测 4 项新增（`restart_outcome` 纯函数：
版本变化=真成功 / 同版本=未变更 / 杀前离线杀后起来=有进展 / 无新版本=未验证兜底）
+ 桌面 lib 6/6 绿 + diag i18n 对称 8/8（10 个 `ui.restart_service_*` 键注册，
ALL 79→89）+ vite build 绿 176 modules + 桌面 clippy 零警告 + 主仓 fmt 干净。

**三条手动验收挂用户（xixi）确认**：
1. 版本不一致场景：临时改 daemon 版本常量编译安装 → 设置页「软件更新」卡出现
   「重启后台服务」按钮 → 点击 → ps 前后 PID 对照（旧进程消失）→ launchd 数秒
   拉起新进程 → 壳读回 status.version 为新版本号 → 按钮消失。
2. 反证：破坏 sidecar 路径让复活失败 → 按钮流程捕获失败并明确提示
   （不显示成功）。
3. 正常场景强制调用 `restart_daemon_process`（版本一致，按钮本不该出现）→
   不 panic、不产生数据损坏（会打断进行中的传输，用户主动点击即视为接受）。

**跨卡声明禁令**：未经上述三条用户确认，不得宣称「daemon 更新按钮已验证有效」。
