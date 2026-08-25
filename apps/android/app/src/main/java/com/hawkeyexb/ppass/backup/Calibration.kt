// MOB-29（2026-08-25 用户定调）：库里删掉的照片会被传回来——**这是对的**，
// 但不能全程静默。
//
// ## 定调（卡面原文三条）
//
// 1. **重传是正确行为，不拦。** 存储端不该丢数据，照片被补回来是对的。
//    这里不做墓碑、不做排除列表、不碰 `manifest`/`missing` 的语义。
// 2. **删除的正确姿势是「先删手机原图、再删库」**——两次删除表达意图，
//    源被消灭，重传自然不发生。不需要任何「记住我不要它」的状态。
// 3. **要做的只是让用户知道**，且**不做精确归因**（人删 vs 换库 vs 磁盘坏，
//    一句带条件从句的话在三种成因下都成立）。
//
// ## 为什么「不会误报」
//
// `confirmed` 只在 `BackupRunner.run()`（含 commit）成功返回后才写入
// （`BackupWorker` 里的 `confirmedStore.recordRun`）——它是「**拿到过 commit
// 确认**」的硬证据。于是：
// - **新照片**从没进过 `confirmed` → 不触发；
// - **传输失败的照片**（commit 没成功）从没进过 `confirmed` → 不触发。
//
// 生产口径下 `existCheck` 喂进去的就是 `confirmed` 集合，所以
// `missing ⊆ confirmed` 结构上恒成立；[lostFromLibrary] 的显式交集是**契约**
// ——反证测试（去掉交集 → 「新照片/失败照片不触发」变红）钉的就是它。
//
// ## 提示为什么天然一次性
//
// 算出 `missing` 后紧接着 `removeMissing`，这批 hash 从 `confirmed` 里被剔除，
// 下一轮 exist-check 根本不会再问到它们。**所以不需要去重窗口/时间戳状态。**
package com.hawkeyexb.ppass.backup

/**
 * 「我确认过、但库里已经没有」的那批 hash——也就是**会被传回来**的那批。
 *
 * @param confirmed 校准前的确认集合（`ConfirmedStore.load().confirmed`）
 * @param missing exist-check 的应答（daemon 说「这些我没有」）
 *
 * 交集是**判据本身**：只有「拿到过 commit 确认」的照片消失才算「客户端
 * 丢了资源」。新照片和传输失败的照片不在 [confirmed] 里，永不触发。
 */
internal fun lostFromLibrary(confirmed: Set<String>, missing: Collection<String>): Set<String> =
    missing.filterTo(mutableSetOf()) { it in confirmed }

/**
 * 校准内核——**不碰 Android、不碰网络类型**，JVM 单测直接跑。
 *
 * 顺序是承重的：先算 `lost` 并提示，**再** `removeMissing`。反过来的话
 * 交集恒空，提示永远发不出去。
 *
 * @param existCheck 只查不传的 exist-check（生产实现见 [BackupRunner.existCheck]）
 * @param onLost 提示回调（生产实现 = 发通知；传空集不会被调用）
 * @return 是否确认与 daemon 交互成功（SENT-01 哨兵据此记可达性）。
 *   无缓存可查 = false（无结论）；抛错 = false 且**缓存原样保留**
 *   ——daemon 不可达绝不许把「已备份」清零。
 */
internal suspend fun calibrateConfirmed(
    store: ConfirmedStore,
    existCheck: suspend (Set<String>) -> Set<String>,
    onLost: (Set<String>) -> Unit,
): Boolean {
    val cached = store.load().confirmed
    if (cached.isEmpty()) return false // 无缓存可查——无结论
    return try {
        val missing = existCheck(cached)
        val lost = lostFromLibrary(cached, missing)
        if (lost.isNotEmpty()) onLost(lost)
        if (missing.isNotEmpty()) store.removeMissing(missing)
        true // 交互成功 = 确认可达
    } catch (_: Throwable) {
        // 不可达/未配对/超时——保留缓存值（三元组显示旧值，下次再校准）。
        false
    }
}

/** MOB-29: 提示文案的字典 key（注册表 `crates/diag/src/keys.rs`，
 *  文案在 `assets/i18n/{en,zh}.json`；Android 捆绑副本的漂移由
 *  `DiagTextTest.bundled_assets_never_drift_from_repo_source` 守）。 */
internal const val MSG_REUPLOAD_TITLE = "ui.mobile_reupload_title"
internal const val MSG_REUPLOAD_BODY = "ui.mobile_reupload_body"
