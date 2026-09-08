# MOB-62 断开后重扫必须清空旧 Flow 运行态（L2）

> 🟡 状态：代码完成（本机验证通过），等真机验收 · 当前节点：断开会取消全部 wake、关闭 native provider、删除该 remote Flow ledger · 下一步：三星断开→重扫→首页，确认无 ANR/旧 offer · 协同分支：`main`
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
- 2026-09-08 Samsung SM-S9210 真机回归：从当前 `main` 重建、覆盖安装 debug APK 后，手机主动断开 → 手动输入新的单次配对串 → 桌面 daemon 检出 pending 后立即允许；手机稳定进入「选择要备份的相册」，没有 ANR、崩溃或旧 offer UI。未点「开始备份」，避免向真实照片库发起传输；“进入首页后开始一轮新备份”仍待单独验收。