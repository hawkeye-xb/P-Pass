// ARCH-06: persistent boundary for adopting a new pairing epoch.
package com.hawkeyexb.ppass.backup.flow

/**
 * `pairing_epoch` 是**授权凭证的版本号**——16 字节随机数
 * （daemon 侧 `pairing.rs:327` `fresh_pairing_epoch`），不是密钥。
 * 稳定密钥是 `identity.key`，它从不轮换。每次业主批准配对都换一个新 epoch，
 * 旧凭证随之作废，这是对的，本类不动这一点。
 *
 * MOB-87 修的是另一件事：epoch **不该兼任内容账本的分区键**。
 * 内容传没传过，跟"这次授权是第几轮"没有关系。
 */
class PairingEpochController(private val ledger: DiscoveryLedgerStore) {
    fun ensureCurrentEpoch(nextEpoch: PairingEpoch) {
        if (ledger.load().pairingEpoch != nextEpoch) replaceDesktop(nextEpoch)
    }

    /**
     * 采用新 epoch：**作废旧凭证，保留内容事实。**
     *
     * ## 为什么不再 `items = emptyList()`
     *
     * 账本按 `daemonNodeId` 分目录存（`flow-state/<nodeId>/`），所以同一份
     * 账本里 epoch 变化**只可能是同一台桌面重新配对**——换一台桌面是换一个
     * 文件，根本走不到这里。把 items 清空等于每次重连都声明"我什么都没传过"，
     * 于是整库重新提供一遍：实测 95 张照片、4 次重连，桌面 `flow_delivery`
     * 记了 603 行。
     *
     * 更要命的是它让对账无从谈起——没有 CONFIRMED 项，就没有"桌面上还在吗"
     * 这个问题可问。
     *
     * ## 保留什么、重置什么：按「内容事实 vs 执行态」切，不按项切
     *
     * - **保留（内容事实）**：`deliveryState == CONFIRMED` 的项逐字段不动——
     *   `contentHash` / `completedAt` / `completionReceiptId` / `queueSequence`
     *   / `stableId` 全留，只把 `pairingEpoch` 这枚**归属章**改成新的。
     *   桌面上那份 blob 是内容寻址的，不随 epoch 消失，所以"传过了"这个事实
     *   跨 epoch 依然成立。
     * - **重置（执行态）**：游标、租约、闸门、取消轮、回填请求，以及**项上
     *   那部分执行态**：
     *   - `partialRetained` 一律清成 false——它声明的是"桌面那边替我留了半个
     *     文件"，而**桌面侧的 staging 随旧 epoch 一起作废了**。带着它进新
     *     epoch，手机会以为能断点续传一个根本不存在的半成品。
     *     （ARCH-06 原测试 `p01` 保护的就是这一条，本卡保留该不变量。）
     *   - `TRANSFERRING` 退回 `QUEUED`——那一次传输随旧凭证一起死了，
     *     新会话从头传。
     *
     * `cursor` 回 INITIAL 让发现重新扫一遍相册：`commitDiscoveryPage` 按
     * `stableId` 去重，老照片不会重复入账，而断开期间新拍的会被补上。
     *
     * ⚠️ 本方法保留账本，**推翻 MOB-62 卡面「旧 remote Flow ledger 删除」
     * 那一条**。MOB-62 要的是"断开后旧会话不能再运行"，删账本只是它当时
     * 选的手段；保留数据、照常关 runtime / provider / 取消 wake，它的目的
     * 依然满足——保留的是数据，关掉的是执行。
     */
    fun replaceDesktop(nextEpoch: PairingEpoch) {
        require(nextEpoch != PairingEpoch.INITIAL) { "a paired Desktop requires an epoch" }
        ledger.update { snapshot ->
            val replaced = snapshot.copy(
                pairingEpoch = nextEpoch,
                cursor = DiscoveryCursor.INITIAL,
                cancellationRound = null,
                uploadCursor = UploadCursor.INITIAL,
                consumerGate = ConsumerGate.OPEN,
                consumerStatus = ConsumerStatus.IDLE,
                fetchLease = null,
                backfillRequests = emptyList(),
                items = snapshot.items.map { it.migrateTo(nextEpoch) },
                // 保留：序号是 stableId 之外的第二条身份线。重排会让审计记录里
                // 的 queueSequence 全部错位，更会让新入账的项跟保留下来的老项
                // 撞号——`headOf` / `acceptCompletionReceipt` 都按序号找项，
                // 撞号等于把两张照片的状态搅在一起。
                nextQueueSequence = snapshot.nextQueueSequence,
                currentRoundId = null,
                // 新会话重新核对一遍桌面，别继承上一轮的进度。
                reconcileCursor = 0L,
            )
            // AUDIT-01: the very first epoch adoption (INITIAL -> real epoch,
            // right after a fresh pairing) invalidates nothing — there was no
            // previous authority to retire. Only a genuine replacement of an
            // already-current epoch is a durable "old grants are void" fact.
            if (snapshot.pairingEpoch == PairingEpoch.INITIAL) {
                replaced
            } else {
                replaced.appendAudit(
                    AuditKinds.EPOCH_INVALIDATED,
                    payload = mapOf(
                        "previousEpoch" to snapshot.pairingEpoch.value,
                        // MOB-87: 迁移了几条内容事实——排查"重连后账本空了"
                        // 这类问题时，这个数字是第一现场。
                        "migratedItems" to snapshot.items.size.toString(),
                    ),
                )
            }
        }
    }
}

/**
 * 把一条账本项交接到新 epoch：**内容事实原样留，执行态就地清。**
 *
 * 只有 `CONFIRMED` 是"已经发生过的事"；其余状态都还在半空中，而托着它们的
 * 那次授权已经没了。
 */
private fun TransferItem.migrateTo(nextEpoch: PairingEpoch): TransferItem = copy(
    pairingEpoch = nextEpoch,
    // 桌面侧的半成品随旧 epoch 作废，别让手机以为还能续。
    partialRetained = false,
    // 那一次传输随旧凭证一起死了；重新排队，从头传。
    deliveryState = if (deliveryState == DeliveryState.TRANSFERRING) {
        DeliveryState.QUEUED
    } else {
        deliveryState
    },
)
