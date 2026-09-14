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
        val nativeOpen = runtimeFor.indexOf("AndroidNativeIrohBlobsProvider.open")
        val publish = runtimeFor.indexOf("return synchronized(flowRuntimeLock)")

        assertTrue("native initialization must remain in runtimeFor", nativeOpen >= 0)
        assertTrue("a ready candidate must publish only after native initialization", publish > nativeOpen)
        assertTrue(
            "the first lock section must end before native initialization begins",
            runtimeFor.substring(0, nativeOpen).contains("flowRuntimes[key]?.takeIf { it.epoch == epoch }?.let { return it }\n    }"),
        )
    }
}
