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
import androidx.compose.material3.Switch
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
    // DOG-02: 电池白名单引导卡片（未加白时显示，加白后消失）
    batteryWhitelisted: Boolean = true,
    onOpenBatterySettings: () -> Unit = {},
    // UX-06: 全局暂停自动备份开关 + 断开连接（警示页确认在 MainActivity）
    autoBackupPaused: Boolean = false,
    onToggleAutoBackup: (Boolean) -> Unit = {},
    onDisconnect: () -> Unit = {},
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
            onClick = onBackupNow,
            enabled = !busy,
            modifier = Modifier.fillMaxWidth().height(64.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
            colors = ButtonDefaults.buttonColors(
                containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                disabledContainerColor = PPColor.Linen, disabledContentColor = PPColor.Ink40,
            ),
        ) {
            Text(
                if (busy) stringResource(R.string.backing_up) else stringResource(R.string.backup_now),
                fontSize = 19.sp, fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(10.dp))
        Text(
            stringResource(R.string.no_cloud),
            fontSize = 14.sp, lineHeight = 22.sp, color = PPColor.Ink40,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(10.dp))
        // UX-06: 设置行——全局暂停自动备份开关 + 断开连接。
        // 开关只控制周期任务（WorkManager），手动「立即备份」不受影响。
        Row(
            Modifier.fillMaxWidth()
                .padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.auto_backup_pause),
                    fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                )
                Text(
                    stringResource(R.string.auto_backup_pause_hint),
                    fontSize = 12.sp, lineHeight = 17.sp, color = PPColor.Ink40,
                )
            }
            Switch(
                checked = !autoBackupPaused,
                onCheckedChange = { on -> onToggleAutoBackup(!on) },
            )
        }
        androidx.compose.material3.OutlinedButton(
            onClick = onDisconnect,
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
            border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.BorderStrong),
        ) {
            Text(stringResource(R.string.disconnect), fontSize = 16.sp, color = PPColor.Ink60)
        }
        Spacer(Modifier.height(6.dp))
    }
}
