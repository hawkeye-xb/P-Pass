---
title: iOS App 一退后台就被杀：0xdead10cc 和 App Group 里的一把文件锁
description: "P-Pass 的 iOS App 每次退到后台约 30 秒就被系统以 0xdead10cc 终止。抓设备实时 syslog 后，runningboardd 直接点名了持锁的文件：放在 App Group 共享容器里的 iroh-blobs 数据库。共享容器是为一个后来取消的后台上传扩展预留的，把存储根挪回 App 私有容器后，挂起 5 轮都没再被杀。"
date: 2026-10-26
tags: [工程, iOS, "0xdead10cc", App Group, 排查]
lang: zh
draft: false
---

P-Pass 的 iOS App 有个毛病：切到别的 App、或者锁屏，过半分钟左右再回来，看到的是冷启动。后台备份也受影响，系统每次在后台唤醒它，都得从头启动一遍。

测试机上从 10 月 16 日起攒了 9 份崩溃报告，全是同一个样子：`EXC_CRASH SIGKILL`，终止原因 `RUNNINGBOARD 0xdead10cc`。

## 0xdead10cc 说的是锁

`0xdead10cc` 读作 dead lock。它的意思是进程被挂起的时候还攥着文件锁或者 SQLite 的锁，系统直接把它杀了。

崩溃报告里只有这个码，没有说是哪把锁。我们的 App 里持锁的东西不止一个：备份账本是 SQLite，传输层 iroh-blobs 的存储用的是 redb，自己写的滚动日志也开着文件。光看报告分不出是谁。

## 让系统自己说

`runningboardd` 是 iOS 里决定进程挂起、终止的那个守护进程，它在动手之前会把检查过程写进系统日志。所以思路很直接：抓设备的实时 syslog，复现一次，看它怎么说。

`log collect --device-udid` 需要 root，用不上。我们用的是 pymobiledevice3：

```bash
pymobiledevice3 syslog live --udid <设备 UDID> | grep --line-buffered -E 'PPass|DEAD10CC|MUST be held'
```

日志开着，用 `devicectl` 把 App 拉起来，再切到「设置」，等。半分钟左右，App 的后台时间用完，被挂起，日志里出来这么一段（路径里的 UUID 省掉了）：

```
check if suspended process is holding locks
Found locked file lock: /var/mobile/Containers/Shared/AppGroup/<uuid>/PPass/blobs/iroh-blobs-provider/blobs.db
Ignoring unlocked SQLite database: /var/mobile/Containers/Shared/AppGroup/<uuid>/PPass/backup-orders.db
Ignoring file .../Data/Application/<uuid>/Library/Logs/ppass.log because it is in an allowed path
Terminating with context: ... code:0xDEAD10CC ... because it was suspended while holding a shared file lock:
  .../Shared/AppGroup/<uuid>/PPass/blobs/iroh-blobs-provider/blobs.db
  File locks MUST be held in one of the following directories:
  /var/mobile/Containers/Data/Application/<uuid>/tmp
  /var/mobile/Containers/Data/Application/<uuid>
```

持锁的是 `blobs.db`，iroh-blobs 的存储文件。redb 在进程活着的整段时间里都持有它的文件锁。

备份账本 `backup-orders.db` 这次被放过，因为挂起那一刻它没有事务在跑。但它和 `blobs.db` 在同一个目录，哪次挂起时正好在写，一样会被杀。

`ppass.log` 也开着，但它在 App 私有容器里，日志写的是 `because it is in an allowed path`，系统没有处理。

末尾两行是系统的规矩：文件锁只能放在 App 自己的容器或者它的 `tmp` 里。共享容器里的锁，挂起时一律不许持有。共享容器是给 App 和它的扩展共用的，一个进程挂起后还占着锁，另一个等锁的进程就会被卡住。我们猜这条规矩是冲着这个来的。

这个复现是稳定的。后来修复前又跑了两轮，两轮都被杀。

## 数据为什么会在共享容器里

存储根放在 App Group 共享容器，是 9 月写 iOS 兼容计划时定的。当时打算做一个后台上传扩展，用 iOS 26.1 的 PhotoKit 后台上传通道，扩展要和主 App 读写同一份账本，而扩展和主 App 之间共享数据只能走 App Group，所以计划里写的是「从第一天就放 App Group」，iroh-blobs 的存储也跟着放了进去。

这个扩展在 10 月中旬被否掉了。现在 iOS 端没有任何扩展，后台任务就跑在主 App 进程里。App Group 留了下来，没派上用场，倒引出了这个 0xdead10cc。

## 两种改法

要么在挂起之前把锁放掉：申请一段后台时间，关掉 redb 和 SQLite，下次回到前台再打开。要么把文件挪到系统允许的目录，挂起时持锁也没事。

前一种要求每次挂起前都把收尾做对。既然已经没有扩展需要共享这些数据，我们选了第二种：存储根整个挪到 App 私有容器的 `Application Support/PPass` 下，去掉 App Group 的分支。

iOS 版还没对外发布，所以没做旧数据迁移。升级后按新安装处理，重新扫一次码配对。App Group 的 entitlement 暂时没动，签名配置以后单独处理。

## 修复前 2 轮被杀，修复后 5 轮正常挂起

修复前用的是 TestFlight 上的 0.10.1 包，同一个脚本拉起、切走、等挂起，2 轮都被以 0xdead10cc 终止。

修复后装本分支的开发签名包，同一个脚本跑 5 轮，5 轮都正常挂起。日志里变成了这样：

```
Ignoring file <App 容器>/Library/Application Support/PPass/blobs/iroh-blobs-provider/blobs.db because it is in an allowed path
```

单看「挂起时会不会被杀」，锁屏后大约 30 秒就有结论。我们又多等了半个多小时，看后台唤醒以后会不会出事。从 13:44 起是同一个进程，期间被系统挂起 6 次、后台唤醒 3 次，一次都没被杀。14:14 那次是锁屏状态下系统用后台刷新任务把 App 叫醒，5 张新照片 18.7 秒传完，电脑那边按哈希核对，5 张都在，传完再次挂起，进程还是那个进程。

修复前那天，前几次被杀都留了崩溃报告，后面几次系统不再生成。崩溃报告里没有新增，不能当作修好的证据，判定看的是 syslog 里 runningboardd 的那几行。
