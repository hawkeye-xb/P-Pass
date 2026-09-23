// UI-04a/c: 全局唯一提示呈现层（batch/ui-04a-c）。
//
// 既有提示已迁入：中断恢复，统一在 [NoticeHost] 里构造候选
// 列表 → [topNotice]，只渲染最高优先级的一条，其余全部收起。
//
// #418：「电脑上少了照片、正在重新传回」（REUPLOAD，MOB-37）已删除——新模型里
// 桌面缺失由慢路径**自动补传、不打扰**（#413），这条提示没有数据源，接不上就删。
//
// 2026-09-14（用户拍板）：取消不走这条常驻琥珀警告条——用户主动取消是
// 正常操作，不该被塑造成"未处理的问题"。#418：取消轮与它的恢复入口已删除，
// 设置卡里只剩「取消剩余 N 张」一行（见 HomeScreen.kt 的 cancelRemainingCount）。
//
// [HOME_NOTICE_PRIORITY] 的排序：
//   PAIRING_LOST (阻塞) 在最前，底下的 SOURCE_MISSING (补充) 在最后——按
//   UI-04c 口径「阻塞备份的 > 需要授权的 > 补充信息的」。
//
// UI-12（2026-09-15，用户真机反馈）：后台备份被系统限制（白名单被撤 /
// 监听被系统清掉）这两个真出问题的状态，此前完全绕开了这个"全局唯一
// 提示宿主"，另起一套埋在设置页普通 CellRow 里——跟本文件这段注释自己
// 声明的契约（"要看的东西只在一个地方"）矛盾，用户反馈"起不到通知作用"。
// 现已接入 BACKUP_INTERRUPTED 候选。同时补上非阻断类缺失的"知道了"二级
// 动作——此前只有"处理"一个动作，逼用户要么处理要么把整个自动备份关掉，
// 没有"知悉但暂不处理"的中间态。
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
import com.hawkeyexb.ppass.backup.BackgroundBackupState

/** 一条常驻提示是哪一类（优先级排序的依据，见 [HOME_NOTICE_PRIORITY]）。 */
enum class HomeNoticeKind {
    /** 配对失效——备份完全停了，最要紧。 */
    PAIRING_LOST,

    /** MOB-28/UI-12: 后台备份被外力停过（白名单被撤/监听被系统清掉），
     *  点一下才恢复。 */
    BACKUP_INTERRUPTED,

    /** 只授权了部分照片——范围被悄悄削掉。 */
    PARTIAL_ACCESS,


    /** A phone-deleted source cannot be sent again; informational only. */
    SOURCE_MISSING,
}

/** 优先级（越靠前越要紧）。UI-04c 口径：阻塞备份的 > 需要授权的 >
 *  补充信息的。 */
val HOME_NOTICE_PRIORITY: List<HomeNoticeKind> = listOf(
    HomeNoticeKind.PAIRING_LOST,
    HomeNoticeKind.BACKUP_INTERRUPTED,
    HomeNoticeKind.PARTIAL_ACCESS,

    HomeNoticeKind.SOURCE_MISSING,
)

/** 一条常驻提示的全部数据。文案已解析成字符串（`stringResource` 在
 *  调用侧取，好让这个类型能进 JVM 单测）。
 *
 *  UI-12: [critical] 决定视觉分级——阻断性问题（目前只有 [PAIRING_LOST]
 *  自己的红卡，不经过本类型）用强色；本类型目前构造的候选都不是阻断性
 *  的，默认 `false`（温和琥珀色）。[dismissLabel]/[onDismiss] 是"知道了/
 *  暂不处理"二级动作，跟 [actionLabel]（"去处理"）分开——阻断性通知不该
 *  提供忽略动作，因此把 `critical=true` 和非空 `dismissLabel` 同时设置
 *  视为调用方的用法错误（不在此处防御，防御在调用侧的判断分支里）。 */
data class HomeNotice(
    val kind: HomeNoticeKind,
    val body: String,
    val actionLabel: String? = null,
    val onAction: () -> Unit = {},
    val critical: Boolean = false,
    val dismissLabel: String? = null,
    val onDismiss: () -> Unit = {},
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
 *  同一族视觉（设计稿 layout-v1 的提示条）。UI-12: `critical` 切到强色
 *  （与 `PPColor.Act`/`ActBg` 同一族，跟"配对失效"红卡用的是同一套
 *  语义色），"知道了"用比处理动作更弱的视觉（无下划线、Ink40）区分
 *  主次两个动作。 */
@Composable
fun NoticeCard(notice: HomeNotice) {
    val bg = if (notice.critical) PPColor.ActBg else PPColor.WaitingBg
    val bodyColor = if (notice.critical) PPColor.Act else PPColor.Ink60
    Surface(
        color = bg,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier.padding(16.dp, 13.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                notice.body,
                fontSize = 13.5.sp, lineHeight = 20.sp, color = bodyColor,
                modifier = Modifier.weight(1f),
            )
            if (notice.dismissLabel != null) {
                Spacer(Modifier.width(10.dp))
                Text(
                    notice.dismissLabel,
                    fontSize = 13.sp, fontWeight = FontWeight.Medium, color = PPColor.Ink40,
                    modifier = Modifier.clickable(onClick = notice.onDismiss).padding(4.dp),
                )
            }
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
 *
 * UI-12（2026-09-15，用户判断二次修正）：[backgroundBackupState] 的横幅
 * **不再提供"知道了"**——它和设置页那行琥珀 hint 描述的是同一个事实，两个
 * 入口不能给出两个不同的承诺（横幅说"已读不打扰"、hint 说"问题还在"）。
 * 唯一的退出路径是把"自动备份"配置改成跟现状一致（关掉开关），不维护
 * 一个独立的"已忽略"状态。
 */
@Composable
fun NoticeHost(
    backgroundBackupState: BackgroundBackupState = BackgroundBackupState.OffByUser,
    onResolveBackgroundBackup: () -> Unit = {},
) {
    val candidates = buildList {
        val bodyRes = when (backgroundBackupState) {
            BackgroundBackupState.NeedsSystemAuthorization ->
                R.string.background_backup_needs_authorization
            BackgroundBackupState.SystemStoppedWatcher ->
                R.string.background_backup_system_stopped
            else -> null
        }
        if (bodyRes != null) add(
            HomeNotice(
                kind = HomeNoticeKind.BACKUP_INTERRUPTED,
                body = stringResource(bodyRes),
                actionLabel = stringResource(R.string.background_backup_notice_action),
                onAction = onResolveBackgroundBackup,
            )
        )
    }
    topNotice(candidates)?.let { NoticeCard(it) }
}
