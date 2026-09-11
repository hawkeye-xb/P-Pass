# MOB-72 新选相册后必须立即唤醒 Flow，不能靠重开 App（L2）

> 🟡 状态：代码完成，待三星真机验收
> 级别：L2 · 阻塞：无

## 问题

2026-09-11 真机回归：用户取消当前轮（其中 2 张被跳过）后，在设置里选择第二个只含 1 张图片的相册。首页随后显示有待备份项，但没有开始传输；客户端连接状态仍为绿色。退出并重新打开 App 后，才触发该待传项的 Flow 传输。

用户刚完成的相册选择本身就是明确的用户在场触发。启动/重启 App 只能是恢复手段，不能是范围变更后开始传输的隐含前置条件。尚未把「待备份」计数的 3 张解释为错误，因为本轮取消项与新范围项的聚合口径需由实现先取证。

## 期望行为

设置页保存新增相册范围后，在当前运行的 runtime 中完成补扫、入队和一次符合当前网络约束的 Flow 唤醒。若无新候选则不虚构传输；若有候选且约束允许则无需退出/重启 App 即开始。

## 验收标准

- [ ] RED→GREEN：以取消轮历史 + 新增相册范围 + 可传候选构造生产 Flow 路径，保存范围后断言候选入队且同一进程内进入传输；改前用例必须复现「仅重开后才触发」。
- [ ] 自动化：相册范围未扩大或新增范围无候选时，不创建重复队列项、不启动空传输。
- [ ] 反证：移除范围变更后的 runtime wake 接线，焦点用例必须失败。
- [ ] 真机：取消当前轮后选择含新照片的第二个隔离相册，在不退出 App 的前提下完成传输；随后重开 App 不产生第二次传输。

## 范围

- 只准动：设置页相册选择保存后的触发接线（`MainActivity.kt`）、`requestFlowScopeBackfill`/Flow runtime 唤醒边界及其 Android JVM 测试。
- 不准动：`CancellationRoundController` 的取消语义、MOB-50 已闭环的 cursor 规则、照片计数/聚合口径、后台自动触发策略、远端协议。

## 阻塞与依赖

无。与 MOB-50、MOB-54 的历史症状相邻但不假定同一根因；本卡先以当前 main 的复现路径定性。

---

## 实施记录

- 2026-09-11：仅记录真机回归失败。当前设置页保存范围后依次调用 `requestFlowScopeBackfill(context)` 与 `triggerUserPresentBackup(context)`；需追踪二者在既有 runtime、取消轮历史与当前网络条件下是否实际形成一次 `runner.run(...)`，不能仅凭调用点断言已唤醒。
- 2026-09-11：已认领。源码初读确认范围保存确实调用 backfill + WorkManager 用户在场 wake；下一步从 runtime 是否存在、`KEEP` work 是否吞掉新 wake、以及取消轮 gate 三处构造生产复现，不凭调用点猜根因。
- 2026-09-11：根因确认：范围保存只靠 `CATCHUP_WORK_NAME` 的 `ExistingWorkPolicy.KEEP`；旧 Wi-Fi 受限 Work 尚在时，关闭限制后的新触发被吞掉。新增后台原子 `requestFlowScopeBackfillAndWake`，在同一 runtime 锁内提交 backfill 并以当前网络约束 `run`，不在主线程创建 runtime；原 WorkManager wake 保留作后续恢复。RED→GREEN 接线测试 1/0/0/0；Android JVM/debug APK 与 `just ci` 全绿。待真机：取消轮后新选含照片相册，不退出 App 即传输；重开不重复。
