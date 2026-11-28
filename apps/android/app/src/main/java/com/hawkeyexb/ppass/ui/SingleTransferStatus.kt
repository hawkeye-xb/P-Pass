package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.picked.PickedBatchSummary

/**
 * #1789 单次传输状态（#1784 定案：自动与单次的待办、当前传输、等待和结果统一由英雄区展示，
 * 设置里的两个单次入口只发起选择，不再显示进度、结果或最近一批）。
 *
 * 英雄区那一句的裁决本体——纯函数，JVM 直接可测（对位 iOS `HomeProjection.pickedLine` 同口径）：
 * - 还有没传完的 → 进度句「正在传 x/y」（正在传的那一张算进度）；
 * - 全部结算且有失败 → 失败句「有 N 张没传成，请重新挑选。」（不再拼「送达 N 张」）；
 * - 全部送达（无失败）或没挑过 → null（英雄区不渲染这一行）。
 *
 * 进程被杀导致的未传完**不算失败**（#1784 验收 4）：Android 的手选行留在
 * pending/transferring，下次打开由引擎按挑选顺序续传——它们仍是 open，出的是进度句不是失败句。
 */
object SingleTransferStatus {

    /** 英雄区的单次传输那一句。 */
    sealed interface Line {
        /** 进行中：[done] 含正在传的那一张。 */
        data class Progress(val done: Int, val total: Int) : Line

        /** 结算有失败：只报失败张数（#1459）。 */
        data class Result(val failed: Int) : Line
    }

    fun heroLine(batch: PickedBatchSummary?): Line? = when {
        batch == null || batch.total <= 0 -> null
        batch.open > 0 -> Line.Progress(done = batch.settled + 1, total = batch.total)
        batch.failed > 0 -> Line.Result(failed = batch.failed)
        else -> null
    }
}
