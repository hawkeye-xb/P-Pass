// 主题层不许有自己的颜色、字号、圆角：全部来自 assets/design/tokens.json。
//
// ThemeBrandColorTest 只证明 M3 槽位取自 PPColor；那条链的第一环——PPColor 本身有没有
// 和 tokens.json 漂移——没人查过。这里直接读 tokens.json 比对，颜色、字号、圆角三节都钉住，
// 并留一条反证：M3 基线 Typography/Shapes 必须被判红。
package com.hawkeyexb.ppass.ui.theme

import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Density
import com.hawkeyexb.ppass.ui.PPColor
import com.hawkeyexb.ppass.ui.PPFont
import java.io.File
import kotlin.math.roundToInt
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PPThemeTokensTest {
    private val tokens = Json.parseToJsonElement(File("../../../assets/design/tokens.json").readText()).jsonObject
    private val colors = tokens["color"]!!.jsonObject
    private val type = tokens["mobile-ui"]!!.jsonObject["type"]!!.jsonObject
    private val radius = tokens["radius"]!!.jsonObject

    private fun tokenColor(key: String): Color = parseColor(colors[key]!!.jsonObject["value"]!!.jsonPrimitive.content)
    private fun tokenPx(key: String): Float =
        type[key]!!.jsonObject["value"]!!.jsonPrimitive.content.removeSuffix("px").toFloat()

    private fun tokenRadius(key: String): Float = radius[key]!!.jsonObject["value"]!!.jsonPrimitive.content.removeSuffix("px").toFloat()

    /** Mongo 名字：tokens 的 kebab 键对应 PPColor 的 Pascal 常量（ink-60 → Ink60）。 */
    private fun pascal(key: String) = key.split("-").joinToString("") { p ->
        p.replaceFirstChar { it.uppercaseChar() }
    }

    private fun ppColor(name: String): Color {
        // Color 是 inline class，getter 名带 mangled 后缀（getPaper-0d7_KjU），按前缀找。
        val getter = PPColor::class.java.declaredMethods.single {
            it.name.startsWith("get") && it.name.substringBefore('-') == "get$name"
        }
        return Color((getter.invoke(PPColor) as Long).toULong())
    }

    private fun allPPColors(): Map<String, Color> = PPColor::class.java.declaredMethods
        .filter { it.parameterCount == 0 && it.returnType == Long::class.javaPrimitiveType && it.name.startsWith("get") }
        .associate { it.name.removePrefix("get").substringBefore('-') to Color((it.invoke(PPColor) as Long).toULong()) }

    @Test
    fun every_token_colour_has_the_same_value_in_ppcolor() {
        assertTrue("tokens.json 没读到颜色", colors.size >= 18)
        for (key in colors.keys) {
            assertEquals("tokens.json color.$key 与 PPColor.${pascal(key)} 不一致", tokenColor(key), ppColor(pascal(key)))
        }
    }

    @Test
    fun ppcolor_has_no_colour_outside_tokens() {
        // PaperDim 是从 paper 派生的半透明叠加色（暗背景上的弱化文字），tokens 里没有
        // 单独登记；其余常量都必须能在 tokens.json 找到同值。
        val allowed = colors.keys.map { tokenColor(it) }.toSet()
        val extra = allPPColors().filterKeys { it != "PaperDim" }.filterValues { it !in allowed }
        assertTrue("这些 PPColor 常量不在 tokens.json 里：$extra", extra.isEmpty())
    }

    @Test
    fun typography_sizes_come_from_mobile_ui_type() {
        assertEquals(tokenPx("hero-number"), PPTypography.displayLarge.fontSize.value, 0.01f)
        assertEquals(tokenPx("pair-code"), PPTypography.displayMedium.fontSize.value, 0.01f)
        assertEquals(tokenPx("pair-name"), PPTypography.titleLarge.fontSize.value, 0.01f)
        assertEquals(tokenPx("card-title"), PPTypography.titleMedium.fontSize.value, 0.01f)
        assertEquals(tokenPx("row-label"), PPTypography.titleSmall.fontSize.value, 0.01f)
        assertEquals(tokenPx("card-body"), PPTypography.bodyMedium.fontSize.value, 0.01f)
        assertEquals(tokenPx("pair-identity"), PPTypography.bodySmall.fontSize.value, 0.01f)
        assertEquals(tokenPx("pair-label"), PPTypography.labelLarge.fontSize.value, 0.01f)
        assertEquals(tokenPx("row-value"), PPTypography.labelMedium.fontSize.value, 0.01f)
        assertEquals(tokenPx("row-hint"), PPTypography.labelSmall.fontSize.value, 0.01f)
    }

    @Test
    fun baseline_typography_is_caught() {
        // 反证：M3 基线字号（映射前 App 拿到的值）必须被判红——11 ≠ tokens 的 12。
        assertEquals(11f, Typography().labelSmall.fontSize.value, 0.01f)
        assertTrue(Typography().labelSmall.fontSize.value != tokenPx("row-hint"))
    }

    @Test
    fun families_follow_tokens_fonts() {
        // tokens.json font.serif = Newsreader（标题/结论句）、font.sans = Manrope（正文/界面）；
        // PPFont 的字体文件就是这两个（res/font/newsreader_*、manrope_*）。
        val serif = tokens["font"]!!.jsonObject["serif"]!!.jsonObject["value"]!!.jsonPrimitive.content
        val sans = tokens["font"]!!.jsonObject["sans"]!!.jsonObject["value"]!!.jsonPrimitive.content
        assertTrue("tokens font.serif 不是 Newsreader：$serif", serif.contains("Newsreader"))
        assertTrue("tokens font.sans 不是 Manrope：$sans", sans.contains("Manrope"))
        val base = Typography()
        // hero-number 是衬线档；其余映射过的槽位都是正文/界面档。
        assertEquals(PPFont.Serif, PPTypography.displayLarge.fontFamily)
        val sansSlots = listOf(
            PPTypography.displayMedium, PPTypography.titleLarge, PPTypography.titleMedium,
            PPTypography.titleSmall, PPTypography.bodyLarge, PPTypography.bodyMedium,
            PPTypography.bodySmall, PPTypography.labelLarge, PPTypography.labelMedium,
            PPTypography.labelSmall,
        )
        for (slot in sansSlots) assertEquals(PPFont.Sans, slot.fontFamily)
        // 衬线档换成 sans（或反排）必须被判红。
        assertTrue(base.displayLarge.fontFamily != PPTypography.displayLarge.fontFamily)
    }

    @Test
    fun line_heights_are_not_invented() {
        // tokens 只登记字号；行高写死就是自创。所有映射槽位的行高必须还是 M3 的默认值。
        val base = Typography()
        val pairs = listOf(
            "displayLarge" to (base.displayLarge to PPTypography.displayLarge),
            "displayMedium" to (base.displayMedium to PPTypography.displayMedium),
            "titleLarge" to (base.titleLarge to PPTypography.titleLarge),
            "titleMedium" to (base.titleMedium to PPTypography.titleMedium),
            "titleSmall" to (base.titleSmall to PPTypography.titleSmall),
            "bodyLarge" to (base.bodyLarge to PPTypography.bodyLarge),
            "bodyMedium" to (base.bodyMedium to PPTypography.bodyMedium),
            "bodySmall" to (base.bodySmall to PPTypography.bodySmall),
            "labelLarge" to (base.labelLarge to PPTypography.labelLarge),
            "labelMedium" to (base.labelMedium to PPTypography.labelMedium),
            "labelSmall" to (base.labelSmall to PPTypography.labelSmall),
        )
        for ((name, slots) in pairs) {
            val (default, mapped) = slots
            assertEquals("PPTypography.$name 的行高是自创值", default.lineHeight.value, mapped.lineHeight.value, 0.01f)
        }
    }

    @Test
    fun shapes_come_from_radius_tokens() {
        val allowed = radius.keys.map { tokenRadius(it) }.toSet() + setOf(0f)
        val density = object : Density {
            override val density = 1f
            override val fontScale = 1f
        }
        for ((name, shape) in shapeSlots(PPShapes)) {
            val px = shape.topStart.toPx(Size.Zero, density)
            assertTrue("PPShapes.$name = ${px}dp 不在 tokens.json radius 里", px in allowed)
        }
        assertEquals(tokenRadius("control-sm"), PPShapes.extraSmall.topStart.toPx(Size.Zero, density), 0.01f)
        assertEquals(tokenRadius("control"), PPShapes.small.topStart.toPx(Size.Zero, density), 0.01f)
        assertEquals(tokenRadius("control-mobile"), PPShapes.medium.topStart.toPx(Size.Zero, density), 0.01f)
        assertEquals(tokenRadius("card"), PPShapes.large.topStart.toPx(Size.Zero, density), 0.01f)
        assertEquals(tokenRadius("card"), PPShapes.extraLarge.topStart.toPx(Size.Zero, density), 0.01f)
    }

    @Test
    fun theme_hands_typography_and_shapes_down_from_the_root() {
        // Composable 接线本仓没有 Robolectric，用源文本钉住根 MaterialTheme 真的带上了三件套。
        val theme = File("src/main/java/com/hawkeyexb/ppass/ui/Theme.kt").readText()
        val call = theme.substringAfter("MaterialTheme(").substringBefore("content = content")
        assertTrue("根 MaterialTheme 必须下发 colorScheme", call.contains("colorScheme ="))
        assertTrue("根 MaterialTheme 必须下发 typography = PPTypography", call.contains("typography = PPTypography"))
        assertTrue("根 MaterialTheme 必须下发 shapes = PPShapes", call.contains("shapes = PPShapes"))
    }

    @Test
    fun app_does_not_follow_system_dark_mode() {
        // #1872 产品定案：本期不实现深色外观，暖纸是唯一外观——系统明暗取到的是同一套配色。
        // 本仓没有 Robolectric，Composable 的运行时配色取不到，这里钉住的是「App 里不存在跟随
        // 系统深色的依赖、也不存在第二套配色」这条真实约束：把跟随分支或暗色一套加回来必须变红。
        val sources = File("src/main/java/com/hawkeyexb/ppass")
            .walkTopDown().filter { it.isFile && it.extension == "kt" }
            .associate { it.name to codeOnly(it.readText()) }
        assertTrue("没扫到 App 源码，测试本身失效", sources.size >= 100)
        val following = sources.filterValues(::followsSystemDark)
        assertTrue("这些文件让外观跟随了系统深色：${following.keys}", following.isEmpty())
        // 反证：修复前的写法必须被这条判据抓住。
        assertTrue(
            "判据抓不住修复前的写法",
            followsSystemDark("colorScheme = if (darkTheme) PPDarkColorScheme else PPColorScheme"),
        )
    }

    /** 判定的是行为不是措辞：注释里提到这些名字不算跟随。 */
    private fun codeOnly(source: String): String =
        source.replace(blockComment, "").lineSequence().joinToString("\n") { it.substringBefore("//") }

    private val blockComment = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

    /** 跟随系统深色的三种写法：读系统标志、建一套暗色配色、引用暗色配色。 */
    private fun followsSystemDark(source: String): Boolean =
        source.contains("isSystemInDarkTheme") ||
            source.contains("darkColorScheme(") ||
            source.contains("PPDarkColorScheme")

    private fun shapeSlots(shapes: Shapes): Map<String, CornerBasedShape> = mapOf(
        "extraSmall" to shapes.extraSmall,
        "small" to shapes.small,
        "medium" to shapes.medium,
        "large" to shapes.large,
        "extraLarge" to shapes.extraLarge,
    )

    private val rgba = Regex("""rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)""")

    private fun parseColor(value: String): Color {
        val text = value.trim()
        if (text.startsWith("#")) return Color(("FF" + text.removePrefix("#")).toLong(16))
        val m = rgba.matchEntire(text) ?: error("看不懂的颜色值：$value")
        val (r, g, b) = m.groupValues.subList(1, 4).map { it.toFloat().roundToInt() }
        val alpha = m.groupValues[4].ifEmpty { "1" }.toFloat()
        return Color(r, g, b, (alpha * 255f).roundToInt())
    }
}
