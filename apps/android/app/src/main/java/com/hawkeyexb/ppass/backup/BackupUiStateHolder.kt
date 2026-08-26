// T-054: glue between the Home screen and the pipeline — scan real
// MediaStore photos, hash, run BackupRunner, advance the watermark.
package com.hawkeyexb.ppass.backup

import android.content.ContentResolver
import android.content.Context
import androidx.work.WorkManager
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.IdentityStore
import com.hawkeyexb.ppass.transport.Pairing
import com.hawkeyexb.ppass.transport.parsePeerAddrToken
import com.hawkeyexb.ppass.ui.BackupUiState
import com.hawkeyexb.ppass.ui.isBackupRunning
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class BackupUiStateHolder(
    private val context: Context,
    private val client: DaemonClient,
    private val identity: IdentityStore,
    private val pairing: Pairing,
    private val scopeStore: BackupScopeStore = BackupScopeStore(context),
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val _state = mutableStateOf<BackupUiState>(BackupUiState.Idle)
    val state: State<BackupUiState> get() = _state
    // DOG-01b: 状态缓存表 key=(hash, remote_id)，落 per-remote 目录。
    // M = 该 remote 已确认条数；N = MediaStore 全量 count；K = N-M。
    // 杀 App 重开不归零；断网也走本地（MediaStore + 本地文件）→ 恒真。
    private val confirmedStore = ConfirmedStore(
        File(context.filesDir, "backup-state/${pairing.daemonNodeId}")
    )
    // MOB-34: 定向补偿队列（与 confirmed.json 同目录）。**这条校准路径也
    // 必须登记**——App 打开时的这次校准同样会把「确认过、库里却没了」的
    // hash 从缓存里剔除，少接一处就等于那批老照片在这条门里照样永远回不来。
    private val reuploads = ReuploadQueue(
        File(context.filesDir, "backup-state/${pairing.daemonNodeId}")
    )
    // MOB-37: 重传告知的落盘（同目录，随配对一起清）。**这条校准门也必须
    // 落盘**——它是「App 打开时」那一次校准，正是真机验收那个场景
    // （通知权限关掉 → 电脑上删几张 → 打开 App 必须看得到）的发生地。
    // 这里刻意**不发系统通知**：人就在看着 App，App 内那条提示就是呈现。
    private val reuploadNotice = ReuploadNoticePrefs(
        File(context.filesDir, "backup-state/${pairing.daemonNodeId}")
    )
    // UX-13: 「用户按下暂停的那一刻」落盘（同目录，随配对一起清）。
    // ⚠️ **同步读**（构造时读一次，见 [pausedAt]）：WorkManager 那条流的
    // 首帧会立刻到，异步读盘会跟它抢跑——首帧赢了就按 pausedAt=0 算出 Idle，
    // 而下一次重算要等下一个 work 事件（可能永远不来）。后果正是「暂停后
    // 杀 App 重开，继续按钮不见了」。文件只有几十字节。
    private val pausePrefs = PausePrefs(
        File(context.filesDir, "backup-state/${pairing.daemonNodeId}")
    )
    /** 用户按下「暂停」的时刻（0 = 没有待续传的暂停）。内存里这一份是
     *  权威值，落盘只为跨进程存活；写内存**同步**发生在点击那一刻，
     *  好让紧随其后的 CANCELLED 那一帧就能算出被暂停态。 */
    private var pausedAt: Long = runCatching { pausePrefs.pausedAt() }.getOrDefault(0L)

    private val _reuploadNoticeCount = mutableStateOf(0)
    /** MOB-37: App 内那条重传告知该显示几张（0 = 不显示）。读的是**落盘
     *  状态**，与系统通知是否送达无关。 */
    val reuploadNoticeCount: State<Int> get() = _reuploadNoticeCount

    private val _triplet = mutableStateOf<BackupTriplet?>(null)
    val triplet: State<BackupTriplet?> get() = _triplet

    // 存储端移除/吊销本设备后，备份请求被配对门拒（err.not_paired /
    // err.not_authorized）——UI 借此感知「配对已失效」，给出重新扫码入口。
    private val _pairingLost = mutableStateOf(false)
    val pairingLost: State<Boolean> get() = _pairingLost

    init {
        // 启动即算一次（MediaStore COUNT 便宜；扫描在 IO 线程）。
        scope.launch { refreshTriplet() }
        // MOB-37: 进程/组合起来时先把盘上的告知读出来（上一轮后台任务
        // 登记的那条——通知可能压根没送到，它只能从盘上来）。
        refreshReuploadNotice()
        // DOG-01c: App 打开即做一次漂移校准（daemon 可达才跑，不可达跳过）。
        scope.launch { calibrateFromDaemon() }
        // MOB-21: 跟住**后台** BackupWorker 的状态变化。
        //
        // 在此之前 refreshTriplet 只在三个时机跑：init、手动备份完成、
        // MOB-13 的补齐之后——**后台自动备份跑完不通知 UI**。于是用户
        // 打开 App（那一刻 M=0）、后台默默传完 142 张，界面上那个大字
        // 一直停在 0，用户以为"备份成功了却显示 0"（2026-08-19 真机实测：
        // 数据层 confirmed.json 有 165 条记录、范围内 142 条完全正确，
        // 重启 App 立刻显示 142/142——纯粹是 UI 没刷新）。
        //
        // 按 tag 观察而不是按 unique name：自动备份有四条通道（周期兜底 /
        // content trigger / 用户在场 catchup / 进程启动补捞），它们共用
        // BackupWorker，逐个 name 订阅既啰嗦又容易漏。
        scope.launch {
            WorkManager.getInstance(context)
                .getWorkInfosByTagFlow(BackupWorker::class.java.name)
                .collect { infos ->
                    refreshTriplet()
                    // MOB-37: 后台任务跑完可能刚登记了一条重传告知——
                    // 重读一次盘，App 摆在眼前时那条提示才会自己出来。
                    refreshReuploadNotice()
                    // MOB-19: 状态行也从这条流里出。管线合并之后手动备份
                    // 不再在前台跑，界面只能靠 work 的 progress/output 跟住
                    // ——顺带自动备份也第一次有了实时进度（在此之前后台跑
                    // 完只刷三元组，状态行全程不动）。
                    observeBackupWork(infos)
                }
        }
    }

    /** MOB-19: 从 work 列表里挑出"当前这一轮"并映射成界面状态。
     *
     *  为什么挑 RUNNING 优先：四条自动通道 + 手动通道共用 BackupWorker 的
     *  tag，列表里会有多条（含已终结的历史）。正在跑的那条才是用户此刻
     *  该看到的；都没跑就看最近一条终态。 */
    /** MOB-33: 当前正在跑的那条 work（暂停要取消它，不认通道）。 */
    private var runningWorkId: java.util.UUID? = null

    private fun observeBackupWork(infos: List<androidx.work.WorkInfo>) {
        // MOB-33: 记住当前正在跑的那条 work 的 id——暂停要取消**它**，
        // 而不是固定的手动通道（见 [backupNow]）。
        runningWorkId = runningInfoOf(infos)?.id
        val next = uiStateOf(infos, pausedAt) ?: return
        // UX-13: 这次暂停已被后来的运行覆盖 → 把标记清掉（内存 + 盘）。
        // 不清的后果：WorkManager 迟早会把终态记录清理掉，届时盘上那个
        // 陈年 pausedAt 面对一张空列表又会算出「被暂停」，「继续」按钮凭空
        // 复活——跟本卡要修的那类幽灵状态同型。
        // ⚠️ 不许在 next 还是「进行中」时清：点完暂停到 CANCELLED 回报之间
        // 那几帧仍然是 Working（字节还在传，MOB-33 要的就是这个），清了就等于
        // 这次暂停从没发生过。
        if (pausedAt > 0L && next !is BackupUiState.Paused && !isBackupRunning(next)) {
            pausedAt = 0L
            scope.launch {
                withContext(Dispatchers.IO) { runCatching { pausePrefs.setPausedAt(0L) } }
            }
        }
        // 配对失效是独立信号（红卡 + 重新扫码入口），不占状态行。
        if (next is BackupUiState.Trouble && isPairingLostText(next.text)) {
            _pairingLost.value = true
        }
        _state.value = next
    }

    /** DOG-01c: 漂移校准——电脑端库被删/换库时，缓存里的旧 hash 已不在
     *  daemon。用只查不传的 exist-check 问出 missing 并从缓存移除。
     *  daemon 不可达/未配对 → 跳过（三元组显示缓存值，不归零不崩）。 */
    private suspend fun calibrateFromDaemon() {
        try {
            // PERF-01: 校准时刻顺手清 hash-cache 孤儿（跟随 MediaStore
            // 现存 _ID 集合；查询失败内部跳过，不影响校准）。
            pruneHashCache(context)
            val cached = withContext(Dispatchers.IO) { confirmedStore.load().confirmed }
            if (cached.isEmpty()) return
            withContext(Dispatchers.IO) { client.bind(identity.secretKey()) }
            val daemon = parsePeerAddrToken(pairing.daemonAddrToken)
            val missing = withContext(Dispatchers.IO) {
                BackupRunner(client).existCheck(daemon, cached)
            }
            if (missing.isNotEmpty()) {
                val lost = lostFromLibrary(cached, missing)
                // MOB-37: 落盘在 removeMissing **之前**（同 MOB-34 的理由：
                // 那一步之后交集恒空）。不发通知——见 reuploadNotice 注释。
                withContext(Dispatchers.IO) {
                    noteReuploadNotice(
                        reuploadNotice, lost, System.currentTimeMillis(), notify = {},
                    )
                }
                refreshReuploadNotice()
                withContext(Dispatchers.IO) {
                    // MOB-34: 登记定向补偿**必须在 removeMissing 之前**——
                    // 那一步会把指向这些 hash 的文件级记录一起删掉，之后
                    // 反查恒空、补偿永不发生（顺序是承重的）。
                    // 第二路见 reuploadTargetsOf：哈希缓存跨版本存活，
                    // 覆盖安装后存量条目只有它查得到。
                    enqueueReuploads(
                        confirmedStore.load(),
                        reuploads,
                        lost,
                        HashCache(hashCacheFile(context)),
                    )
                    confirmedStore.removeMissing(missing)
                }
                refreshTriplet()
            }
        } catch (_: Throwable) {
            // 不可达/未配对/超时——保留缓存值，下次再校准。
        }
    }

    /** MOB-37: 用户在 App 里点了「知道了」——告知消失。新一批 lost
     *  会重新登记、重新显示（acknowledge 只清当前这一批）。 */
    fun acknowledgeReuploadNotice() {
        scope.launch {
            withContext(Dispatchers.IO) { reuploadNotice.acknowledge() }
            refreshReuploadNotice()
        }
    }

    private fun refreshReuploadNotice() {
        scope.launch {
            _reuploadNoticeCount.value = withContext(Dispatchers.IO) {
                reuploadNoticeCountOf(reuploadNotice.load())
            }
        }
    }

    /** N=全量 count，M=确认缓存，K=N-M——随时可算（含断网/从未备份）。
     *  DOG-01d: 全链容错——媒体查询/缓存读取失败退化为「三元组不显示」
     *  （triplet=null），绝不崩 App（三星真机：countAll 启动即跑且异常
     *  未接住 → 启动必闪退）。 */
    private suspend fun refreshTriplet() {
        _triplet.value = withContext(Dispatchers.IO) {
            computeTripletSafe(
                context.contentResolver,
                confirmedStore,
                scopeStore.selectedBucketIds(),
            )
        }
    }

    /**
     * MOB-19 事件⑥：用户手点「立即备份」。
     *
     * 在此之前这里是**另一份**扫描+哈希+传输的实现（约 130 行），与
     * `BackupWorker` 并行存在。后果：MOB-09 的「一条坏记录不许炸整批」
     * 只修了 worker 那一份，这里照旧一条读不了就整批失败、永久卡死。
     *
     * 用户定稿（2026-08-20）："不是说应该自动和手动触发的备份一样吗？……
     * 手动就相当于第 5 种触发方式。你为什么这里弄了两条路径去做备份呢？"
     *
     * 所以现在这里只做一件事：**派活**。管线只有一条，手动与自动共用；
     * 手动专属的两个语义（零约束、全量重扫）在 [triggerManualBackup] 里
     * 靠 input data 表达，界面状态由 [observeBackupWork] 从这条 work 上读。
     */
    fun backupNow() {
        // UX-01: 进行中再点 = 暂停——取消这条 work。幂等管线保证安全：
        // 中断不 commit、水位不推进，已到家的 blob 下次去重跳过；再点
        // 一次 = 续传（重新 offer 全部候选，dedup 收敛缺 0）。
        // UX-13: 判据抽成纯函数（ui/BackupStatus.kt 的 isBackupRunning），
        // 与英雄区按钮的文案裁决共用同一份——「界面显示什么」和「点下去
        // 干什么」永远对得上。`Paused` 不算在跑，所以「继续」落到下面那条
        // triggerManualBackup（续传：重新 offer 全部候选，dedup 收敛缺 0）。
        val running = isBackupRunning(_state.value)
        if (running) {
            // MOB-33（2026-08-26 真机）：暂停是**管线级**动作，不是通道级。
            // 验收人定的原则：「传输只有一个路径，暂停也得在一个路径。上传
            // 不分自动手动，只有触发会区分。」——这与 MOB-19 的既有定调一致
            // （备份只有一条管线，手动是第 6 种触发方式）。
            //
            // 原来这里调 cancelManualBackup，只取消 MANUAL_BACKUP_WORK_NAME。
            // 而界面是按 tag 观察全部五条通道的，于是自动触发的备份也会显示
            // 进度条、也会出现暂停按钮，点下去**取消不了它**。
            // UX-13: 先记下「用户在这一刻按了暂停」，**再**取消 work——
            // 顺序是承重的：cancelWorkById 会很快让流吐出 CANCELLED 那一帧，
            // 标记要在那之前就位，否则那一帧算出的是 Idle（按钮消失一下再
            // 冒出来）。内存同步写，落盘异步（跨进程存活用）。
            pausedAt = System.currentTimeMillis()
            val stamp = pausedAt
            scope.launch {
                withContext(Dispatchers.IO) { runCatching { pausePrefs.setPausedAt(stamp) } }
            }
            val id = runningWorkId
            if (id != null) {
                WorkManager.getInstance(context).cancelWorkById(id)
            } else {
                // 兜底：拿不到 id（流还没送来第一帧）时退回按通道取消，
                // 至少手动那条能停。
                cancelManualBackup(context)
            }
            // ⚠️ 这里**不许**自己把状态置成 Idle。原来那句
            // `_state.value = BackupUiState.Idle` 让界面当场假装停了，而字节
            // 还在传——界面与传输脱钩。状态必须等 WorkManager 把 CANCELLED
            // 回报回来（此后 uiStateOf 按 pausedAt 与 work 真实状态合成出
            // BackupUiState.Paused —— UX-13；没有 pausedAt 的取消仍是 Idle）。
            return
        }
        triggerManualBackup(context)
    }

}

/**
 * DOG-01d: 三元组计算全链容错（refreshTriplet 的生产实现，测试共用——
 * DOG-01c 教训：语义测试走生产调用链）。媒体查询或缓存读取抛任何异常
 * → 返回 null（UI 不显示三元组），绝不崩 App。三星真机实锤：COUNT(*)
 * 投影被 provider 拒绝（Invalid column count(*)），refreshTriplet 启动
 * 即跑、异常未接住 → 启动必闪退。
 *
 * @param resolver 生产恒传 context.contentResolver；null 仅测试注入
 *  （JVM 单测无法实例化 android.jar 的 ContentResolver——构造即 Stub!，
 *  checkNotNull 抛的 IllegalArgumentException 与三星 provider 拒绝同型）。
 */
internal fun computeTripletSafe(
    resolver: ContentResolver?,
    store: ConfirmedStore,
    bucketIds: Set<Long>? = null,
): BackupTriplet? = try {
    // MOB-40 收尾：**没选过范围时三元组不显示。** `countAll(null)` 是全库口径，
    // 而 worker 现在一张都不传——两边一拼，状态条会走 `Pending(254)`，挂着一句
    // 「还有 254 张待备份」永不收敛。那是 MOB-40 要杀的同一类谎话。
    // 走 null（与 DOG-01d 的「查询失败 → 三元组不显示」同一个退化出口）：
    // 还没告诉我要备什么，我就报不出待备份张数。
    val scanner = MediaScanner(checkNotNull(resolver))
    if (bucketIds == null) {
        null
    } else {
        val n = scanner.countAll(bucketIds)
        // FIX-T6: M 必须按同一范围口径（范围外确认数不进 M），否则先全量
        // 备份再缩范围会显示「手机 10 张 · 已备份 51」。
        tripletOf(n, store.countInScope(bucketIds).toLong(), store.lastSuccessAt())
    }
} catch (_: Throwable) {
    null
}

/**
 * 配对失效判定（存储端移除/吊销本设备）：备份链路的 check 失败异常消息
 * 携带 daemon 的 msg_key——`err.not_paired`（设备行已删/从未配对）与
 * `err.not_authorized`（已吊销/角色不允）都意味着「配对关系已失效，
 * 需重新扫码」。其余错误（超时/磁盘满/网络）不算配对失效。
 *
 * 生产调用链：BackupUiStateHolder.backupNow 的 catch → 此函数。
 * 测试注入：直接构造含 msg_key 的异常消息。
 */
internal fun isPairingLostError(t: Throwable): Boolean {
    val msg = t.message ?: return false
    return msg.contains("err.not_paired") || msg.contains("err.not_authorized")
}

/**
 * MOB-19: work 状态 → 界面状态。**纯函数**，JVM 单测直接覆盖。
 *
 * 备份只有一条管线（`BackupWorker`），五种触发方式共用它。界面要显示的
 * 「找照片 / 读取 x/y / 正在备份 x/y / 都存好了 / 出错了」全部从这条 work
 * 的 progress 与 output 里读——**没有第二个状态源**，所以不会再出现
 * 「数据层对了但界面停在旧值」（MOB-21 那次的形状）。
 *
 * 返回 null = 这批 work 里没有可展示的信息（还没跑过 / 全是无关历史），
 * 调用方保持当前状态不动，绝不擅自改回 Idle（否则进度会闪回）。
 */
/**
 * MOB-33: 从 work 列表里挑出「当前正在跑的那一条」——**确定性的**。
 *
 * 原来是 `infos.firstOrNull { it.state == RUNNING }`。在**只有一条在跑**时它
 * 是对的；但备份有五条独立 unique name 的通道，两条同时 RUNNING 是可能的
 * （这正是 MOB-33 的本体），而 `getWorkInfosByTagFlow` **不保证按时间排序**
 * （Room 查询顺序，实际按 UUID）——于是 `firstOrNull` 在两条之间随机挑，
 * 每一帧挑的可能不是同一条，界面就在两轮进度之间来回跳。验收人看到的
 * 「正在读文件 → 长时间 pending → 又展示读文件 → 上传」就是这个。
 *
 * `backupInFlight` 那道门（BackupWorker）保证正常情况下只有一条在跑，这里
 * 是**第二道防线**：真出现多条时按 id 排序取第一条，保证同一批输入永远选出
 * 同一条，界面不闪。
 *
 * 暂停也用这个判据（[BackupUiStateHolder.backupNow] 取消它的 id），这样
 * 「界面在显示谁的进度」和「暂停会停掉谁」永远是同一条。
 */
internal fun runningInfoOf(infos: List<androidx.work.WorkInfo>): androidx.work.WorkInfo? =
    infos.filter { it.state == androidx.work.WorkInfo.State.RUNNING }
        .minByOrNull { it.id.toString() }

internal fun uiStateOf(
    infos: List<androidx.work.WorkInfo>,
    // UX-13: 用户按下暂停的时刻（0 = 没暂停过）。默认值让既有调用点不变。
    pausedAt: Long = 0L,
): BackupUiState? {
    // 正在跑的优先——那才是用户此刻该看到的。
    val runningNow = runningInfoOf(infos)
    runningNow?.let { running ->
        val p = running.progress
        val phase = p.getString(KEY_PHASE)
        val done = p.getInt(KEY_DONE, 0)
        val total = p.getInt(KEY_TOTAL, 0)
        return when (phase) {
            PHASE_SCANNING -> BackupUiState.Scanning(total)
            PHASE_HASHING -> BackupUiState.Hashing(done, total)
            PHASE_SENDING -> BackupUiState.Sending(done, total, p.getString(KEY_FILE) ?: "")
            // 已经在跑但还没发出第一条进度（绑定 daemon、校准阶段）——
            // 说「找照片」而不是沉默，用户点了按钮必须立刻有反应。
            else -> BackupUiState.Scanning(0)
        }
    }
    // 没有在跑的，看**最近**一条终态。ENQUEUED（等约束）不改状态行——
    // 手动触发是零约束不会排队；自动触发排队时界面另有「已排队」提示行。
    //
    // ⚠️ MOB-31（2026-08-21 真机）：这里原本是 `infos.lastOrNull { … }`，
    // 取的是**列表最后一个元素**。备份有五条通道（auto / catchup /
    // process-catchup / manual / media-watch），各自独立 unique name，
    // **终态记录会同时躺着最多五条**，而它们共用同一个 tag；
    // `getWorkInfosByTagFlow` **不保证按时间排序**（Room 查询顺序，实际
    // 按 UUID）。于是「拿最后一个」= 随机挑一条：用户刚同步完 12 张，
    // 界面报「186 张」——那是前一天那次全量运行留下的旧记录。
    //
    // 现在按 worker 盖的 [KEY_FINISHED_AT] 选最大值。没有戳的记录
    // （升级前的存量、CANCELLED 拿不到 outputData）视为最旧，只有在
    // **一条戳都没有**时才退回旧的列表顺序口径（升级首帧不至于空白）。
    // MOB-33: 排除**空转**那一轮（抢不到互斥门、什么也没干）。它按 MOB-31 的
    // 不变量盖了戳，但它不是一个结果——被选中就会显示「已备份 0 张」，还会盖过
    // 用户暂停留下的 CANCELLED（取消拿不到 outputData → 无戳 → 被当最旧）。
    val finished = infos.filter { it.state.isFinished }
        .filterNot { it.outputData.getBoolean(KEY_SKIPPED, false) }
    // UX-13: 「被用户暂停」是与 Idle 并列的独立态——先于终态选取裁决。
    // 判据（纯函数 pausedAfterOf）：没有在跑 + 用户按过暂停 + 这次暂停还没
    // 被后来跑完的运行覆盖。**刻意不看那条 CANCELLED 记录**：取消拿不到
    // outputData → 无戳 → 在按戳取最大的选取里恒被当上古记录，靠它判断
    // 「刚被暂停」永远不成立（本卡最容易踩的坑）。
    // newestFinishedAt 从**已排除空转轮**的 finished 里算——空转轮也盖戳
    // 且常紧跟暂停落地，不排除它就会把刚发生的暂停当成已被覆盖。
    val newestFinishedAt = finished
        .maxOfOrNull { it.outputData.getLong(KEY_FINISHED_AT, 0L) } ?: 0L
    if (pausedAfterOf(pausedAt, newestFinishedAt, anyRunning = runningNow != null)) {
        return BackupUiState.Paused
    }
    if (finished.isEmpty()) return null
    val stamped = finished.filter { it.outputData.getLong(KEY_FINISHED_AT, 0L) > 0L }
    val last = if (stamped.isEmpty()) {
        finished.last()
    } else {
        stamped.maxByOrNull { it.outputData.getLong(KEY_FINISHED_AT, 0L) }!!
    }
    return when {
        last.state == androidx.work.WorkInfo.State.FAILED ->
            BackupUiState.Trouble(last.outputData.getString(KEY_ERROR) ?: "")
        last.state == androidx.work.WorkInfo.State.CANCELLED -> BackupUiState.Idle
        // MOB-40: 两种「没东西可备」都不许落到下面的 AllSafe 分支——那会
        // 渲染成「照片都存好了」，对着一个还没选过相册的用户说这句是假话。
        // 文案共用（出路相同：去选相册），盖戳分开只为诊断。
        last.outputData.getBoolean(KEY_NO_ALBUMS, false) ||
            last.outputData.getBoolean(KEY_NO_SCOPE, false) -> BackupUiState.NoAlbums
        else -> BackupUiState.AllSafe(
            last.outputData.getInt(KEY_INGESTED, 0),
            last.outputData.getInt(KEY_DUPLICATES, 0),
        )
    }
}

/** 存储端移除/吊销本设备后备份被配对门拒——从错误串里认出来。
 *  与 [isPairingLostError] 同一套判据，只是这里拿到的是字符串
 *  （work 的 outputData 只能带基本类型，异常对象过不来）。 */
internal fun isPairingLostText(text: String): Boolean =
    text.contains("err.not_paired") || text.contains("err.not_authorized")
