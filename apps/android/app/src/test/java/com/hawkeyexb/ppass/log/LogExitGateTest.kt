// #548 门禁：App 写 logcat 只有一个出口（log/PLog.kt），出口统一脱敏。
//
// 行为测试证明「这次的日志打了码」，门禁证明「以后绕不过去」：src/main 下任何 Kotlin 源码（PLog.kt
// 除外）出现以下写法即红——
// - `android.util.Log`（import、全限定调用、`import android.util.Log as X` 别名都含这个串）；
// - 裸 `Log.x(`（`import android.util.*` 通配导入后的调用）；
// - `printStackTrace()`、`System.out` / `System.err`、`println(`：在 Android 上都会进 logcat（tag
//   System.out / System.err），同样不经脱敏。
// 注释行（`//`、`*`、`/*` 开头）跳过——说明文字里提到这些名字不是调用。
package com.hawkeyexb.ppass.log

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class LogExitGateTest {

    private val root = File("src/main/java")
    private val exit = File(root, "com/hawkeyexb/ppass/log/PLog.kt")

    private val forbidden = listOf(
        Regex("""\bandroid\.util\.Log\b""") to "android.util.Log",
        Regex("""(?<![\w.])Log\.(v|d|i|w|e|wtf|println)\(""") to "bare Log.x(",
        Regex("""\.printStackTrace\(\s*\)""") to "printStackTrace()",
        Regex("""\bSystem\.(out|err)\b""") to "System.out/err",
        Regex("""(?<![\w.])println\(""") to "println(",
    )

    /** 返回 `文件:行号: 命中规则` 列表；[sources] 可注入，便于测门禁自身。 */
    internal fun violations(sources: Map<String, String>): List<String> = sources.flatMap { (path, text) ->
        text.lines().withIndex().flatMap { (i, line) ->
            val t = line.trimStart()
            if (t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")) {
                emptyList()
            } else {
                forbidden.filter { (re, _) -> re.containsMatchIn(line) }.map { (_, why) -> "$path:${i + 1}: $why" }
            }
        }
    }

    private fun mainSources(): Map<String, String> {
        assertTrue("run from apps/android/app", root.isDirectory && exit.isFile)
        return root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" && it.canonicalFile != exit.canonicalFile }
            .associate { it.path to it.readText() }
    }

    @Test
    fun `nothing writes logcat except the PLog exit`() {
        val sources = mainSources()
        assertTrue("scan found too few files (${sources.size}) — wrong root?", sources.size > 50)
        val hits = violations(sources)
        assertTrue("绕过日志出口直接写 logcat（改用 com.hawkeyexb.ppass.log.PLog）：\n" + hits.joinToString("\n"), hits.isEmpty())
    }

    @Test
    fun `the gate itself catches each bypass and ignores comments`() {
        val bad = mapOf(
            "A.kt" to "import android.util.Log\nfun f() { Log.i(\"T\", \"x\") }",
            "B.kt" to "fun f() { android.util.Log.w(\"T\", \"x\") }",
            "C.kt" to "import android.util.*\nfun f() { Log.e(\"T\", \"x\") }",
            "D.kt" to "fun f(t: Throwable) { t.printStackTrace() }",
            "E.kt" to "fun f() { System.err.println(\"x\") }",
            "F.kt" to "fun f() { println(\"x\") }",
        )
        val hits = violations(bad)
        for (file in bad.keys) assertTrue("$file not caught: $hits", hits.any { it.startsWith("$file:") })
        val ok = mapOf(
            "G.kt" to "// 不直接碰 android.util.Log\n/** 生产 = PLog.i(\"T\", …) */\n * Log.e(x)\nfun f() { PLog.i(\"T\", \"x\"); FlowLogger { } }",
        )
        assertTrue(violations(ok).toString(), violations(ok).isEmpty())
    }
}
