// MOB-34（2026-08-25 真机回归）：库里删掉的**老**照片永远不会被重传。
//
// ## 断在哪
//
// MOB-29 定的语义是「重传是正确行为，不拦」，存储端那一半是对的（删掉的
// hash 在下一轮 manifest 里仍在 missing）。手机端这一半是断的：增量扫描
// **按水位只看新照片**，被删的老照片远在水位之下，永远不会被重新扫到 →
// 永远不进 manifest → 存储端一直报缺、手机压根不来问。同一个 bug 的另一面
// 是「待备份 K 永远归不了零」：校准把这些 hash 从 confirmed 里剔除（K 变大），
// 而它们永远不会被重新 offer。
//
// ## 补偿的形状：定向，不是全量
//
// 卡面硬约束：**只补「校准查出来缺的那些 hash」，不许退化成每轮全量重扫**
// （全量重扫在大库上是几分钟的活，不能变成常态）。
//
// 抓手是 MOB-13 加的**文件级**确认记录（`ConfirmedState.files`：
// fileKey = MediaStore uri 字符串 → hash）。校准算出 `lost` 之后、
// `removeMissing` 把这批记录抹掉**之前**，从 hash 反查出 fileKey 存进队列；
// 下一轮（或同一轮）备份按 fileKey 定向查回那几条 MediaStore 记录，塞进
// 候选，走同一条管线上传。commit 成功后 `recordRun` 把 hash 与文件级记录
// 一起写回 → K 归零。
//
// ⚠️ 顺序是承重的：`calibrateConfirmed` 先 `onLost` 再 `removeMissing`
// （Calibration.kt 的契约，CalibrationTest.notice_fires_before_the_cache_is_pruned
// 钉着）。反过来的话 files 表已经被清，反查恒空、补偿永不发生。
//
// ## 不许无限重试（别和 MOB-09 打架）
//
// 队列里的条目可能已经**没救**了：MediaStore 行本身消失（用户把手机上的
// 原图也删了——MOB-29 说的「正确删除姿势」）、或行还在但文件打不开（MOB-09
// 的坏记录）。两种都必须**丢掉队列条目**而不是每轮重试，否则「一条坏记录
// 卡死整批」的老坑换个门重现。清理三规则见 [planReuploads] 与 doWork 的调用点。
package com.hawkeyexb.ppass.backup

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * MOB-34: 从「校准查出来缺的 hash」反查「本地是哪几个 MediaStore 条目」。
 *
 * 必须在 [ConfirmedStore.removeMissing] **之前**调用——那一步会把指向这些
 * hash 的文件级记录一起删掉，之后反查恒空。
 *
 * 存量旧条目（MOB-13 之前备份的，没有文件级记录）反查不到 fileKey，定向
 * 补偿够不着它们——这是已知边界，**不为此加全量重扫**（卡面第 3 条）。
 */
internal fun reuploadTargetsOf(state: ConfirmedState, lost: Set<String>): Set<String> =
    state.files.filterValues { it.hash in lost }.keys.toSet()

/**
 * MOB-34: 两条校准路径共用的登记动作——BackupWorker 的
 * `calibrateIfReachable`（onLost 回调）与 BackupUiStateHolder 的
 * `calibrateFromDaemon`（App 打开时那次）。
 *
 * 少接一处 = 那条路径上的 hash 照样被剔除、永不补偿，bug 换个门重现。
 *
 * @return 实际登记的 fileKey（空集 = 这批 lost 全是存量旧条目，够不着）
 */
internal fun enqueueReuploads(
    state: ConfirmedState,
    queue: ReuploadQueue,
    lost: Set<String>,
): Set<String> {
    val targets = reuploadTargetsOf(state, lost)
    if (targets.isNotEmpty()) queue.add(targets)
    return targets
}

/** 队列内容（fileKey = MediaStore uri 字符串，与 [ConfirmedState.files] 同 key）。 */
@Serializable
internal data class ReuploadState(val keys: Set<String> = emptySet())

/**
 * MOB-34: 待定向补偿的 fileKey 队列。
 *
 * 落在 `backup-state/<remoteId>/` 里（与 confirmed.json 同目录）——断开配对
 * 时 [clearConfirmedCacheForRemote] 的 `deleteRecursively` 顺手把它清掉，
 * 清理语义免费拿到，不需要第二处逻辑。
 *
 * 崩溃安全落盘（tmp + rename，与 ConfirmedStore/BackupHealthPrefs 同款）。
 */
internal class ReuploadQueue(private val dir: File) {
    private val file = File(dir, "reupload-queue.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): Set<String> =
        if (file.isFile) {
            runCatching {
                json.decodeFromString(ReuploadState.serializer(), file.readText()).keys
            }.getOrDefault(emptySet())
        } else emptySet()

    /** 幂等：同一批 key 重复登记无副作用。 */
    fun add(keys: Set<String>) {
        if (keys.isEmpty()) return
        persist(load() + keys)
    }

    /** 处理完（传成功）/ 没救了（行没了、打不开）/ 不在范围内 → 丢掉。 */
    fun remove(keys: Set<String>) {
        if (keys.isEmpty()) return
        val cur = load()
        val next = cur - keys
        if (next.size != cur.size) persist(next)
    }

    private fun persist(keys: Set<String>) {
        dir.mkdirs()
        val tmp = File(dir, "reupload-queue.json.tmp")
        tmp.writeText(json.encodeToString(ReuploadState.serializer(), ReuploadState(keys)))
        check(tmp.renameTo(file)) { "cannot persist reupload queue" }
    }
}

/** MOB-34: 本轮要处理的条目 + 要从队列里丢掉的 key（见 [planReuploads]）。 */
internal data class ReuploadPlan<T>(val items: List<T>, val drop: Set<String>)

/**
 * MOB-34: 定向补偿的编排——**纯函数**，JVM 单测直接跑。
 *
 * @param pending 队列里登记的 fileKey
 * @param found 按 [pending] **定向**查回来的 MediaStore 条目（查不到的行天然
 *   不在里面）。定向的意思是查询只带这几个 _ID，不是全量重扫。
 * @param scanned 本轮增量扫描的结果（水位之上的新照片）
 * @param keyOf 条目 → fileKey（生产口径 = `item.uri.toString()`）
 * @param inScope 条目是否在当前备份范围内（用户缩过范围的相册不该被补回来）
 *
 * @return [ReuploadPlan.items] = 本轮真正要跑的条目：增量扫描结果 **+** 补偿
 *   条目（去重：已在扫描结果里的不重复添加——下游 `fileEntriesOf` 靠「文件
 *   列表与候选列表 1:1 同序」配 fileKey↔hash，重复项会让长度对不上而整体
 *   降级，K 又归不了零）；
 *   [ReuploadPlan.drop] = 没救了/不该管的 key：
 *   - 查无此行（用户把手机原图也删了 = MOB-29 说的「正确删除姿势」）；
 *   - 在范围外（用户缩过备份范围，那些照片已经不是我们的事）。
 *   打不开的行不在这里判——它们进得了 MediaStore 查询、死在
 *   `buildCandidates` 的探针上（MOB-09），由调用方按 `built.skipped` 丢。
 */
internal fun <T> planReuploads(
    pending: Set<String>,
    found: List<T>,
    scanned: List<T>,
    keyOf: (T) -> String,
    inScope: (T) -> Boolean,
): ReuploadPlan<T> {
    if (pending.isEmpty()) return ReuploadPlan(scanned, emptySet())
    val scannedKeys = scanned.mapTo(mutableSetOf()) { keyOf(it) }
    val usable = found.filter { inScope(it) }
    val extra = usable.filterNot { keyOf(it) in scannedKeys }
    val drop = pending - usable.mapTo(mutableSetOf()) { keyOf(it) }
    return ReuploadPlan(scanned + extra, drop)
}

/**
 * MOB-34: fileKey → MediaStore `_ID`（**纯字符串解析**，不碰 Android）。
 *
 * fileKey 的生产口径是 `content://media/external/{images,video}/media/<_ID>`
 * （`MediaItem.uri.toString()`）。定向查询要按 collection 分组，所以按前缀
 * 筛：只认「前缀 + `/` + 全数字」这一种形状，别的（格式漂移、别的 volume）
 * 一律不认——认错了就会去查一个不相干的 _ID，把无关照片重传上去。
 *
 * 反向重建（`ContentUris.withAppendedId` 后再 `toString`）必须与原 fileKey
 * **字符串全等**才算配上，那一步在 [MediaScanner.itemsByKeys] 里做。
 */
internal fun mediaIdsOf(keys: Set<String>, collectionPrefix: String): Set<Long> {
    val prefix = "$collectionPrefix/"
    return keys.mapNotNullTo(mutableSetOf()) { key ->
        if (!key.startsWith(prefix)) return@mapNotNullTo null
        key.removePrefix(prefix).takeIf { it.isNotEmpty() && it.all(Char::isDigit) }?.toLongOrNull()
    }
}
