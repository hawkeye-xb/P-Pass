# MOB-62 断开后重扫必须清空旧 Flow 运行态（L2）

> 🟠 状态：进行中（2026-09-08）· 当前节点：三星真机实证断开→重扫后 ANR；旧 Flow runtime、账本及多个 wake work 未随配对清除，重连同一 daemon NodeId 时旧任务继续 offer · 下一步：断开路径原子取消全部 wake、释放 runtime/provider、删除该 remote Flow ledger，再写回归用例 · 协同分支：`main`
> 级别：L2 · 阻塞：无

## 问题

手机主动断开后重新扫码同一台电脑，必须是全新业务会话。现有 `clearLocalPairing()` 只删 pairing/confirmed cache、取消一个 periodic work；它遗留 `flow-state/<NodeId>`、内存 `flowRuntimes` 和 catchup/manual/process/media-watch wakes。真机表现为旧 offer 连续发起、主线程 ANR、重连后崩溃。

## 期望行为

断开提交后旧会话的所有本地 Flow 状态与调度都不可再运行；重扫同一 NodeId 后只创建新 runtime/new ledger。不得触碰照片库。

## 验收标准

- [ ] 断开后所有 unique Flow wake work 与 media watch 均取消；旧 runtime/provider 关闭并从 map 移除，旧 remote Flow ledger 删除。
- [ ] 重扫同一 NodeId 后首次 wake 只读新 runtime/new ledger；无旧 offer、无 ANR/崩溃。
- [ ] JVM 覆盖 reset 语义；Android build/test 与 `just ci` 通过。
- [ ] 三星真机：主动断开→重扫→配对→进入首页，不崩溃；随后选择隔离相册可正常开始新一轮。

## 范围

- 只准动：Android pairing cleanup、Flow runtime 生命周期、work/media-watch cancel 与测试、卡/队列/进度。
- 不准动：daemon pairing auth、照片库/用户媒体、传输协议。

## 阻塞与依赖

无。

---

## 实施记录

- 2026-09-08 三星系统记录 `MainActivity` ANR；logcat 同时可见旧 `flow.fetch` offer 密集重放。