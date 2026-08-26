// MOB-37: 常驻提示的最小骨架——**给 UI-04 留的接口**，不是完整框架。
//
// ## 为什么在这里放一个骨架而不是直接写进 HomeScreen
//
// UI-04 要做的正是「多条提示堆叠没有优先级 / 提示只出现在总览」。两张卡
// 都会动提示的呈现层，卡面写明「谁先落地谁把优先级框架搭好」。本卡先到，
// 于是把新增的这条重传告知做成**数据**（[HomeNotice]）+ 一个统一渲染的
// 卡片（[NoticeCard]）+ 一个纯函数挑选器（[topNotice]），而不是又在
// HomeScreen 里硬编码一段 Surface。
//
// ## 刻意没做的事
//
// **既有的四条提示（部分授权 / 配对失效 / 电池白名单 / 通知引导 /
// 中断恢复）没有迁进来。** 迁移是 UI-04 的活，且会跟正在进行中的
// HomeScreen 改动撞车。本卡只保证：新增的这条从第一天就是可接入的形状，
// UI-04 把其余几条包成 [HomeNotice] 丢进 [topNotice] 即可，不用返工。
//
// [HOME_NOTICE_PRIORITY] 的排序是**提案**，UI-04 可以重排：那张卡建议的
// 口径是「阻塞备份的 > 需要授权的 > 补充信息的」，重传告知属于补充信息
// （照片已经在传回来了，用户不做任何动作也没事）。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** 一条常驻提示是哪一类（优先级排序的依据，见 [HOME_NOTICE_PRIORITY]）。 */
enum class HomeNoticeKind {
    /** 配对失效——备份完全停了，最要紧。 */
    PAIRING_LOST,

    /** MOB-28: 后台备份被外力停过，点一下才恢复。 */
    BACKUP_INTERRUPTED,

    /** 只授权了部分照片——范围被悄悄削掉。 */
    PARTIAL_ACCESS,

    /** 电池优化没加白——后台可能被杀。 */
    BATTERY_WHITELIST,

    /** 通知权限没授——告知送不到。 */
    NOTIFICATION_PERMISSION,

    /** MOB-37: 库里少了照片、正在传回来。补充信息类：用户不动手也没事。 */
    REUPLOAD,
}

/** 优先级**提案**（越靠前越要紧）。UI-04 可重排，见文件头注释。 */
val HOME_NOTICE_PRIORITY: List<HomeNoticeKind> = listOf(
    HomeNoticeKind.PAIRING_LOST,
    HomeNoticeKind.BACKUP_INTERRUPTED,
    HomeNoticeKind.PARTIAL_ACCESS,
    HomeNoticeKind.BATTERY_WHITELIST,
    HomeNoticeKind.NOTIFICATION_PERMISSION,
    HomeNoticeKind.REUPLOAD,
)

/** 一条常驻提示的全部数据。文案已解析成字符串（`stringResource` 在
 *  调用侧取，好让这个类型能进 JVM 单测）。 */
data class HomeNotice(
    val kind: HomeNoticeKind,
    val body: String,
    val actionLabel: String? = null,
    val onAction: () -> Unit = {},
)

/**
 * 同时满足多条时该显示哪一条——**纯函数**，JVM 单测直接跑。
 *
 * 未登记在 [HOME_NOTICE_PRIORITY] 里的类别排在最后（新增提示忘了登记也
 * 不会消失，只是排到末位）。
 */
fun topNotice(notices: List<HomeNotice>): HomeNotice? =
    notices.minByOrNull { n ->
        HOME_NOTICE_PRIORITY.indexOf(n.kind).let { if (it < 0) Int.MAX_VALUE else it }
    }

/** 琥珀底一句话 + 右侧下划线动作——与电池白名单/通知引导/中断恢复
 *  同一族视觉（设计稿 layout-v1 的提示条）。 */
@Composable
fun NoticeCard(notice: HomeNotice) {
    Surface(
        color = PPColor.WaitingBg,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier.padding(16.dp, 13.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                notice.body,
                fontSize = 13.5.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                modifier = Modifier.weight(1f),
            )
            if (notice.actionLabel != null) {
                Spacer(Modifier.width(12.dp))
                Text(
                    notice.actionLabel,
                    fontSize = 14.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                    textDecoration = TextDecoration.Underline,
                    modifier = Modifier.clickable(onClick = notice.onAction).padding(4.dp),
                )
            }
        }
    }
}
