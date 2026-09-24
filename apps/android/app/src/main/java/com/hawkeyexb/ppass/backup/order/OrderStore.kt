// ARCH-12 (#416) / ARCH-13 (#417) → #413 三层模型：
//   意图（相册范围、跳过名单、暂停标志）—— 只有用户操作写；范围在 BackupScopeStore，暂停在 FlowControl，跳过名单在这里。
//   事实（order：一次传输一行）—— 只有执行循环与对账写。
//   待办 —— 不存；现算 = 范围内照片 − 跳过名单 − 已有结局（见 FlowEngine 的计数）。
package com.hawkeyexb.ppass.backup.order

/**
 * 一条 order（一次传输）的状态。
 *
 * 持久化时存 [name]，所以**不许改名**；新增值要同步 SQLite 表的 CHECK 约束（并升 schema 版本）。
 * 没有「暂停」（暂停是全局意图，中断的那张保持 [TRANSFERRING]）、没有「版本已变」（旧版本记 [SKIPPED_SOURCE_MISSING]，
 * 新版本另起一行）、没有「因范围取消」（范围只作查询条件）。
 */
enum class OrderState {
    /** 待传输：桌面缺失的已确认照片补传新建的行、在飞时相册被移出范围的行、用户点「重试」的失败行。 */
    PENDING,

    /** 传输中。中断（暂停、FGS 被收、断网、进程被杀）后保持不变，下一轮按「遗留续传」最先取。 */
    TRANSFERRING,
    CONFIRMED,

    /** 单张失败。兜底对账重试到 [OrderStore.MAX_FAILURES] 次为止；之后保持失败，只有用户点「重试」再来。 */
    FAILED,

    /** 用户取消剩余时这一张正在传 / 待传（意图在跳过名单里，这里是事实）。 */
    SKIPPED_BY_USER,

    /** 原图没了，或这一行记的版本已经不存在（中断期间被编辑）。不计失败。 */
    SKIPPED_SOURCE_MISSING,
    ;

    /** 还没有结局、取消剩余可以覆盖的状态（首页的「未完成」也按它数）。 */
    val isOpen: Boolean
        get() = this == PENDING || this == TRANSFERRING || this == FAILED

    /** 对**同一版本**的照片来说已有结局：不再是待办。 */
    val isSettled: Boolean
        get() = this == CONFIRMED || this == SKIPPED_SOURCE_MISSING
}

/**
 * 一行 order（一次传输）。
 *
 * [id] 是 `INTEGER PRIMARY KEY AUTOINCREMENT`，永不复用，会被填进协议的 `queue_sequence`
 * （`lease_token` = `"lease-<id>"`，#417：线协议不改）。同一个 [mediaId] 可以有多行（编辑后的新版本、
 * 桌面缺失的补传都是新的一行、新的 queue_sequence——桌面对已完成的同编号直接回完成，不会重拉）；
 * 「当前」那一行是该 media_id 下 id 最大的那行。
 */
data class Order(
    val id: Long,
    val mediaId: Long,
    /** `sourceVersionOf(dateModified, size)` 的口径（MOB-98：generation 不进身份）。 */
    val sourceVersion: String,
    val bucketId: Long,
    /** BLAKE3 hex；导入之前为 null。 */
    val contentHash: String?,
    val state: OrderState,
    /** 失败次数（每记一次 FAILED 加 1；当场重试那一次不单独算）。 */
    val attempts: Int,
    /** 建这行时的配对代号（防护列，#415 裁决 6）。 */
    val pairingEpoch: String,
    val createdAtMs: Long,
    val updatedAtMs: Long,
    /**
     * #416 裁决 2：MediaStore 里已经没有这张的原图。CONFIRMED 不改写，只打这个标记。
     * #413 去掉了本地对账，循环不再写它；列与读口径保留给 UI 的 m。
     */
    val sourceMissing: Boolean = false,
)

/** 新建一行 order 的输入；id 与时间戳由存储分配。 */
data class NewOrder(
    val mediaId: Long,
    val sourceVersion: String,
    val bucketId: Long,
    val contentHash: String?,
    val state: OrderState,
    val pairingEpoch: String,
) {
    init {
        require(sourceVersion.isNotBlank()) { "sourceVersion must not be blank" }
        require(contentHash == null || contentHash.isNotBlank()) { "contentHash must be null or non-blank" }
    }
}

/** 「取消剩余」边界里的一张：MediaStore 里的一张照片（弹窗那一刻它还是待办）。 */
data class SkipTarget(
    val mediaId: Long,
    val sourceVersion: String,
    val bucketId: Long,
) {
    init {
        require(sourceVersion.isNotBlank()) { "sourceVersion must not be blank" }
    }
}

/** [OrderStore.cancelRemaining] 的结果：写进跳过名单几张、其中几张的在途 order 改成用户跳过、几张弹窗之后已有结局（未动）。 */
data class SkipResult(val written: Int, val ordersSkipped: Int, val untouched: Int)

/**
 * 每个 MediaStore 卷的元数据（#416 裁决 7：G 按卷分开存）。
 *
 * - [generation] / [generationMediaId]：发现游标 G = (generation, `_id`)。发现 = 按 (generation, `_id`) 排在 G
 *   之后的新照片；只有新照片（发现来源）提交或被发现跳过时推进。带上 `_id` 是因为同一次批量写入的多张照片
 *   generation 相同，只按 generation 推进会把同一拍里还没轮到的那几张一起跳过。
 * - [mediaStoreVersion]：上次看到的 `MediaStore.getVersion`；它一变（MediaStore 重建）就把 G 重置到当前最大
 *   generation、并把对账扫描置脏——已有的照片交给扫描，新照片仍然按 G。
 */
data class VolumeState(
    val volumeName: String,
    val generation: Long,
    val generationMediaId: Long,
    val mediaStoreVersion: String?,
)

/**
 * 与状态迁移同一次写入里推进 G：`G = max(G, (generation, mediaId))`（字典序），不动 [VolumeState.mediaStoreVersion]。
 * [mediaId] = [Long.MAX_VALUE] 表示「这个 generation 整个过去了」。
 */
data class GenerationAdvance(val volumeName: String, val generation: Long, val mediaId: Long = Long.MAX_VALUE)

/**
 * 对账扫描的游标 S（按 `_id` 升序，只读元数据）。[dirty] 时扫描才是取件来源：勾选新相册、恢复已跳过、
 * getVersion 变化、G 缺失时置脏并把 [cursor] 归 0；扫到末尾清脏。扫描来源提交时只推进 S，不推进 G。
 */
data class ScanState(val dirty: Boolean, val cursor: Long)

/**
 * AUDIT-01 的持久 outbox 事件。和它描述的事实**同一个事务**落库（见 [OrderStore.transition] 的 audit），
 * 由 AuditOutboxDispatcher 送给桌面、桌面确认后删除。
 */
data class AuditRecord(
    val eventId: String,
    val kind: String,
    val roundId: String? = null,
    val occurredAtMs: Long,
    val payload: Map<String, String> = emptyMap(),
)

/**
 * order 存储 + 跳过名单。所有写操作各自是一个事务：要么全部生效，要么一条都不生效。
 */
interface OrderStore {
    /** 插入一行，返回带 id 与时间戳的完整行。[advance] / [scanTo] / [audit] 与插入同一事务。 */
    fun insert(order: NewOrder, advance: GenerationAdvance? = null, scanTo: Long? = null, audit: AuditRecord? = null): Order

    fun get(id: Long): Order?

    /** 该 media_id 当前的那一行（id 最大）；没有则 null。 */
    fun currentForMedia(mediaId: Long): Order?

    /**
     * 按 media_id 严格升序流式读出每个 media_id 当前的那一行。
     *
     * 流只在 [block] 内有效（游标在返回前关闭），不许把 Sequence 带出去。实现按页读，不会一次把整张表读进内存。
     */
    fun <R> readCurrentOrders(block: (Sequence<Order>) -> R): R

    /** 当前行里状态属于 [states]、id > [afterId] 的，按 id 升序，最多 [limit] 条（取件用）。 */
    fun currentInStates(states: Set<OrderState>, afterId: Long = 0L, limit: Int = Int.MAX_VALUE): List<Order>

    /** 当前行里 CONFIRMED、有 hash、id > [afterId] 的，按 id 升序（分页问桌面用）。 */
    fun confirmedWithHashAfter(afterId: Long, limit: Int): List<Order>

    /**
     * 比较并转换：只有当前状态在 [expected] 里时才改成 [to]，单事务。
     * [countAttempt] 为 true 时 attempts 同一事务内加 1；[contentHash] 非空时同一事务写上（行里还没有 hash 时）；
     * [advance] / [scanTo] / [audit] 也在同一事务里（#415 裁决 8：结局与游标推进同一次写入）。
     * 返回是否真的改了——没改时其余一条都不写。
     */
    fun transition(
        id: Long,
        expected: Set<OrderState>,
        to: OrderState,
        countAttempt: Boolean = false,
        contentHash: String? = null,
        advance: GenerationAdvance? = null,
        scanTo: Long? = null,
        audit: AuditRecord? = null,
    ): Boolean

    /** #416 裁决 2：打 / 清 `source_missing` 标记。返回是否找到该行。 */
    fun setSourceMissing(id: Long, missing: Boolean, audit: AuditRecord? = null): Boolean

    // ---------------------------------------------------------------- 意图：跳过名单

    /** 这张照片在跳过名单里吗。 */
    fun isSkipped(mediaId: Long): Boolean

    /** 跳过名单按 media_id 严格升序流式读出。流只在 [block] 内有效。 */
    fun <R> readSkipList(block: (Sequence<Long>) -> R): R

    /** 跳过名单的张数；[bucketIds] 非 null 时只数这些相册里的（按跳过时记下的相册）。 */
    fun countSkipped(bucketIds: Set<Long>? = null): Long

    /**
     * 「取消剩余 N 张」：**一个事务**把 [targets]（弹窗那一刻的边界）写进跳过名单，它们当前行里还没结局的
     * （待传输 / 传输中 / 失败）改成 SKIPPED_BY_USER。弹窗之后这一张已经有了同版本的结局 → 不动。
     * 任何一项失败，整批回滚。[audit] 与整批同一事务。
     */
    fun cancelRemaining(targets: List<SkipTarget>, audit: AuditRecord? = null): SkipResult

    /**
     * 「已跳过的照片 · 点击恢复」：一个事务清空跳过名单并把对账扫描置脏（S 归 0）——这些照片在 G 以下，
     * 只有扫描取得到。返回恢复了几张。order 表不动（SKIPPED_BY_USER 行是历史事实）。
     */
    fun restoreSkipped(audit: AuditRecord? = null): Int

    // ---------------------------------------------------------------- 游标

    fun volumeState(volumeName: String): VolumeState?

    fun saveVolumeState(state: VolumeState)

    /** 只推进 G（发现跳过了不需要动作的新照片，批量合并写）。 */
    fun advanceGeneration(advance: GenerationAdvance)

    fun scanState(): ScanState

    /** 置脏并把 S 归 0。 */
    fun markScanDirty()

    /** 只推进 S（扫描跳过了不需要动作的照片，批量合并写）：`S = max(S, cursor)`。 */
    fun advanceScan(cursor: Long)

    /** 扫到末尾：清脏、S 归 0。 */
    fun finishScan()

    /** 用户点「重试」：当前行里所有 FAILED 改回 PENDING（失败次数保留）。返回改了几行。 */
    fun retryFailed(audit: AuditRecord? = null): Int

    // ---------------------------------------------------------------- UI 读口径

    /**
     * UI 投影：当前行按状态计数；[bucketIds] 非 null 时只数这些相册里的。
     *
     * #413：[OrderState.SKIPPED_BY_USER] 这一项报的是**跳过名单**的张数（意图），不是 order 行数——没有传过的照片
     * 被跳过时只进名单、不建 order；恢复之后名单清空，历史的 SKIPPED_BY_USER 行也就不再算「已跳过」。
     */
    fun countCurrentByState(bucketIds: Set<Long>? = null): Map<OrderState, Long>

    /** #418 英雄区的 m：当前行为 CONFIRMED、且原图还在手机上（`source_missing` = 0）的张数。 */
    fun countConfirmedPresent(bucketIds: Set<Long>? = null): Long

    /** 当前行里 CONFIRMED 的最近一次 updated_at（0 = 一张都没有）。 */
    fun lastConfirmedAtMs(): Long

    /** 当前行里 SKIPPED_SOURCE_MISSING、updated_at 在 (after, upTo] 之间的张数（提示横幅的水位线用）。 */
    fun countSourceMissingSkipped(afterMs: Long, upToMs: Long = Long.MAX_VALUE): Long

    // ---------------------------------------------------------------- 审计

    /** 追加一条审计（不伴随状态迁移的事实，例如 `unrecoverable`）。 */
    fun appendAudit(audit: AuditRecord)

    fun pendingAudit(limit: Int): List<AuditRecord>

    fun acknowledgeAudit(eventIds: Set<String>)

    /**
     * 换桌面（#415 裁决 6）：[ownerKey]（daemonNodeId）与库里记着的不一样时，清空 order、卷游标、扫描游标与
     * 审计 outbox，并把新 id 的起点抬到 [idFloor] 之上。返回是否清了。
     * **跳过名单保留**：它是用户意图，与哪台桌面无关（#413 裁定 9，待用户最终确认）。清库后扫描置脏。
     *
     * 为什么要抬 id 起点：桌面的 `flow_delivery` 按 `(node_id, pairing_epoch, queue_sequence)` 记账，
     * 已完成的行不会被覆盖。order id 若从 1 开始，就会撞上旧账本早已 completed 的那些行（不同 hash），offer 被拒。
     */
    fun claimOwner(ownerKey: String, idFloor: Long): Boolean

    companion object {
        /** 同一行最多失败几次（当场重试 1 次 + 兜底对账 1 次，#413 裁定 6）；到了之后保持失败。 */
        const val MAX_FAILURES = 2
    }
}
