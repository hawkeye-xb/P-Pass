// MOB-88: 账本的持久化被收到接口后面，业务代码不再碰 File。
//
// 为什么要这层：改造前 DiscoveryLedgerStore 把「整份读出、整份写回」这个
// **存储实现细节**泄漏成了业务正确性问题——一个只想删审计事件的写入，
// 物理上能把租约按回旧值。reducer 只该面对内存里的状态，落盘是背后的
// 适配器；今天是 JSON，将来换 SQLite 业务一行不用动。
package com.hawkeyexb.ppass.backup.flow

import java.io.File
import kotlinx.serialization.json.Json

/** 账本的持久化边界。实现只管存取整份快照，不含任何业务判断。 */
interface FlowLedgerRepository {
    /** 还没有持久化过返回 null（调用方用默认快照起步）。 */
    fun read(): DiscoveryLedgerSnapshot?

    fun write(snapshot: DiscoveryLedgerSnapshot)
}

/** 生产实现：单个 JSON 文件 + 临时文件原子 rename。 */
class JsonFileFlowLedgerRepository(private val dir: File) : FlowLedgerRepository {
    private val file = File(dir, "discovery-ledger.json")
    private val json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
    }

    // 改造前的语义：解析失败当作「没有账本」，静默从空白起步。这是一个
    // 独立的隐患（一次损坏的写入会让整条队列凭空消失，且不报错），但它
    // 先于 MOB-88 存在、也不在本卡范围——此处逐字保留原行为，不顺手改。
    override fun read(): DiscoveryLedgerSnapshot? =
        if (!file.isFile) {
            null
        } else {
            try {
                json.decodeFromString(DiscoveryLedgerSnapshot.serializer(), file.readText())
            } catch (_: Exception) {
                null
            }
        }

    override fun write(snapshot: DiscoveryLedgerSnapshot) {
        dir.mkdirs()
        val temporary = File(dir, "${file.name}.tmp")
        temporary.writeText(json.encodeToString(DiscoveryLedgerSnapshot.serializer(), snapshot))
        check(temporary.renameTo(file)) { "cannot atomically persist discovery ledger" }
    }
}

/**
 * 写入线程归属门禁。
 *
 * 这是 MOB-88 的核心保障，也是取代 `MOB56CallbackLockGuardTest` 的那道门：
 * 账本只允许在单写者线程上落盘。任何绕过 writer 的写入**当场抛异常**，
 * 而不是像改造前那样静默覆盖别人的状态——「竞态发生时系统不出声」正是
 * #107 真机验收做不出结论的根因。
 */
fun interface LedgerWriteGuard {
    fun assertAllowed()
}

/** 测试与不涉并发的场景用：不做检查。 */
object UncheckedLedgerWrites : LedgerWriteGuard {
    override fun assertAllowed() = Unit
}

/** 生产用：只有 [owner] 这一个线程可以写。 */
class SingleThreadLedgerWrites(private val owner: Thread) : LedgerWriteGuard {
    override fun assertAllowed() {
        val current = Thread.currentThread()
        check(current === owner) {
            "flow ledger written off the single-writer thread: ${current.name} (owner=${owner.name})"
        }
    }
}
