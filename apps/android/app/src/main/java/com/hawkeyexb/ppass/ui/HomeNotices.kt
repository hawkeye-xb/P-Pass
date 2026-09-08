// UI-04a/c: 全局唯一提示呈现层（batch/ui-04a-c）。
//
// 既有提示已迁入：电池白名单 / 通知引导 / 中断恢复 / 取消轮入口 /
// 重传告知五条，统一在 [NoticeHost] 里构造候选列表 → [topNotice]
// 只渲染最高优先级的一条，其余全部收起。
//
// [HOME_NOTICE_PRIORITY] 的排序：
//   PAIRING_LOST (阻塞) 在最前，底下的 REUPLOAD (补充) 在最后——按
//   UI-04c 口径「阻塞备份的 > 需要授权的 > 补充信息的」。
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R

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

    /** A phone-deleted source cannot be sent again; informational only. */
    SOURCE_MISSING,

    /** MOB-59: X-05——取消轮次的重传常驻入口，不是可关闭的提示。 */
    CANCELLED_ROUND,
}

/** 优先级（越靠前越要紧）。UI-04c 口径：阻塞备份的 > 需要授权的 >
 *  补充信息的。 */
val HOME_NOTICE_PRIORITY: List<HomeNoticeKind> = listOf(
    HomeNoticeKind.PAIRING_LOST,
    HomeNoticeKind.BACKUP_INTERRUPTED,
    HomeNoticeKind.PARTIAL_ACCESS,
    HomeNoticeKind.BATTERY_WHITELIST,
    HomeNoticeKind.NOTIFICATION_PERMISSION,
    HomeNoticeKind.SOURCE_MISSING,
    HomeNoticeKind.CANCELLED_ROUND,
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

/**
 * UI-04a/c: the single, global notice presentation host.
 *
 * Reads the full set of user-facing notice inputs, builds every active
 * candidate as a [HomeNotice] (no presentation anywhere else), and renders
 * only `topNotice(candidates)` — the highest-priority active notice. All
 * others stay queued/off-screen. The trigger condition for each notice is a
 * verbatim copy of what used to live in HomeScreen; nothing about the
 * conditions changed, only where they are collected and how rendered.
 *
 * `pairingLost` / partial-access are intentionally NOT here: they have their
 * own dedicated hero / red-card presentation and are not amber one-liners.
 */
@Composable
fun NoticeHost(
    backupInterrupted: Boolean,
    batteryWhitelisted: Boolean,
    notificationSkipped: Boolean,
    cancelledRoundCount: Int?,
    reuploadCount: Int,
    onResumeBackup: () -> Unit,
    onOpenBatterySettings: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
    onRestoreCancelledRounds: () -> Unit,
    onAcknowledgeReupload: () -> Unit,
) {
    val candidates = buildList {
        if (backupInterrupted) add(
            HomeNotice(
                kind = HomeNoticeKind.BACKUP_INTERRUPTED,
                body = stringResource(R.string.backup_interrupted_body),
                actionLabel = stringResource(R.string.backup_interrupted_action),
                onAction = onResumeBackup,
            )
        )
        if (!batteryWhitelisted) add(
            HomeNotice(
                kind = HomeNoticeKind.BATTERY_WHITELIST,
                body = stringResource(R.string.dog_battery_body),
                actionLabel = stringResource(R.string.dog_battery_action),
                onAction = onOpenBatterySettings,
            )
        )
        if (notificationSkipped) add(
            HomeNotice(
                kind = HomeNoticeKind.NOTIFICATION_PERMISSION,
                body = stringResource(R.string.notif_nudge_body),
                actionLabel = stringResource(R.string.notif_nudge_action),
                onAction = onOpenNotificationSettings,
            )
        )
        if (cancelledRoundCount != null) add(
            HomeNotice(
                kind = HomeNoticeKind.CANCELLED_ROUND,
                body = stringResource(R.string.cancelled_round_notice_body, cancelledRoundCount),
                actionLabel = stringResource(R.string.cancelled_round_notice_restore),
                onAction = onRestoreCancelledRounds,
            )
        )
        if (reuploadCount > 0) add(
            HomeNotice(
                kind = HomeNoticeKind.REUPLOAD,
                body = stringResource(R.string.reupload_notice_body, reuploadCount),
                actionLabel = stringResource(R.string.reupload_notice_action),
                onAction = onAcknowledgeReupload,
            )
        )
    }
    topNotice(candidates)?.let { NoticeCard(it) }
}
