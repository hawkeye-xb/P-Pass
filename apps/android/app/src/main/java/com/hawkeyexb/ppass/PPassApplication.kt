// MOB-15: 进程启动补捞。
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
import com.hawkeyexb.ppass.backup.AutoBackupPrefs
import com.hawkeyexb.ppass.backup.triggerProcessStartCatchup
import com.hawkeyexb.ppass.transport.PairingStore

class PPassApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // 未配对 / 已暂停 → 什么都不做（doWork 内部还有第二道闸）。
        if (PairingStore(filesDir).load() == null) return
        if (AutoBackupPrefs(filesDir).paused()) return
        // enqueue 本身是异步的，不阻塞主线程；扫描无新照片时 doWork 立刻
        // 早退，所以「每次进程启动多一次检查」的代价很小。
        triggerProcessStartCatchup(this)
    }
}
