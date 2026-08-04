// T-054 home: the design file's Backup tab, minimal edition — one
// status pill answering "are the photos safe?", one action. T-055
// builds the full two-tab layout.
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.BackupTriplet
import androidx.compose.ui.unit.sp

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
    onReconnect: () -> Unit = {},
    // DOG-02: 电池白名单引导卡片（未加白时显示，加白后消失）
    batteryWhitelisted: Boolean = true,
    onOpenBatterySettings: () -> Unit = {},
    // DOG-01: 恒真三元组（持久缓存，断网/失败时仍显示）
    triplet: BackupTriplet? = null,
    // UX-03: 极简设置——仅充电 / 仅 WiFi（写 WorkManager 约束）
    chargeOnly: Boolean = true,
    onChargeOnlyChange: (Boolean) -> Unit = {},
    wifiOnly: Boolean = true,
    onWifiOnlyChange: (Boolean) -> Unit = {},
) {
    val (dot, pillBg) = when (state) {
        is BackupUiState.Idle -> PPColor.Idle to PPColor.IdleBg
        is BackupUiState.AllSafe -> PPColor.Safe to PPColor.SafeBg
        is BackupUiState.Trouble -> PPColor.Act to PPColor.ActBg
        else -> PPColor.Waiting to PPColor.WaitingBg
    }
    val pillText = when (state) {
        is BackupUiState.Idle -> stringResource(R.string.state_ready)
        is BackupUiState.Scanning -> stringResource(R.string.state_scanning, state.found)
        is BackupUiState.Hashing -> stringResource(R.string.state_hashing, state.done, state.total)
        is BackupUiState.Sending -> stringResource(R.string.state_sending, state.done, state.total)
        is BackupUiState.AllSafe -> stringResource(R.string.state_safe)
        is BackupUiState.Trouble -> stringResource(R.string.state_trouble)
    }

    Column(Modifier.fillMaxSize().background(PPColor.Paper).padding(28.dp)) {
        Text(
            "P-PASS", fontSize = 14.sp, fontWeight = FontWeight.Bold,
            letterSpacing = 2.5.sp, color = PPColor.Ink60,
        )
        Spacer(Modifier.height(22.dp))

        Row(
            Modifier.fillMaxWidth().background(pillBg, RoundedCornerShape(999.dp))
                .padding(horizontal = 18.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            androidx.compose.foundation.layout.Box(
                Modifier.size(12.dp).background(dot, CircleShape)
            )
            Spacer(Modifier.width(12.dp))
            Text(pillText, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink)
        }

        Spacer(Modifier.height(26.dp))

        // DOG-02: ROM 杀后台防护引导卡片（鸿蒙/三星已知咬点）——加白后消失
        if (!batteryWhitelisted) {
            Spacer(Modifier.height(4.dp))
            androidx.compose.material3.Surface(
                color = PPColor.WaitingBg,
                shape = RoundedCornerShape(PPSize.RadiusControl),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(16.dp)) {
                    Text(
                        stringResource(R.string.dog_battery_title),
                        fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        stringResource(R.string.dog_battery_body),
                        fontSize = 13.sp, lineHeight = 20.sp, color = PPColor.Ink60,
                    )
                    Spacer(Modifier.height(10.dp))
                    Button(
                        onClick = onOpenBatterySettings,
                        modifier = Modifier.fillMaxWidth().height(46.dp),
                        shape = RoundedCornerShape(PPSize.RadiusControl),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                        ),
                    ) {
                        Text(stringResource(R.string.dog_battery_action), fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }

        Text(
            stringResource(R.string.connected_to), fontSize = 15.sp, color = PPColor.Ink40,
        )
        Text(
            storageName, fontSize = 26.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
        )

        // DOG-01: 恒真三元组「N 张 · 已备份 M · 待备份 K + 最后成功时间」
        triplet?.let { t ->
            Spacer(Modifier.height(14.dp))
            Text(
                stringResource(R.string.dog_triplet_line, t.n, t.m, t.k),
                fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
            )
            Text(
                stringResource(
                    R.string.dog_last_success,
                    formatLastSuccess(t.lastSuccessAt),
                ),
                fontSize = 13.sp, color = PPColor.Ink40,
            )
        }

        when (state) {
            is BackupUiState.AllSafe -> {
                Spacer(Modifier.height(14.dp))
                Text(
                    if (state.duplicates > 0) {
                        stringResource(R.string.safe_detail_dup, state.ingested, state.duplicates)
                    } else {
                        stringResource(R.string.safe_detail, state.ingested)
                    },
                    fontSize = PPSize.BodyMin, lineHeight = 26.sp, color = PPColor.Ink60,
                )
            }
            is BackupUiState.Trouble -> {
                Spacer(Modifier.height(14.dp))
                Text(
                    state.text, fontSize = PPSize.BodyMin, lineHeight = 25.sp, color = PPColor.Ink60,
                )
            }
            else -> {}
        }

        Spacer(Modifier.weight(1f))
        val busy = state is BackupUiState.Scanning ||
            state is BackupUiState.Hashing || state is BackupUiState.Sending
        Button(
            // UX-01: 备份进行中按钮变「暂停」且可点——点击由 holder 转成
            // 取消当前批（幂等管线安全），再点一次续传。
            onClick = onBackupNow,
            enabled = true,
            modifier = Modifier.fillMaxWidth().height(64.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
            colors = ButtonDefaults.buttonColors(
                containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                disabledContainerColor = PPColor.Linen, disabledContentColor = PPColor.Ink40,
            ),
        ) {
            Text(
                if (busy) stringResource(R.string.backup_pause) else stringResource(R.string.backup_now),
                fontSize = 19.sp, fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(10.dp))
        Text(
            stringResource(R.string.no_cloud),
            fontSize = 14.sp, lineHeight = 22.sp, color = PPColor.Ink40,
            modifier = Modifier.fillMaxWidth(),
        )

        // UX-03: 后台规则一行 + 极简设置两开关（仅充电/仅 WiFi）。
        Spacer(Modifier.height(14.dp))
        Text(
            stringResource(R.string.auto_backup_rule),
            fontSize = 14.sp, lineHeight = 22.sp, color = PPColor.Ink60,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(4.dp))
        SettingSwitchRow(
            label = stringResource(R.string.setting_charge_only),
            checked = chargeOnly,
            onCheckedChange = onChargeOnlyChange,
        )
        SettingSwitchRow(
            label = stringResource(R.string.setting_wifi_only),
            checked = wifiOnly,
            onCheckedChange = onWifiOnlyChange,
        )

        Spacer(Modifier.height(10.dp))
        androidx.compose.material3.OutlinedButton(
            onClick = onReconnect,
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
            border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.BorderStrong),
        ) {
            Text(stringResource(R.string.reconnect), fontSize = 16.sp, color = PPColor.Ink60)
        }
        Spacer(Modifier.height(6.dp))
    }
}

// DOG-01: 「最后成功时间」人性化——几分钟前 → 几小时前 → 日期。
private fun formatLastSuccess(ts: Long): String {
    val now = System.currentTimeMillis()
    val mins = (now - ts) / 60_000
    return when {
        mins < 1 -> "刚刚"
        mins < 60 -> "$mins 分钟前"
        mins < 60 * 24 -> "${mins / 60} 小时前"
        else -> java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.getDefault())
            .format(java.util.Date(ts))
    }
}

/** UX-03: 极简设置开关行——label 左、Switch 右。 */
@Composable
private fun SettingSwitchRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label, fontSize = 14.sp, color = PPColor.Ink,
            modifier = Modifier.weight(1f),
        )
        androidx.compose.material3.Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
        )
    }
}
