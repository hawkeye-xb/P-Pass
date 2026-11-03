// #1321 决定页（docs/decisions/2026-11-03-onboarding-gate.md 结论 1、5）：配对之后、进照片页之前必须做一次
// 「备份哪些照片」的决定。只有两个出口——范围备份（主按钮）/ 单张备份（次入口），不能跳过。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R

@Composable
fun DecisionScreen(computerName: String, onChooseScope: () -> Unit, onPickPhotos: () -> Unit) {
    PPScreen {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
            Column(Modifier.fillMaxSize().padding(32.dp)) {
                Text(
                    stringResource(R.string.decision_connected, computerName),
                    fontSize = 15.sp, lineHeight = 22.sp, color = PPColor.Ink60,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    stringResource(R.string.decision_title),
                    fontSize = 32.sp, lineHeight = 40.sp,
                    fontFamily = PPFont.Serif, color = PPColor.Ink,
                )
                Spacer(Modifier.height(40.dp))
                PrimaryButton(stringResource(R.string.decision_choose_scope), onChooseScope)
                Spacer(Modifier.height(8.dp))
                Text(
                    stringResource(R.string.decision_choose_scope_note),
                    fontSize = 14.sp, color = PPColor.Ink40,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
                // 与欢迎页「手动输入配对码」同一种次入口：一行文字链接。
                Text(
                    stringResource(R.string.decision_pick_photos),
                    fontSize = 15.sp, fontWeight = FontWeight.Bold, color = PPColor.Ink60,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth()
                        .clickable(onClick = onPickPhotos)
                        .padding(26.dp, 18.dp, 26.dp, 8.dp),
                )
            }
        }
    }
}
