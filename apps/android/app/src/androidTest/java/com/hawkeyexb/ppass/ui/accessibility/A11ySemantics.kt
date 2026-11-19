// #1801 E2：Compose 读屏语义回归——宿主与取树工具。
//
// 断言对象 = UiAutomation 读到的 AccessibilityNodeInfo 树：这是 TalkBack 实际消费的
// 界面，也是 round3 真机 uiautomator dump 的同一口径（E2 与 E3 判同一种语义，
// 卡上验收「E2 Compose 语义覆盖名称/角色/状态/选中」在 a11y 边界上成立）。
//
// 宿主 = 本 App 自己的 MainActivity（ComponentActivity）：launch 之后把窗口内容换成
// 被测组件。为什么不用 androidx.test:core 的 BootstrapActivity——它是普通 Activity
// （不是 ComponentActivity），挂不上 Compose 需要的 ViewTreeLifecycleOwner /
// SavedStateRegistryOwner；也不新增 test 清单或 gradle 依赖（本卡不改构建配置）。
// MainActivity 的欢迎页会先渲染一两秒（身份解析），替换内容后即为被测界面。
//
// 只在本测试进程内生效：setContentView 只换了测试里这个 activity 实例的内容，
// 不写任何生产状态、不发请求。

package com.hawkeyexb.ppass.ui.accessibility

import android.app.Activity
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.ComposeView
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.hawkeyexb.ppass.MainActivity
import com.hawkeyexb.ppass.ui.PPTheme
import java.io.File

internal val testContext get() = InstrumentationRegistry.getInstrumentation().targetContext

/** 起本 App 的 MainActivity，把窗口内容换成 [content]，随后在 [block] 里做断言（activity 保持前台）。 */
internal fun hostCompose(content: @Composable () -> Unit, block: () -> Unit) {
    ActivityScenario.launch(MainActivity::class.java).use { scenario ->
        scenario.onActivity { activity: Activity ->
            val composeView = ComposeView(activity)
            composeView.setContent { PPTheme { content() } }
            activity.setContentView(composeView)
        }
        block()
    }
}

private val uiAutomation get() = InstrumentationRegistry.getInstrumentation().uiAutomation

internal fun a11yRoot(): AccessibilityNodeInfo? = uiAutomation.rootInActiveWindow

/** 先序遍历一棵 a11y 子树（节点可能在树更新后失效，取子节点失败按没有算）。 */
internal fun walk(root: AccessibilityNodeInfo): Sequence<AccessibilityNodeInfo> = sequence {
    val queue = ArrayDeque<AccessibilityNodeInfo>()
    queue.add(root)
    while (queue.isNotEmpty()) {
        val cur = queue.removeFirst()
        yield(cur)
        for (i in 0 until cur.childCount) {
            runCatching { cur.getChild(i) }.getOrNull()?.let { queue.add(it) }
        }
    }
}

internal fun nodeIn(root: AccessibilityNodeInfo, pred: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? =
    walk(root).firstOrNull(pred)

/** 轮询等一个满足 [pred] 的节点（树由 Compose 异步发布，等它出现）。超时把整棵树打进失败消息。 */
internal fun awaitNode(desc: String, timeoutMs: Long = 10_000, pred: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
    val deadline = SystemClock.elapsedRealtime() + timeoutMs
    while (SystemClock.elapsedRealtime() < deadline) {
        a11yRoot()?.let { root -> nodeIn(root, pred)?.let { return it } }
        Thread.sleep(200)
    }
    throw AssertionError("没等到节点：$desc；当前树：\n${describeTree()}")
}

/** 自己或最近的 checkable 祖先——卡/开关行的语义挂在可点容器上，文本节点自己不带状态。 */
internal fun AccessibilityNodeInfo.checkableSelfOrAncestor(): AccessibilityNodeInfo? {
    var cur: AccessibilityNodeInfo? = this
    while (cur != null) {
        if (cur.isCheckable) return cur
        cur = runCatching { cur.parent }.getOrNull()
    }
    return null
}

/** 自己或最近的可点祖先——单次入口行、按钮行同理。 */
internal fun AccessibilityNodeInfo.clickableSelfOrAncestor(): AccessibilityNodeInfo? {
    var cur: AccessibilityNodeInfo? = this
    while (cur != null) {
        if (cur.isClickable) return cur
        cur = runCatching { cur.parent }.getOrNull()
    }
    return null
}

/** 人类可读的整棵树（class/text/cd/checkable/checked/clickable/stateDesc/bounds-dp），失败消息与证据文件共用。 */
internal fun describeTree(root: AccessibilityNodeInfo? = a11yRoot()): String {
    if (root == null) return "(没有活动窗口)"
    val density = testContext.resources.displayMetrics.density
    val out = StringBuilder()
    for (n in walk(root)) {
        val b = Rect()
        runCatching { n.getBoundsInScreen(b) }
        val state = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) n.stateDescription?.toString() else null
        out.append(
            "class=${n.className} text=${n.text?.toString()} cd=${n.contentDescription?.toString()} " +
                "chk=${n.isCheckable}/${n.isChecked} clk=${n.isClickable} sel=${n.isSelected} " +
                "stateDesc=$state dp=${(b.width() / density).toInt()}x${(b.height() / density).toInt()}\n",
        )
    }
    return out.toString()
}

/** 证据：把断言看到的整棵树写成人类可读文件，存到 App 外部目录（跑完 pull 进 .evidence）。 */
internal fun saveTree(name: String, root: AccessibilityNodeInfo?) {
    val dir = testContext.getExternalFilesDir(null) ?: return
    val d = File(dir, "a11y-e2")
    d.mkdirs()
    File(d, name).writeText(describeTree(root))
}
