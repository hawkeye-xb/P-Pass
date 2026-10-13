---
title: Android 后台耗电排查：两个没关的 iroh 连接，一天 300mAh 降到不到 30mAh
description: "Android 后台耗电排查：电量数据查不下去，改用 netstats 流量对账，找到两个被唤醒后一直不关的 iroh/QUIC endpoint。空闲 30 秒关掉它们，再加上退避修复，一天耗电从约 300mAh 降到不到 30mAh。"
date: 2026-10-13
tags: [工程, Android, 耗电, iroh, QUIC]
lang: zh
draft: false
---

P-Pass 把手机里的照片自动备份到家里的电脑上。手机端平时在后台不干活，有新照片才传。

九月底，我们自己的一台 Android 手机耗电明显。正常用的一天里同步了 13 张照片，系统设置的电池页里，P-Pass 用了约 300mAh。

## batterystats 为什么是空的

第一反应是去看 Android 的 batterystats，按 wakelock、CPU、射频拆开，看电花在哪。

拆不出来。排查那会儿手机插着充电线，而充电时 batterystats 里各应用的这几项全是空的。`adb shell dumpsys battery unplug` 可以让系统当作没在充电，我们这次没用。几分钟的短时统计本来也说明不了一天的耗电。

电量不好测，就改查流量。系统按应用记了后台移动流量，照片传了几张、每张多大，电脑那边的日志里都有，拿来对账。

当时用的是这几条命令，换成你自己的包名就能用：

```bash
# 查出 App 的 uid
adb shell cmd package list packages -U <包名>

# 按 uid 看累计流量，前台、后台分开记
adb shell dumpsys netstats detail | grep -A 6 "uid=<uid>"

# 找到 App 登记的后台任务和 job id（WorkManager 的 id 是自动生成的）
adb shell dumpsys jobscheduler | grep <包名>

# 不等系统，手动触发一次后台任务
adb shell cmd jobscheduler run -f <包名> <job id>

# 只看自己的日志 tag
adb logcat -s <你的 tag>
```

netstats 的输出里，`set=DEFAULT` 是后台流量，`set=FOREGROUND` 是前台流量。每隔一分钟跑一次，就能看出 App 退到后台之后流量还涨不涨。

## 流量账对不上

系统 `netstats` 里，P-Pass 的后台移动流量，9 月 28 日约 215MB，29 日约 192MB。

按一天十几张照片、每张几 MB 算，也撑不起 200MB。电脑那边的日志也对得上，这台手机连过来的次数和收到的照片都不多。流量基本不是照片。

我们在手机上手动触发了一次后台唤醒。日志里这一轮很快结束，写的是 `nothing to transfer`，没有东西要传。可进程没有被系统冻住，P-Pass 的流量还在一直往上涨，每小时 8 到 20MB 不等。系统为什么没冻住它，我们没有深挖，能做的是让 App 自己不再联网。

logcat 里有两个线程，每隔 20 多秒读一次系统路由表。这两个线程就是下面那两个 endpoint。这个间隔和 iroh 1.0.3 源码里的定时器对得上。它每 20 到 26 秒重新做一次 STUN，每 15 秒给 relay 发一次 ping。完整的网络探测则是 5 分钟一次。

## 两个没人关的 endpoint

P-Pass 用 iroh 做传输，底下是 QUIC。直连不通时，数据经 relay（中继服务器）转发。一个 endpoint 会占着本地的 UDP 端口，并和一台 relay 保持长连接。手机进程里有两个 iroh endpoint：一个是跟电脑说话的控制通道，一个是给电脑供照片数据的 provider。

控制通道的 endpoint 绑定之后，全仓没有一处调用它的 `close()`。provider 那边的注释写着每个进程只开一次，而且它在判断「要不要传」之前就已经把 endpoint 开好了。

后台唤醒的来源很多：相册有变化、开机、5 小时一次的兜底任务、连不上电脑时的补探。任何一次唤醒都会把这两个 endpoint 拉起来。拉起来之后，它们一直开着，按 iroh 的节奏跟 relay 保持联系，不传照片的时候也一样，直到进程被系统杀掉为止。

## 改法：空闲 30 秒关掉 endpoint

改成用时才开、闲了就关：

- 两个 endpoint 都改成懒绑定，第一次真要用的时候才开。
- 新增一个回收器：App 不在前台，这一轮备份也结束了，等 30 秒，把两个 endpoint 都关掉。
- 电脑正连着拉照片时不许关，回收器每 30 秒再试一次。
- 关掉之后又被用到，就重新绑定，再重新开始计时。

回收器的主要逻辑就这么几行，节选自 `NetworkIdleReaper.kt`：

```kotlin
private fun update(change: () -> Unit) = synchronized(lock) {
    change()
    if (idle()) {
        // 空闲了：排一次回收
        if (pending?.isActive != true) pending = scope.launch { reap() }
    } else {
        // 回到前台或开始传：取消回收
        pending?.cancel()
        pending = null
    }
}

private fun idle() = !foreground && !engineBusy

private suspend fun reap() {
    while (true) {
        delay(30_000)
        if (!synchronized(lock) { idle() }) return
        if (park()) return  // 两个 endpoint 都关掉了
        // park() 返回 false：电脑还连着，30 秒后再试
    }
}
```

`foreground` 由 Activity 的可见性更新，自己实现的话用 `ProcessLifecycleOwner` 也可以；`engineBusy` 由备份引擎在一轮开始和结束时更新。`park()` 负责真正关 endpoint，有请求在飞或对端还连着时返回 false。如果 `park()` 执行时 App 恰好回到前台，endpoint 照样会被关掉，下次用到时懒绑定会重新打开，不影响功能。

provider 改成懒绑定后有个问题。我们在模拟器上加了 300 毫秒网络延迟。第一张照片会先失败一次，换了 endpoint 才传成。所以在探测电脑之前，先把 provider 提前绑定好。手机只在确实有照片要传时才会探测电脑，空闲时不会因此把连接打开。

同一段时间还修了一处退避。手机连不上电脑时，会排几次探测，过一会儿再试。原来的探测是 10 分钟一次。传到一半断了的话，探测没有上限，电脑一直不在，手机就每 10 分钟醒一次，没完没了。

现在一次故障只排一组，一共 4 次：第一次在 10 分钟后，之后依次隔 20、40、80 分钟，加起来约两个半小时。之后交给 5 小时一次的兜底任务。只有真的传成功了，这组探测才会清掉，下一次故障会重新排一组。

## 修复前后的流量对照

模拟器上做对照：同一个测试用的电脑端，App 退到后台后每 30 秒记一次这个应用的流量，记 6 分钟。

| | 6 分钟流量 | 日志 |
|---|---|---|
| 修复前 | 收 695KB、发 562KB，一直在涨，约 12.6MB/小时 | 没有回收日志 |
| 修复后 | 0KB | `network idle for 30000ms in background: endpoints parked` |

然后在那台手机上装正式签名的测试包，5G 网络，App 从最近任务里划掉，锁屏放着。

- 手动触发一次后台唤醒，没有新照片，日志写 `nothing to transfer`。30 秒后两个 endpoint 关掉，之后几分钟流量都是 0。
- 拍一张照片，1 秒内被唤醒，传到 Mac，30 秒后再次关掉。

关掉之前那 30 秒里，还会有几百 KB 的收发，这是 iroh 在连 relay、做网络探测。当时 App 日志里看不到，因为 Rust 这一层的日志还没接进 logcat，之后补上了。

## 结果：一天耗电不到 30mAh

同一台手机，允许走 5G，每天新增十张左右照片。系统电池页里，P-Pass 一天的耗电不到 30mAh。

这是上面几处改动合在一起的结果，我们没有逐项拆开测，没法说每一处各省了多少。现在后台没东西要传时，30 秒后不再联网。

WebSocket、MQTT、gRPC 这类后台长连接也一样，空闲不关就会一直发心跳。
