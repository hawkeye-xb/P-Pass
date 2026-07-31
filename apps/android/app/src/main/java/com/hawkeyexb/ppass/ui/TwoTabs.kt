// The design's two-tab shell: Photos and Backup, nothing else in the
// way. Selected tab = ink on paper, exactly as the mobile design file.
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.R
import androidx.compose.ui.unit.sp

@Composable
fun TwoTabs(
    tab: Int,
    onTab: (Int) -> Unit,
    photos: @Composable () -> Unit,
    backup: @Composable () -> Unit,
) {
    Column(Modifier.fillMaxSize().background(PPColor.Paper)) {
        Box(Modifier.weight(1f)) {
            if (tab == 0) photos() else backup()
        }
        Row(
            Modifier.fillMaxWidth().background(PPColor.Paper)
                .padding(16.dp, 10.dp, 16.dp, 24.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            TabButton(stringResource(R.string.tab_photos), tab == 0, Modifier.weight(1f)) { onTab(0) }
            TabButton(stringResource(R.string.tab_backup), tab == 1, Modifier.weight(1f)) { onTab(1) }
        }
    }
}

@Composable
private fun TabButton(
    label: String,
    selected: Boolean,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        modifier = modifier.height(58.dp),
        shape = RoundedCornerShape(18.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = if (selected) PPColor.Ink else PPColor.Linen,
            contentColor = if (selected) PPColor.Paper else PPColor.Ink60,
        ),
    ) {
        Text(label, fontSize = 17.sp, fontWeight = FontWeight.Bold)
    }
}
