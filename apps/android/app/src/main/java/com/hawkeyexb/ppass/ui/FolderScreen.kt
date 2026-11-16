// #1762「素材文件夹」最小二级页：添加（系统目录选择器）/ 查看（名称 + 授权状态）/ 移除 / 重新授权。
// 正式 UX 设计后置（issue #1762：先做真实功能闭环）；这里的结构照设置卡现有行与存储电脑详情页的既有样式拼。
package com.hawkeyexb.ppass.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R

/** 二级页展示用的一条目录来源。状态不内部猜：needsPermission 由调用方按真实 SAF 可用性给。 */
data class FolderUi(val id: String, val name: String, val needsPermission: Boolean)

@Composable
fun FolderScreen(
    folders: List<FolderUi>,
    onAdd: () -> Unit,
    onRemove: (FolderUi) -> Unit,
    onReauthorize: (FolderUi) -> Unit,
    onBack: () -> Unit,
) {
    // 移除的二次确认：说明清「只停止备份，不动文件」，避免「移除 = 删照片」的误读（issue 产品边界）。
    var removing by remember { mutableStateOf<FolderUi?>(null) }
    BackHandler { onBack() }
    Column(
        Modifier.fillMaxSize().background(PPColor.Paper).padding(20.dp, 14.dp, 20.dp, 8.dp)
            .verticalScroll(rememberScrollState()),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "‹", fontSize = 24.sp, color = PPColor.Ink,
                modifier = Modifier.clickable(onClick = onBack).padding(4.dp, 0.dp, 12.dp, 0.dp),
            )
            Text(
                stringResource(R.string.folder_settings_title),
                fontSize = 24.sp, fontFamily = PPFont.Serif, color = PPColor.Ink,
            )
        }
        Spacer(Modifier.height(16.dp))
        if (folders.isEmpty()) {
            Text(
                stringResource(R.string.folder_empty),
                fontSize = 14.sp, color = PPColor.Ink60,
            )
        }
        for (folder in folders) {
            Surface(
                color = PPColor.Paper,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(18.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            Modifier.size(9.dp).clip(CircleShape)
                                .background(if (folder.needsPermission) PPColor.Act else PPColor.Safe),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(folder.name, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink)
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        stringResource(
                            if (folder.needsPermission) R.string.folder_status_needs_permission
                            else R.string.folder_status_ok,
                        ),
                        fontSize = 14.sp,
                        color = if (folder.needsPermission) PPColor.Act else PPColor.Ink60,
                    )
                    Spacer(Modifier.height(10.dp))
                    Row {
                        if (folder.needsPermission) {
                            Text(
                                stringResource(R.string.folder_reauthorize),
                                fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                                modifier = Modifier.clickable { onReauthorize(folder) }.padding(vertical = 6.dp),
                            )
                            Spacer(Modifier.width(24.dp))
                        }
                        Text(
                            stringResource(R.string.folder_remove),
                            fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Act,
                            modifier = Modifier.clickable { removing = folder }.padding(vertical = 6.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
        }
        Surface(
            color = PPColor.ActBg,
            shape = RoundedCornerShape(PPSize.RadiusCard),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.clickable(onClick = onAdd).padding(18.dp)) {
                Text(
                    stringResource(R.string.folder_add),
                    fontSize = 17.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        Text(
            stringResource(R.string.folder_boundary_note),
            fontSize = 13.sp, color = PPColor.Ink40,
        )
        Spacer(Modifier.height(8.dp))
    }

    removing?.let { folder ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text(stringResource(R.string.folder_remove_confirm_title, folder.name)) },
            text = { Text(stringResource(R.string.folder_remove_confirm_body)) },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    onRemove(folder)
                }) { Text(stringResource(R.string.folder_remove_confirm_action), color = PPColor.Act) }
            },
            dismissButton = {
                TextButton(onClick = { removing = null }) {
                    Text(stringResource(R.string.folder_cancel), color = PPColor.Ink)
                }
            },
        )
    }
}
