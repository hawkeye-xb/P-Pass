// ARCH-13 (#417) → #413: 意图层的暂停标志、持久化的等待原因、最近一次 FGS 受阻原因。
//
// 取代 ledger 里的 ConsumerGate 与 flow-transfer-protection.json（TransferProtectionStore）。
// 单个小 JSON 文件，唯一临时文件名 + rename（MOB-102 的教训：固定 .tmp 名在两个线程同一毫秒写时会互相踩）。
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
internal data class FlowControlState(
    val paused: Boolean = false,
    /** [WaitReason] 的 name；空 = 没在等。 */
    val waitReason: String = "",
    /** [FgsBlockReason] 的 name；空 = 没有受阻。 */
    val fgsBlocked: String = "",
    val fgsBlockedAtMs: Long = 0L,
    val missingSourceAckAtMs: Long = 0L,
)

class FlowControlStore(private val dir: File, private val clock: () -> Long = System::currentTimeMillis) : FlowControl {
    private val file = File(dir, FILE_NAME)
    private val json = Json { ignoreUnknownKeys = true }

    @Volatile
    private var cached: FlowControlState? = null

    private fun load(): FlowControlState =
        cached ?: synchronized(this) {
            cached ?: (
                if (file.isFile) {
                    runCatching { json.decodeFromString(FlowControlState.serializer(), file.readText()) }.getOrDefault(FlowControlState())
                } else {
                    FlowControlState()
                }
                ).also { cached = it }
        }

    @Synchronized
    private fun update(transform: (FlowControlState) -> FlowControlState) {
        val next = transform(load())
        cached = next
        // 写盘失败不能变成崩溃（这条路径多半本来就在处理别的失败）；内存里的事实照样生效。
        runCatching {
            dir.mkdirs()
            val tmp = File.createTempFile("$FILE_NAME.", ".tmp", dir)
            try {
                tmp.writeText(json.encodeToString(FlowControlState.serializer(), next))
                check(tmp.renameTo(file)) { "rename failed" }
            } finally {
                tmp.delete()
            }
        }
    }

    override fun paused(): Boolean = load().paused

    override fun setPaused(paused: Boolean) = update { it.copy(paused = paused) }

    override fun waitReason(): WaitReason? = WaitReason.entries.firstOrNull { it.name == load().waitReason }

    override fun setWaitReason(reason: WaitReason?) {
        val name = reason?.name.orEmpty()
        if (load().waitReason != name) update { it.copy(waitReason = name) }
    }

    override fun fgsBlock(): FgsBlockReason? = FgsBlockReason.entries.firstOrNull { it.name == load().fgsBlocked }

    override fun recordFgsBlock(reason: FgsBlockReason) = update {
        // 已经受阻时不覆盖：额度耗尽（能说清原因的那条）不被随后「说不清原因的拒绝」冲掉（UI-19 的教训）。
        if (it.fgsBlocked.isNotEmpty()) it else it.copy(fgsBlocked = reason.name, fgsBlockedAtMs = clock())
    }

    override fun clearFgsBlock() {
        if (load().fgsBlocked.isNotEmpty()) update { it.copy(fgsBlocked = "", fgsBlockedAtMs = 0L) }
    }

    override fun missingSourceAckAt(): Long = load().missingSourceAckAtMs

    override fun setMissingSourceAckAt(atMs: Long) = update { it.copy(missingSourceAckAtMs = atMs) }

    companion object {
        const val FILE_NAME = "flow-control.json"
    }
}
