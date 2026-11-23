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

    // 截取「funSig 之后到下一个行首顶层函数之前」的函数体：顶层函数在行首（无缩进），
    // 嵌套函数有缩进，不匹配，所以不会提前截断。
    private fun topLevelBody(path: String, funSig: String): String {
        val text = File(sourceRoot, path).readText()
        // #1930：签名找不到时必须立刻失败——过去找不到签名会静默返回空串，
        // 函数重命名后 `!body.contains("PPScreen")` 会假绿，等于这条守卫悄悄失效。
        check(text.contains(funSig)) { "在 $path 中找不到函数签名：$funSig" }
        val after = text.substringAfter(funSig)
        val next = Regex("""\n(?:private |internal |public |override |suspend )?fun [A-Za-z]""").find(after)
        return if (next != null) after.substring(0, next.range.first) else after
    }

    // 只保留会执行的代码行：丢掉 `//`、`*`、`/*` 开头的注释行，避免把「不再嵌套 PPScreen」
    // 这类解释文字当成真的调用。
    private fun codeLines(path: String): List<String> =
        File(sourceRoot, path).readLines()
            .map { it.trim() }
            .filterNot { it.startsWith("//") || it.startsWith("*") || it.startsWith("/*") }

    // 从 "name(" 起按括号配对截出整个调用块，比 substringBefore 之类的启发式截断可靠。
    private fun callBlock(text: String, call: String): String {
        val start = text.indexOf(call)
        check(start >= 0) { "在文件中找不到调用：$call" }
        val open = text.indexOf('(', start)
        check(open >= 0) { "找不到调用括号：$call" }
        var depth = 0
        for (i in open until text.length) {
            when (text[i]) {
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) return text.substring(start, i + 1)
                }
            }
        }
        error("调用括号未闭合：$call")
    }

    @Test
    fun entry_home_picker_onboarding_and_viewer_all_go_through_ppscreen() {
        // 函数签名 → 所在文件。判据：该函数体里必须有 PPScreen 调用——按函数体判，
        // 避免整文件 contains 扫到同文件里另一个页面的调用（Onboarding.kt 有 WelcomeScreen 和 PairStatusScreen 两个调用点）。
        // #1926：PhotoViewer / VideoScreen 运行在 TwoTabs 的唯一顶层 PPScreen 内，不再单独套 PPScreen；
        // 由下方 two_tabs_is_the_single_top_level_ppscreen_for_home_and_viewer 锁定查看器走 TwoTabs(background = ...)。
        val required = mapOf(
            "入口 WelcomeScreen" to ("ui/Onboarding.kt" to "fun WelcomeScreen("),
            "双 tab 首页与查看器宿主" to ("ui/TwoTabs.kt" to "fun TwoTabs("),
            "相册选择" to ("ui/BucketScreen.kt" to "fun BucketScreen("),
            "onboarding 决定页" to ("ui/DecisionScreen.kt" to "fun DecisionScreen("),
        )
        val missing = required.filterValues { (path, funSig) ->
            !topLevelBody(path, funSig).contains("PPScreen")
        }
        assertTrue("这些页面没有经过 PPScreen：$missing", missing.isEmpty())
    }

    @Test
    fun two_tabs_is_the_single_top_level_ppscreen_for_home_and_viewer() {
        // #1926：一个 Window 同一时刻只能有一个顶层 PPScreen 控制整屏底色、安全区 inset 与系统栏外观。
        // PhotoViewer / VideoScreen 在 TwoTabs 子树内，禁止再嵌套调用 PPScreen（否则外层 Paper 消费
        // safeDrawingPadding 后顶部露出 97px 浅色白条，且退出查看器时外层不重组导致状态栏图标卡死变白）。
        val photoViewerBody = topLevelBody("ui/PhotosScreen.kt", "private fun PhotoViewer(")
        val videoScreenBody = topLevelBody("ui/VideoScreen.kt", "fun VideoScreen(")
        val twoTabsBody = topLevelBody("ui/TwoTabs.kt", "fun TwoTabs(")
        val mainActivity = File(sourceRoot, "MainActivity.kt").readText()
        val tabsCall = mainActivity.substringAfter("TwoTabs(").substringBefore("photos = {")

        assertTrue(
            "PhotoViewer 在 TwoTabs 内，不得嵌套调用 PPScreen",
            !photoViewerBody.contains("PPScreen(") && !photoViewerBody.contains("PPScreen {"),
        )
        assertTrue(
            "VideoScreen 在 TwoTabs 内，不得嵌套调用 PPScreen",
            !videoScreenBody.contains("PPScreen(") && !videoScreenBody.contains("PPScreen {"),
        )
        assertTrue(
            "TwoTabs 必须把 background 参数透传给唯一顶层 PPScreen",
            twoTabsBody.contains("PPScreen(background = background)"),
        )
        assertTrue(
            "MainActivity 必须按 photoViewerOpen 切换 TwoTabs 背景色",
            tabsCall.contains("background = twoTabsBackground(viewerOpen = photoViewerOpen)"),
        )
    }

    @Test(expected = IllegalStateException::class)
    fun top_level_body_fails_fast_when_signature_is_missing() {
        // #1930：签名拼错/函数被改名时必须抛错，不能静默返回空串让调用方误判为绿。
        topLevelBody("ui/PhotosScreen.kt", "fun 不存在的函数签名(")
    }

    @Test
    fun viewer_screens_have_no_nested_ppscreen_anywhere_in_code() {
        // #1926 的补充：不只看 PhotoViewer / VideoScreen 两个函数体，还扫描两个文件里所有
        // 非注释代码行——查看器子树任何位置（PhotosScreen 本体、MediaViewer、PhotoViewer…）
        // 都不允许再套一层 PPScreen，否则外层安全区与系统栏外观会被第二层抢走。
        val violations = mutableListOf<String>()
        for (path in listOf("ui/PhotosScreen.kt", "ui/VideoScreen.kt")) {
            codeLines(path).forEach { line ->
                if (line.contains("PPScreen(") || line.contains("PPScreen {")) {
                    violations += "$path: $line"
                }
            }
        }
        assertTrue("查看器文件全文件代码不得嵌套 PPScreen（注释除外）：$violations", violations.isEmpty())
    }

    @Test
    fun viewer_open_is_reported_in_the_same_frame_not_deferred_before_recomposition() {
        val photos = File(sourceRoot, "ui/PhotosScreen.kt").readText()
        // 滞后写法：把 onViewerOpenChange 塞进 LaunchedEffect，要等重组后的下一帧协程才通知
        // 外层，打开/关闭查看器时 TwoTabs 背景色与系统栏图标会晚一帧（闪烁）。
        assertTrue(
            "onViewerOpenChange 不得放在 LaunchedEffect 里延后一帧",
            !Regex("""LaunchedEffect\s*\([^)]*\)\s*\{[^}]*onViewerOpenChange""", RegexOption.DOT_MATCHES_ALL)
                .containsMatchIn(photos),
        )
        val code = codeLines("ui/PhotosScreen.kt").joinToString("\n")
        assertTrue("查看器开关必须在同一帧同步调用 onViewerOpenChange(", code.contains("onViewerOpenChange("))
        assertTrue(
            "打开查看器必须走同一帧的 updateViewer 收口",
            code.contains("updateViewer(MediaViewerSession.open("),
        )
        assertTrue("关闭查看器必须走同一帧的 updateViewer 收口", code.contains("updateViewer(null)"))
    }

    @Test
    fun main_activity_wires_photo_viewer_open_into_two_tabs_background() {
        val mainActivity = File(sourceRoot, "MainActivity.kt").readText()
        val photosCall = callBlock(mainActivity, "PhotosScreen(")
        val twoTabsCall = callBlock(mainActivity, "TwoTabs(")
        assertTrue(
            "PhotosScreen 必须把查看器开关同步回写到 photoViewerOpen",
            photosCall.contains("onViewerOpenChange = { photoViewerOpen = it }"),
        )
        assertTrue(
            "TwoTabs 必须按 photoViewerOpen 切换背景色",
            twoTabsCall.contains("background = twoTabsBackground(viewerOpen = photoViewerOpen)"),
        )
        assertTrue(
            "查看器打开时必须隐藏底部 tab 栏",
            twoTabsCall.contains("showTabBar = !photoViewerOpen && !storageDetailOpen"),
        )
    }

    @Test
    fun ppscreen_tracks_nesting_and_restores_system_bar_appearance_on_background_change() {
        val ppscreen = File(sourceRoot, "ui/PPScreen.kt").readText()
        // #1926：显式守卫禁止运行时嵌套 PPScreen，同时用 DisposableEffect(window, view, lightAppearance)
        // 同步系统栏明暗，保证背景切换或重新进入时立即更新窗口系统栏外观。
        assertTrue("PPScreen 必须检测禁止嵌套", ppscreen.contains("LocalInsidePPScreen"))
        assertTrue("PPScreen 必须校验非嵌套前置条件", ppscreen.contains("check(!LocalInsidePPScreen.current)"))
        assertTrue("PPScreen 必须提供嵌套标记", ppscreen.contains("CompositionLocalProvider(LocalInsidePPScreen provides true)"))
        assertTrue("PPScreen 必须按 lightAppearance 同步系统栏外观", ppscreen.contains("DisposableEffect(view, lightAppearance)"))
    }

    @Test
    fun appearance_light_icons_are_wired_to_the_pure_function() {
        val ppscreen = File(sourceRoot, "ui/PPScreen.kt").readText()
        // 纯函数结果必须接到状态栏/导航栏图标明暗上。反证：删掉任一接线行（或整个 SideEffect 块）→ 本测试红。
        assertTrue("明暗必须来自纯函数 isAppearanceLightFor(background)", ppscreen.contains("val lightAppearance = isAppearanceLightFor(background)"))
        assertTrue("状态栏图标明暗接线缺失", ppscreen.contains("isAppearanceLightStatusBars = lightAppearance"))
        assertTrue("导航栏图标明暗接线缺失", ppscreen.contains("isAppearanceLightNavigationBars = lightAppearance"))
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
