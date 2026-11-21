// #1902：配对后优先引导开启自动备份，也可从相册或文件发起单次传输。
package com.hawkeyexb.ppass.ui
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R

@Composable
fun DecisionScreen(
    computerName: String,
    busy: Boolean = false,
    onChooseScope: () -> Unit,
    onPickPhotos: () -> Unit,
    onPickFiles: () -> Unit,
    photoPickerAvailable: Boolean = SingleTransferFilePicker.hasDedicatedPhotoPicker(LocalContext.current),
) {
    val name = computerName.ifBlank { stringResource(R.string.storage_device_default) }
    PPScreen {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
            Column(Modifier.fillMaxSize().padding(32.dp)) {
                Text(
                    stringResource(R.string.decision_connected, name),
                    fontSize = 15.sp, lineHeight = 22.sp, color = PPColor.Ink60,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    stringResource(R.string.decision_title),
                    fontSize = 32.sp, lineHeight = 40.sp,
                    fontFamily = PPFont.Serif, color = PPColor.Ink,
                )
                // 产品负责人 11-04：标题下一行说清选完之后会发生什么（照片传到哪台电脑）。
                Text(
                    stringResource(R.string.decision_destination, name),
                    fontSize = 15.sp, lineHeight = 22.sp, color = PPColor.Ink60,
                    modifier = Modifier.padding(top = 12.dp),
                )
                Spacer(Modifier.height(40.dp))
                PrimaryButton(stringResource(R.string.decision_choose_scope), onChooseScope, enabled = !busy)
                Spacer(Modifier.height(18.dp))
                androidx.compose.material3.Surface(
                    color = PPColor.Paper,
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(PPSize.RadiusCard),
                    border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column {
                        if (photoPickerAvailable) {
                            CellRow(stringResource(R.string.pick_from_photos_label), onClick = onPickPhotos.takeUnless { busy })
                            androidx.compose.material3.HorizontalDivider(color = PPColor.Divider)
                        }
                        CellRow(stringResource(R.string.pick_from_files_label), onClick = onPickFiles.takeUnless { busy })
                    }
                }
            }
        }
    }
}
