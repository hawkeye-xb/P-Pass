// ARCH-12 (#416): order 存储——#413 逐张循环模型里「对哪张照片做过决定」的唯一证据。
//
// 本包只做新增，尚未接入生产路径（backup/flow/ 不引用这里）。
package com.hawkeyexb.ppass.backup.order

/**
 * 一条 order 的状态。前两个是「还在路上」，其余都是这张照片的结局（#413「每张照片都有一个结局」）。
 *
 * 持久化时存 [name]，所以**不许改名**；新增值要同步 SQLite 表的 CHECK 约束。
 */
enum class OrderState {
    TRANSFERRING,
    PAUSED,
    CONFIRMED,
    FAILED,
    SKIPPED_BY_USER,
    SKIPPED_SOURCE_MISSING,
    CANCELLED_BY_SCOPE,
    ;

    /** 用户明确做过决定：差集规划对它们不产出待传（#413：SKIPPED_BY_USER 这类不补传）。 */
    val isUserDecided: Boolean
        get() = this == SKIPPED_BY_USER || this == CANCELLED_BY_SCOPE

    /** 还没有结局、批量跳过可以覆盖的状态。FAILED 会被兜底重试一次，所以也算未完结。 */
    val isOpen: Boolean
        get() = this == TRANSFERRING || this == PAUSED || this == FAILED
}

/**
 * 一行 order。
 *
 * [id] 是 `INTEGER PRIMARY KEY AUTOINCREMENT`，永不复用，会被填进协议的 `queue_sequence`。
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
    val pairingEpoch: Long,
    val createdAtMs: Long,
    val updatedAtMs: Long,
)

/** 新建一行 order 的输入；id 与时间戳由存储分配。 */
data class NewOrder(
    val mediaId: Long,
    val sourceVersion: String,
    val bucketId: Long,
    val contentHash: String?,
    val state: OrderState,
    val pairingEpoch: Long,
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
data class SkipResult(val inserted: Int, val updated: Int, val untouched: Int)

/**
 * 每个 MediaStore 卷的元数据。
 *
 * - [fastPathGeneration]：快路径游标 G。只是加速提示，漏掉的照片由慢路径补上。
 * - [mediaStoreVersion]：上次看到的 `MediaStore.getVersion`；它一变就该做一次全量对账。
 */
data class VolumeState(
    val volumeName: String,
    val fastPathGeneration: Long,
    val mediaStoreVersion: String?,
)

/**
 * order 存储。所有写操作各自是一个事务：要么全部生效，要么一条都不生效。
 */
interface OrderStore {
    /** 插入一行，返回带 id 与时间戳的完整行。 */
    fun insert(order: NewOrder): Order

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

    /**
     * 比较并转换：只有当前状态在 [expected] 里时才改成 [to]，单事务。
     * [countAttempt] 为 true 时 attempts 同一事务内加 1。返回是否真的改了。
     */
    fun transition(id: Long, expected: Set<OrderState>, to: OrderState, countAttempt: Boolean = false): Boolean

    /** 只改映射（media_id / 版本 / bucket），不动状态与 hash。返回是否找到该行。 */
    fun updateMapping(id: Long, mediaId: Long, sourceVersion: String, bucketId: Long): Boolean

    /**
     * 「取消剩余 N 张」：单事务把每个 target 落成 SKIPPED_BY_USER。
     *
     * - 当前行未完结（[OrderState.isOpen]）：改成 SKIPPED_BY_USER
     * - 当前行已有结局：不动
     * - 没有任何行：插入一行 SKIPPED_BY_USER
     *
     * 任何一项失败，整批回滚，一行都不写。
     */
    fun skipByUser(targets: List<SkipTarget>, pairingEpoch: Long): SkipResult

    fun volumeState(volumeName: String): VolumeState?

    fun saveVolumeState(state: VolumeState)

    /** 已记录过的卷名（为以后分卷留口子）。 */
    fun volumeNames(): List<String>
}
