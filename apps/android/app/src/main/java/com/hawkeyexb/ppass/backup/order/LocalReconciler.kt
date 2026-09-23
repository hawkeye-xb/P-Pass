// ARCH-13 (#417): 慢路径第 1 步「手机完整性检查」——MediaStore × order 两遍归并。
package com.hawkeyexb.ppass.backup.order

/**
 * 两遍，顺序是承重的（见 [DiffPlanner]）：第一遍的动作**全部落库之后**才开第二遍。
 *
 * 读（含算 hash）与写分成 collect / apply 两段，是为了让调用方把读放到 IO 线程、
 * 把写放到单写者线程（MOB-88）；[run] 是给测试和单线程场景的串联入口。
 */
class LocalReconciler(
    private val store: OrderStore,
    private val media: MediaSnapshotSource,
    private val planner: DiffPlanner,
    private val applier: DiffApplier,
) {
    fun collectPresent(): List<DiffAction> =
        media.readAll { snapshots -> store.readCurrentOrders { orders -> planner.planPresent(snapshots, orders).toList() } }

    fun applyPresent(actions: List<DiffAction>, stats: ApplyStats) = actions.forEach { applier.applyPresent(it, stats) }

    fun collectGone(): List<DiffAction.Gone> =
        media.readAll { snapshots -> store.readCurrentOrders { orders -> planner.planGone(snapshots, orders).toList() } }

    fun applyGone(actions: List<DiffAction.Gone>, stats: ApplyStats) = applier.applyGone(actions, stats)

    fun run(): ApplyStats {
        val stats = ApplyStats()
        applyPresent(collectPresent(), stats)
        applyGone(collectGone(), stats)
        return stats
    }
}
