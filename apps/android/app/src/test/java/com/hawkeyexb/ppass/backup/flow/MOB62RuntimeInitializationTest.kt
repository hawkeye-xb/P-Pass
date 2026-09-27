package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB62RuntimeInitializationTest {
    private fun source(): String =
        File("src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt").readText()

    /**
     * MOB-62 / #414：原生初始化（数秒）绝不能在 runtimeLock 里做，调用方也绝不能无界等待它——
     * 之前 flowConstructionLock 里原生 open 永久阻塞时，所有入口跟着永久阻塞。
     */
    @Test
    fun runtime_map_lock_never_wraps_native_provider_open() {
        val source = source()
        val runtimeFor = source.substringAfter("internal fun runtimeFor(context: Context)").substringBefore("private fun buildRuntime(")
        assertFalse("runtimeFor 里不许直接 open 原生仓库", runtimeFor.contains("sharedNativeProvider(app)"))
        assertTrue("构造在专门的线程上跑", runtimeFor.contains("thread(name = \"ppass-flow-init\")"))
        assertTrue("调用方有界等待初始化", runtimeFor.contains("task.get(INIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)"))
        assertTrue("超时要留痕", runtimeFor.contains("initialization still running after"))
        val build = source.substringAfter("private fun buildRuntime(")
        assertTrue("原生 open 在构造里", build.contains("sharedNativeProvider(app)"))
    }

    /**
     * MOB-91：原生仓库**开一次，永不关**。
     *
     * 同一进程内的第二次 `nativeOpen` 会永久阻塞（真机实测 60s+ 未返回），
     * 而它卡在 `flowConstructionLock` 里，之后每个 `runtimeFor` 全部堵死——
     * 整个 Flow 引擎瘫痪到进程重启为止。**这就是 MOB-87「必须杀掉 App
     * 重开」的真根因。**
     *
     * 仓库里没有 token / pairing_epoch / 密钥对，它是资产不是会话，本就该
     * 跨配对活着。解除配对只停在飞的传输（revoke），不关仓库（close）。
     */
    @Test
    fun the_native_provider_is_opened_once_per_process_and_never_closed() {
        val source = source()
        assertTrue(
            "原生仓库必须是进程内单例",
            source.contains("private var sharedNativeProvider: AndroidNativeIrohBlobsProvider?"),
        )
        // 唯一一处真 open，在单例的惰性初始化里。
        assertTrue(
            "只允许单例里 open 一次",
            source.split("AndroidNativeIrohBlobsProvider.open(").size - 1 == 1,
        )
        // 真 open 和「复用」必须分开打日志：一个进程里「opening」只该出现
        // 一次，出现第二次就是单例被绕过了（而第二次 nativeOpen 会永久阻塞）。
        assertTrue(
            "真 open 要有独立的一条日志",
            source.contains("native blobs provider: opening (once per process)"),
        )
        val clear = source.substringAfter("fun clearFlowRuntime(").substringBefore("\n}")
        assertFalse("解除配对不许关仓库——关了同一进程内再也开不回来", clear.contains(".close()"))
        assertTrue("解除配对要停掉在飞的传输", clear.contains("sharedNativeProvider?.revoke("))
        assertTrue("旧运行时仍要显式关", clear.contains("stale?.shutdown()"))
    }
}
