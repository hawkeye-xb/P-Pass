// #1118: the two pairing screens that carry the code exchange — "connect to this computer?"
// (before anything is sent) and "enter this code on the computer" (after the request was queued).
// Same page shell and tokens as the other pairing screens ([PairStatusScreen]).
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R

/** The 6-digit pairing code in two groups of three (`123456` → `123 456`); anything else is shown as is. */
internal fun groupPairCode(code: String): String =
    if (code.length == 6) code.substring(0, 3) + " " + code.substring(3) else code

/**
 * "Connect to this computer?": the computer's name and its identity (the same `AB12 CD34` the
 * computer prints under its QR code). Shown before any pair.request, so a wrongly scanned QR code
 * of somebody else's computer is caught here.
 */
@Composable
fun ConfirmDesktopScreen(name: String, fingerprint: String, onConnect: () -> Unit, onCancel: () -> Unit) {
    PPScreen {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
            Column(
                Modifier.fillMaxSize().padding(34.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    stringResource(R.string.pair_confirm_desktop_title), fontSize = 30.sp, lineHeight = 38.sp,
                    fontFamily = PPFont.Serif, color = PPColor.Ink, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                Text(
                    stringResource(R.string.pair_desktop_name_label), fontSize = 14.sp,
                    fontWeight = FontWeight.Bold, color = PPColor.Ink40,
                )
                Text(
                    name, fontSize = 22.sp, fontWeight = FontWeight.Bold,
                    color = PPColor.Ink, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    stringResource(R.string.pair_desktop_identity_label), fontSize = 14.sp,
                    fontWeight = FontWeight.Bold, color = PPColor.Ink40,
                )
                Text(
                    fingerprint, fontSize = 28.sp, fontWeight = FontWeight.Bold,
                    letterSpacing = 2.sp, color = PPColor.Ink, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(20.dp))
                Text(
                    stringResource(R.string.pair_confirm_desktop_body), fontSize = PPSize.BodyMin,
                    lineHeight = 26.sp, color = PPColor.Ink40, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(32.dp))
                PrimaryButton(stringResource(R.string.pair_connect), onConnect)
                Spacer(Modifier.height(12.dp))
                OutlinedButton(
                    onClick = onCancel,
                    modifier = Modifier.fillMaxWidth().height(58.dp),
                    shape = RoundedCornerShape(PPSize.RadiusControl),
                    border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.BorderStrong),
                ) { Text(stringResource(R.string.cancel), fontSize = 18.sp, color = PPColor.Ink60) }
            }
        }
    }
}

/** "Enter this code on the computer": the code, big, in 3 + 3 groups, plus the one-line explanation. */
@Composable
fun PairCodeScreen(code: String, onCancel: () -> Unit) {
    PPScreen {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
            Column(
                Modifier.fillMaxSize().padding(34.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    stringResource(R.string.pair_code_title), fontSize = 30.sp, lineHeight = 38.sp,
                    fontFamily = PPFont.Serif, color = PPColor.Ink, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(28.dp))
                Text(
                    groupPairCode(code), fontSize = 64.sp, fontWeight = FontWeight.Bold,
                    letterSpacing = 4.sp, color = PPColor.Ink, textAlign = TextAlign.Center,
                    maxLines = 1,
                )
                Spacer(Modifier.height(24.dp))
                Text(
                    stringResource(R.string.pair_code_body), fontSize = PPSize.BodyMin,
                    lineHeight = 26.sp, color = PPColor.Ink40, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(36.dp))
                OutlinedButton(
                    onClick = onCancel,
                    modifier = Modifier.fillMaxWidth().height(58.dp),
                    shape = RoundedCornerShape(PPSize.RadiusControl),
                    border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.BorderStrong),
                ) { Text(stringResource(R.string.cancel), fontSize = 18.sp, color = PPColor.Ink60) }
            }
        }
    }
}
