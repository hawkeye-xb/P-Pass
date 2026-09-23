// ARCH-12 (#416) / ARCH-13 (#417): order 存储——#413 逐张循环模型里「对哪张照片做过决定」的唯一证据。
package com.hawkeyexb.ppass.backup.order

/**
 * 一条 order 的状态。前三个是「还在路上」，其余都是这张照片的结局（#413「每张照片都有一个结局」）。
 *
 * 持久化时存 [name]，所以**不许改名**；新增值要同步 SQLite 表的 CHECK 约束（并升 schema 版本）。
 */
enum class OrderState {
    /** 正在传。进程重启后遗留的 TRANSFERRING 会被降回 [PAUSED]。 */
    TRANSFERRING,

    /** 传到一半停下（暂停、路径失败、条件不满足）；取件顺序 ①，续传。 */
    PAUSED,

    /**
     * #417：慢路径标出来要（重新）传的——快路径漏掉的新照片、桌面缺失的补传、FAILED 的重试、
     * 相册重新纳入范围 / 原图重新出现的照片。取件顺序 ②。
     */
    QUEUED,
    CONFIRMED,
    FAILED,
    SKIPPED_BY_USER,
    SKIPPED_SOURCE_MISSING,
    CANCELLED_BY_SCOPE,
    ;

    /**
     * 用户明确做过、且长期有效的决定：差集规划对它们不产出待传（#413：SKIPPED_BY_USER 这类不补传）。
     *
     * #415 裁决 5：CANCELLED_BY_SCOPE **不是**长期决定——所在相册重新纳入范围后重新变为可传，
     * 所以它不在这里。
     */
    val isUserDecided: Boolean
        get() = this == SKIPPED_BY_USER

    /** 还没有结局、批量跳过可以覆盖的状态。FAILED 会被兜底重试一次，所以也算未完结（#415 裁决 7）。 */
    val isOpen: Boolean
        get() = this == TRANSFERRING || this == PAUSED || this == QUEUED || this == FAILED
}

/**
 * 一行 order。
 *
 * [id] 是 `INTEGER PRIMARY KEY AUTOINCREMENT`，永不复用，会被填进协议的 `queue_sequence`
 * （`lease_token` = `"lease-<id>"`，#417：线协议不改）。
 * 同一个 [mediaId] 可以有多行（编辑后的新内容是新的一行、新的 queue_sequence）；
 * 「当前」那一行是该 media_id 下 id 最大的那行，见 [OrderStore.readCurrentOrders]。
 */
data class Order(
    val id: Long,
    val mediaId: Long,
    /** `sourceVersionOf(dateModified, size)` 的口径（MOB-98：generation 不进身份）。 */
    val sourceVersion: String,
    val bucketId: Long,
    /** BLAKE3 hex；批量跳过时还没算过 hash 的行为 null。 */
    val contentHash: String?,
    val state: OrderState,
    val attempts: Int,
    /** 建这行时的配对代号（防护列，#415 裁决 6）。 */
    val pairingEpoch: String,
    val createdAtMs: Long,
    val updatedAtMs: Long,
    /**
     * #416 裁决 2：MediaStore 里已经没有这张的原图。CONFIRMED 不改写（「CONFIRMED 不可否定」），
     * 只打这个标记；原图重新出现时清掉。
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

/** 批量跳过的一项：MediaStore 里的一张照片。还没有 order 的会被插入一行 SKIPPED_BY_USER。 */
data class SkipTarget(
    val mediaId: Long,
    val sourceVersion: String,
    val bucketId: Long,
    val contentHash: String? = null,
) {
    init {
        require(sourceVersion.isNotBlank()) { "sourceVersion must not be blank" }
    }
}

/** [OrderStore.skipByUser] 的结果：插入几行、改了几行、几张本来就有结局（未动）。 */
data class SkipResult(val inserted: Int, val updated: Int, val untouched: Int) {
    /** 这一次真正落成 SKIPPED_BY_USER 的张数（「取消剩余 N 张」里的 N）。 */
    val written: Int get() = inserted + updated
}

/**
 * 每个 MediaStore 卷的元数据（#416 裁决 7：G 按卷分开存）。
 *
 * - [fastPathGeneration]：快路径游标 G。只是加速提示，漏掉的照片由慢路径补上。
 * - [mediaStoreVersion]：上次全量对账时看到的 `MediaStore.getVersion`；它一变就该做一次全量对账。
 */
data class VolumeState(
    val volumeName: String,
    val fastPathGeneration: Long,
    val mediaStoreVersion: String?,
)

/** 与状态迁移同一次写入里推进 G：`G = max(G, generation)`，不动 [VolumeState.mediaStoreVersion]。 */
data class GenerationAdvance(val volumeName: String, val generation: Long)

/**
 * AUDIT-01 的持久 outbox 事件。和它描述的事实**同一个事务**落库（见 [OrderStore.transition] 的 [audit]），
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
 * order 存储。所有写操作各自是一个事务：要么全部生效，要么一条都不生效。
 */
interface OrderStore {
    /** 插入一行，返回带 id 与时间戳的完整行。[advance] / [audit] 与插入同一事务。 */
    fun insert(order: NewOrder, advance: GenerationAdvance? = null, audit: AuditRecord? = null): Order

    fun get(id: Long): Order?

    /** 该 media_id 当前的那一行（id 最大）；没有则 null。 */
    fun currentForMedia(mediaId: Long): Order?

    /** 所有 content_hash 等于 [hash] 的行，按 id 升序。 */
    fun ordersWithHash(hash: String): List<Order>

    /**
     * 按 media_id 严格升序流式读出每个 media_id 当前的那一行。
     *
     * 流只在 [block] 内有效（游标在返回前关闭），不许把 Sequence 带出去。
     * 实现按页读，不会一次把整张表读进内存；[block] 里可以写库，已读过的 media_id 不会重复出现。
     */
    fun <R> readCurrentOrders(block: (Sequence<Order>) -> R): R

    /** 当前行里状态属于 [states] 的，按 id 升序，最多 [limit] 条（取件顺序 ① ② 用）。 */
    fun currentInStates(states: Set<OrderState>, limit: Int): List<Order>

    /** 当前行里 CONFIRMED、有 hash、id > [afterId] 的，按 id 升序（分页问桌面用）。 */
    fun confirmedWithHashAfter(afterId: Long, limit: Int): List<Order>

    /**
     * 比较并转换：只有当前状态在 [expected] 里时才改成 [to]，单事务。
     * [countAttempt] 为 true 时 attempts 同一事务内加 1；[advance] / [audit] 也在同一事务里
     * （#415 裁决 8：CONFIRMED、hash 映射、G 三者同一次写入）。返回是否真的改了——没改时
     * [advance] 与 [audit] 也一条都不写。
     */
    fun transition(
        id: Long,
        expected: Set<OrderState>,
        to: OrderState,
        countAttempt: Boolean = false,
        advance: GenerationAdvance? = null,
        audit: AuditRecord? = null,
    ): Boolean

    /** 只改映射（media_id / 版本 / bucket），不动状态与 hash。返回是否找到该行。 */
    fun updateMapping(id: Long, mediaId: Long, sourceVersion: String, bucketId: Long): Boolean

    /** 给还没有 hash 的行补上 hash（批量跳过、Unhashable 留下的行）。已有 hash 时不改，返回 false。 */
    fun setContentHash(id: Long, hash: String): Boolean

    /** #416 裁决 2：打 / 清 `source_missing` 标记。返回是否找到该行。 */
    fun setSourceMissing(id: Long, missing: Boolean, audit: AuditRecord? = null): Boolean

    /** #416 裁决 3：删掉一行（它的 hash 仍在另一条现存行上时）。返回是否真的删了。 */
    fun delete(id: Long): Boolean

    /**
     * 「取消剩余 N 张」：单事务把每个 target 落成 SKIPPED_BY_USER。
     *
     * - 当前行未完结（[OrderState.isOpen]，含 FAILED）：改成 SKIPPED_BY_USER
     * - 当前行已有结局：不动
     * - 没有任何行：插入一行 SKIPPED_BY_USER
     *
     * 任何一项失败，整批回滚，一行都不写。[audit] 与整批同一事务。
     */
    fun skipByUser(targets: List<SkipTarget>, pairingEpoch: String, audit: AuditRecord? = null): SkipResult

    /**
     * #418「已跳过的照片 · 点击恢复」：删掉所有**当前行**为 SKIPPED_BY_USER 的行（一个事务，[audit] 同一事务），
     * 返回删了几行。之后下一次慢路径把这些照片当作「还没有 order」重新规划——内容桌面已有的只记映射，
     * 其余进待传。历史行（被更新版本盖过的旧行）不动。
     */
    fun restoreSkippedByUser(audit: AuditRecord? = null): Int

    fun volumeState(volumeName: String): VolumeState?

    fun saveVolumeState(state: VolumeState)

    /** 只推进 G（快路径跳过了不需要动作的照片）。 */
    fun advanceGeneration(advance: GenerationAdvance)

    /** 已记录过的卷名。 */
    fun volumeNames(): List<String>

    /** UI 投影：当前行按状态计数；[bucketIds] 非 null 时只数这些相册里的。 */
    fun countCurrentByState(bucketIds: Set<Long>? = null): Map<OrderState, Long>

    /**
     * #418 英雄区的 m：当前行为 CONFIRMED、且原图还在手机上（`source_missing` = 0）的张数。
     * 原图删了的行按 #416 裁决 2 保持 CONFIRMED，但它已不在 n（范围内 MediaStore 实时计数）里，
     * 算进 m 会让 m > n，英雄区永远停在「两个数对不上」。
     */
    fun countConfirmedPresent(bucketIds: Set<Long>? = null): Long

    /** 当前行里 CONFIRMED 的最近一次 updated_at（0 = 一张都没有）。 */
    fun lastConfirmedAtMs(): Long

    /** 当前行里 SKIPPED_SOURCE_MISSING、updated_at 在 (after, upTo] 之间的张数（提示横幅的水位线用）。 */
    fun countSourceMissingSkipped(afterMs: Long, upToMs: Long = Long.MAX_VALUE): Long

    /** 追加一条审计（不伴随状态迁移的事实，例如 `unrecoverable`）。 */
    fun appendAudit(audit: AuditRecord)

    fun pendingAudit(limit: Int): List<AuditRecord>

    fun acknowledgeAudit(eventIds: Set<String>)

    /**
     * 换桌面（#415 裁决 6）：[ownerKey]（daemonNodeId）与库里记着的不一样时，清空 order、卷游标与
     * 审计 outbox，并把新 id 的起点抬到 [idFloor] 之上。返回是否清了。
     *
     * 为什么要抬 id 起点：桌面的 `flow_delivery` 按 `(node_id, pairing_epoch, queue_sequence)` 记账，
     * 已完成的行不会被覆盖。旧账本的序号从 1 开始、在桌面上早已 completed；order id 若也从 1 开始，
     * 就会撞上那些行（不同 hash），offer 被拒。
     */
    fun claimOwner(ownerKey: String, idFloor: Long): Boolean
}
