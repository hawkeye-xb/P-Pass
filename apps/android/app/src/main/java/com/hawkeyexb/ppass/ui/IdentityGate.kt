// #1106: nothing in the app runs without the device identity. When Keystore cannot unseal it
// (after IdentityStore's own retries) the app refuses to start — no plaintext fallback — and offers
// two ways out: try again, or reset (this phone becomes a new device and pairs again).
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.transport.IdentityStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private enum class IdentityGateState { CHECKING, READY, UNAVAILABLE, RESET_FAILED }

@Composable
fun IdentityGate(identity: IdentityStore, content: @Composable () -> Unit) {
    var state by remember {
        mutableStateOf(if (identity.isReady) IdentityGateState.READY else IdentityGateState.CHECKING)
    }
    val scope = rememberCoroutineScope()
    suspend fun check() {
        state = IdentityGateState.CHECKING
        state = withContext(Dispatchers.IO) {
            if (runCatching { identity.secretKey() }.isSuccess) IdentityGateState.READY else IdentityGateState.UNAVAILABLE
        }
    }
    LaunchedEffect(Unit) { if (state != IdentityGateState.READY) check() }
    when (state) {
        IdentityGateState.READY -> content()
        IdentityGateState.CHECKING -> PPScreen {}
        IdentityGateState.UNAVAILABLE, IdentityGateState.RESET_FAILED -> IdentityUnavailableScreen(
            resetFailed = state == IdentityGateState.RESET_FAILED,
            onRetry = { scope.launch { check() } },
            onReset = {
                scope.launch {
                    state = IdentityGateState.CHECKING
                    state = withContext(Dispatchers.IO) {
                        if (runCatching { identity.reset() }.isSuccess) IdentityGateState.READY else IdentityGateState.RESET_FAILED
                    }
                }
            },
        )
    }
}

@Composable
private fun IdentityUnavailableScreen(resetFailed: Boolean, onRetry: () -> Unit, onReset: () -> Unit) {
    PPScreen {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
            Column(
                Modifier.fillMaxSize().padding(34.dp),
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    stringResource(R.string.identity_unavailable_title),
                    fontSize = 30.sp, lineHeight = 38.sp, fontFamily = PPFont.Serif, color = PPColor.Ink,
                )
                Spacer(Modifier.height(14.dp))
                Text(
                    stringResource(if (resetFailed) R.string.identity_reset_failed_body else R.string.identity_unavailable_body),
                    fontSize = PPSize.BodyMin, lineHeight = 26.sp, color = PPColor.Ink60,
                )
                Spacer(Modifier.height(36.dp))
                PrimaryButton(stringResource(R.string.identity_unavailable_retry), onRetry)
                Spacer(Modifier.height(12.dp))
                OutlinedButton(
                    onClick = onReset,
                    modifier = Modifier.fillMaxWidth().height(58.dp),
                    shape = RoundedCornerShape(PPSize.RadiusControl),
                    border = androidx.compose.foundation.BorderStroke(1.5.dp, PPColor.BorderStrong),
                ) { Text(stringResource(R.string.identity_unavailable_reset), fontSize = 18.sp, color = PPColor.Ink60) }
                Spacer(Modifier.height(10.dp))
                Text(
                    stringResource(R.string.identity_unavailable_reset_hint),
                    fontSize = 14.sp, lineHeight = 22.sp, color = PPColor.Ink40,
                    textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
