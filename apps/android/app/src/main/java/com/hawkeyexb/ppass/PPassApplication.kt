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
import com.hawkeyexb.ppass.backup.AutoBackupPrefs
import com.hawkeyexb.ppass.backup.BackupHealthPrefs
import com.hawkeyexb.ppass.backup.isBackupScheduled
import com.hawkeyexb.ppass.backup.scheduleAutoBackup
import com.hawkeyexb.ppass.backup.triggerProcessStartCatchup
import com.hawkeyexb.ppass.transport.PairingStore
import kotlin.concurrent.thread

class PPassApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // 未配对 / 已暂停 → 什么都不做（doWork 内部还有第二道闸）。
        if (PairingStore(filesDir).load() == null) return
        if (AutoBackupPrefs(filesDir).paused()) return

        // isBackupScheduled 会阻塞（读 WorkManager 本地库），不能占主线程；
        // 后续两个 enqueue 本身是异步的，一起放进这条短命线程里最省事。
        thread(name = "ppass-boot-check") {
            // MOB-18: 先查再排——顺序不能反。调度体系整个不在（content
            // trigger 监听没了）意味着 job 被外力清空过，最常见的成因是用户
            // 在系统设置里「强行停止」。这件事必须让用户知道：权限还在、
            // 配对还在，既有的三张引导卡一张都不会亮，用户完全看不出备份
            // 已经停摆，只会觉得"照片怎么不同步了"。
            //
            // 用户定调（2026-08-19）："必须点了才恢复。你都提示了，就别
            // 自作主张。"——所以检测到调度体系被清空时**只记录、不恢复**，
            // 由设置页显示琥珀提示条，用户点「立即恢复」才真正重排。
            // 悄悄恢复等于把提示变成马后炮，用户没有选择权。
            if (!isBackupScheduled(this)) {
                BackupHealthPrefs(filesDir).recordInterrupted(System.currentTimeMillis())
            }

            // MOB-27: 这里**不能再 early-return**。事件②的监听现在是
            // JobScheduler 上的看门 job，而 trigger URI 与 setPersisted 互斥
            // （javadoc 明文）——**每次重启监听必然消失**。进程被拉起时不重挂，
            // 监听就一直失联到用户主动打开 App 为止，比 MOB-18 想防的那个
            // 问题严重得多。
            //
            // 与用户旧指令（"必须点了才恢复，你都提示了就别自作主张"）的关系：
            // 那句话的前提是"你都提示了"。MOB-18 的提示 UI 已随功能一起 pending
            // 进 backlog，现在没有任何提示——不恢复 = 静默死亡。所以 pend 掉这个
            // 功能就意味着回到 always-ensure。上面那行 record 保留，将来重做
            // MOB-18 时判据现成（但要先解决重启与 force-stop 无法区分的问题）。
            //
            // MOB-16（用户架构要求）：**监听的挂载不能依赖用户打开 App**。
            // 在此之前 scheduleAutoBackup 只在 MainActivity 里调用，意味着
            // content trigger 监听和周期任务的存在取决于"用户打开过 App"——
            // 一旦它们因为任何原因丢失，只有用户主动打开才能恢复。用户明确
            // 要求："App 它的一个作用是做配置和查看，真正运行作用物的不是它。"
            //
            // 这里的两个调用都是幂等的**兜底确认**（不是恢复）：content
            // trigger 走 KEEP（不打断正在等待的那个，见 MOB-14），周期任务
            // 走 UPDATE（更新约束但保留计时，见 MOB-12）。
            scheduleAutoBackup(this)
            // MOB-15: 扫一遍补捞窗口期丢失的通知。扫描无新照片时 doWork 立刻
            // 早退，所以「每次进程启动多一次检查」的代价很小。
            triggerProcessStartCatchup(this)
        }
    }
}
