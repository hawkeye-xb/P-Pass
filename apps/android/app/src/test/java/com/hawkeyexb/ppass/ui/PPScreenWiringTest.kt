// #112：静态扫描——入口 / 双 tab 首页 / 相册选择 / onboarding / 查看器都经 PPScreen；
// 安全区 inset 只在 PPScreen 消费。例外必须写在这里并说明理由。
package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class PPScreenWiringTest {

    private val sourceRoot = mainSourceRoot()

    private fun mainSourceRoot(): File {
        var dir: File? = File(System.getProperty("user.dir"))
        val candidates = listOf(
            "src/main/java/com/hawkeyexb/ppass",
            "app/src/main/java/com/hawkeyexb/ppass",
            "apps/android/app/src/main/java/com/hawkeyexb/ppass",
        )
        while (dir != null) {
            for (rel in candidates) {
                val candidate = File(dir, rel)
                if (candidate.isDirectory) return candidate
            }
            dir = dir.parentFile
        }
        error("找不到 main 源目录（user.dir=${System.getProperty("user.dir")}）")
    }

    private fun rel(file: File): String = file.relativeTo(sourceRoot).path.replace(File.separatorChar, '/')

    @Test
    fun entry_home_picker_onboarding_and_viewer_all_go_through_ppscreen() {
        val required = mapOf(
            "入口 WelcomeScreen" to "ui/Onboarding.kt",
            "双 tab 首页" to "ui/TwoTabs.kt",
            "相册选择" to "ui/BucketScreen.kt",
            "onboarding 决定页" to "ui/DecisionScreen.kt",
            "查看器" to "ui/PhotosScreen.kt",
        )
        val missing = required.filterValues { !File(sourceRoot, it).readText().contains("PPScreen") }
        assertTrue("这些页面没有经过 PPScreen：$missing", missing.isEmpty())
    }

    @Test
    fun safe_area_insets_are_consumed_only_in_ppscreen() {
        val patterns = listOf(
            "safeDrawingPadding", "safeContentPadding", "safeGesturesPadding",
            "statusBarsPadding", "navigationBarsPadding", "displayCutoutPadding",
            "windowInsetsPadding", "systemBarsPadding", "imePadding", "WindowInsets",
        )
        // 例外表：文件 | 理由。只有这里列出的文件可以消费安全区 inset。
        val allowed = mapOf(
            "ui/PPScreen.kt" to "全应用唯一的安全区容器",
            // MainActivity 的例外仅限 SnackbarHost 浮层（不是页面容器）自行避让导航栏；
            // 下面还会核对它确实在 SnackbarHost 块里，出现别处仍判红。
            "MainActivity.kt" to "SnackbarHost 是底部浮层，不是页面容器",
        )
        val violations = mutableListOf<String>()
        sourceRoot.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .forEach { file ->
                val path = rel(file)
                val lines = file.readLines()
                lines.forEachIndexed { index, line ->
                    if (patterns.none { line.contains(it) }) return@forEachIndexed
                    // import 只是声明，不是消费——MainActivity 等文件 import 了 safeDrawingPadding 这类扩展也要放行。
                    if (line.trimStart().startsWith("import ")) return@forEachIndexed
                    when (path) {
                        "ui/PPScreen.kt" -> Unit
                        "MainActivity.kt" -> {
                            val context = lines.subList(maxOf(0, index - 10), index + 1).joinToString("\n")
                            if (context.contains("SnackbarHost(")) return@forEachIndexed
                            violations += "$path:${index + 1}: ${line.trim()}（只许 SnackbarHost 浮层例外）"
                        }
                        else -> violations += "$path:${index + 1}: ${line.trim()}（未登记例外：${allowed[path] ?: "无"}）"
                    }
                }
            }
        assertTrue("安全区 inset 只许在 PPScreen 消费（例外见测试注释）：$violations", violations.isEmpty())
    }
}
