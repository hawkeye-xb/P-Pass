// T6 (H-10b): 相册选择——"选择备份内容"与"发起备份"是两个动作。
// 列出 MediaStore 相册（名称+张数），勾选要备份的，微信/QQ 等相册
// 可以不勾（微信自带备份，无需独立备份它收到的图）。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaScanner

@Composable
fun BucketScreen(
    buckets: List<MediaScanner.Bucket>,
    selected: Set<Long>,
    onDone: (Set<Long>) -> Unit,
    onCancel: () -> Unit,
) {
    var checked by remember { mutableStateOf(selected) }
    var selectAll by remember { mutableStateOf(selected.size == buckets.size) }

    Column(
        Modifier.fillMaxSize().background(PPColor.Paper).padding(24.dp),
    ) {
        Text(
            stringResource(R.string.bucket_title),
            fontSize = 28.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.bucket_hint),
            fontSize = 14.sp, lineHeight = 21.sp, color = PPColor.Ink40,
        )
        Spacer(Modifier.height(16.dp))

        Box(Modifier.weight(1f)) {
            if (buckets.isEmpty()) {
                Text(
                    stringResource(R.string.bucket_empty),
                    fontSize = 15.sp, color = PPColor.Ink40,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 40.dp),
                )
            } else {
                LazyColumn {
                    items(buckets, key = { it.id }) { b ->
                        val on = b.id in checked
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable {
                                    checked = if (on) checked - b.id else checked + b.id
                                }
                                .padding(vertical = 13.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(
                                checked = on,
                                onCheckedChange = { c ->
                                    checked = if (c) checked + b.id else checked - b.id
                                },
                                colors = CheckboxDefaults.colors(
                                    checkedColor = PPColor.Safe,
                                    uncheckedColor = PPColor.Ink40,
                                ),
                            )
                            Text(
                                b.name,
                                fontSize = 16.sp, color = PPColor.Ink,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                stringResource(R.string.bucket_count, b.count),
                                fontSize = 14.sp, color = PPColor.Ink40,
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                onClick = {
                    selectAll = !selectAll
                    checked = if (selectAll) buckets.map { it.id }.toSet() else emptySet()
                },
                modifier = Modifier.weight(1f).height(52.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
            ) {
                Text(
                    stringResource(if (selectAll) R.string.bucket_clear else R.string.bucket_select_all),
                    fontSize = 15.sp, color = PPColor.Ink,
                )
            }
            OutlinedButton(
                onClick = onCancel,
                modifier = Modifier.weight(1f).height(52.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
            ) { Text(stringResource(R.string.cancel), fontSize = 15.sp, color = PPColor.Ink) }
        }
        Spacer(Modifier.height(10.dp))
        OutlinedButton(
            onClick = { onDone(checked) },
            modifier = Modifier.fillMaxWidth().height(58.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
        ) {
            Text(
                stringResource(R.string.bucket_done, checked.size),
                fontSize = 17.sp, color = PPColor.Safe, fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(6.dp))
    }
}
