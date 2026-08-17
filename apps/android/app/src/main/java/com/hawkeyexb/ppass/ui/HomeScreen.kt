// T-080 Backup tab — aligned to layout v1 (docs/design/2026-08-05-layout-v1):
// 恒真三元组英雄卡（M / N 张已回家 + 最近成功 + 待备份 K）+ 进行中可暂停
// + 失败才说话（Trouble/配对失效红卡）+ 备份规则卡 + 底部红字断开。
// 状态条文案由纯函数 statusLineOf / lastSuccessOf 裁决（BackupStatus.kt，
// 有单测锁死缺陷 a/b），本文件只做裁决 → 字符串资源的映射。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.BuildConfig
import com.hawkeyexb.ppass.backup.BackupTriplet
import com.hawkeyexb.ppass.update.UpdateChannel
import kotlinx.coroutines.launch

/** What the user sees: exactly one of the design's meaning states. */
sealed class BackupUiState {
    data object Idle : BackupUiState()
    data class Scanning(val found: Int) : BackupUiState()
    data class Hashing(val done: Int, val total: Int) : BackupUiState()
    // 2026-08-17：currentFile——设计稿"正在备份 {文件名}（第 x / y 张）"
    // 要求展示当前文件名，不只是计数；默认空串（还没传完第一个文件时）。
    data class Sending(val done: Int, val total: Int, val currentFile: String = "") : BackupUiState()
    data class AllSafe(val ingested: Int, val duplicates: Int) : BackupUiState()
    /** FIX-T6: 一个相册都没选（空集 = 一个都不备）——显式「没有可
     *  备份的相册」，绝不显示假话「照片都存好了」。 */
    data object NoAlbums : BackupUiState()
    data class Trouble(val text: String) : BackupUiState()
}

@Composable
fun HomeScreen(
    // T-083 目标 1：副标题「已连接 …」已删（连接状态是桌面设备行的职责，
    // 手机页头只有「备份」）。参数位暂留——调用方仍传入，后续卡可能复用。
    storageName: String,
    state: BackupUiState,
    onBackupNow: () -> Unit,
    // DOG-02: 电池白名单引导（未加白时显示，加白后消失）
    batteryWhitelisted: Boolean = true,
    onOpenBatterySettings: () -> Unit = {},
    // Onboarding「系统权限」步骤里跳过的通知权限——同款不堵路引导卡，
    // 已授予或本来就不需要（API<33）时不显示。
    notificationSkipped: Boolean = false,
    onOpenNotificationSettings: () -> Unit = {},
    // 手机 Onboarding 三步（系统权限/选相册/备份条件）事后重看入口。
    onReviewOnboarding: () -> Unit = {},
    // DOG-01: 恒真三元组（持久缓存，断网/失败时仍显示）
    triplet: BackupTriplet? = null,
    // UX-03: 极简设置——仅充电 / 仅 WiFi（写 WorkManager 约束）
    chargeOnly: Boolean = true,
    onChargeOnlyChange: (Boolean) -> Unit = {},
    wifiOnly: Boolean = true,
    onWifiOnlyChange: (Boolean) -> Unit = {},
    // UX-06: 全局暂停自动备份开关 + 断开连接（警示页确认在 MainActivity）
    autoBackupPaused: Boolean = false,
    onToggleAutoBackup: (Boolean) -> Unit = {},
    onDisconnect: () -> Unit = {},
    // 存储端移除/吊销本设备后备份被拒——「配对已失效」红卡 + 重新扫码。
    pairingLost: Boolean = false,
    onRepair: () -> Unit = {},
    // T6: 备份范围（null = 全部相册）——「选择相册」与「发起备份」分离。
    selectedBucketCount: Int? = null,
    onOpenBucketPicker: () -> Unit = {},
    // MOB-02 §二: 部分授权态（只授权了部分照片）——hero 显示引导卡顶替
    // 三元组（部分授权下 N/M 是假数），一键去系统设置。
    partialAccess: Boolean = false,
    onOpenAppSettings: () -> Unit = {},
    // MOB-02 §四事件①: Wi-Fi 要求不满足时触发已排队——显示提示行。
    wifiDeferred: Boolean = false,
) {
    val line = statusLineOf(state, triplet?.k ?: 0L)
    val busy = line is StatusLine.Working

    // 设计稿"什么时候备份 ›"点进去的详情页——本地状态局部替换内容，
    // 跟 PhotosScreen 的大图查看同一个套路，不需要 MainActivity 的顶层
    // Screen 状态机（这只是设置子页，不需要像大图那样隐藏底部 tab 栏）。
    var showTimingDetail by remember { mutableStateOf(false) }
    if (showTimingDetail) {
        BackupTimingDetail(
            chargeOnly = chargeOnly,
            onChargeOnlyChange = onChargeOnlyChange,
            wifiOnly = wifiOnly,
            onWifiOnlyChange = onWifiOnlyChange,
            onBack = { showTimingDetail = false },
        )
        return
    }
    // "存储电脑"详情子页——"断开连接"收进这里最底部（滑动确认）。
    var showStorageDetail by remember { mutableStateOf(false) }
    if (showStorageDetail) {
        StorageComputerDetail(
            storageName = storageName,
            onBack = { showStorageDetail = false },
            onDisconnect = onDisconnect,
        )
        return
    }

    Column(
        Modifier.fillMaxSize().background(PPColor.Paper)
            .verticalScroll(rememberScrollState())
            .padding(20.dp, 14.dp, 20.dp, 8.dp),
    ) {
        // ── 标题：设计稿 = 仅「设置」28px serif，无副标题（T-083 目标 1；
        // UX-09 改名，随 tab 同步）──
        Text(
            stringResource(R.string.tab_settings),
            fontSize = 28.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
        )
        Spacer(Modifier.height(14.dp))

        // ── 英雄卡：恒真三元组（M / N 张已回家 · 最近成功 · 待备份 K）──
        // MOB-02 §二: 部分授权下不显示假 0/0——引导卡顶替三元组，
        // 诚实说明「只授权了部分照片——备份需要完整相册权限」+ 去设置。
        Surface(
            color = if (partialAccess) PPColor.ActBg else PPColor.SafeBg,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(20.dp)) {
                if (partialAccess) {
                    Text(
                        stringResource(R.string.partial_access_title),
                        fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.partial_access_body),
                        fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink60,
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = onOpenAppSettings,
                        modifier = Modifier.fillMaxWidth().height(PPSize.TapMin),
                        shape = RoundedCornerShape(PPSize.RadiusControl),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                        ),
                    ) {
                        Text(
                            stringResource(R.string.partial_access_action),
                            fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        )
                    }
                } else {
                val t = triplet
                if (t != null) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        // 设计稿："1,180 / 1,234 张已回家"——千分位分组，
                        // 三位数以内跟纯数字一样，大库才看得出差别。
                        Text(
                            groupThousands(t.m),
                            fontSize = 40.sp, fontFamily = FontFamily.Serif,
                            color = PPColor.Safe,
                        )
                        Text(
                            stringResource(R.string.hero_of_n, groupThousands(t.n)),
                            fontSize = 18.sp, fontFamily = FontFamily.Serif,
                            color = PPColor.Safe,
                            modifier = Modifier.padding(start = 6.dp, bottom = 4.dp),
                        )
                    }
                    Spacer(Modifier.height(6.dp))
                    // 缺陷 (b)：从未成功（ts<=0）→ 「还没有成功备份过」，
                    // 绝不渲染 epoch 0 日期。裁决在 lastSuccessOf（有单测）。
                    val lastText = lastSuccessText(t.lastSuccessAt)
                    val pendingSuffix = if (t.k > 0) {
                        " · " + stringResource(R.string.pending_count, t.k)
                    } else ""
                    Text(
                        lastText + pendingSuffix,
                        fontSize = 14.sp, color = PPColor.Ink60,
                    )
                } else {
                    // DOG-01d: 三元组不可用（媒体查询失败）→ 不编数字。
                    Text(
                        stringResource(R.string.triplet_unavailable),
                        fontSize = 15.sp, color = PPColor.Ink60,
                    )
                }

                Spacer(Modifier.height(14.dp))
                // 设计稿：hero 内 border-top = rgba(46,107,79,.18)（绿系）。
                HorizontalDivider(color = PPColor.Safe.copy(alpha = 0.18f))
                Spacer(Modifier.height(12.dp))

                // ── 进度区（T-083 目标 2 + MOB-02 重构 + UX-09）：进行中 =
                // 状态行 + 6dp 进度条 + 「暂停」；空闲态 = 按裁决结果说话
                // （statusText——Ready/Pending/AllSafe/NoAlbums 各有文案，
                // 不再恒是「插电 + Wi-Fi 时自动进行」）。UX-09：「选择相册」
                // 大按钮从 hero 移除——onboarding 已经选过一次，属低频操作，
                // 入口留在下方设置卡「备份范围」行（已存在，未删功能）；
                // 空出的位置让状态文案占满整行，「立即备份」点击后不再
                // 「看起来毫无反应」。配对失效时按钮收起，出路在红卡。
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        if (busy) {
                            Text(
                                workingText(line as StatusLine.Working),
                                fontSize = 13.5.sp, fontWeight = FontWeight.Medium,
                                color = PPColor.Ink60,
                            )
                            val progress = progressOf(state)
                            if (progress != null) {
                                Spacer(Modifier.height(8.dp))
                                androidx.compose.material3.LinearProgressIndicator(
                                    progress = { progress },
                                    modifier = Modifier.fillMaxWidth().height(6.dp),
                                    color = PPColor.Safe,
                                    trackColor = PPColor.Safe.copy(alpha = 0.18f),
                                )
                            }
                        } else {
                            Text(
                                idleStatusText(line),
                                fontSize = 13.5.sp, color = PPColor.Ink60,
                            )
                        }
                    }
                    if (busy && !pairingLost) {
                        Spacer(Modifier.width(12.dp))
                        // UX-01 不动：进行中再点 = 暂停（幂等管线安全）。
                        HeroSecondaryButton(
                            label = stringResource(R.string.backup_pause),
                            onClick = onBackupNow,
                        )
                    }
                }
                }
            }
        }

        // MOB-02 §四事件①: 触发已排队（Wi-Fi 要求不满足）——「将在连上
        // Wi-Fi 后进行」，不假装已经开跑。
        if (wifiDeferred && !busy && !partialAccess) {
            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(R.string.wifi_deferred_hint),
                fontSize = 13.5.sp, fontWeight = FontWeight.Medium,
                color = PPColor.Waiting,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
            )
        }

        // ── 失败才说话（T-083 目标 3 红线）：红卡正文只有人话（当前语言
        // 单语，先说「照片没丢」）；原始错误串（IrohError/异常 dump）绝不
        // 进主文案，只住在默认收起的「查看技术详情」里——troubleTextOf
        // 是唯一渲染闸门（有单测）；完整原文另走 Log.e(PPassBackup) 的
        // logcat/bugreport 诊断导出路径（BackupUiStateHolder catch）。
        // 目标 4：普通失败主按钮 = 「再试一次」（重跑即从断点续传）。
        if (state is BackupUiState.Trouble && !pairingLost) {
            Spacer(Modifier.height(12.dp))
            Surface(
                color = PPColor.ActBg,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    val copy = troubleTextOf(
                        rawError = state.text,
                        humanBody = stringResource(R.string.run_failed),
                    )
                    Text(
                        stringResource(R.string.state_trouble),
                        fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        copy.main,
                        fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink60,
                    )
                    if (copy.detail.isNotEmpty()) {
                        var showDetail by remember { mutableStateOf(false) }
                        Spacer(Modifier.height(6.dp))
                        Text(
                            stringResource(
                                if (showDetail) R.string.trouble_details_hide
                                else R.string.trouble_details_show
                            ),
                            fontSize = 13.sp, fontWeight = FontWeight.Bold,
                            color = PPColor.Ink40,
                            textDecoration = TextDecoration.Underline,
                            modifier = Modifier
                                .clickable { showDetail = !showDetail }
                                .padding(vertical = 4.dp),
                        )
                        if (showDetail) {
                            Text(
                                copy.detail,
                                fontSize = 12.sp, lineHeight = 17.sp,
                                fontFamily = FontFamily.Monospace, color = PPColor.Ink40,
                            )
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = onBackupNow,
                        modifier = Modifier.fillMaxWidth().height(PPSize.TapMin),
                        shape = RoundedCornerShape(PPSize.RadiusControl),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                        ),
                    ) {
                        Text(
                            stringResource(R.string.try_again),
                            fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }

        // ── 配对已失效：红卡说明 + 出路（重新扫码），报错先说照片没丢 ──
        if (pairingLost) {
            Spacer(Modifier.height(12.dp))
            Surface(
                color = PPColor.ActBg,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text(
                        stringResource(R.string.pairing_lost_title),
                        fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.pairing_lost_body),
                        fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink60,
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = onRepair,
                        modifier = Modifier.fillMaxWidth().height(PPSize.TapMin),
                        shape = RoundedCornerShape(PPSize.RadiusControl),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                        ),
                    ) {
                        Text(
                            stringResource(R.string.reconnect),
                            fontSize = 17.sp, fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }

        // ── DOG-02: 电池白名单建议条（设计稿：琥珀底一句话 + 去设置）──
        if (!batteryWhitelisted) {
            Spacer(Modifier.height(12.dp))
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
                        stringResource(R.string.dog_battery_body),
                        fontSize = 13.5.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(
                        stringResource(R.string.dog_battery_action),
                        fontSize = 14.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                        textDecoration = TextDecoration.Underline,
                        modifier = Modifier.clickable(onClick = onOpenBatterySettings)
                            .padding(4.dp),
                    )
                }
            }
        }

        // ── Onboarding 通知权限跳过引导（同款琥珀底一句话 + 去设置，
        // 跟电池白名单卡视觉一致，出现时机由 shouldOfferNotificationPermission
        // 之外的「已跳过但仍未授权」态决定，调用方传入）──
        if (notificationSkipped) {
            Spacer(Modifier.height(12.dp))
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
                        stringResource(R.string.notif_nudge_body),
                        fontSize = 13.5.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(
                        stringResource(R.string.notif_nudge_action),
                        fontSize = 14.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                        textDecoration = TextDecoration.Underline,
                        modifier = Modifier.clickable(onClick = onOpenNotificationSettings)
                            .padding(4.dp),
                    )
                }
            }
        }

        // ── 备份规则（2026-08-17 对齐设计稿截图：4 行 cell，不再是一串
        // 开关——"备份哪些相册 ›"/"什么时候备份 ›"/"通知 ›"/"存储电脑 ›"，
        // 每行 label 左、值+chevron 右，点进去才展开细节，跟设计稿的
        // cell 结构一致。仅充电/仅 WiFi 两个开关折进"什么时候备份"详情
        // 页（BackupTimingDetail），不再各占一行。）──
        Spacer(Modifier.height(18.dp))
        Text(
            stringResource(R.string.rules_title),
            fontSize = 12.sp, fontWeight = FontWeight.Bold,
            letterSpacing = 1.5.sp, color = PPColor.Ink40,
            modifier = Modifier.padding(horizontal = 2.dp),
        )
        Spacer(Modifier.height(8.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(vertical = 8.dp)) {
                CellRow(
                    label = stringResource(R.string.backup_scope),
                    value = stringResource(
                        if (selectedBucketCount == null) R.string.backup_scope_all
                        else R.string.backup_scope_n,
                        selectedBucketCount ?: 0,
                    ),
                    onClick = onOpenBucketPicker,
                )
                HorizontalDivider(color = PPColor.Divider)
                CellRow(
                    label = stringResource(R.string.backup_timing_title),
                    value = stringResource(timingSummaryKey(chargeOnly, wifiOnly)),
                    onClick = { showTimingDetail = true },
                )
                HorizontalDivider(color = PPColor.Divider)
                // 通知这行本身不是开关——权限在系统层，这里只显示现有
                // 行为陈述（成功沉默/仅失败通知）+ chevron 去系统通知
                // 设置（未授予时才有实际动作，已授予也允许点开看一眼）。
                CellRow(
                    label = stringResource(R.string.rule_notify),
                    value = stringResource(R.string.rule_notify_value),
                    onClick = onOpenNotificationSettings,
                )
                HorizontalDivider(color = PPColor.Divider)
                // 2026-08-17 设计稿原文对齐："断开连接"不再裸露在主列表
                // 里——收进这行"存储电脑"详情子页最底部，滑动确认才生效。
                // 数据源：pairing 时缓存的 storageDeviceName（proto/daemon
                // 没有主动查询"这台设备现在叫什么"的接口，改名后要等下次
                // 配对才刷新，如实挂账，不做新协议改动）。
                CellRow(
                    label = stringResource(R.string.storage_computer),
                    value = storageName,
                    onClick = { showStorageDetail = true },
                )
            }
        }

        // ── 更多（设计稿截图没画这几行，但都是现有功能，不能删——挪到
        // 第二张卡，跟上面 4 行设计稿明确给的 cell 分开，视觉上次要）──
        Spacer(Modifier.height(18.dp))
        Text(
            stringResource(R.string.more_section_title),
            fontSize = 12.sp, fontWeight = FontWeight.Bold,
            letterSpacing = 1.5.sp, color = PPColor.Ink40,
            modifier = Modifier.padding(horizontal = 2.dp),
        )
        Spacer(Modifier.height(8.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(vertical = 8.dp)) {
                RuleSwitchRow(
                    label = stringResource(R.string.auto_backup_pause),
                    hint = stringResource(R.string.auto_backup_pause_hint),
                    checked = !autoBackupPaused,
                    onCheckedChange = { on -> onToggleAutoBackup(!on) },
                )
                HorizontalDivider(color = PPColor.Divider)
                Row(
                    Modifier.fillMaxWidth().heightIn(min = RuleRowMinHeight).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        stringResource(R.string.setting_version),
                        fontSize = 15.sp, color = PPColor.Ink,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                        fontSize = 14.sp, color = PPColor.Ink40,
                    )
                }
                // 手机 Onboarding 三步重看入口——想回头补授权（通知/电池）
                // 或者单纯想再看一遍那三步说明，不需要重新扫码配对。
                HorizontalDivider(color = PPColor.Divider)
                CellRow(
                    label = stringResource(R.string.review_onboarding),
                    onClick = onReviewOnboarding,
                )
                // MOB-02 §一: 设置页低调「立即备份」入口（测试/狗粮用，
                // 不在首页）——跑前台管线，进度/暂停可见。部分授权下隐藏
                // （部分授权态不落范围、不显示假数据，入口无意义）。
                if (!partialAccess) {
                    HorizontalDivider(color = PPColor.Divider)
                    Row(
                        Modifier.fillMaxWidth()
                            .clickable(onClick = onBackupNow)
                            .heightIn(min = RuleRowMinHeight)
                            .padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            stringResource(R.string.manual_backup_entry),
                            fontSize = 14.sp, fontWeight = FontWeight.Medium,
                            color = PPColor.Ink40,
                            modifier = Modifier.weight(1f),
                        )
                        Text("›", fontSize = 16.sp, color = PPColor.Ink40)
                    }
                }
            }
        }

        Spacer(Modifier.height(8.dp))
    }
}

/** "存储电脑"详情子页——2026-08-17 设计稿原文对齐："断开连接"不再
 *  裸露在备份页主列表里，收进这里最底部，且必须滑动确认才生效（不是
 *  点一下弹确认框）——危险操作要求一个连续、有意识的手势，比"点击→
 *  再点一次确认"更难被无意划过触发。 */
@Composable
private fun StorageComputerDetail(
    storageName: String,
    onBack: () -> Unit,
    onDisconnect: () -> Unit,
) {
    Column(Modifier.fillMaxSize().background(PPColor.Paper).padding(20.dp, 14.dp, 20.dp, 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "‹", fontSize = 24.sp, color = PPColor.Ink,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp, 0.dp, 12.dp, 0.dp),
            )
            Text(
                stringResource(R.string.storage_computer),
                fontSize = 22.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
            )
        }
        Spacer(Modifier.height(16.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = RuleRowMinHeight).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.storage_computer),
                    fontSize = 15.sp, color = PPColor.Ink,
                    modifier = Modifier.weight(1f),
                )
                Text(storageName, fontSize = 14.sp, color = PPColor.Ink40)
            }
        }
        Spacer(Modifier.weight(1f))
        Text(
            stringResource(R.string.no_cloud),
            fontSize = 13.sp, lineHeight = 20.sp, color = PPColor.Ink40,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(14.dp))
        SwipeToConfirm(
            label = stringResource(R.string.disconnect_swipe_hint),
            confirmLabel = stringResource(R.string.disconnect),
            onConfirmed = onDisconnect,
        )
        Spacer(Modifier.height(8.dp))
    }
}

/** 进行中裁决 → 字符串资源（T-083 目标 2：进度区只在 Working 出状态行）。 */
@Composable
private fun workingText(line: StatusLine.Working): String = when (val s = line.state) {
    is BackupUiState.Scanning -> stringResource(R.string.state_scanning, s.found)
    is BackupUiState.Hashing -> stringResource(R.string.state_hashing, s.done, s.total)
    // 设计稿："正在备份 {文件名}（第 x / y 张）"——sent=0 时还没有当前
    // 文件（onProgress(0, total, "") 那一次），退回旧的纯计数文案。
    is BackupUiState.Sending -> if (s.currentFile.isNotEmpty()) {
        stringResource(R.string.state_sending_file, s.currentFile, s.done, s.total)
    } else {
        stringResource(R.string.state_sending, s.done, s.total)
    }
    else -> stringResource(R.string.idle_auto_hint) // unreachable
}

/**
 * UX-09: 空闲态状态文案——statusLineOf 早就算出了 Pending/AllSafe/
 * NoAlbums/Ready 四种裁决（BackupStatusTest 锁死了 Pending→state_pending、
 * AllSafe→state_safe 的映射与真实中文文案），但这层映射从没接上过 UI：
 * 空闲态永远只显示 idle_auto_hint，导致「立即备份」点完（尤其是已经被
 * 后台自动任务提前传完、这次点击零新增）看起来毫无反应。按裁决结果
 * 逐一出对应文案，才是「点了有交代」的最小闭环。
 */
@Composable
private fun idleStatusText(line: StatusLine): String = when (line) {
    is StatusLine.NoAlbums -> stringResource(R.string.state_no_albums)
    is StatusLine.Pending -> stringResource(R.string.state_pending, line.k)
    is StatusLine.AllSafe -> stringResource(R.string.state_safe)
    is StatusLine.Ready -> stringResource(R.string.idle_auto_hint)
    is StatusLine.Working, is StatusLine.Trouble -> stringResource(R.string.idle_auto_hint) // unreachable
}

/** 设计稿 hero 内次级按钮：白底 #FBF8F2 + 描边 rgba(23,21,18,.24) +
 *  圆角 14 + 高 44——现仅「暂停」用（UX-09：空闲态「选择相册」已移除，
 *  入口在下方设置卡「备份范围」行）。 */
@Composable
private fun HeroSecondaryButton(label: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .height(44.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(PPColor.Paper)
            .border(1.dp, PPColor.BorderStrong, RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink)
    }
}

/** 「最后成功」裁决 → 文案；Never 分支 = 缺陷 (b) 的正确出口。 */
@Composable
private fun lastSuccessText(ts: Long): String =
    when (val last = lastSuccessOf(ts, System.currentTimeMillis())) {
        is LastSuccess.Never -> stringResource(R.string.last_success_never)
        is LastSuccess.JustNow ->
            stringResource(R.string.dog_last_success, stringResource(R.string.last_just_now))
        is LastSuccess.MinutesAgo -> stringResource(
            R.string.dog_last_success, stringResource(R.string.last_mins_ago, last.mins)
        )
        is LastSuccess.HoursAgo -> stringResource(
            R.string.dog_last_success, stringResource(R.string.last_hours_ago, last.hours)
        )
        is LastSuccess.At -> stringResource(
            R.string.dog_last_success,
            java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.getDefault())
                .format(java.util.Date(last.ts)),
        )
    }

/** 千分位分组（设计稿"1,180 / 1,234"）——用户当前 locale 的分组符号。 */
private fun groupThousands(n: Long): String =
    java.text.NumberFormat.getIntegerInstance().format(n)

/** 进行中的确定进度（0..1）；扫描/无总数时 null = 不画进度条。 */
private fun progressOf(state: BackupUiState): Float? = when (state) {
    is BackupUiState.Hashing ->
        if (state.total > 0) state.done.toFloat() / state.total else null
    is BackupUiState.Sending ->
        if (state.total > 0) state.done.toFloat() / state.total else null
    else -> null
}

/**
 * MOB-02 §三: 四种条件组合 → 设置页顶部合成句的字符串资源（纯函数，
 * JVM 可测）。四种组合各有明确句子，不留歧义。
 */
fun policySentenceKey(chargeOnly: Boolean, wifiOnly: Boolean): Int = when {
    chargeOnly && wifiOnly -> R.string.policy_both
    chargeOnly && !wifiOnly -> R.string.policy_charge_only
    !chargeOnly && wifiOnly -> R.string.policy_wifi_only
    else -> R.string.policy_none
}

/** 同款四组合判定，短句形式给"什么时候备份 › {这句}" cell 用（design
 *  只要"充电 + Wi-Fi 时自动"，不要 policySentenceKey 那个"当前："前缀
 *  的完整句）。 */
fun timingSummaryKey(chargeOnly: Boolean, wifiOnly: Boolean): Int = when {
    chargeOnly && wifiOnly -> R.string.timing_summary_both
    chargeOnly && !wifiOnly -> R.string.timing_summary_charge_only
    !chargeOnly && wifiOnly -> R.string.timing_summary_wifi_only
    else -> R.string.timing_summary_none
}

/** UX-12: 备份规则卡所有单行统一的最小高度——真机反馈：带 Switch 的行
 *  用 8dp 垂直 padding、纯文字行用 14dp，但 Switch 组件自带的最小触控
 *  尺寸比文字行高，两种 padding 反而让 Switch 行看起来更大，行与行
 *  高度参差。改用同一条 heightIn(min=...) 兜底、内容垂直居中——单行
 *  内容（开关/纯文字/带箭头）视觉行高统一；带 hint 的两行开关自然
 *  长过这个下限，是合理例外，不受这条线约束。 */
private val RuleRowMinHeight = 56.dp

/** 备份规则卡里的开关行——label（可带 hint）左、Switch 右。 */
@Composable
private fun RuleSwitchRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    hint: String? = null,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = RuleRowMinHeight).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, fontSize = 15.sp, color = PPColor.Ink)
            if (hint != null) {
                Text(hint, fontSize = 12.sp, lineHeight = 17.sp, color = PPColor.Ink40)
            }
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/** 设计稿的 cell 行——label 左、可选的 value + "›" 右，整行可点。 */
@Composable
private fun CellRow(label: String, value: String? = null, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .clickable(onClick = onClick)
            .heightIn(min = RuleRowMinHeight)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 15.sp, color = PPColor.Ink, modifier = Modifier.weight(1f))
        if (value != null) {
            Text(value, fontSize = 14.sp, color = PPColor.Ink40)
            Spacer(Modifier.width(4.dp))
        }
        Text("›", fontSize = 16.sp, color = PPColor.Ink40)
    }
}

/** "什么时候备份 ›" 详情页——原来直接摆在备份规则卡里的仅充电/仅 WiFi
 *  两个开关，收进这个子页（跟 HomeScreen 顶部大卡片同一套返回手势，
 *  不需要 MainActivity 的顶层 Screen 状态机，局部替换即可）。 */
@Composable
private fun BackupTimingDetail(
    chargeOnly: Boolean,
    onChargeOnlyChange: (Boolean) -> Unit,
    wifiOnly: Boolean,
    onWifiOnlyChange: (Boolean) -> Unit,
    onBack: () -> Unit,
) {
    Column(Modifier.fillMaxSize().background(PPColor.Paper).padding(20.dp, 14.dp, 20.dp, 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "‹", fontSize = 24.sp, color = PPColor.Ink,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp, 0.dp, 12.dp, 0.dp),
            )
            Text(
                stringResource(R.string.backup_timing_title),
                fontSize = 22.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
            )
        }
        Spacer(Modifier.height(16.dp))
        Text(
            stringResource(policySentenceKey(chargeOnly, wifiOnly)),
            fontSize = 14.sp, lineHeight = 20.sp, color = PPColor.Ink60,
            modifier = Modifier.padding(horizontal = 2.dp),
        )
        Spacer(Modifier.height(14.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(vertical = 8.dp)) {
                RuleSwitchRow(
                    label = stringResource(R.string.setting_charge_only),
                    checked = chargeOnly,
                    onCheckedChange = onChargeOnlyChange,
                )
                // MOB-02 §三: 「需要充电」关闭的后果描述（用户定稿文案）。
                if (!chargeOnly) {
                    Text(
                        stringResource(R.string.req_charge_off_consequence),
                        fontSize = 12.5.sp, lineHeight = 18.sp, color = PPColor.Ink40,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 10.dp),
                    )
                }
                HorizontalDivider(color = PPColor.Divider)
                RuleSwitchRow(
                    label = stringResource(R.string.setting_wifi_only),
                    checked = wifiOnly,
                    onCheckedChange = onWifiOnlyChange,
                )
            }
        }
    }
}

/** 滑动确认——危险操作（断开连接）要求一个连续、有意识的拖动手势，
 *  比"点一下→弹确认框再点一次"更难被无意间划过触发（设计稿原文明确
 *  要求"滑动确认才生效"，不是弹窗）。Compose Material3 没有现成组件，
 *  自绘：一个可拖拽的圆形把手 + 底纹提示文字，拖到轨道 85% 以上松手
 *  才触发 [onConfirmed]，否则弹回起点。 */
@Composable
private fun SwipeToConfirm(label: String, confirmLabel: String, onConfirmed: () -> Unit) {
    val density = androidx.compose.ui.platform.LocalDensity.current
    val handleSize = 48.dp
    val trackHeight = 56.dp
    var trackWidthPx by remember { mutableStateOf(0f) }
    val handleSizePx = with(density) { handleSize.toPx() }
    val maxOffsetPx = (trackWidthPx - handleSizePx).coerceAtLeast(0f)
    val offset = remember { androidx.compose.animation.core.Animatable(0f) }
    val scope = rememberCoroutineScope()

    Surface(
        color = PPColor.ActBg,
        shape = RoundedCornerShape(trackHeight / 2),
        border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.35f)),
        modifier = Modifier.fillMaxWidth().height(trackHeight)
            .onGloballyPositioned { trackWidthPx = it.size.width.toFloat() },
    ) {
        Box(Modifier.fillMaxSize()) {
            // 底纹：拖得越远这句提示越淡，快到底时几乎看不见（视觉反馈
            // "快松手了"）。
            val labelAlpha = 1f - (if (maxOffsetPx > 0) offset.value / maxOffsetPx else 0f) * 0.85f
            Text(
                if (offset.value / maxOffsetPx.coerceAtLeast(1f) > 0.5f) confirmLabel else label,
                fontSize = 14.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                modifier = Modifier.fillMaxSize().alpha(labelAlpha.coerceIn(0f, 1f))
                    .padding(start = handleSize + 8.dp),
                textAlign = TextAlign.Center,
            )
            Box(
                Modifier
                    .offset { androidx.compose.ui.unit.IntOffset(offset.value.toInt(), 0) }
                    .padding(4.dp)
                    .size(handleSize)
                    .clip(RoundedCornerShape(50))
                    .background(PPColor.Act)
                    .pointerInput(maxOffsetPx) {
                        detectHorizontalDragGestures(
                            onDragEnd = {
                                scope.launch {
                                    if (maxOffsetPx > 0 && offset.value >= maxOffsetPx * 0.85f) {
                                        offset.animateTo(maxOffsetPx)
                                        onConfirmed()
                                    } else {
                                        offset.animateTo(0f)
                                    }
                                }
                            },
                            onDragCancel = { scope.launch { offset.animateTo(0f) } },
                        ) { change, dragAmount ->
                            change.consume()
                            scope.launch {
                                offset.snapTo((offset.value + dragAmount).coerceIn(0f, maxOffsetPx))
                            }
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text("→", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = PPColor.Paper)
            }
        }
    }
}
