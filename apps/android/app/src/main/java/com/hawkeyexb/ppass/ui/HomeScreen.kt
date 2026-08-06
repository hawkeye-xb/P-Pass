// T-080 Backup tab — aligned to layout v1 (docs/design/2026-08-05-layout-v1):
// 恒真三元组英雄卡（M / N 张已回家 + 最近成功 + 待备份 K）+ 进行中可暂停
// + 失败才说话（Trouble/配对失效红卡）+ 备份规则卡 + 底部红字断开。
// 状态条文案由纯函数 statusLineOf / lastSuccessOf 裁决（BackupStatus.kt，
// 有单测锁死缺陷 a/b），本文件只做裁决 → 字符串资源的映射。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackupTriplet

/** What the user sees: exactly one of the design's meaning states. */
sealed class BackupUiState {
    data object Idle : BackupUiState()
    data class Scanning(val found: Int) : BackupUiState()
    data class Hashing(val done: Int, val total: Int) : BackupUiState()
    data class Sending(val done: Int, val total: Int) : BackupUiState()
    data class AllSafe(val ingested: Int, val duplicates: Int) : BackupUiState()
    data class Trouble(val text: String) : BackupUiState()
}

@Composable
fun HomeScreen(
    storageName: String,
    state: BackupUiState,
    onBackupNow: () -> Unit,
    // DOG-02: 电池白名单引导（未加白时显示，加白后消失）
    batteryWhitelisted: Boolean = true,
    onOpenBatterySettings: () -> Unit = {},
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
) {
    val line = statusLineOf(state, triplet?.k ?: 0L)
    val busy = line is StatusLine.Working

    Column(
        Modifier.fillMaxSize().background(PPColor.Paper)
            .verticalScroll(rememberScrollState())
            .padding(20.dp, 14.dp, 20.dp, 8.dp),
    ) {
        // ── 标题：设计稿 = 「备份」大字 serif；电脑名做副行 ──
        Text(
            stringResource(R.string.tab_backup),
            fontSize = 30.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
        )
        Text(
            "${stringResource(R.string.connected_to)} $storageName",
            fontSize = 14.sp, color = PPColor.Ink40,
        )
        Spacer(Modifier.height(14.dp))

        // ── 英雄卡：恒真三元组（M / N 张已回家 · 最近成功 · 待备份 K）──
        Surface(
            color = PPColor.SafeBg,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(20.dp)) {
                val t = triplet
                if (t != null) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            "${t.m}",
                            fontSize = 40.sp, fontFamily = FontFamily.Serif,
                            color = PPColor.Safe,
                        )
                        Text(
                            stringResource(R.string.hero_of_n, t.n),
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
                HorizontalDivider(color = PPColor.Border)
                Spacer(Modifier.height(12.dp))

                // ── 状态行 + 暂停/立即备份（配对失效时收起，出路在红卡）──
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            statusText(line),
                            fontSize = 14.sp, fontWeight = FontWeight.Medium,
                            color = if (line is StatusLine.Trouble) PPColor.Act else PPColor.Ink60,
                        )
                        val progress = progressOf(state)
                        if (progress != null) {
                            Spacer(Modifier.height(8.dp))
                            androidx.compose.material3.LinearProgressIndicator(
                                progress = { progress },
                                modifier = Modifier.fillMaxWidth().height(6.dp),
                                color = PPColor.Safe,
                                trackColor = PPColor.Hairline,
                            )
                        }
                    }
                    if (!pairingLost) {
                        Spacer(Modifier.width(12.dp))
                        Button(
                            // UX-01: 进行中点 = 暂停（holder 取消当前批，幂等
                            // 管线安全），再点 = 从断点续传。
                            onClick = onBackupNow,
                            modifier = Modifier.height(48.dp),
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (busy) PPColor.Paper else PPColor.Ink,
                                contentColor = if (busy) PPColor.Ink else PPColor.Paper,
                            ),
                        ) {
                            Text(
                                if (busy) stringResource(R.string.backup_pause)
                                else stringResource(R.string.backup_now),
                                fontSize = 15.sp, fontWeight = FontWeight.Bold,
                            )
                        }
                    }
                }
            }
        }

        // ── 失败才说话：运行失败详情（ActBg 卡，成功永远沉默）──
        if (state is BackupUiState.Trouble && !pairingLost) {
            Spacer(Modifier.height(12.dp))
            Surface(
                color = PPColor.ActBg,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    state.text,
                    fontSize = 13.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                    modifier = Modifier.padding(16.dp),
                )
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

        // ── 备份规则（设计稿：小节标题 + 圆角卡逐行）──
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
                RuleSwitchRow(
                    label = stringResource(R.string.auto_backup_pause),
                    hint = stringResource(R.string.auto_backup_pause_hint),
                    checked = !autoBackupPaused,
                    onCheckedChange = { on -> onToggleAutoBackup(!on) },
                )
                HorizontalDivider(color = PPColor.Divider)
                RuleSwitchRow(
                    label = stringResource(R.string.setting_charge_only),
                    checked = chargeOnly,
                    onCheckedChange = onChargeOnlyChange,
                )
                HorizontalDivider(color = PPColor.Divider)
                RuleSwitchRow(
                    label = stringResource(R.string.setting_wifi_only),
                    checked = wifiOnly,
                    onCheckedChange = onWifiOnlyChange,
                )
                HorizontalDivider(color = PPColor.Divider)
                Row(
                    Modifier.fillMaxWidth().padding(16.dp, 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        stringResource(R.string.rule_notify),
                        fontSize = 15.sp, color = PPColor.Ink,
                        modifier = Modifier.weight(1f),
                    )
                    // UX-02 既有行为：成功沉默，仅失败通知——此行如实陈述。
                    Text(
                        stringResource(R.string.rule_notify_value),
                        fontSize = 14.sp, color = PPColor.Ink40,
                    )
                }
            }
        }

        // ── 底部：断开连接 = 红字文本（危险动作电脑上确认更重的部分）──
        Spacer(Modifier.height(10.dp))
        Text(
            stringResource(R.string.no_cloud),
            fontSize = 13.sp, lineHeight = 20.sp, color = PPColor.Ink40,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            stringResource(R.string.disconnect),
            fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
                .clickable(onClick = onDisconnect)
                .padding(vertical = 18.dp),
        )
    }
}

/** 裁决 → 字符串资源的映射（唯一允许出文案的地方）。 */
@Composable
private fun statusText(line: StatusLine): String = when (line) {
    is StatusLine.Ready -> stringResource(R.string.state_ready)
    is StatusLine.Working -> when (val s = line.state) {
        is BackupUiState.Scanning -> stringResource(R.string.state_scanning, s.found)
        is BackupUiState.Hashing -> stringResource(R.string.state_hashing, s.done, s.total)
        is BackupUiState.Sending -> stringResource(R.string.state_sending, s.done, s.total)
        else -> stringResource(R.string.state_ready) // unreachable
    }
    is StatusLine.Pending -> stringResource(R.string.state_pending, line.k)
    is StatusLine.AllSafe -> stringResource(R.string.state_safe)
    is StatusLine.Trouble -> stringResource(R.string.state_trouble)
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

/** 进行中的确定进度（0..1）；扫描/无总数时 null = 不画进度条。 */
private fun progressOf(state: BackupUiState): Float? = when (state) {
    is BackupUiState.Hashing ->
        if (state.total > 0) state.done.toFloat() / state.total else null
    is BackupUiState.Sending ->
        if (state.total > 0) state.done.toFloat() / state.total else null
    else -> null
}

/** 备份规则卡里的开关行——label（可带 hint）左、Switch 右。 */
@Composable
private fun RuleSwitchRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    hint: String? = null,
) {
    Row(
        Modifier.fillMaxWidth().padding(16.dp, 8.dp),
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
