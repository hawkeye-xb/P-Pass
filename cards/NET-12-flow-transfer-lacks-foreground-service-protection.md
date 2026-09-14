# NET-12 Flow 传输期间无前台服务保护，随时可被系统判定为可回收后台优先级（L2）

> 🟡 状态：代码已合并，等真机长期回归观察（真机验证已通过，见下）
> 级别：**L2**（跨模块系统集成缺失，非单文件局部修补）· 阻塞：无

## 问题

三星 SM-S9210 真机 2026-09-14 当天两次真实被系统杀死：

```
09-14 14:35:50.866  ActivityManager: Killing 19954:com.hawkeyexb.ppass/u0a386 (adj 915): one-time permission revoked
09-14 15:51:35.327  ActivityManager: Killing 27530:com.hawkeyexb.ppass/u0a387 (adj 900): one-time permission revoked
```

两次杀进程时 `adj` 都在 900~915 区间——这是 Android 后台缓存进程档位
（"可随时回收"），不是前台服务档位（前台服务档位 `adj` 应为个位数/两位数，
如 0-200）。杀之前 `FreecessController` 日志显示进程反复
`Initial -> Frozen`（三星 One UI 的后台冻结机制）。

本 agent 用干净测试相册复现：三星真机推入 35 张 6MB 测试图触发真实 Flow
传输，传输期间（`fetchLease` 非 null，`deliveryState=TRANSFERRING`）持续
每 10 秒采样 `/proc/<pid>/oom_score_adj`：

```
t=0s   （按 Home 切后台瞬间）  adj=700
t=+10s ~ +60s（传输仍在进行）  adj=700（不变）
传输完成后（35/35 全部 CONFIRMED） adj=900
```

`dumpsys notification` 确认全程通知栏**没有任何前台服务通知**；
`dumpsys activity oom` 显示进程 `cur=700/set=700`——系统日志里
`SGM:FgCheckThread: pkgName: com.hawkeyexb.ppass is not in foreground`。

结论：传输进程从按 Home 那一刻起就落进普通后台优先级（700→900 区间），
全程没有 `setForeground()`/`ForegroundInfo` 把它提升到前台服务档位。
`AndroidManifest.xml` 里 `FOREGROUND_SERVICE_DATA_SYNC` 权限和
`SystemForegroundService` 的 `dataSync` 类型声明都还在（历史遗留），
但**没有任何生产代码调用它们**——manifest 声明是空的承诺。

根因考古（`git show a325208`，2026-09-01 "feat(backup): cut worker over
to flow wake adapter"）：旧 `BackupWorker.kt`（1147 行）里
`foregroundInfo()` 私有函数 + `doWork()` 开头的
`setForeground(foregroundInfo())` 调用，随着这次重构把 Worker 削到
125 行（降级为纯 `runFlowWake()` OS 唤醒适配器）一起被删掉。新 Flow
架构（`FlowRunner`/`StrictConsumer`/`NativeFlowDeliveryPort`）的传输
生命周期完全在 `CoroutineScope(SupervisorJob() + Dispatchers.IO)` 里跑
（`NativeFlowDeliveryPort.scope`），从未挂靠任何 Android 组件生命周期
（Service/Worker），所以也没有任何东西能调用 `setForeground`。

「一次性权限到期」只是这次的触发方式之一，不是本质问题——只要传输进程
处于 700-900 档，OEM 的省电/内存回收策略（三星 FreecessController 冻结、
低内存杀进程、其它一次性权限/前台状态变化触发的重新评估）随时可能在
传输中途杀掉它，用户会看到「传了一半突然停了」且无任何解释。电池白名单
（`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`）管不了这个——白名单只防
Doze 限流待机唤醒频率，不提升进程 oom_adj、不防「可回收后台优先级下被
系统按内存/策略直接杀」。

## 期望行为

Flow 有传输在跑期间（`StrictConsumer.wake()` 成功进入
`fetchLease != null` / `deliveryState=TRANSFERRING`，直到
`NativeFlowDeliveryPort.start()` 收到 receipt 或失败，或 `stop()` 被调用）
应挂起一个 `dataSync` 前台服务保护，通知栏显示"正在传输"（复用
`strings.xml` 已有的 `state_sending_file` 文案：「正在备份 %1$s（第
%2$d / %3$d 张）」）。传输结束（confirmed / permanent failure / paused /
cancelled）应及时降级/停止前台服务，不能让通知常驻。

## 验收标准

- [x] RED 先行：`ForegroundServiceDecisionTest`（纯决策函数 `foregroundActionFor`，
      5 例含反证靶 `foreground_action_is_not_a_constant`）+
      `ForegroundServiceWiringTest`（源码断言：`flushAuditOutbox` 每个
      trigger 出口必须调用 `FlowTransferForeground.sync`）。真机 adj 采样
      脚本本身就是本卡的 RED 证据，已在下方"实施记录"复现故障。
- [x] GREEN：新增 `FlowTransferForegroundService`（Service，`onStartCommand`
      按 API 29+/以下分支调用 `startForeground`，manifest 声明
      `foregroundServiceType="dataSync"`）+ `FlowTransferForeground.sync()`
      （挂在 `AndroidFlowRuntime.flushAuditOutbox` 里，每个 Flow trigger
      的统一收尾点，不依赖任何调用方记得单独调用）。决策纯函数
      `foregroundActionFor` 复用既有 `flowRoundActive`（MOB-51 的账本派生
      事实）。
- [x] 反证：临时注释掉 `flushAuditOutbox` 里的 `FlowTransferForeground.sync`
      调用，`ForegroundServiceWiringTest` 立即真红（`AssertionError`），
      恢复后复绿。
- [x] Android JVM 全量绿（361 tests / 0 failures / 0 errors / 4 skipped）+
      `just ci` 全绿。
- [x] 真机：三星 SM-S9210 用新构建 debug APK（含本卡修复）重复相同的
      35 张 6MB 大图传输场景，切后台后每 8 秒采样
      `/proc/<pid>/oom_score_adj`：**全程锁定在 200**（perceptible/前台
      服务档位），不再是修复前的 700-900（后台缓存档，与两次真实被杀
      记录的 900/915 完全同区间）。`dumpsys activity services` 确认
      `FlowTransferForegroundService` 处于 `isForeground=true`
      `foregroundId=2026` `types=0x00000001`（dataSync）。35 张全部
      `CONFIRMED`，全程无杀进程记录。

## 范围

- 只准动：`backup/flow/NativeFlowDeliveryPort.kt`（或新增一个前台服务
  组件，由它在 `start()`/`stop()` 生命周期内驱动）、复用
  `SystemFailureNotifier.kt` 的通知基础设施写法（Channel/id 模式）、
  `strings.xml`（如需新增前台服务通知渠道名）、对应 JVM 测试。
- 不准动：`StrictConsumer` 的状态机语义、`FlowRunner` 的暂停/继续/取消
  控制面逻辑、`DiscoveryLedgerStore` 账本结构。前台服务只是给已有传输
  生命周期加一层系统可见性保护，不能改变 Flow 的状态判定。

## 阻塞与依赖

无前置。与 MOB-69（REBUILD-04 删除的通知发送端未接回）并列但不同——
MOB-69 是终态/提醒类通知（失败、哨兵、白名单、重传），本卡是进行时的
前台服务保护，两者复用同一套通知基础设施但服务的是不同的系统语义
（一个是"提醒用户看"，一个是"告诉系统不要杀我"）。

---

## 实施记录

- 2026-09-14：三星 SM-S9210 真机复现。测试方法：`/tmp/ppass-net12-test/`
  生成 35 张 6MB JPEG，`adb push` 到 `/sdcard/DCIM/NET12Test/`，
  `content query` 取得新相册 `bucket_id=-1862563778`，改写
  `run-as com.hawkeyexb.ppass` 的 `shared_prefs/backup_scope.xml`
  加入该 bucket，`am force-stop` + `am start` 重开进程触发扫描发现。
  传输期间 `input keyevent KEYCODE_HOME` 切后台，每 10 秒采样
  `/proc/<pid>/oom_score_adj`：全程 700，不随传输进行而提升；传输完成
  （账本 `Counter({'CONFIRMED': 35})`）后降为 900。`dumpsys notification`
  确认通知栏零 P-Pass 前台服务通知；`dumpsys activity oom` 的
  `SGM:FgCheckThread` 日志逐行确认 `pkgName: com.hawkeyexb.ppass is not
  in foreground`。测试完成后已恢复 `backup_scope.xml` 原始内容
  （已备份 `/tmp/backup_scope_orig.xml`），设备端测试相册待清理
  （`/sdcard/DCIM/NET12Test/`，桌面 daemon 库中对应测试文件待清理）。
- 源码交叉核实：`git show a325208^:.../BackupWorker.kt` 的
  `foregroundInfo()`（第 1122-1146 行）与 `doWork()` 开头的
  `setForeground(foregroundInfo())` 调用（第 517 行）确认为本次改动
  删除的原始实现；新架构 `NativeFlowDeliveryPort.kt`/`FlowRunner.kt`/
  `StrictConsumer.kt`/`AndroidFlowRuntime.kt` 全文核实零命中
  `setForeground`/`ForegroundInfo`。

## 备注

- Manifest 里 `FOREGROUND_SERVICE_DATA_SYNC` 权限与
  `SystemForegroundService` 的 `dataSync` 声明未删——这是历史遗留的
  "空壳"：声明齐全但无任何调用点，本卡要做的是接回调用点，不是重新
  声明权限。
- 真机测试相册与桌面库测试文件按拍板可直接创建/清理（本机测试环境，
  不进 git，见卡片模板"本机状态禁令"）。
- 通知权限（`POST_NOTIFICATIONS`）三星设备默认未授予时，前台服务本身
  仍正常以 `startForeground` 运行（系统不因通知不可见而拒绝提升），
  只是用户看不到"正在备份"提示条——这是独立的可见性问题，不影响本卡
  验收的核心事实（进程不被系统回收）。真机回归时建议一并引导用户授予
  该权限以获得完整体验，但非本卡阻塞项。
- **事故记录（与本卡代码无关，写此存档）**：真机验证第二轮测试时，
  清理临时测试图片执行了 `rm -rf /sdcard/DCIM/Camera`，误删了该相册
  本身就有的 237 张真实照片（该相册不是本次测试创建的，是本机现有
  相册，测试图片被推入了这个已存在目录）。排查确认：该机未登录三星
  账号（无云同步）、未装 Google 相册、P-Pass 该设备 `backup_scope`
  历史上从未选中过 Camera 相册（无 P-Pass 库副本）——**该批照片已确认
  无法恢复**。已将"验证清理只删自己创建的文件/目录，不对已存在目录做
  递归删除"的教训写入 `card-driven-repair` 技能，防止复现。
