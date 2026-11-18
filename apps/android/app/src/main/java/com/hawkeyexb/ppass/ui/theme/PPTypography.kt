// P-Pass 字体层：把 tokens.json 的字族与 mobile-ui.type 的字号映射进 M3 Typography。
//
// 只映射 tokens.json 记过的档位；没记过的槽位保持 M3 默认。等宽（验证码、电脑标识）
// 由页面显式 copy FontFamily.Monospace，不在主题里强制——同一个 bodySmall 也用于
// 来源卡数量这类正文，强制等宽会改错地方。
//
// 尺寸以 tokens 为准，测试 PPThemeTokensTest 逐个读 tokens.json 比对，防止漂移。
package com.hawkeyexb.ppass.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.ui.PPFont

private val base = Typography()

val PPTypography: Typography = base.copy(
    // mobile-ui.type.hero-number：英雄卡大数字 40，衬线 Regular。行高不写死：tokens 只登记字号，
    // 自拟行高就是自创，沿用 M3 的 64。
    displayLarge = base.displayLarge.copy(fontFamily = PPFont.Serif, fontSize = 40.sp),
    // mobile-ui.type.pair-code：tokens 注明 Android displayMedium 45。
    displayMedium = base.displayMedium.copy(fontFamily = PPFont.Sans, fontWeight = FontWeight.Bold),
    // mobile-ui.type.pair-name：电脑名 titleLarge 22 粗体。
    titleLarge = base.titleLarge.copy(fontFamily = PPFont.Sans, fontWeight = FontWeight.Bold),
    // mobile-ui.type.card-title：卡片标题 16 粗体。
    titleMedium = base.titleMedium.copy(fontFamily = PPFont.Sans, fontWeight = FontWeight.Bold),
    // mobile-ui.type.row-label：设置行标签 15。
    titleSmall = base.titleSmall.copy(fontFamily = PPFont.Sans, fontSize = 15.sp),
    // mobile-ui.type.card-body（14）之上的一档正文，字族取 sans。
    bodyLarge = base.bodyLarge.copy(fontFamily = PPFont.Sans),
    // mobile-ui.type.card-body：卡片正文 14。
    bodyMedium = base.bodyMedium.copy(fontFamily = PPFont.Sans),
    // mobile-ui.type.pair-identity：tokens 注明 Android bodySmall 12。
    bodySmall = base.bodySmall.copy(fontFamily = PPFont.Sans),
    // mobile-ui.type.pair-label：配对页小标签 labelLarge 14（tokens 没写粗体，字重不在这里加）。
    labelLarge = base.labelLarge.copy(fontFamily = PPFont.Sans),
    // mobile-ui.type.row-value：设置行右侧的值 14。
    labelMedium = base.labelMedium.copy(fontFamily = PPFont.Sans, fontSize = 14.sp),
    // mobile-ui.type.row-hint：开关下的说明 12。
    labelSmall = base.labelSmall.copy(fontFamily = PPFont.Sans, fontSize = 12.sp),
)
