package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MOB62RuntimeInitializationTest {
    private fun source(): String =
        File("src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt").readText()

    @Test
    fun runtime_map_lock_never_wraps_native_provider_open() {
        val source = source()
        val runtimeFor = source.substringAfter("private fun runtimeFor(context: Context)")
            .substringBefore("private val flowTriggerLock")
        // MOB-91 之后原生仓库是进程内单例，`runtimeFor`/`buildRuntime` 拿的是
        // 它的引用（第一次才真 open）。MOB-62 要守的不变量没变：**原生初始化
        // 绝不能被 `flowRuntimeLock` 包住**——那把锁是给「取一下运行时引用」
        // 用的，原生初始化要几秒，挡住它就是 ANR。
        val nativeInit = runtimeFor.indexOf("sharedNativeProvider(context)")
        val publish = runtimeFor.indexOf("return synchronized(flowRuntimeLock)")

        assertTrue("native initialization must remain in runtimeFor", nativeInit >= 0)
        assertTrue("a ready candidate must publish only after native initialization", publish > nativeInit)
        assertTrue(
            "the first lock section must end before native initialization begins",
            runtimeFor.substring(0, nativeInit)
                .contains("flowRuntimes[key]?.takeIf { it.epoch == epoch }?.let { return it }\n    }"),
        )
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
        val clear = source.substringAfter("fun clearFlowRuntime(").substringBefore("\n}")
        assertFalse("解除配对不许关仓库——关了同一进程内再也开不回来", clear.contains(".close()"))
        assertTrue("解除配对要停掉在飞的传输", clear.contains("nativeProvider.revoke("))
        // MOB-62 要的那半仍然成立：旧运行时该关的照关。
        assertTrue("旧运行时仍要从 map 移除", clear.contains("flowRuntimes.remove("))
        assertTrue("写者线程仍要显式关", clear.contains("stale.shutdown()"))
    }
}
