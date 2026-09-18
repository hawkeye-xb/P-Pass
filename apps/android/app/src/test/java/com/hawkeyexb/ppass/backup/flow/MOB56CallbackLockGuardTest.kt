package com.hawkeyexb.ppass.backup.flow

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MOB-56 门禁：`AndroidFlowRuntime.kt` 里每一个 `runner.<x>()` 状态变更调用
 * 都必须在 `synchronized(flowTriggerLock)` 的词法范围内。
 *
 * 为什么是源码扫描而不是运行时测试：MOB-56 修的是「原生回调
 * （`onPermanentFailure`/`onReceipt`）绕过 flowTriggerLock」，而
 * [StrictConsumer.wake] 是读-检查-写、内部不同步，靠调用方串行化。
 * 回归时实测过：把那两个回调的 `synchronized` 摘掉，Android JVM 全量
 * 406 tests 照样全绿——`ARCH01StrictConsumerTest` 直接驱动
 * `StrictConsumer.wake()`、压根不经过 `AndroidFlowRuntime`，所以没有
 * 任何自动化测试锁住这个不变量。这个文件就是补这个缺口。
 *
 * 同 [MOB62RuntimeInitializationTest] 的做法读自身源码（相对路径在
 * Gradle 测试工作目录下成立）。
 *
 * 覆盖时机：`ci-android` 只在 push main 时按 `apps/android` 路径触发，
 * 业务代码 PR 不跑任何 lane（2026-08-23 额度决定），所以这道门禁是
 * **合入后让 main 变红**，不是合入前拦截；本地 `just android-test` /
 * `./gradlew :app:testDebugUnitTest` 即时生效。
 */
class MOB56CallbackLockGuardTest {
    private fun source(): String =
        File("src/main/java/com/hawkeyexb/ppass/backup/flow/AndroidFlowRuntime.kt").readText()

    @Test
    fun every_runner_mutation_runs_inside_the_flow_trigger_lock() {
        val source = blankCommentsAndStrings(source())
        // `synchronized(flowTriggerLock) {` —— 记住那个 `{` 的下标
        val lockBraces = Regex("""synchronized\s*\(\s*flowTriggerLock\s*\)\s*\{""")
            .findAll(source)
            .map { it.range.last }
            .toSet()
        // 只认「调用」：`runner.` + 标识符 + `(`。声明/构造（`val runner: FlowRunner,`、
        // `runner = FlowRunner(`）与注释里的 "the runner. On ..." 都不会命中。
        val callSites = Regex("""\brunner\.[A-Za-z_][A-Za-z0-9_]*\s*\(""")
            .findAll(source)
            .associateBy { it.range.first }

        val open = ArrayDeque<Boolean>()
        val unguarded = mutableListOf<String>()
        var line = 1
        source.forEachIndexed { index, ch ->
            callSites[index]?.let { hit ->
                val name = hit.value.trim().removePrefix("runner.").substringBefore("(").trim()
                if (open.none { it } && name !in PRE_PUBLICATION) {
                    unguarded += "  $line: ${hit.value.trim()}"
                }
            }
            when (ch) {
                '{' -> open.addLast(index in lockBraces)
                '}' -> if (open.isNotEmpty()) open.removeLast()
                '\n' -> line += 1
            }
        }

        // 反空转：正则一旦因为重命名（`runner` → `flowRunner`）扫不到东西，
        // 上面的断言会在空集上无条件通过。基线是 2026-09-18 的 10 处调用。
        assertTrue(
            "expected at least 10 runner.* call sites, found ${callSites.size} — " +
                "the scan pattern went stale and this guard is vacuous",
            callSites.size >= 10,
        )
        assertTrue(
            "ARCH-03 violation: runner.* mutation outside synchronized(flowTriggerLock):\n" +
                unguarded.joinToString("\n"),
            unguarded.isEmpty(),
        )
    }

    private companion object {
        /**
         * 唯一允许在锁外的调用：`runner.reconcileProcessStart()` 跑在 `runtimeFor`
         * 的构造段，此时 `runner` 还没写进 `flowRuntimes`，别的线程拿不到它，
         * 不存在需要串行化的并发触发。
         *
         * 留白（本卡不处理）：`runtimeFor` 的构造段本身没有互斥——两个线程
         * 同时为同一 key 构造，会各自建一个 FlowRunner 并各跑一次
         * `reconcileProcessStart()`，写的是**同一份磁盘账本**。这与 MOB-56
         * 同类但独立，需要单独开卡评估，不要在这里顺手加锁。
         */
        private val PRE_PUBLICATION = setOf("reconcileProcessStart")
    }

    /** 把注释与字符串字面量整段替换成等长空格：位置/行号不变，里面的花括号不再干扰配平。 */
    private fun blankCommentsAndStrings(source: String): String {
        val out = StringBuilder(source)
        var i = 0
        fun blankUntil(end: Int) {
            for (j in i until minOf(end, source.length)) if (out[j] != '\n') out[j] = ' '
        }
        while (i < source.length) {
            when {
                source.startsWith("//", i) -> {
                    val end = source.indexOf('\n', i).let { if (it < 0) source.length else it }
                    blankUntil(end); i = end
                }
                source.startsWith("/*", i) -> {
                    val end = source.indexOf("*/", i).let { if (it < 0) source.length else it + 2 }
                    blankUntil(end); i = end
                }
                source[i] == '"' -> {
                    var j = i + 1
                    while (j < source.length && source[j] != '"' && source[j] != '\n') {
                        if (source[j] == '\\') j += 1
                        j += 1
                    }
                    val end = minOf(j + 1, source.length)
                    blankUntil(end); i = end
                }
                else -> i += 1
            }
        }
        return out.toString()
    }
}
