// 配对验证码页的主次：验证码 > 电脑名 > 说明 > 电脑标识（扫码后直接到这一屏，#1118）。
// 字号来自 Material 字号体系（这里用默认 Typography，App 里是 MaterialTheme.typography，主题没有自定义字号），
// tokens.json mobile-ui.type.pair-* 记的就是这些值——两边不许各写各的数。
package com.hawkeyexb.ppass.ui

import androidx.compose.material3.Typography
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairCodeTypeTest {
    private val type = pairCodeType(Typography())

    @Test fun codeOutranksNameOutranksBodyOutranksIdentity() {
        val code = type.code.fontSize.value
        val name = type.name.fontSize.value
        val body = type.body.fontSize.value
        val identity = type.identity.fontSize.value
        assertTrue("验证码 $code > 电脑名 $name", code > name)
        assertTrue("电脑名 $name > 说明 $body", name > body)
        assertTrue("说明 $body > 标识 $identity", body > identity)
    }

    @Test fun tokensRecordTheActualSizes() {
        val mobileType = Json.parseToJsonElement(File("../../../assets/design/tokens.json").readText())
            .jsonObject["mobile-ui"]!!.jsonObject["type"]!!.jsonObject
        fun token(key: String) = mobileType[key]!!.jsonObject["value"]!!.jsonPrimitive.content.removeSuffix("px").toFloat()
        assertEquals(token("pair-label"), type.label.fontSize.value)
        assertEquals(token("pair-name"), type.name.fontSize.value)
        assertEquals(token("pair-code"), type.code.fontSize.value)
        assertEquals(token("pair-body"), type.body.fontSize.value)
        assertEquals(token("pair-identity"), type.identity.fontSize.value)
    }
}
