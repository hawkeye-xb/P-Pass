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
