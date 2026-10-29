// MOB-95（#282）：断开时「什么留什么清」的**唯一落点**。
//
// 以前是三张卡各自决定、结果堆在 `clearLocalPairing` 里的一串语句；MOB-93
// 的回归就出在有人在别处单独决定了，看不见那串语句依赖的前提。现在：
//
// - 手机侧每一样持久状态（files/、shared_prefs/、databases/ 下的东西）和
//   每一个断开时要停的运行时生产者，都在 [DisconnectState] 里登记一行：
//   处置 + 依据（卡号）。
// - 断开只做一件事：[applyDisconnectManifest] 按清单逐行执行。改某一行的
//   处置，行为跟着变；不存在清单之外的断开动作。
// - 新增持久状态不登记会被门禁挡下（DisconnectStateManifestTest：编译产物
//   扫描 + 真实文件往返后遍历目录）。
//
// 依据写 [UNDECIDED] 的行：现行为就是「不碰」，但没有任何卡或注释定过它
// 断开时该留还是该清——保持现状登记在这里，等拍板，不在代码里替人决定。
package com.hawkeyexb.ppass.backup

import java.io.File

/** 断开时对一样状态的处置。 */
enum class DisconnectDisposition {
    /** 不碰，断开后原样留着。 */
    KEEP,

    /** 删掉（只允许 [StateLocation.FILES] / [StateLocation.CACHE]：shared_prefs / databases 在进程里有活的句柄，不能从文件层删）。 */
    CLEAR,

    /** 文件留着，但改写其中一部分（逐项实现见 [applyDisconnectManifest]）。 */
    RESET,

    /** 运行时生产者：停掉（只允许 [StateLocation.RUNTIME]）。 */
    STOP,

    /** 已退役：生产代码里既无写者也无读者。断开不处理——老版本留下的文件无人读，删不删都不影响行为。 */
    RETIRED,
}

/** 状态落在 App 私有目录的哪一处；RUNTIME = 不落盘，只在进程 / 系统调度里。 */
enum class StateLocation(val dirName: String?) {
    FILES("files"),
    SHARED_PREFS("shared_prefs"),
    DATABASES("databases"),

    /** `Context.cacheDir`（App 数据目录下的 `cache/`）。#1119：原图缓存在这里。 */
    CACHE("cache"),
    RUNTIME(null),
}

/** 依据前缀：没有卡或代码注释定过语义，现状保留、待拍板。 */
const val UNDECIDED = "待拍板"

private const val ID = "<id>"

/**
 * 断开时的状态清单。**声明顺序就是执行顺序**（配对凭据最先作废，与原
 * `clearLocalPairing` 的次序一致）。
 *
 * [path] 相对 [location] 的根目录；`<id>` 匹配一段任意名字（daemonNodeId）。
 * 一行同时覆盖该路径下的所有子项，以及以 `.` / `-` 接续的同名伴生文件
 * （`x.json.tmp`、`flow-control.json.<n>.tmp`、`backup-orders.db-wal` ……）。
 *
 * [owners] 是负责读写它的类（门禁用它对账编译产物里的每一个 store 类）。
 */
enum class DisconnectState(
    val location: StateLocation,
    val path: String,
    val disposition: DisconnectDisposition,
    val basis: String,
    val owners: List<String> = emptyList(),
    val workNames: List<String> = emptyList(),
) {
    // ── 配对凭据 ───────────────────────────────────────────────
    PAIRING(
        StateLocation.FILES, "pairing.json", DisconnectDisposition.CLEAR,
        "UX-06/UX-06b：本地单方断开，令牌作废（#282 清单「配对记录」）",
        owners = listOf("com.hawkeyexb.ppass.transport.PairingStore"),
    ),

    // ── 运行时生产者 ───────────────────────────────────────────
    FLOW_RUNTIME(
        StateLocation.RUNTIME, "flow-runtime", DisconnectDisposition.STOP,
        "#264/MOB-91：同一 NodeId 重连不许复活旧的运行时；原生仓库只 revoke 不 close",
    ),

    AUTO_BACKUP_PREFS(
        StateLocation.FILES, "auto_backup_prefs.json", DisconnectDisposition.RESET,
        "MOB-93（#275/#279）：停生产者（autoEnabled=false），留意图（userRequested）；换新电脑由 onboarding 入口清意图",
        owners = listOf("com.hawkeyexb.ppass.backup.AutoBackupPrefs"),
    ),
    AUTO_BACKUP_WORKS(
        StateLocation.RUNTIME, "work", DisconnectDisposition.STOP,
        "MOB-93：停生产者（周期 / 前台补捞 / 进程补捞 / 手动 四条 unique work）",
        workNames = listOf(BACKUP_WORK_NAME, CATCHUP_WORK_NAME, PROCESS_CATCHUP_WORK_NAME, MANUAL_BACKUP_WORK_NAME),
    ),
    OTHER_WORKS(
        StateLocation.RUNTIME, "work", DisconnectDisposition.STOP,
        "#1119：断开取消全部相关后台任务——约束唤醒、相册变更触发的单次备份（原先「待拍板」，断开从来没取消过）",
        workNames = listOf(CONSTRAINT_WAKE_WORK_NAME, MEDIA_WATCH_BACKUP_WORK_NAME),
    ),
    ENGINE_WAKE_WORKS(
        StateLocation.RUNTIME, "work", DisconnectDisposition.STOP,
        "#1119：引擎登记的唤醒——探测梯、额度复位唤醒、续传哨兵；没有配对就没有东西可传，不许留着空转",
        workNames = listOf(UNREACHABLE_PROBE_LADDER_WORK_NAME, BUDGET_RESET_WAKE_WORK_NAME, RESUME_SENTINEL_WORK_NAME),
    ),
    MEDIA_WATCH_JOB(
        StateLocation.RUNTIME, "media-watch-job", DisconnectDisposition.STOP,
        "MOB-27/MOB-93：相册变更监听（JobScheduler）是生产者，断开停掉",
    ),

    // ── 缓存（cacheDir）：#1119 断开清掉这台电脑的原图 ──────────────
    ORIGINAL_VIDEO_CACHE(
        StateLocation.CACHE, "video-$ID", DisconnectDisposition.CLEAR,
        "#1119：视频原片缓存 video-<hash>.mp4 及下载中的 .part——来自这台电脑的内容，断开后不许留在手机上",
    ),
    SHARE_CACHE(
        StateLocation.CACHE, "share", DisconnectDisposition.CLEAR,
        "#1119：「分享 / 用其他应用打开」的临时原图（cacheDir/share/）",
    ),
    PREVIEW_MEMORY_CACHE(
        StateLocation.RUNTIME, "preview-memory-cache", DisconnectDisposition.STOP,
        "#1119：内存里的小图缓存（全 App 唯一的 LruCache）；不落盘，但同样是这台电脑的内容，断开清空",
    ),
    UPDATE_ARTIFACTS(
        StateLocation.CACHE, "update", DisconnectDisposition.KEEP,
        "#719：App 自身的更新下载产物（cacheDir/update/），与配对无关，生命周期由更新线自己管",
    ),

    // ── 留：跨配对仍然成立的事实 ────────────────────────────────
    IDENTITY(
        StateLocation.FILES, "identity.sealed", DisconnectDisposition.KEEP,
        "红线：密钥就是这台设备（#282 清单「身份」）；#1106 起只以 Keystore 加密形态落盘",
        owners = listOf("com.hawkeyexb.ppass.transport.IdentityStore"),
    ),
    IDENTITY_RETIRED_PLAINTEXT(
        StateLocation.FILES, "identity.key", DisconnectDisposition.CLEAR,
        "#1106：旧版明文身份是退役密钥，不迁移、只销毁（IdentityStore 换新身份时最后一步删；断开也删，对位 iOS）",
        owners = listOf("com.hawkeyexb.ppass.transport.IdentityStore"),
    ),
    ONBOARDED_DESKTOPS(
        StateLocation.FILES, "onboarded_desktops.json", DisconnectDisposition.KEEP,
        "MOB-114（#455/#461）：「连过这台」必须活过断开、配对失效、换台再换回来；只增不减",
        owners = listOf("com.hawkeyexb.ppass.backup.OnboardedDesktopsStore"),
    ),
    BACKUP_SCOPE(
        StateLocation.SHARED_PREFS, "backup_scope-$ID.xml", DisconnectDisposition.KEEP,
        "MOB-92（#266）：相册范围按桌面分，断开不清",
        owners = listOf("com.hawkeyexb.ppass.backup.BackupScopeStore"),
    ),
    BACKUP_SCOPE_LEGACY(
        StateLocation.SHARED_PREFS, "backup_scope.xml", DisconnectDisposition.KEEP,
        "MOB-92（#266）：老的全局范围，一次性认领的来源（adopted_by 记认领者），断开不碰",
        owners = listOf("com.hawkeyexb.ppass.backup.BackupScopeStore"),
    ),
    BACKUP_SETTINGS(
        StateLocation.FILES, "backup-settings.json", DisconnectDisposition.KEEP,
        "#282 验收 4：Wi-Fi / 充电设置仍保留",
        owners = listOf("com.hawkeyexb.ppass.backup.BackupSettings"),
    ),
    ORDER_DB(
        StateLocation.DATABASES, "backup-orders.db", DisconnectDisposition.KEEP,
        "#413/#415 裁决 6：连回同一台桌面 CONFIRMED 仍有效；换一台桌面由 OrderStore.claimOwner 清（#282 验收 4「账本仍保留」）",
        owners = listOf("com.hawkeyexb.ppass.backup.order.SqliteOrderStore"),
    ),
    NATIVE_BLOB_STORE(
        StateLocation.FILES, "iroh-blobs-provider", DisconnectDisposition.KEEP,
        "MOB-91：原生内容仓库进程内开一次永不关，断开只 revoke，仓库本身不动",
        owners = listOf("com.hawkeyexb.ppass.backup.flow.AndroidNativeIrohBlobsProvider"),
    ),
    FLOW_MIGRATION_MARKER(
        StateLocation.FILES, "flow-migrated-arch13", DisconnectDisposition.KEEP,
        "#413：migrateLegacyFlowState 只做一次（marker 文件）",
    ),
    ONBOARDING_NOTIFICATION_ASK(
        StateLocation.FILES, "onboarding_notification_ask.json", DisconnectDisposition.RETIRED,
        "#130 遗留：onboarding 只问一次通知的标记；#1262 起 onboarding 不再申请通知，已无读写者，升级上来的机器上留着不动",
    ),
    BACKGROUND_BACKUP_OFFER(
        StateLocation.FILES, "background_backup_offer.json", DisconnectDisposition.KEEP,
        "#1263：首页「开启后台备份」卡片被用户手动关掉——是对这台手机的偏好，与连哪台电脑无关",
        owners = listOf("com.hawkeyexb.ppass.backup.BackgroundBackupOfferStore"),
    ),
    WORK_MANAGER_DB(
        StateLocation.DATABASES, "androidx.work.workdb", DisconnectDisposition.KEEP,
        "WorkManager 库自有；断开只经由 AUTO_BACKUP_WORKS 取消 unique work，不动库文件",
    ),

    // ── 留（现状）：没有依据，待拍板 ────────────────────────────
    FLOW_CONTROL(
        StateLocation.FILES, "flow-control.json", DisconnectDisposition.KEEP,
        "$UNDECIDED：暂停标志 / 等待原因 / FGS 受阻原因（#413），断开从来没碰过",
        owners = listOf("com.hawkeyexb.ppass.backup.flow.FlowControlStore"),
    ),
    NOTIFY_ON_FAILURE_PREFS(
        StateLocation.FILES, "notify_on_failure_prefs.json", DisconnectDisposition.KEEP,
        "$UNDECIDED：设置页「需要处理时通知我」开关（M10/#130），断开从来没碰过",
        owners = listOf("com.hawkeyexb.ppass.backup.NotifyOnFailurePrefs"),
    ),
    UPDATE_PREFS(
        StateLocation.FILES, "update_prefs.json", DisconnectDisposition.KEEP,
        "$UNDECIDED：更新节流门（6h）/ 升级回执 / 待办更新（UPD-02 #624 新引入，卡面无断开语义）；" +
            "它是 App 自身更新的记账，与配对无关，断开从来没碰过",
        owners = listOf("com.hawkeyexb.ppass.update.UpdatePrefs"),
    ),
    BACKUP_HEALTH(
        StateLocation.FILES, "backup_health.json", DisconnectDisposition.KEEP,
        "$UNDECIDED：监听中断待确认（MOB-28），断开从来没碰过",
        owners = listOf("com.hawkeyexb.ppass.backup.BackupHealthPrefs"),
    ),
    SENTINEL(
        StateLocation.FILES, "sentinel.json", DisconnectDisposition.KEEP,
        "$UNDECIDED：「失联 N 天」的上次可达时间（SENT-01 遗留），断开从来没碰过",
        owners = listOf("com.hawkeyexb.ppass.backup.SentinelStore"),
    ),
    DEFINITIVE_NOTICES(
        StateLocation.FILES, "definitive_notices.json", DisconnectDisposition.KEEP,
        "$UNDECIDED：三类确定事件通知的去重状态（#130），断开从来没碰过",
        owners = listOf("com.hawkeyexb.ppass.backup.DefinitiveNoticeStore"),
    ),

    // ── 已退役：生产代码无写者、无读者 ──────────────────────────
    LEGACY_BACKUP_STATE(
        StateLocation.FILES, "backup-state/$ID", DisconnectDisposition.RETIRED,
        "REBUILD-00/UI-09：确认缓存 confirmed.json 与同目录的 reupload-queue / pause_state / run_start / reupload_notice；" +
            "整条旧批量管线已无生产调用方（#282）。原先断开时 deleteRecursively，已删",
        owners = listOf(
            "com.hawkeyexb.ppass.backup.ConfirmedStore",
            "com.hawkeyexb.ppass.backup.ReuploadQueue",
            "com.hawkeyexb.ppass.backup.PausePrefs",
            "com.hawkeyexb.ppass.backup.RunStartPrefs",
            "com.hawkeyexb.ppass.backup.ReuploadNoticePrefs",
        ),
    ),
    LEGACY_WATERMARK(
        StateLocation.FILES, "backup.watermark", DisconnectDisposition.RETIRED,
        "REBUILD-05：legacy watermark，load() 无生产调用方（#282）。原先断开时 save(0)，已删",
        owners = listOf("com.hawkeyexb.ppass.backup.WatermarkStore"),
    ),
    LEGACY_HASH_CACHE(
        StateLocation.FILES, "hash-cache.json", DisconnectDisposition.RETIRED,
        "PERF-01：只剩旧管线（ScopeBackfill/ReuploadQueue）在用；文件头本就写明断开不清",
        owners = listOf("com.hawkeyexb.ppass.backup.HashCache"),
    ),
    LEGACY_BACKUP_ATTEMPT(
        StateLocation.FILES, "backup-attempt.txt", DisconnectDisposition.RETIRED,
        "MOB-02 §五：失败重试计数，生产代码无构造点",
        owners = listOf("com.hawkeyexb.ppass.backup.BackupAttemptStore"),
    ),
    LEGACY_WHITELIST_NUDGE(
        StateLocation.FILES, "whitelist-nudge.json", DisconnectDisposition.RETIRED,
        "DOG-02b：电池白名单契机提醒，生产代码无构造点",
        owners = listOf("com.hawkeyexb.ppass.backup.WhitelistNudgeStore"),
    ),
    LEGACY_FLOW_LEDGER(
        StateLocation.FILES, "flow-state", DisconnectDisposition.RETIRED,
        "#413：旧 Flow 账本，migrateLegacyFlowState 一次性删掉",
    ),
    LEGACY_TRANSFER_PROTECTION(
        StateLocation.FILES, "flow-transfer-protection.json", DisconnectDisposition.RETIRED,
        "#413：旧前台保护状态，migrateLegacyFlowState 一次性删掉",
    ),
    ;

    private val regex: Regex = Regex(
        "^" + path.split(ID).joinToString("[^/]+") { Regex.escape(it) } + "([/.\\-].*)?$",
    )

    /** [rel] 是相对 [location] 根目录、以 `/` 分隔的路径。 */
    fun matches(rel: String): Boolean = regex.matches(rel)
}

/** 断开时要停的、不落盘的东西——生产里由 Context 实现，JVM 测试里记账。 */
interface DisconnectRuntime {
    fun stopFlowRuntime()
    fun cancelUniqueWork(name: String)
    fun cancelMediaWatch()

    /** #1119：清空内存里的小图缓存。 */
    fun clearPreviewCache()
}

/**
 * 断开（UX-06/UX-06b）与「配对已失效重新扫码」共用的清理：按 [DisconnectState]
 * 逐行执行，不依赖 daemon 是否可达 / 是否已撤销本设备。
 *
 * [filesDir] 的父目录即 App 数据目录（`shared_prefs/`、`databases/` 与它平级）；[cacheDir] 是 `Context.cacheDir`（#1119）。
 */
fun applyDisconnectManifest(
    filesDir: File,
    cacheDir: File,
    runtime: DisconnectRuntime,
    manifest: List<DisconnectState> = DisconnectState.entries,
) {
    // #1039（对位 iOS #974）：某一行失败（写盘 / 删文件出错）不短路后面的行——停任务、停监听、停 Flow 必须照常执行，
    // 否则「偏好写不进去」会连带让旧配对的后台生产者继续跑。全部跑完后抛出第一个错误，不吞，由调用方记日志。
    var firstError: Exception? = null
    for (state in manifest) {
        try {
            applyDisconnectRow(filesDir, cacheDir, runtime, state)
        } catch (e: Exception) {
            if (firstError == null) firstError = e else firstError.addSuppressed(e)
        }
    }
    firstError?.let { throw it }
}

private fun applyDisconnectRow(filesDir: File, cacheDir: File, runtime: DisconnectRuntime, state: DisconnectState) {
    when (state.disposition) {
        DisconnectDisposition.KEEP, DisconnectDisposition.RETIRED -> Unit
        DisconnectDisposition.CLEAR -> {
            val root = when (state.location) {
                StateLocation.FILES -> filesDir
                StateLocation.CACHE -> cacheDir
                else -> error("$state: CLEAR only supported under files/ and cache/")
            }
            deleteMatching(root, "", state)
        }
        DisconnectDisposition.RESET -> when (state) {
            // MOB-93：停生产者，**留意图**（换新电脑时由 onboarding 入口清意图）。
            DisconnectState.AUTO_BACKUP_PREFS -> suspendAutoBackupForPairingChange(filesDir)
            else -> error("$state: no RESET action defined")
        }
        DisconnectDisposition.STOP -> {
            check(state.location == StateLocation.RUNTIME) { "$state: STOP only applies to runtime producers" }
            when (state) {
                DisconnectState.FLOW_RUNTIME -> runtime.stopFlowRuntime()
                DisconnectState.MEDIA_WATCH_JOB -> runtime.cancelMediaWatch()
                DisconnectState.PREVIEW_MEMORY_CACHE -> runtime.clearPreviewCache()
                else -> {
                    check(state.workNames.isNotEmpty()) { "$state: no STOP action defined" }
                    state.workNames.forEach(runtime::cancelUniqueWork)
                }
            }
        }
    }
}

/** 删掉 [dir] 下匹配 [state] 的路径（含伴生文件）；路径带子目录（如 `a/<id>`）时逐层下钻。 */
private fun deleteMatching(dir: File, prefix: String, state: DisconnectState) {
    for (child in dir.listFiles().orEmpty()) {
        val rel = prefix + child.name
        if (state.matches(rel)) {
            child.deleteRecursively()
        } else if (child.isDirectory && state.path.count { it == '/' } > prefix.count { it == '/' }) {
            // 只下钻到清单路径的深度——不去遍历内容仓库之类的大目录。
            deleteMatching(child, "$rel/", state)
        }
    }
}

/**
 * 登记门禁的运行时一半：[dataDir]（App 数据目录）下 files/、shared_prefs/、
 * databases/ 里**不属于任何一行清单**的路径。已登记路径不再下钻（内容仓库
 * 可能有成千上万个文件）；未登记的空目录也算。
 */
fun unregisteredStatePaths(dataDir: File, manifest: List<DisconnectState> = DisconnectState.entries): List<String> {
    val out = mutableListOf<String>()
    for (location in StateLocation.entries) {
        val name = location.dirName ?: continue
        val root = File(dataDir, name)
        if (!root.isDirectory) continue
        val rows = manifest.filter { it.location == location }
        fun walk(dir: File, prefix: String) {
            val children = dir.listFiles().orEmpty()
            if (children.isEmpty() && prefix.isNotEmpty()) out += "$name/${prefix.removeSuffix("/")}"
            for (child in children.sortedBy { it.name }) {
                val rel = prefix + child.name
                when {
                    rows.any { it.matches(rel) } -> Unit
                    child.isDirectory -> walk(child, "$rel/")
                    else -> out += "$name/$rel"
                }
            }
        }
        walk(root, "")
    }
    return out
}
