# MOB-61 手机相册源已删除时必须跳过，不得崩溃或无限重传（L2）

> ✅ 状态：归档（2026-09-11 三星真机验收通过） · 当前节点：缺源 URI 已原子落为不可恢复跳过，绝不进入重试或取消轮 · 协同分支：`main`
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
- 2026-09-08 根因：`StrictConsumer` 先为严格队头写入 `fetchLease`/`TRANSFERRING`，
  随后 `NativeFlowDeliveryPort.start()` 同步执行 `hashSource()` 与
  `openFileDescriptor()`；相册项目已删时两者抛 `FileNotFoundException`/空
  descriptor，异常在 launch 前逃逸，既未清 lease 也没有终态，因此会闪退或
  走普通网络失败的重试循环。
- 2026-09-08 落地：新增 `SKIPPED_SOURCE_MISSING` 终态。缺源时原子写入
  `sourcePresence=MISSING`、`disposition=UNRECOVERABLE`、清除 lease、推进
  cursor 并立即唤醒下一张；该态不进入 `FAILED_NEEDS_USER`、取消轮或重传队列。
  首页显示无动作提示「已跳过 N 张已从手机相册删除的照片，不会再重传」。
- 本机验证：定向 JVM 通过；Android JVM **310 tests / 0 failures / 0 errors /
  4 skipped**、debug APK `assembleDebug`、`just ci` 全绿。
- 真机仍欠：使用隔离的测试照片，让其入队再从系统相册删除；确认 App 不闪退、
  后续项继续、缺源项不再出现「再试一次」或「重新传输」，且首页提示计数正确。

## 真机验收（2026-09-11，三星 SM-S9210）

- 当前 `main` 重建的 debug APK 覆盖安装后，Android JVM 全量为 **337 tests /
  0 failures / 0 errors / 4 skipped**；`just ci` 通过。桌面端使用当前 `main`
  的 debug daemon：已安装 sidecar 因数据库 migration 5 不匹配无法打开现有库，
  该真实 stderr 属于既有 DESK-09 的覆盖面，未在本卡绕过或修改。
- 在已选的隔离 `P-Pass-BLOB-02` 相册中创建唯一命名测试照片；Flow 账本已持久
  入队（有 lease）后冻结 App，随后从系统存储删除该源文件，再恢复同一生产
  Flow。该项最终为 `SKIPPED_SOURCE_MISSING`，`sourcePresence=MISSING`，
  `disposition=UNRECOVERABLE`，lease 已清空；App 进程继续运行，未进入
  `FAILED_NEEDS_USER`。
- 随后新增的隔离后续照片在 **2 秒**内 `CONFIRMED`，证明严格队头已越过缺源项。
- 冷启动后 Settings/Home 实窗显示「已跳过 1 张已从手机相册删除的照片，不会再
  重传。」且没有动作按钮、重试或重传入口。测试后恢复原测试机状态：备份范围
  回到 1 个相册、后台备份保持原先关闭；手机侧所有本轮显式命名测试源文件已删除。
  桌面库中已确认的显式测试副本保留为验收证据，未以猜测路径直接删除。