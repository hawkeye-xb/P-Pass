// 品牌色主题：M3 组件的默认色只能来自 PPColor，不许落到 M3 基线配色。
//
// 起因：工程原本没有 MaterialTheme，设置页开关在真机上是 M3 基线紫 #6750A4。
// PPColorScheme 是普通 val，JVM 单测直接读每个槽位（真行为）；「根部真的包了
// PPTheme」「开关开启色是 Safe」是 Composable 接线，本仓无 Robolectric，由末尾
// 源文本门禁钉住。
package com.hawkeyexb.ppass.ui

import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ThemeBrandColorTest {

    private val brand: Set<Color> = PPColor::class.java.declaredMethods
        .filter { it.parameterCount == 0 && it.returnType == Long::class.javaPrimitiveType && it.name.startsWith("get") }
        .map { Color((it.invoke(PPColor) as Long).toULong()) }
        .toSet()

    /** ColorScheme 的全部颜色槽位（Color 是 inline class，JVM 上 getter 返回 long）。 */
    private fun slots(scheme: Any): Map<String, Color> = scheme.javaClass.declaredMethods
        .filter { it.parameterCount == 0 && it.returnType == Long::class.javaPrimitiveType && it.name.startsWith("get") }
        .associate { it.name.substringBefore('-') to Color((it.invoke(scheme) as Long).toULong()) }

    @Test
    fun every_slot_comes_from_ppcolor() {
        val all = slots(PPColorScheme)
        assertTrue("反射没取到槽位，测试本身失效", all.size >= 30)
        // scrim 是遮罩用的半透明黑，不是品牌色，保留 M3 默认。
        val leaked = all.filterKeys { it != "getScrim" }.filterValues { it !in brand }
        assertTrue("这些槽位没映射到 PPColor，会落到 M3 基线色：$leaked", leaked.isEmpty())
    }

    @Test
    fun reverse_check_baseline_scheme_is_caught() {
        // 反证：M3 基线配色（即修复前的状态）必须被上面的判据判红。
        val leaked = slots(lightColorScheme()).filterKeys { it != "getScrim" }.filterValues { it !in brand }
        assertTrue("基线紫 primary 必须被判为泄漏", "getPrimary" in leaked)
        assertEquals(Color(0xFF6750A4), leaked["getPrimary"])
    }

    @Test
    fun primary_is_ink_not_safe() {
        // 与 iOS 根部 tint = ink 对齐；绿色只表示安全，不能当通用强调色。
        assertEquals(PPColor.Ink, PPColorScheme.primary)
        assertEquals(PPColor.Paper, PPColorScheme.onPrimary)
        assertEquals(PPColor.Paper, PPColorScheme.surfaceContainerHigh) // AlertDialog 底
        assertEquals(PPColor.Act, PPColorScheme.error)
    }

    // ── 源文本门禁：只钉接线还在 ──

    @Test
    fun root_content_is_wrapped_in_pptheme() {
        val main = File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()
        // #1106：身份门（IdentityGate）在主题里面、App 外面——拒绝启动页也要走品牌主题。
        assertTrue(
            "setContent 必须包 PPTheme",
            main.contains("setContent { PPTheme { IdentityGate((application as PPassApplication).identity) { PPassApp() } } }"),
        )
    }

    @Test
    fun rule_switch_on_color_is_safe() {
        val home = File("src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt").readText()
        val row = home.substringAfter("private fun RuleSwitchRow(").substringBefore("\n}\n")
        assertTrue("开关开启轨道必须是 PPColor.Safe（对齐 iOS Toggle tint）", row.contains("checkedTrackColor = PPColor.Safe"))
    }
}
