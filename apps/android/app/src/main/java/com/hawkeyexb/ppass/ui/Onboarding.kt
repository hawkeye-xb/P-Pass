// T-052 onboarding — three screens from the design file (P-Pass
// Mobile.dc.html): welcome → scan → joined. One promise, one big
// button; Chinese always at the same level as English; body >=17sp,
// buttons >=56dp.
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
private fun PrimaryButton(text: String, textZh: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Button(
            onClick = onClick,
            modifier = Modifier.fillMaxWidth().height(64.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
            colors = ButtonDefaults.buttonColors(
                containerColor = PPColor.Ink, contentColor = PPColor.Paper
            ),
        ) {
            Text(text, fontSize = 19.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(10.dp))
        Text(textZh, fontSize = PPSize.BodyMin, color = PPColor.Ink60)
    }
}

/** Screen 1: one promise, one big button. */
@Composable
fun WelcomeScreen(onScan: () -> Unit) {
    Column(
        Modifier.fillMaxSize().background(PPColor.Paper).padding(32.dp),
    ) {
        Text(
            "P-PASS",
            fontSize = 14.sp, fontWeight = FontWeight.Bold,
            letterSpacing = 2.5.sp, color = PPColor.Ink60,
        )
        Spacer(Modifier.weight(1f))
        Text(
            "Your photos, kept at home.",
            fontSize = 40.sp, lineHeight = 46.sp,
            fontFamily = FontFamily.Serif, color = PPColor.Ink,
        )
        Spacer(Modifier.height(14.dp))
        Text(
            "照片自动存回自己家的电脑。",
            fontSize = 23.sp, color = PPColor.Ink60, fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.height(10.dp))
        Text(
            "No account, no password, no monthly fee.\n不用注册、不用密码、不花钱。",
            fontSize = PPSize.BodyMin, lineHeight = 26.sp, color = PPColor.Ink40,
        )
        Spacer(Modifier.height(40.dp))
        PrimaryButton("Scan the code on the computer", "扫描电脑上的二维码", onScan)
        Spacer(Modifier.height(24.dp))
    }
}

/** Screen 3: joined — say what happens next, allow walking away. */
@Composable
fun JoinedScreen(storageName: String, onDone: () -> Unit) {
    Column(
        Modifier.fillMaxSize().background(PPColor.Paper).padding(34.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier.size(104.dp).background(PPColor.SafeBg, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text("✓", fontSize = 46.sp, color = PPColor.Safe, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(24.dp))
        Text(
            "This phone has joined.",
            fontSize = PPSize.Headline, fontFamily = FontFamily.Serif,
            color = PPColor.Ink, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text("这台手机已加入。", fontSize = PPSize.BodyZh, color = PPColor.Ink60)
        Spacer(Modifier.height(14.dp))
        Text(
            "Connected to $storageName.\nBacking up starts now — on Wi-Fi, while charging. You can close the app.\n现在开始备份：连 Wi-Fi、充电时自动进行。可以关掉 App。",
            fontSize = PPSize.BodyMin, lineHeight = 26.sp,
            color = PPColor.Ink40, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(40.dp))
        Button(
            onClick = onDone,
            modifier = Modifier.fillMaxWidth().height(64.dp),
            shape = RoundedCornerShape(PPSize.RadiusControl),
            colors = ButtonDefaults.buttonColors(
                containerColor = PPColor.Ink, contentColor = PPColor.Paper
            ),
        ) { Text("Done 好的", fontSize = 19.sp, fontWeight = FontWeight.Bold) }
    }
}

/** Pairing in flight / refused / failed states share one screen. */
@Composable
fun PairStatusScreen(title: String, titleZh: String, body: String, action: Pair<String, () -> Unit>?) {
    Column(
        Modifier.fillMaxSize().background(PPColor.Paper).padding(34.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            title, fontSize = 30.sp, fontFamily = FontFamily.Serif,
            color = PPColor.Ink, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(10.dp))
        Text(titleZh, fontSize = PPSize.BodyZh, color = PPColor.Ink60, textAlign = TextAlign.Center)
        Spacer(Modifier.height(14.dp))
        Text(
            body, fontSize = PPSize.BodyMin, lineHeight = 26.sp,
            color = PPColor.Ink40, textAlign = TextAlign.Center,
        )
        if (action != null) {
            Spacer(Modifier.height(36.dp))
            OutlinedButton(
                onClick = action.second,
                modifier = Modifier.fillMaxWidth().height(58.dp),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.BorderStrong),
            ) { Text(action.first, fontSize = 18.sp, color = PPColor.Ink60) }
        }
    }
}

