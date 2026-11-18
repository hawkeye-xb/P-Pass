// P-Pass 圆角层：tokens.json radius 映射进 M3 Shapes。
//
// M3 只有五档，tokens 有五个可用尺寸（control-sm / control / control-mobile / card /
// pill）。pill（999）没有对应槽位，需要胶囊时页面用 CircleShape——M3 的槽位表达不了
// 「无穷大圆角」，硬塞一档会把它变成普通圆角。
package com.hawkeyexb.ppass.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

val PPShapes: Shapes = Shapes(
    extraSmall = RoundedCornerShape(12.dp), // radius.control-sm：菜单行
    small = RoundedCornerShape(14.dp), // radius.control：桌面按钮
    medium = RoundedCornerShape(20.dp), // radius.control-mobile：手机按钮
    large = RoundedCornerShape(20.dp), // radius.card：卡片
    extraLarge = RoundedCornerShape(20.dp), // radius.card：M3 没有更高一档，卡片与弹窗同 20
)
