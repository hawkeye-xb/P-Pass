// UPD-02: 更新对话框——渲染 UpdateUiState 的弹窗态（Available /
// Downloading / Verifying / Failed / ReadyToInstall / Installing）。
// 视觉与既有对话框（媒体权限引导、Wi-Fi 二次确认、取消剩余确认）同构：
// M3 AlertDialog + PP 语义色按钮；进度条按 MOB-33 教训显式覆盖 M3 1.3
// 的 gapSize / drawStopIndicator 默认值，否则条上会出现"移动的洞"。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.update.UpdateUiState
import com.hawkeyexb.ppass.update.failureTextRes
import com.hawkeyexb.ppass.update.displayUpdateNotes

@Composable
fun UpdateDialog(
    state: UpdateUiState,
    onConfirmDownload: () -> Unit,
    onLater: () -> Unit,
    onRetry: () -> Unit,
    onDismissFailed: () -> Unit,
    onInstall: () -> Unit,
    onReopenInstall: () -> Unit,
    onGiveUpInstall: () -> Unit,
) {
    when (state) {
        is UpdateUiState.Available -> AlertDialog(
            onDismissRequest = onLater,
            title = { Text(stringResource(R.string.update_available_title, state.info.version)) },
            text = {
                // #741：按 App 当前语言选 notes_i18n（取不到回落 notes）→ 含网址/控制字符等
                // 整段拒收 → 清洗截断（UPD-03 #580）；结果为空回落默认文案。
                // 语言取自与 stringResource 同一份 Configuration（per-app 语言 / 系统语言都
                // 反映在这里），保证说明与弹窗其余文字同一种语言。
                val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
                val notes = displayUpdateNotes(state.info.notesI18n, state.info.notes, languageTag)
                Text(notes.ifBlank { stringResource(R.string.update_available_body) })
            },
            confirmButton = {
                TextButton(onClick = onConfirmDownload) {
                    Text(stringResource(R.string.update_download_install), color = PPColor.Act)
                }
            },
            dismissButton = {
                TextButton(onClick = onLater) {
                    Text(stringResource(R.string.update_later), color = PPColor.Ink)
                }
            },
        )

        is UpdateUiState.Downloading -> AlertDialog(
            onDismissRequest = onLater, // = 后台下载
            title = { Text(stringResource(R.string.update_downloading_title)) },
            text = {
                Column {
                    UpdateProgressBar(
                        progress = if (state.total > 0) {
                            (state.received.toFloat() / state.total).coerceIn(0f, 1f)
                        } else {
                            null
                        },
                    )
                    Spacer(Modifier.height(10.dp))
                    Text(
                        if (state.total > 0) {
                            stringResource(
                                R.string.update_downloading_progress,
                                (state.received * 100 / state.total).toInt().coerceIn(0, 100),
                            )
                        } else {
                            stringResource(R.string.update_downloading_unknown_total)
                        },
                        fontSize = 13.5.sp, color = PPColor.Ink60,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = onLater) {
                    Text(stringResource(R.string.update_background), color = PPColor.Ink)
                }
            },
        )

        is UpdateUiState.Verifying -> AlertDialog(
            onDismissRequest = onLater,
            title = { Text(stringResource(R.string.update_downloading_title)) },
            text = {
                Column {
                    UpdateProgressBar(progress = null)
                    Spacer(Modifier.height(10.dp))
                    Text(
                        stringResource(R.string.update_verifying),
                        fontSize = 13.5.sp, color = PPColor.Ink60,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = onLater) {
                    Text(stringResource(R.string.update_background), color = PPColor.Ink)
                }
            },
        )

        is UpdateUiState.Failed -> AlertDialog(
            onDismissRequest = onDismissFailed,
            title = { Text(stringResource(R.string.update_failed_title)) },
            text = { Text(stringResource(failureTextRes(state.kind))) },
            confirmButton = {
                TextButton(onClick = onRetry) {
                    Text(stringResource(R.string.update_retry), color = PPColor.Act)
                }
            },
            dismissButton = {
                TextButton(onClick = onDismissFailed) {
                    Text(stringResource(R.string.update_close), color = PPColor.Ink)
                }
            },
        )

        is UpdateUiState.ReadyToInstall -> AlertDialog(
            onDismissRequest = onLater,
            title = { Text(stringResource(R.string.update_ready_install, state.version)) },
            text = { Text(stringResource(R.string.update_ready_body)) },
            confirmButton = {
                TextButton(onClick = onInstall) {
                    Text(stringResource(R.string.update_install_now), color = PPColor.Act)
                }
            },
            dismissButton = {
                TextButton(onClick = onLater) {
                    Text(stringResource(R.string.update_later), color = PPColor.Ink)
                }
            },
        )

        // #828：系统确认页可能被 Home 盖到后台（会话还在、没有终态）——给两个显式出口，不把人卡住。
        is UpdateUiState.Installing -> AlertDialog(
            onDismissRequest = {}, // 系统确认页在前，点外面不关；要走用下面的按钮
            title = { Text(stringResource(R.string.update_installing_title)) },
            text = {
                Column {
                    UpdateProgressBar(progress = null)
                    Spacer(Modifier.height(10.dp))
                    Text(
                        stringResource(R.string.update_installing_body),
                        fontSize = 13.5.sp, color = PPColor.Ink60,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = onReopenInstall) {
                    Text(stringResource(R.string.update_install_now), color = PPColor.Act)
                }
            },
            dismissButton = {
                TextButton(onClick = onGiveUpInstall) {
                    Text(stringResource(R.string.update_later), color = PPColor.Ink)
                }
            },
        )

        UpdateUiState.Idle, UpdateUiState.Checking -> Unit // 无弹窗态
    }
}

/** 进度条：null = 不确定总量（往返动画）。MOB-33 的两个显式覆盖不能省。 */
@Composable
private fun UpdateProgressBar(progress: Float?) {
    if (progress != null) {
        LinearProgressIndicator(
            progress = { progress },
            modifier = Modifier.fillMaxWidth().height(6.dp),
            color = PPColor.Safe,
            trackColor = PPColor.Safe.copy(alpha = 0.18f),
            gapSize = 0.dp,
            drawStopIndicator = {},
        )
    } else {
        LinearProgressIndicator(
            modifier = Modifier.fillMaxWidth().height(6.dp),
            color = PPColor.Safe,
            trackColor = PPColor.Safe.copy(alpha = 0.18f),
            gapSize = 0.dp,
        )
    }
}
