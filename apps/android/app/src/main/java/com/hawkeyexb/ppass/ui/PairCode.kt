// #1118: the pairing screen that carries the code exchange — "enter this code on the computer",
// shown right after the scan once the request was queued.
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R

/** The 6-digit pairing code in two groups of three (`123456` → `123 456`); anything else is shown as is. */
internal fun groupPairCode(code: String): String =
    if (code.length == 6) code.substring(0, 3) + " " + code.substring(3) else code

/**
 * Type levels of [PairCodeScreen], most to least prominent: code > computer name > explanation >
 * computer identity; "Connecting to" is a small label above the name. Built from the Material type
 * scale ([MaterialTheme.typography] in the app, the default [Typography] in tests) — no hand-written
 * sizes except the explanation, raised to the phone body floor (tokens size.mobile.body-min).
 * tokens.json mobile-ui.type.pair-* records the resulting sizes; iOS deviations live in platforms.ios.
 */
internal data class PairCodeType(
    val label: TextStyle,
    val name: TextStyle,
    val code: TextStyle,
    val body: TextStyle,
    val identity: TextStyle,
)

internal fun pairCodeType(t: Typography) = PairCodeType(
    label = t.labelLarge.copy(fontFamily = PPFont.Sans, fontWeight = FontWeight.Bold),
    name = t.titleLarge.copy(fontFamily = PPFont.Sans, fontWeight = FontWeight.Bold),
    code = t.displayMedium.copy(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, letterSpacing = 2.sp),
    body = t.bodyLarge.copy(fontFamily = PPFont.Sans, fontSize = PPSize.BodyMin, lineHeight = 26.sp),
    identity = t.bodySmall.copy(fontFamily = FontFamily.Monospace),
)

/**
 * The code page, straight after the scan (#1118; no "connect to this computer?" step): which
 * computer this is, the code in 3 + 3 groups, what to do with it, and the computer's identity (the
 * same `AB12 CD34` the computer prints under its QR code).
 */
@Composable
fun PairCodeScreen(code: String, desktopName: String, fingerprint: String, onCancel: () -> Unit) {
    val type = pairCodeType(MaterialTheme.typography)
    PPScreen {
        Column(
            Modifier.fillMaxSize().padding(34.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(stringResource(R.string.pair_connecting_label), style = type.label, color = PPColor.Ink40)
            Spacer(Modifier.height(6.dp))
            Text(desktopName, style = type.name, color = PPColor.Ink, textAlign = TextAlign.Center)
            Spacer(Modifier.height(24.dp))
            Text(groupPairCode(code), style = type.code, color = PPColor.Ink, textAlign = TextAlign.Center, maxLines = 1)
            Spacer(Modifier.height(24.dp))
            Text(stringResource(R.string.pair_code_body), style = type.body, color = PPColor.Ink60, textAlign = TextAlign.Center)
            Spacer(Modifier.height(12.dp))
            Text(
                stringResource(R.string.pair_desktop_identity, fingerprint),
                style = type.identity, color = PPColor.Ink40, textAlign = TextAlign.Center,
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
