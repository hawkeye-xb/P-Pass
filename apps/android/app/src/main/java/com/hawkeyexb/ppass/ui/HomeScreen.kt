// T-080 Backup tab — aligned to layout v1 (docs/design/2026-08-05-layout-v1):
// 恒真三元组英雄卡（M / N 张已回家 + 最近成功 + 待备份 K）+ 进行中可暂停
// + 失败才说话（Trouble/配对失效红卡）+ 备份规则卡 + 底部红字断开。
// 状态条文案由纯函数 statusLineOf / lastSuccessOf 裁决（BackupStatus.kt，
// 有单测锁死缺陷 a/b），本文件只做裁决 → 字符串资源的映射。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
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
    // MOB-18: 后台调度体系被外力清空过（最常见成因：系统设置里「强行停止」）。
    // 权限和配对都还在，所以下面三张引导卡一张都不会亮——必须单独提示，
    // 否则用户完全看不出备份已经停摆过。
    backupInterrupted: Boolean = false,
    onAcknowledgeInterruption: () -> Unit = {},
    // DOG-02: 电池白名单引导（未加白时显示，加白后消失）
    batteryWhitelisted: Boolean = true,
    onOpenBatterySettings: () -> Unit = {},
    // 通知权限未授予的不堵路引导卡（同 DOG-02 电池白名单卡风格）——
    // 已授予或本来就不需要（API<33）时不显示。
    notificationSkipped: Boolean = false,
    onOpenNotificationSettings: () -> Unit = {},
    // DOG-01: 恒真三元组（持久缓存，断网/失败时仍显示）
    triplet: BackupTriplet? = null,
    // UX-03: 极简设置——仅 WiFi（写 WorkManager 约束）。
    // MOB-10: 「仅充电」开关整个删掉，后台档改用「电量不低」硬约束
    // （见 TriggerPolicy.constraintsFor）——它在开着电池保护的设备上
    // 等于「永不备份」，且局域网传照片的能耗根本不是瓶颈。
    wifiOnly: Boolean = true,
    onWifiOnlyChange: (Boolean) -> Unit = {},
    // M10（全页面状态稿）："备份失败时通知我"——真实开关，不是摆设，
    // 默认开，落地到 NotifyOnFailurePrefs，BackupWorker 发通知前会读。
    notifyOnFailure: Boolean = true,
    onNotifyOnFailureChange: (Boolean) -> Unit = {},
    // UX-06: 全局暂停自动备份开关 + 断开连接（警示页确认在 MainActivity）
    autoBackupPaused: Boolean = false,
    onToggleAutoBackup: (Boolean) -> Unit = {},
    onDisconnect: () -> Unit = {},
    // 存储端移除/吊销本设备后备份被拒——「配对已失效」红卡 + 重新扫码。
    pairingLost: Boolean = false,
    onRepair: () -> Unit = {},
    // 存储电脑详情是二级页——打开/关闭时告知调用方，好让底部 Photos/
    // 设置 tab 栏跟大图查看页一样整体隐藏（用户实机反馈：进了二级页
    // 底部 tab 还杵在那，不该在）。
    onStorageDetailOpenChange: (Boolean) -> Unit = {},
    // M11（全页面状态稿）"存储电脑"详情页富文本用——配对日期（0=未知，
    // 老 pairing 升级上来的存量数据，不倒推瞎编）。
    pairedAt: Long = 0L,
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

    // "存储电脑"详情子页——"断开连接"收进这里最底部（点按钮二次确认）。
    // M10：仅充电/仅 Wi-Fi 改回主列表里的直接开关行，不再收进单独的
    // "什么时候备份"子页（用户实机反馈：设计稿 M10 就是直接开关行，
    // 折进子页是上一轮自己想当然加的一层，设计稿没有）。
    var showStorageDetail by remember { mutableStateOf(false) }
    if (showStorageDetail) {
        StorageComputerDetail(
            storageName = storageName,
            pairedAt = pairedAt,
            confirmedCount = triplet?.m ?: 0L,
            lastSuccessAt = triplet?.lastSuccessAt ?: 0L,
            pairingLost = pairingLost,
            onBack = { showStorageDetail = false; onStorageDetailOpenChange(false) },
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

        // ── MOB-18: 后台备份中断提示（同款琥珀底，放在最前——它比权限类
        // 提示更严重：那些是"可能影响"，这条是"确实已经停过"）──
        if (backupInterrupted) {
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
                        stringResource(R.string.backup_interrupted_body),
                        fontSize = 13.5.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(
                        stringResource(R.string.backup_interrupted_action),
                        fontSize = 14.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                        textDecoration = TextDecoration.Underline,
                        modifier = Modifier.clickable(onClick = onAcknowledgeInterruption)
                            .padding(4.dp),
                    )
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

        // ── "备份"（M10，全页面状态稿）：4 行——第 1 行导航到选相册，
        // 后 3 行是直接开关（不折进子页——用户实机反馈上一轮把充电/
        // WiFi 折进"什么时候备份"子页是自己想当然加的一层，设计稿就是
        // 摆开的开关行；"备份失败时通知我"落地成真实偏好，见
        // NotifyOnFailurePrefs）。──
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
            Column {
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
                RuleSwitchRow(
                    label = stringResource(R.string.setting_wifi_only),
                    checked = wifiOnly,
                    onCheckedChange = onWifiOnlyChange,
                )
                HorizontalDivider(color = PPColor.Divider)
                RuleSwitchRow(
                    label = stringResource(R.string.rule_notify),
                    checked = notifyOnFailure,
                    onCheckedChange = onNotifyOnFailureChange,
                )
            }
        }

        // ── "其他"（M10）：存储电脑 + 版本，两行。──
        Spacer(Modifier.height(18.dp))
        Text(
            stringResource(R.string.other_section_title),
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
            Column {
                // 数据源：pairing 时缓存的 storageDeviceName（proto/daemon
                // 没有主动查询"这台设备现在叫什么"的接口，改名后要等下次
                // 配对才刷新，如实挂账，不做新协议改动）。
                CellRow(
                    label = stringResource(R.string.storage_computer),
                    value = storageName,
                    onClick = { showStorageDetail = true; onStorageDetailOpenChange(true) },
                )
                HorizontalDivider(color = PPColor.Divider)
                Row(
                    Modifier.fillMaxWidth().height(CellRowHeight).padding(horizontal = 16.dp),
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
            }
        }

        // MOB-11: 「自动备份」总开关放回来——2026-08-18 上一轮按用户
        // "默认自动备份，不提供手动触发"把整张"更多"卡隐藏了，暂停开关
        // 被一起藏掉，于是桌面端有停止后台服务的入口、手机端没有（用户
        // 实机反馈）。这里只放回总开关，**手动备份入口继续不露出**——
        // 那才是用户当初真正不想要的东西。
        //
        // 位置：设置区最底部、与上面的「备份规则」卡分开成独立一张，
        // 视觉上和常规规则拉开距离（关掉它 = 停掉全部后台备份，属于
        // 高风险低频操作，跟「断开配对」同级；断开配对本身藏在存储电脑
        // 二级详情页 + 三层防误触，暂停可逆、危险性低一档，放这里）。
        Spacer(Modifier.height(18.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            RuleSwitchRow(
                label = stringResource(R.string.auto_backup_pause),
                // checked = 开着自动备份；关掉即 pauseAutoBackup。
                checked = !autoBackupPaused,
                onCheckedChange = { enabled -> onToggleAutoBackup(!enabled) },
            )
        }

        Spacer(Modifier.height(8.dp))
    }
}

/** "存储电脑"详情子页（M11/M12，全页面状态稿）——信息卡是状态点+
 *  设备名+"已连接·最近同步 X\n配对日期·存了 N 张照片"富文本，不是
 *  简单的"存储电脑｜名字"重复行（上一轮的真实差距，用户实机反馈
 *  "M11/12 也都需要对齐"）；断开连接三层防误触：入口藏在这个详情页 →
 *  红色描边按钮 → 点了展开一张"确定断开吗？"说明卡，卡里再点一次
 *  "确认断开"才真的触发。 */
@Composable
private fun StorageComputerDetail(
    storageName: String,
    pairedAt: Long,
    confirmedCount: Long,
    lastSuccessAt: Long,
    pairingLost: Boolean,
    onBack: () -> Unit,
    onDisconnect: () -> Unit,
) {
    var armed by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(PPColor.Paper).padding(20.dp, 14.dp, 20.dp, 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "‹", fontSize = 24.sp, color = PPColor.Ink,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp, 0.dp, 12.dp, 0.dp),
            )
            Text(
                stringResource(R.string.storage_computer),
                fontSize = 24.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
            )
        }
        Spacer(Modifier.height(16.dp))
        Surface(
            color = PPColor.Paper,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(20.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(9.dp).clip(androidx.compose.foundation.shape.CircleShape)
                            .background(if (pairingLost) PPColor.Act else PPColor.Safe),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(storageName, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink)
                }
                Spacer(Modifier.height(10.dp))
                Text(storageDetailBody(pairingLost, lastSuccessAt, pairedAt, confirmedCount),
                    fontSize = 14.sp, lineHeight = 24.sp, color = PPColor.Ink60,
                )
            }
        }
        Spacer(Modifier.weight(1f))
        if (armed) {
            Surface(
                color = PPColor.ActBg,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text(
                        stringResource(R.string.disconnect_armed_title),
                        fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.disconnect_armed_body),
                        fontSize = 13.5.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                    )
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(
                            onClick = { armed = false },
                            modifier = Modifier.weight(1f).height(48.dp),
                            shape = RoundedCornerShape(14.dp),
                        ) { Text(stringResource(R.string.cancel), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink) }
                        Button(
                            onClick = onDisconnect,
                            modifier = Modifier.weight(1f).height(48.dp),
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = PPColor.Act, contentColor = PPColor.Paper,
                            ),
                        ) { Text(stringResource(R.string.disconnect_confirm), fontSize = 15.sp, fontWeight = FontWeight.Bold) }
                    }
                }
            }
        } else {
            OutlinedButton(
                onClick = { armed = true },
                modifier = Modifier.fillMaxWidth().height(48.dp),
                shape = RoundedCornerShape(14.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Act.copy(alpha = 0.4f)),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = PPColor.Act),
            ) { Text(stringResource(R.string.disconnect), fontSize = 15.sp, fontWeight = FontWeight.Bold) }
        }
        Spacer(Modifier.height(8.dp))
    }
}

/** M11 信息卡正文——已失效直接说失效；否则"已连接·最近同步 X"，
 *  配对日期未知（老 pairing 升级上来，字段是 0）就不硬凑第二行，
 *  不编数据。 */
@Composable
private fun storageDetailBody(
    pairingLost: Boolean,
    lastSuccessAt: Long,
    pairedAt: Long,
    confirmedCount: Long,
): String {
    if (pairingLost) return stringResource(R.string.storage_detail_lost)
    val line1 = stringResource(R.string.storage_detail_connected, lastSuccessText(lastSuccessAt))
    if (pairedAt <= 0) return line1
    val date = java.text.SimpleDateFormat("yyyy年M月d日", java.util.Locale.getDefault())
        .format(java.util.Date(pairedAt))
    val line2 = stringResource(R.string.storage_detail_paired, date, groupThousands(confirmedCount))
    return "$line1\n$line2"
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
internal fun groupThousands(n: Long): String =
    java.text.NumberFormat.getIntegerInstance().format(n)

/** 进行中的确定进度（0..1）；扫描/无总数时 null = 不画进度条。 */
private fun progressOf(state: BackupUiState): Float? = when (state) {
    is BackupUiState.Hashing ->
        if (state.total > 0) state.done.toFloat() / state.total else null
    is BackupUiState.Sending ->
        if (state.total > 0) state.done.toFloat() / state.total else null
    else -> null
}

/** M10（全页面状态稿）：cell 行高 52dp——设计稿原文数值，带 hint 的
 *  两行开关自然长过这个下限，是合理例外，不受这条线约束。 */
private val CellRowHeight = 52.dp

/** 备份规则卡里的开关行——label（可带 hint）左、Switch 右。 */
@Composable
private fun RuleSwitchRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    hint: String? = null,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = CellRowHeight).padding(horizontal = 16.dp),
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
            .heightIn(min = CellRowHeight)
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

