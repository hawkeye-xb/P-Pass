// MOB-36（2026-08-26 真机回归）：**移进**已选相册的照片永远不会被扫到。
//
// ## 断在哪
//
// 在相册之间移动一张照片**不改 `_ID`、不改 `date_added`/`date_modified`**，
// 变的只是 `bucket_id` / `RELATIVE_PATH`。而增量扫描按**水位**过滤，一张从
// 未选相册移进已选相册的老照片，其水位值远在当前水位之下 → 永远不进候选。
// MediaStore 的内容变化通知照发、看门 job 照样被叫起来、派活照样正常——
// **触发了，但什么也没传**，用户看起来就是「移动不触发」。
//
// 这与 MOB-34 是同一族根因：水位只认「新拍的」，认不出「变成范围内的」。
// MOB-34 修「被删了要传回来」，本卡修「被移进来要传上去」。
//
// ## 补齐的形状：按范围定向查 + 靠现成的两张表把成本压成零
//
// 每轮在增量扫描之外，再查一次「**已选 bucket 里**、水位**之下**的行」
// （[MediaScanner.scanScopeBelow]，元数据 only，一个 collection 一次查询）。
// 返回集 ≈ 已选相册总张数，所以**绝不能对它们全部哈希**——每一行先问两张
// 现成的表要「已知 hash」：
//
// 1. `ConfirmedState.files`（MOB-13 的文件级确认记录，fileKey → hash）；
// 2. PERF-01 的哈希缓存（`uri → hash`，跨版本跨配对存活）。
//
// 已知 hash 且仍在 `confirmed` 里 → 已经备份过，**直接跳过，不开流不哈希**
// （卡面验收④：移动已备份过的照片不许重复上传，要在客户端就挡住，不靠存储
// 端 duplicate 兜底——那等于每次移动白跑一趟传输）。稳态下已选相册里每一张
// 都命中这一条，本轮候选为空、哈希次数为 0，与库大小无关。
//
// 剩下的两类才进候选：hash **未知**的（= 从来没在范围内被哈希过，正是刚被
// 移进来的那些），以及 hash 已知但**不在 `confirmed`** 里的（还没传成功/被
// 校准剔除过）。
//
// ## 为什么不搭 MOB-34 的 ReuploadQueue
//
// 队列存在的理由是「lost hash 只在校准那一刻知道，必须活到下一轮」。本卡的
// 待补集合**每轮都能从 MediaStore 重新推导**（一次范围查询 + 两张表比对），
// 持久化它是白存一份状态。所以复用的是 MOB-34 的**汇合点**（`plan.items`
// 那条唯一列表）与两张反查表，不复用它的落盘队列。
//
// ## 副作用：不只治「移进来」
//
// 「新勾选一个相册 → 里面的存量照片自动备份永远够不着」是同一个根因的另一
// 面（此前只有手动触发的全量重扫能覆盖）。本卡顺带治好它。代价是勾选大相册
// 后的第一轮自动备份会一次 offer 整个存量（与手动全量重扫同量级）——这是
// 预期行为，不是回归。
//
// ## 与 MOB-09 的取舍（明写）
//
// 一条「在范围内、水位之下、hash 未知、文件打不开」的坏记录，此前被水位永久
// 跳过，现在每轮都会被查回来、在 `buildCandidates` 的探针上开流失败一次。
// 代价 = 每轮每条坏记录一次失败的 open，上界是坏记录条数；`buildCandidates`
// 的逐条隔离保证它挡不住整批。**刻意不为此加一张「打不开」的负缓存**——那正是
// 本方案（相对卡面 B 路）要省掉的那份状态。
package com.hawkeyexb.ppass.backup

/**
 * MOB-36: 一个文件的**已知** hash——不开流、不哈希，只查两张现成的表。
 *
 * @param fileKey MediaStore uri 字符串（= [ConfirmedState.files] 的 key）
 * @param cacheKey PERF-01 的哈希缓存 key（[hashCacheKey]，带修改信号）
 * @return null = 两张表都不知道 → 它需要被哈希（= 从没在范围内处理过）
 *
 * 顺序有讲究：文件级确认记录是 per-remote 的权威口径，哈希缓存是全局兜底
 * （存量条目 / 换过配对的机器）。缓存 key 带修改信号，文件改过就必然 miss
 * → 当作未知重新哈希，不会拿旧内容的 hash 冒充。
 */
internal fun knownHashOfFile(
    state: ConfirmedState,
    cache: HashCache?,
    fileKey: String,
    cacheKey: String,
): String? = state.files[fileKey]?.hash ?: cache?.get(cacheKey)

/**
 * MOB-36: 从「已选相册里、水位之下的全部行」筛出**真的需要补**的那些——
 * **纯函数**，JVM 单测直接跑。
 *
 * @param below 范围内、水位之下的行（[MediaScanner.scanScopeBelow] 的结果）
 * @param already 本轮已经在列表里的条目（增量扫描 + MOB-34 的定向补偿）
 * @param keyOf 条目 → fileKey（生产口径 = `item.uri.toString()`）
 * @param knownHashOf 条目 → 已知 hash（[knownHashOfFile]）；null = 未知
 * @param isConfirmed 该 hash 是否已确认到家
 *
 * @return 要追加进本轮候选的条目。已确认的一律不进（验收④），已在本轮列表
 *   里的不重复追加（下游 `fileEntriesOf` 靠「文件列表与候选列表 1:1 同序」
 *   配 fileKey↔hash，重复项会让长度对不上而整体降级，MOB-13 的 K 又归不了
 *   零）；`below` 内部万一有重复 key 也只留第一条（同一个 `seen` 集合兜住）。
 *
 * 成本判据（卡面第 3 条）：返回集大小 ∝ **变化量**，不随库大小线性增长；
 * 稳态（范围内每张都已确认）返回空集 → 本轮零哈希、零上传。
 */
internal fun <T> planScopeBackfill(
    below: List<T>,
    already: List<T>,
    keyOf: (T) -> String,
    knownHashOf: (T) -> String?,
    isConfirmed: (String) -> Boolean,
): List<T> {
    if (below.isEmpty()) return emptyList()
    val seen = already.mapTo(mutableSetOf(), keyOf)
    return below.filter { item ->
        if (!seen.add(keyOf(item))) return@filter false
        val known = knownHashOf(item) ?: return@filter true
        !isConfirmed(known)
    }
}
