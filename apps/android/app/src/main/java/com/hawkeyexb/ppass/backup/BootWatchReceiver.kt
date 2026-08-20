// MOB-28: 开机重挂照片监听。
//
// 为什么必须有这个 receiver：`JobInfo` 的 trigger URI 与 `setPersisted`
// **互斥**（AOSP javadoc 明文），所以 MOB-27 的看门 job 天生不可持久化，
// **每次重启都会消失**。没有这个 receiver 的话，复活链路只剩"5h 周期任务
// 到点了把进程拉起来"——监听空窗上限就是 5 小时。
//
// 成本：`RECEIVE_BOOT_COMPLETED` 权限在合并 manifest 里**本来就有**
// （WorkManager 带进来的），所以不增加任何用户可见权限；manifest receiver
// 不常驻，只在广播到来时实例化，跑完即回收。
//
// force-stop 之后收不到这个广播——系统把 App 置为 stopped 态，重启也不清除，
// 只有用户手动打开才解除。这正是 MOB-28 要的语义（被强停过就等用户点），
// 不是缺陷。
package com.hawkeyexb.ppass.backup

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import kotlin.concurrent.thread

class BootWatchReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        // 只认开机广播（LOCKED_BOOT_COMPLETED 不处理——我们的状态在
        // credential-encrypted 存储里，用户解锁前读不到）。
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        // goAsync：onReceive 返回后进程就可被回收，而对账要读文件 + 发 binder。
        // 不用 goAsync 的话这段活可能跑不完（"实测通常来得及"不算保证）。
        val pending = goAsync()
        val app = context.applicationContext
        thread(name = "ppass-boot-rearm") {
            try {
                reconcileWatchOnProcessStart(
                    app, System.currentTimeMillis(), SystemClock.elapsedRealtime(),
                )
            } catch (t: Throwable) {
                android.util.Log.w("PPassWatch", "boot rearm failed", t)
            } finally {
                pending.finish()
            }
        }
    }
}
