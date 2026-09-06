# MOB-51 英雄区暂停/继续只在单文件传输瞬间可达，整轮进行中没有粘性（L1）

> 🟡 状态：代码完成（本机全绿），等真机验收 · 当前节点：RED 2 条缝隙用例真红 → 粘性实现合入；下一步：真机连续备份全程有「暂停」、点暂停→「继续」→「取消」→ 同轮完成 MOB-49/50 组合验收 · 协同分支：`main`
> 级别：L1 · 阻塞：无（本卡挡 MOB-49/50 组合真机验收）

## 问题

v0.5.0-test.5 真机（三星）：备份进行中，首页进度数字正常跳动（20/30 已回家、
待备份递减——UI-09 换源生效），但**暂停/取消按钮全程不出现**。编辑相册时
选片页的单文件取消操作「一闪而过」。

验收人预期（原话归纳）：虽然单管道执行，按钮应该在「执行与不执行」之间
切换——**整轮进行中就该有暂停入口**，而不是恰好抓住某个文件的传输瞬间。

代码层根因（源码核实）：`heroActionOf` 以 `isBackupRunning(state)` 为门，
`Sending` 态来自投影 `flowUiStateOf` 的 `Transferring`——仅当轮询瞬间存在
`deliveryState == TRANSFERRING` 的 item。局域网单张照片数百毫秒完成，
500ms 轮询大概率错过；队列连续跑时相邻两文件的 TRANSFERRING 窗口之间
还有 receipt→wake→下一项 start 的空隙，按钮因此近乎永不可达。
这不是投影 bug，是**状态模型缺一个「本轮活跃」的粘性事实**。

## 期望行为

- 只要本轮仍有未完成工作（存在 QUEUED/TRANSFERRING 项且 gate OPEN 且
  有活跃消费在跑），首页持续显示「暂停」；paused 后持续显示「继续」+可「取消」。
- 「本轮是否有活」与「此刻是否正好在传某一个文件」分开建模；文件名级
  进度仍归单文件态。
- 选片页逐行取消的闪现行为属 UX 细节，本卡只保证首页整轮按钮正确。

## 验收标准

- [ ] RED 先行：JVM 用例——账本含多个 QUEUED、无 TRANSFERRING 瞬间（模拟
      轮询采样落在文件间隙），断言投影仍判为「本轮进行中」、`heroActionOf`
      返回 Pause；当前实现必须变红。
- [ ] 真机：连续备份 ≥20 张，全程任意时刻打开首页都能看到「暂停」；
      点暂停 → 变「继续」→（等 2s）按钮仍在；「取消」出现且可用——
      顺带完成 MOB-49/50 的取消流组合验收。
- [ ] 反证：把粘性判定接回「仅 TRANSFERRING 存在」的变体必须变红。
- [ ] Android JVM 全量绿（报测试计数）+ debug APK + `just ci`。

## 范围

- 只准动：`backup/flow/FlowUiProjection.kt`（轮级粘性事实的投影）、
  `backup/flow/DiscoveryLedger.kt`（如「本轮活跃」需持久字段则加，默认值
  兼容旧账本）、`ui/BackupStatus.kt`（heroActionOf 门）、对应 JVM 测试、
  卡片/队列/进度文档。
- 不准动：严格消费者/receipt 协议语义；选片页组件；桌面端。

## 阻塞与依赖

无前置。下游：MOB-49、MOB-50 真机组合验收以本卡交付的持续按钮为操作入口。

---

## 实施记录

- 2026-09-06 RED：`MOB51HeroStickyTest` 以 RED stub（复刻今日「仅 TRANSFERRING
  可达」行为）跑 → **2 条缝隙用例真红**（`a_running_round_keeps_the_Pause_
  affordance_visible_in_the_gap`、`the_per_file_projection_is_idle_...`），
  4 条现状用例绿——精确命中缺陷不牵连。
- 2026-09-06 实现：
  - `flowRoundActive`：**只从持久账本事实**推导的轮级粘性——gate OPEN 且
    （有 lease ∨ 有 QUEUED/TRANSFERRING 项）。用户暂停=轮次结束（转 Resume，
    不显示 Pause）；仅有耗尽失败的队头=停滞不是运行（不撒谎说在传）。**不新增
    调度真相字段**——缝隙本就是 gate OPEN + QUEUED 未清零，直接可读。
  - `backupUiStateOf`：单一共享 snapshot→首页态映射（holder 与测试同走生产
    链）；缝隙态渲染为带真实计数的 Sending（confirmed / confirmed+pending），
    不编 0/0 假进度。
  - `flowCommandOf`：按钮点击路由与按钮文案**读同一批事实**——此前文案显示
    Pause、点击却重读到 Idle 而 fire wake，「按钮撒两次谎」；现在可见 Pause
    必暂停（含缝隙）。
- 2026-09-06 反证（实现已 commit `d030bc3` 之后才做，安全）：`flowRoundActive`
  改恒 false → 3 条用例真红，`git checkout` 单文件还原（工作区只有破坏 diff，
  教训落地）。
- 2026-09-06 基线：Android JVM 全量 **274 tests / 0 failures / 4 skipped**
  （51 类；基线 268 + 本卡 6），XML 时间戳为本次生成；just ci / assembleDebug
  结果见下条追加。
- 2026-09-06 过程记录：反证脚手架脚本第二次在同一处崩溃（`subprocess.run`
  未加 capture → `.stdout` None）。**根因是脚本健壮性、非纪律问题**；纪律
  改进（先 commit 再反证）本次生效——工作区仅 1 行破坏 diff，checkout 干净
  还原，实现无恙。

## 备注

- 「本轮活跃」的诚实定义实施时定：候选 = fetchLease 存在 ∨ (gate OPEN ∧
  存在 QUEUED ∧ 有已调度的 wake)——第三种在账本无调度事实，可能需要
  轻量持久标志位；方案先写进本卡再动码。
