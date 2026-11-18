// 明暗两套配色。
//
// tokens.json 只有一套颜色，品牌语言也要求颜色一律以它为准、不许自创。所以深色模式
// 沿用同一套值：暖纸外观是产品设计，不是缺省主题。这里保留独立的深色入口，等设计
// 给出暗色 token 时只改这一处，根部接线不用动。
package com.hawkeyexb.ppass.ui.theme

import androidx.compose.material3.ColorScheme
import com.hawkeyexb.ppass.ui.PPColorScheme

val PPDarkColorScheme: ColorScheme = PPColorScheme
