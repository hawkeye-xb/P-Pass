# DOG-03 三星退到后台 20 秒就冻进程，看门 job 直接丢　级别 L1

> 🔴 状态：待实施
> 级别：**L1**（后台自动备份在未加白名单的机器上根本不工作）· 阻塞：无

## 问题

验收人反馈（2026-08-26 真机 0.4.0-test.8，回归步骤 #2）：

> 「在没授权后台进程的时候，我从【最近】移动相片到【P-Pass】目录，等待一分钟，
> 没有触发上传。」（#3：重新将 app 切换到前台，传输成功）

## 实锤

```
17:01:52.896  FreecessController: com.hawkeyexb.ppass (state: Initial -> Frozen, Reason: uidIdle)
17:01:52.899  FZ : com.hawkeyexb.ppass(10366) [10957] reason: Bg
17:04:03.026  W/JobScheduler: Job didn't exist in JobStore:
              7624c5e #u0a366/20260819 com.hawkeyexb.ppass/.backup.MediaWatchJob
```

App 退到后台约 **20 秒**，三星 Freecess 就以 `uidIdle` 把进程冻结。冻结期间
content trigger 的回调送不进来，那个看门 job（`MediaWatchJob`，id 20260819）
在清理里直接丢失——移动照片时**没有任何东西接得住**。

#3 切回前台之所以传成功，是 MOB-38 的 `foregroundCatchup` 把它捞回来的。
授权电池白名单之后（回归步骤 #6/#7）立即触发恢复正常，因为白名单让 Freecess
不再冻。

## 一条要记的纠正

上一轮我把 `W/JobScheduler: Job didn't exist in JobStore` 判成「大概无害」，
理由是「那几轮备份都成功了」。**那是错的推断**——成功是因为别的触发通道补上了，
而这条警告本身就是「看门 job 死了」的直接证据。

## 决策：这不是代码能修的触发问题

冻结期间我们根本不运行，**检测不到自己的 job 死了**，也没有任何时机去重挂。
`reconcileWatchOnProcessStart`（MOB-28）已经覆盖了「进程被拉起时重挂」这条路，
但被冻结的进程压根不会被拉起。

所以出路在产品侧：**把「加电池白名单」从可以跳过的提示卡，提成 onboarding 的
必经一步。** 当前 DOG-02 的白名单引导是首页上一张可以无视的卡；在三星这类
OEM 上，不加白名单等于「后台自动备份这个功能不存在」，而用户不会知道。

## 要做的（方向，实施前先定稿）

1. onboarding 里选完相册之后加一步：**「让 P-Pass 在后台工作」**，说清后果
   （不授权 = 只有打开 App 时才同步），给一个直达系统页的按钮。
2. 允许跳过，但跳过后首页的状态必须**持续**说明「后台同步已关闭」——不是一张
   可以划走的提示卡，而是状态行的一部分。
3. 已授权的机器上这一步不出现（幂等，`isIgnoringBatteryOptimizations`）。

## 不准动

- MOB-28 的中断确认红线（白名单引导不许顺手重挂监听）
- DOG-02b 的契机式提醒（那是给「装完很久之后才发现没授权」的补救，两者并存）
