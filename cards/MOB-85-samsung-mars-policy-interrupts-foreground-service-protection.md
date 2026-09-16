# MOB-85 三星 MARs 资源策略在前台服务保护生效期间仍主动杀进程/降级服务（L1）

> ⬜ 状态：未开工 · 真机复现于 2026-09-16 NET-01/NET-12 真机回归会话
> 级别：**L1**（系统策略绕过已有的前台服务保护，非数据丢失）· 阻塞：无

## 问题

2026-09-16 三星 SM-S9210 真机回归（daemon debug 日志
`RUST_LOG=info,transport=debug,daemon=debug,iroh=debug` + `adb logcat -v
threadtime` 全程持久化抓取，非复述）：手机切 5G 蜂窝、Mac 保持家庭 Wi-Fi
（跨网络场景），反复卸装重装 App 并配对测试期间，观察到系统在
`FlowTransferForegroundService`（NET-12 已接回的前台服务保护）处于
`isForeground=true` 期间仍两次主动介入：

```
15:12:14.269  ActivityManager: Killing 4220:com.hawkeyexb.ppass/u0a392 (adj 900): stop com.hawkeyexb.ppass due to MARs #2
15:12:40.064  ActivityManager: Stop FGS timeout: ServiceRecord{...FlowTransferForegroundService...}
15:12:55.578  ActivityManager: Killing 5352:com.hawkeyexb.ppass/u0a392 (adj 50): stop com.hawkeyexb.ppass due to MARs #2
15:15:08.990  ActivityManager: Stop FGS timeout: ServiceRecord{...FlowTransferForegroundService...}
```

`MARs`（三星资源管控策略）两次直接 `Killing`，`Stop FGS timeout` 两次将
前台服务强制降级——均由系统日志记录，非用户手动划掉最近任务触发（对照
同一时间窗口的 `adb logcat`，两次杀进程紧邻 App 重装/重启操作，但
`Stop FGS timeout` 是系统超时机制，与用户操作无直接因果）。

NET-12 已验证「给 Flow 传输加前台服务保护」本身生效（真机 `oom_score_adj`
锁定在 200，不再降到 700-900 杀档），但本次观察到**前台服务保护存在
本身不能阻止三星 MARs 策略和系统级 FGS timeout 机制介入**——这是 NET-12
未覆盖到的相邻缺口：NET-12 解决的是「没有保护」，本卡要查的是「有保护但
仍被系统策略绕过」。

## 期望行为

需先定性两件事，再决定是否需要代码修复：

1. `Stop FGS timeout` 触发的条件是什么（Android 有前台服务运行时长上限，
   还是三星特化行为）？触发后服务是否自动重建，用户是否有可感知的传输
   中断？
2. `MARs` 杀进程是否与本次会话中反复卸装/重装/强退 App 的操作强相关（即
   系统在检测到"频繁重启"时启动的特殊限制），还是安静运行期间也会触发？
   需要一次不被用户操作打断的、连续观察 10+ 分钟的干净回归来排除操作
   干扰这个变量。

若确认是"安静运行期间也会被系统主动打断"，需要评估：
- 是否需要在 `FlowTransferForegroundService` 里响应 `onTimeout`
  （Android 14+ API）优雅处理，而不是被系统直接杀掉后静默失败；
- 是否需要三星电池白名单之外的额外用户引导（当前 DOG-03 已拍板不做
  onboarding 强制，但 MARs 可能是与电池白名单不同的独立机制）。

## 验收标准

- [ ] 真机取证：一次不被用户操作干扰的干净回归（App 安装完成、配对完成、
      发起一次会传输数分钟的大文件，之后不再触碰手机），观察 `MARs`/
      `Stop FGS timeout` 是否仍会出现；若不出现，说明本次观察与频繁
      重装/强退操作强相关，需在卡内更新结论并降级或关闭本卡。
- [ ] 若确认安静运行期间也会触发：定位三星 `MARs` 策略的触发条件（查
      `FreecessController`/`MARsPolicyManager` 相关系统日志字段），
      写清楚触发阈值（如后台时长、内存压力等）。
- [ ] 若需要代码修复：给出具体方案（响应 `onTimeout`、重新拉起服务、或
      用户可见的降级提示），RED→GREEN 覆盖。
- [ ] 反证：确认修复前的对照组（无 `onTimeout` 处理）在相同条件下会
      呈现传输中断且无提示。

## 范围

- 待定性后再列。默认候选：`FlowTransferForegroundService`（NET-12 已
  接回的前台服务组件）、`FlowTransferForeground.sync()`。
- 不准动：NET-12 已验收的「传输期间 oom_adj 锁定在前台档位」这条结论
  本身不重开，本卡只处理"保护生效期间仍被系统策略绕过"这个新缺口。

## 阻塞与依赖

无。与 NET-12 相邻但不同——NET-12 已归档「待共享回归」（保护本身已生效
并有真机 adj 采样证据），本卡查的是保护生效之后系统策略仍能绕过它这个
新观察。

---

## 实施记录

- 2026-09-16：真机回归会话中用持久化 daemon debug 日志
  （`RUST_LOG=info,transport=debug,daemon=debug,iroh=debug`）+
  `adb logcat -v threadtime` 全程后台采集（非轮询采样,避免漏帧）取证。
  发现两次 `MARs #2` 杀进程 + 两次 `Stop FGS timeout`，均落在用户反复
  卸装/重装/强退 App 操作的时间窗口内，尚未排除与操作本身的相关性，
  已开卡记录，验收标准第一条要求先做一次不被操作干扰的干净回归来
  排除这个变量。
