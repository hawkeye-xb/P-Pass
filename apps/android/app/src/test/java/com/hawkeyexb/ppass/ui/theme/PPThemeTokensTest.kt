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
