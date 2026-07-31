// T-054 home: the design file's Backup tab, minimal edition — one
// status pill answering "are the photos safe?", one action. T-055
// builds the full two-tab layout.
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
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
import androidx.compose.ui.unit.dp
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
) {
    val (dot, pillBg, pillText, pillTextZh) = when (state) {
        is BackupUiState.Idle ->
            Quad(PPColor.Idle, PPColor.IdleBg, "Ready", "随时可以备份")
        is BackupUiState.Scanning ->
            Quad(PPColor.Waiting, PPColor.WaitingBg, "Looking for photos… ${state.found}", "正在找照片")
        is BackupUiState.Hashing ->
            Quad(PPColor.Waiting, PPColor.WaitingBg, "Reading ${state.done}/${state.total}", "正在读取照片")
        is BackupUiState.Sending ->
            Quad(PPColor.Waiting, PPColor.WaitingBg, "Sending ${state.done}/${state.total} home", "正在传回家")
        is BackupUiState.AllSafe ->
            Quad(PPColor.Safe, PPColor.SafeBg, "All photos are backed up", "照片都存好了")
        is BackupUiState.Trouble ->
            Quad(PPColor.Act, PPColor.ActBg, "Needs another try", "需要再试一次")
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
            Column {
                Text(pillText, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink)
                Text(pillTextZh, fontSize = 15.sp, color = PPColor.Ink60)
            }
        }

        Spacer(Modifier.height(26.dp))
        Text(
            "Connected to", fontSize = 15.sp, color = PPColor.Ink40,
        )
        Text(
            storageName, fontSize = 26.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
        )

        when (state) {
            is BackupUiState.AllSafe -> {
                Spacer(Modifier.height(14.dp))
                Text(
                    "${state.ingested} new photos arrived home" +
                        (if (state.duplicates > 0) ", ${state.duplicates} were already there" else "") + ".\n" +
                        "新存 ${state.ingested} 张" +
                        (if (state.duplicates > 0) "，${state.duplicates} 张原本就在" else "") + "。",
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
                if (busy) "Backing up… 备份中" else "Back up now 立即备份",
                fontSize = 19.sp, fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(10.dp))
        Text(
            "Photos go straight to your own computer. Nothing is uploaded to a cloud.\n照片直接传回自己家的电脑，不经过任何云端。",
            fontSize = 14.sp, lineHeight = 22.sp, color = PPColor.Ink40,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))
    }
}

private data class Quad(val dot: Color, val bg: Color, val en: String, val zh: String)
