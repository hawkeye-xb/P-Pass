# MOB-63 暂停恰逢最后一张完成时直接归位 Idle（L1）

> ✅ 状态：已通过验收（2026-09-10 三星真机隔离相册回归）
> 级别：**L1** · 阻塞：无
> 协同分支：`main` · 当前节点：完成。

## 问题

用户在传输最后一张时点「暂停」，桌面的完成回执可能与暂停交错到达。当前
`StrictConsumer.pauseByUser()` 会先把闸门写成 `PAUSED_BY_USER`，并将正在传的
最后一项退回 `QUEUED`；随后 `CompletionAndScope.acceptCompletionReceipt()` 允许该
已在飞行中的回执把它确认成 `CONFIRMED`，但不归位闸门。于是账本已没有
`QUEUED`/`TRANSFERRING` 项，`flowUiStateOf()` 仍因闸门优先级而投影成
`PausedByUser`，首页错误显示「继续」。

反向交错也必须成立：若最后一张的回执先落库，`acceptCompletionReceipt()` 清空
lease 后，随后的 `pauseByUser()` 目前会在无 lease 分支无条件写入
`PAUSED_BY_USER`；同样会把已完成的轮次伪装为暂停。

这不是取消流程（MOB-60），也不是把正常暂停改成空闲：只处理**暂停与最后一个
在飞传输成功完成交错，且确认后本轮没有可继续传输项**的收敛。

## 期望行为

检测到用户暂停之后（或期间）最后一张已持久化为 `CONFIRMED`，且账本没有
`QUEUED`/`TRANSFERRING` 项时，原子地收敛为既有 Idle 语义：
`consumerGate = OPEN`、`consumerStatus = IDLE`、无 fetch lease。首页不显示
「继续」或「取消当前轮」；若该轮有完成项，沿既有投影显示 AllSafe。

仍有任何 `QUEUED`/`TRANSFERRING` 项时，用户暂停必须保持 `PAUSED_BY_USER` 和
「继续」入口，不能因这项优化吞掉真实可续传工作。不得新增 UI 状态或由 UI
自行猜测传输是否结束。

## 验收标准

- [x] JVM RED→GREEN：构造单项传输，先 `pause()` 再接收该项的有效
      `CompletionReceipt`；最终账本为 `consumerGate == OPEN`、
      `consumerStatus == IDLE`、无 lease、唯一项为 `CONFIRMED`，并且
      `flowUiStateOf(...) == Idle`、`backupUiStateOf(...) == AllSafe`。
- [x] JVM RED→GREEN：构造相同单项传输，先接收有效完成回执、再执行暂停；最终
      仍是上述 Idle 收敛，证明两种允许的到达顺序语义一致。
- [x] JVM：两项轮次中第一项完成、第二项仍 `QUEUED` 时暂停，闸门仍为
      `PAUSED_BY_USER`，投影仍为 `PausedByUser`；不许开启下一项或丢掉「继续」。
- [x] 反证：把「确认后已无 `QUEUED`/`TRANSFERRING` 项」的终态判定去掉、改成
      暂停后总是归位 Idle，上一条两项暂停用例必须变红。
- [x] 跑受影响 Android JVM 测试，记录实际测试计数；再跑 `just ci`，均通过。
- [x] 真机：对隔离相册的最后一张传输连点暂停，覆盖回执先后两个可操作时机；
      完成后首页没有「继续」/「取消当前轮」，已完成数量正确且不会再启动空传输。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/`
  内暂停/完成回执的账本收敛，以及对应 `apps/android/app/src/test/java/com/hawkeyexb/ppass/backup/flow/`
  JVM 测试。
- 不准动：`FlowUiProjection` 的状态种类与优先级、`CancellationRoundController`
  和 MOB-60 取消完成归位路径、桌面完成回执 wire 协议、HomeScreen UI 文案。

## 阻塞与依赖

无。可与 MOB-51 的共享真机回归同轮验证，但实现及 JVM 验收不依赖它。

---

## 实施记录

2026-09-09：`StrictConsumer.pauseByUser()` 的无 lease 分支仅在账本无
`QUEUED`/`TRANSFERRING` 项时归位 `OPEN + IDLE`；
`CompletionAndScope.acceptCompletionReceipt()` 在暂停后的最后迟到回执落库时做同一
原子收敛。新增 `MOB63PauseCompletionRaceTest` 覆盖 pause→receipt、receipt→pause，
并以两项轮次反证锁住「仍有可续传项必须保留 PausedByUser」。RED：3 项中 2 项失败；
GREEN：定向 JVM XML 3/0/0，全量 Android JVM XML 317/0/0/4 skipped（61 文件，均为
本次生成），`just ci` 全绿。

2026-09-10 三星真机验收人实测确认：暂停与最后完成回执交错的两种时机均收敛
Idle，无残留「继续/取消当前轮」。验收通过。

## 备注

根因锚点：`StrictConsumer.pauseByUser()` 的有 lease/无 lease 两个暂停分支，以及
`CompletionAndScope.acceptCompletionReceipt()` 对暂停后迟到回执的既有接纳规则。
修复应在账本写入边界收敛事实，而不是在 `flowUiStateOf()` 为 `PausedByUser` 增加
例外；后者会留下持久化闸门与 UI 语义不一致。