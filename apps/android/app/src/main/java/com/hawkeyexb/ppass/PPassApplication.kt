// MOB-15/16/18: 后台备份的进程级入口。
//
// 背景（真机时间线，用户 2026-08-19 报"kill 掉 app 之后拍照要等好几分钟"）：
//   10:39:50  用户从最近任务划掉 App，进程被杀
//   10:40:07~09 用户拍照 → 通知落在「进程被杀 → job 重排」的窗口里，无人接收
//   10:40:18  系统拉起进程执行 SystemJobService（**进程活了**）
//   10:44:30  直到下一个触发事件到来，才把这批一起传完
//
// 10:40:18 那一刻进程已经起来了，却只做了「重排 job」一件事就完了——完全
// 有能力顺手扫一遍相册，白白等了 4 分钟。
//
// 用户的原话点破了要害："我肯定是需要 kill app 的啊，配置好了谁整天看你
// 这个同步备份用的 app？"——所以「打开 App 时补跑」不能算解决方案，用户
// 根本不会打开。补捞必须发生在**进程因任何原因被拉起**的时候。
package com.hawkeyexb.ppass

import android.app.Application
import android.os.SystemClock
import com.hawkeyexb.ppass.backup.reconcileWatchOnProcessStart
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import kotlin.concurrent.thread

class PPassApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // MOB-28: 判定与重挂全部收进 reconcileWatchOnProcessStart（开机
        // receiver 共用同一段）。这里只负责"别占主线程"——它要读文件、
        // 发 binder、可能 enqueue work。
        //
        // 未配对 / 已暂停的早退在对账函数内部（那是它的前置条件，不是
        // 调用方的责任），BackupWorker.doWork 里另有第二道闸。
        thread(name = "ppass-boot-check") {
            reconcileWatchOnProcessStart(
                this, System.currentTimeMillis(), SystemClock.elapsedRealtime(),
            )
            // REBUILD-03: process wake is a Flow discovery request, not a
            // batch scan or transport operation. R4 will remove the legacy
            // worker scheduling path; this bridge keeps its behavior unchanged.
            requestFlowWake(this)
        }
    }
}
