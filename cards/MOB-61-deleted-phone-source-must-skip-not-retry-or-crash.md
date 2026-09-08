# MOB-61 手机相册源已删除时必须跳过，不得崩溃或无限重传（L2）

> 🟠 状态：进行中（2026-09-08）· 当前节点：三星真机复现；删除已入 Flow 队列但未完成的手机相册照片后，`hashSource` / `openFileDescriptor` 抛错越过 Flow 终态，触发崩溃或失败重试循环 · 下一步：先写缺源终态失败用例，再把缺源原子落为不可恢复跳过并验证队头推进 · 协同分支：`main`
> 级别：L2 · 阻塞：无

## 问题

三星真机：照片已被发现并进入 Flow 队列后，用户在系统相册删除该照片。随后传输
尝试在 Android `NativeFlowDeliveryPort` 的 `hashSource()` 或 provider 的
`openFileDescriptor()` 打开 `content://` 源时失败。当前异常在创建协程前或外部
try/catch 之外，不能转换为账本事实；严格队头会重复失败，用户点“再试一次”又把
同一张不存在的照片重新入队，甚至触发 App 崩溃/ANR。UI 同时混出“已跳过 N 张”
与“重新传输”入口，给人错误印象：不存在的手机原图还能恢复。

## 期望行为

手机源已不存在是一个**本地不可恢复的终态**，不是网络暂时故障，也不是用户取消：

- 该 item 原子落为 `SKIPPED_SOURCE_MISSING`，带 `sourcePresence=MISSING` 与
  `disposition=UNRECOVERABLE`；清除当前 lease，严格消费者推进到下一张。
- 不消耗失败重试预算，不进入 `FAILED_NEEDS_USER`，不出现“再试一次”或
  “重新传输”动作。
- 首页只以无操作的说明告诉用户“已跳过 N 张已从手机删除的照片”；已确认项和
  后续仍存在的照片照常继续。
- 若整轮只剩已确认项与此类跳过项，显示完成（已确认数只计真正 `CONFIRMED`），
  不保留暂停/继续/取消入口。

## 验收标准

- [ ] RED：模拟严格队头的手机源缺失，断言当前实现不会把它变为可重试失败；用例
  先红。
- [ ] GREEN：缺源 item 一次原子提交为 `SKIPPED_SOURCE_MISSING`，lease 清空、
  upload cursor 指向下一 `QUEUED` 项，下一张启动；该 item 不再被 retry/wake。
- [ ] 投影：缺源跳过不计“待备份”、不计“已到家”；全队列为 CONFIRMED + 缺源跳过
  时进入完成态；“已跳过”说明没有恢复/重传动作。
- [ ] 反证：把缺源重新映射成 `FAILED_NEEDS_USER`，上述终态/队头推进用例必须红。
- [ ] Android JVM 全量绿（报告测试计数）+ debug APK；真机用隔离测试相册重跑：
  先让一张入队再从系统相册删除，App 不崩、该张只被跳过、后续照片继续完成。

## 范围

- 只准动：`backup/flow/` 的账本终态、严格消费者、Android delivery adapter 与
  对应 JVM 测试；首页针对缺源跳过的只读说明及 en/zh 资源。
- 不准动：daemon/native iroh-blobs 协议、远端对账的 `NEEDS_DECISION` 语义、
  用户取消轮的恢复入口、旧批次管线。

## 阻塞与依赖

无。NET-01 的长 RPC 超时与本卡独立：超时的源仍存在可重试；本卡的源已经不存在，
必须终态跳过。

---

## 实施记录

- 2026-09-08 三星真机：用户删除队列中的手机相册照片后复现崩溃/循环重传；
  Flow 当前只有 `QUEUED`、`TRANSFERRING`、`FAILED_NEEDS_USER`、`CONFIRMED` 和
  两类取消态，没有“本地源消失”的专用终态。