package com.hawkeyexb.ppass.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.R

/** 二级页展示用的一条目录来源。状态不内部猜：needsPermission 由调用方按真实 SAF 可用性给。 */
data class FolderUi(val id: String, val name: String, val needsPermission: Boolean)

internal fun folderStatusRes(needsPermission: Boolean): Int =
    if (needsPermission) R.string.folder_status_needs_permission else R.string.folder_status_ok

internal fun folderStatusColor(needsPermission: Boolean): Color =
    if (needsPermission) PPColor.Act else PPColor.Ink60

internal fun folderDotColor(needsPermission: Boolean): Color =
    if (needsPermission) PPColor.Act else PPColor.Safe

/**
 * 移除的二次确认状态。移除入口只把目录挂起，确认后才回调 [onConfirmRemove]——
 * 取消永远不触发删除，避免「移除 = 删照片」的误读。
 */
internal class FolderRemovalController(
    private val onConfirmRemove: (FolderUi) -> Unit,
) {
    var pending: FolderUi? by mutableStateOf(null)
        private set

    fun requestRemove(folder: FolderUi) {
        pending = folder
    }

    fun dismiss() {
        pending = null
    }

    fun confirm() {
        val target = pending ?: return
        pending = null
        onConfirmRemove(target)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderScreen(
    folders: List<FolderUi>,
    onAdd: () -> Unit,
    onRemove: (FolderUi) -> Unit,
    onReauthorize: (FolderUi) -> Unit,
    onBack: () -> Unit,
) {
    val removal = remember(onRemove) { FolderRemovalController(onRemove) }
    BackHandler(onBack = onBack)
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = PPColor.Paper,
        contentColor = PPColor.Ink,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        stringResource(R.string.folder_settings_title),
                        style = MaterialTheme.typography.headlineSmall.copy(fontFamily = PPFont.Serif),
                        color = PPColor.Ink,
                        modifier = Modifier.semantics { heading() },
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                            tint = PPColor.Ink,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = PPColor.Paper,
                    scrolledContainerColor = PPColor.Paper,
                    navigationIconContentColor = PPColor.Ink,
                    titleContentColor = PPColor.Ink,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            Modifier.fillMaxSize()
                .background(PPColor.Paper)
                .padding(innerPadding)
                .padding(20.dp, 14.dp, 20.dp, 8.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            if (folders.isEmpty()) {
                Text(
                    stringResource(R.string.folder_empty),
                    style = MaterialTheme.typography.labelMedium,
                    color = PPColor.Ink60,
                )
            }
            for (folder in folders) {
                Surface(
                    color = PPColor.Paper,
                    shape = RoundedCornerShape(PPSize.RadiusCard),
                    border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    ListItem(
                        leadingContent = {
                            Box(
                                Modifier.size(9.dp).clip(CircleShape)
                                    .background(folderDotColor(folder.needsPermission)),
                            )
                        },
                        headlineContent = {
                            Text(
                                folder.name,
                                style = MaterialTheme.typography.titleMedium,
                                color = PPColor.Ink,
                            )
                        },
                        supportingContent = {
                            Column {
                                Text(
                                    stringResource(folderStatusRes(folder.needsPermission)),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = folderStatusColor(folder.needsPermission),
                                )
                                Spacer(Modifier.height(4.dp))
                                Row {
                                    if (folder.needsPermission) {
                                        TextButton(onClick = { onReauthorize(folder) }) {
                                            Text(
                                                stringResource(R.string.folder_reauthorize),
                                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                                color = PPColor.Act,
                                            )
                                        }
                                        Spacer(Modifier.width(24.dp))
                                    }
                                    TextButton(onClick = { removal.requestRemove(folder) }) {
                                        Text(
                                            stringResource(R.string.folder_remove),
                                            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                            color = PPColor.Act,
                                        )
                                    }
                                }
                            }
                        },
                        colors = ListItemDefaults.colors(
                            containerColor = Color.Transparent,
                            headlineColor = PPColor.Ink,
                            supportingColor = PPColor.Ink60,
                            leadingIconColor = folderDotColor(folder.needsPermission),
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Spacer(Modifier.height(12.dp))
            }
            Card(
                onClick = onAdd,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                colors = CardDefaults.cardColors(containerColor = PPColor.ActBg, contentColor = PPColor.Ink),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    stringResource(R.string.folder_add),
                    style = MaterialTheme.typography.titleMedium,
                    color = PPColor.Ink,
                    modifier = Modifier.padding(18.dp),
                )
            }
            Spacer(Modifier.height(12.dp))
            Text(
                stringResource(R.string.folder_boundary_note),
                style = MaterialTheme.typography.labelSmall,
                color = PPColor.Ink40,
            )
            Spacer(Modifier.height(8.dp))
        }
    }

    removal.pending?.let { folder ->
        AlertDialog(
            onDismissRequest = { removal.dismiss() },
            title = { Text(stringResource(R.string.folder_remove_confirm_title, folder.name)) },
            text = { Text(stringResource(R.string.folder_remove_confirm_body)) },
            confirmButton = {
                TextButton(onClick = { removal.confirm() }) {
                    Text(stringResource(R.string.folder_remove_confirm_action), color = PPColor.Act)
                }
            },
            dismissButton = {
                TextButton(onClick = { removal.dismiss() }) {
                    Text(stringResource(R.string.folder_cancel), color = PPColor.Ink)
                }
            },
        )
    }
}
