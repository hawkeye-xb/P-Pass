// T-052 onboarding — three screens from the design file (P-Pass
// Mobile.dc.html): welcome → scan → joined. One promise, one big
// button; Chinese always at the same level as English; body >=17sp,
// buttons >=56dp.
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.hawkeyexb.ppass.R
import androidx.compose.ui.unit.sp

internal data class WelcomeLinkAppearance(
    val color: Color,
    val fontWeight: FontWeight,
    val topGapDp: Int,
    val minTouchHeightDp: Int,
)

internal fun welcomeManualLinkAppearance(): WelcomeLinkAppearance = WelcomeLinkAppearance(
    color = PPColor.Ink60,
    fontWeight = FontWeight.Bold,
    topGapDp = 6,
    minTouchHeightDp = 48,
)

internal fun welcomeDesktopLinkAppearance(): WelcomeLinkAppearance = WelcomeLinkAppearance(
    color = PPColor.Ink40,
    fontWeight = FontWeight.Normal,
    topGapDp = 28,
    minTouchHeightDp = 48,
)

@Composable
internal fun PrimaryButton(text: String, onClick: () -> Unit, enabled: Boolean = true) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth().height(64.dp),
        shape = RoundedCornerShape(PPSize.RadiusControl),
        colors = ButtonDefaults.buttonColors(
            containerColor = PPColor.Ink, contentColor = PPColor.Paper
        ),
    ) {
        Text(text, fontSize = 19.sp, fontWeight = FontWeight.Bold)
    }
}

/** Screen 1: one promise, one big button. */
@Composable
fun WelcomeScreen(
    onScan: () -> Unit,
    onManual: () -> Unit,
    onShareDesktopLink: () -> Unit = {},
) {
    val manualStyle = welcomeManualLinkAppearance()
    val desktopStyle = welcomeDesktopLinkAppearance()
    PPScreen {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
        // #1964：系统最大字号下正文会高于屏幕——整屏可纵向滚动；内容矮时用 SpaceBetween 把字标顶到上、主操作组压在中间、页脚退路推至最底（对位 iOS）。
        // 不能在可滚动的 Column 里用 weight 占位：滚动的无限高度约束会直接崩；heightIn(min = maxHeight) + SpaceBetween 是同一效果的合法写法。
        BoxWithConstraints(Modifier.fillMaxSize()) {
            Column(
                Modifier.fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = maxHeight)
                    .padding(32.dp),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    "P-PASS",
                    fontSize = 14.sp, fontWeight = FontWeight.Bold,
                    letterSpacing = 2.5.sp, color = PPColor.Ink60,
                )
                Column(Modifier.fillMaxWidth().padding(top = 32.dp)) {
                    Text(
                        stringResource(R.string.welcome_headline),
                        fontSize = 36.sp, lineHeight = 44.sp,
                        fontFamily = PPFont.Serif, color = PPColor.Ink,
                        modifier = Modifier.semantics { heading() },
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        stringResource(R.string.welcome_sub),
                        fontSize = PPSize.BodyMin, lineHeight = 28.sp, color = PPColor.Ink60,
                    )
                    Spacer(Modifier.height(20.dp))
                    // T-080 layout v1: 三步说明——1 打开电脑端 / 2 扫码 / 3 什么都不用做。
                    Text(
                        stringResource(R.string.welcome_step1),
                        fontSize = 15.sp, lineHeight = 25.sp, color = PPColor.Ink40,
                    )
                    Text(
                        stringResource(R.string.welcome_step2),
                        fontSize = 15.sp, lineHeight = 25.sp, color = PPColor.Ink40,
                    )
                    Text(
                        stringResource(R.string.welcome_step3),
                        fontSize = 15.sp, lineHeight = 25.sp, color = PPColor.Ink40,
                    )
                    Spacer(Modifier.height(40.dp))
                    PrimaryButton(stringResource(R.string.welcome_scan), onScan)
                    // #421：扫不了码的人（不给摄像头 / 摄像头坏了）在这一屏就有退路，
                    // 与扫码页底部同一行文字链接、同一句文案。
                    // #2093：与主按钮紧贴为同一配对操作组，保持 Ink60 与 ≥48dp 最小触摸高度。
                    Text(
                        stringResource(R.string.scan_manual_link),
                        fontSize = 14.sp,
                        fontWeight = manualStyle.fontWeight,
                        color = manualStyle.color,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth()
                            .padding(top = manualStyle.topGapDp.dp)
                            .heightIn(min = manualStyle.minTouchHeightDp.dp)
                            .semantics { role = Role.Button }
                            .clickable(onClick = onManual)
                            .padding(horizontal = 26.dp, vertical = 10.dp)
                            .wrapContentHeight(Alignment.CenterVertically),
                    )
                }
                // #2093：页脚兜底退路，由 SpaceBetween 推至页面最底部，大字号滚动时保底留出 ≥28dp 间距。
                Text(
                    stringResource(R.string.welcome_desktop_link),
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = desktopStyle.fontWeight,
                    color = desktopStyle.color,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth()
                        .padding(top = desktopStyle.topGapDp.dp)
                        .heightIn(min = desktopStyle.minTouchHeightDp.dp)
                        .clickable(role = Role.Button, onClick = onShareDesktopLink)
                        .padding(horizontal = 26.dp, vertical = 10.dp)
                        .wrapContentHeight(Alignment.CenterVertically),
                )
            }
        }
        }
    }
}

/**
 * Pairing in flight / refused / failed states share one screen. [body] null = title only (10-29 copy
 * B5/B7/B8); [footnote] = the small "error code" line under the body (B13).
 * [loading] = 正在等电脑确认（`PairPhase.Asking`）：标题上方画系统转圈（对位 iOS ProgressView）。
 */
@Composable
fun PairStatusScreen(
    title: String,
    body: String?,
    action: Pair<String, () -> Unit>?,
    footnote: String? = null,
    loading: Boolean = false,
) {
    PPScreen {
        androidx.compose.material3.ProvideTextStyle(
            androidx.compose.material3.LocalTextStyle.current.copy(fontFamily = PPFont.Sans),
        ) {
        // #1964：内容矮时垂直居中（`heightIn(min = maxHeight)` + Center），大字号超高时照常可滚，不被裁掉。
        BoxWithConstraints(Modifier.fillMaxSize()) {
            Column(
                Modifier.fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = maxHeight)
                    .padding(34.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                if (loading) {
                    CircularProgressIndicator(color = PPColor.Ink60, modifier = Modifier.padding(bottom = 18.dp))
                }
                Text(
                    title, fontSize = 30.sp, fontFamily = PPFont.Serif,
                    color = PPColor.Ink, textAlign = TextAlign.Center,
                    modifier = Modifier.semantics { heading() },
                )
                if (!body.isNullOrEmpty()) {
                    Spacer(Modifier.height(14.dp))
                    Text(
                        body, fontSize = PPSize.BodyMin, lineHeight = 26.sp,
                        color = PPColor.Ink40, textAlign = TextAlign.Center,
                    )
                }
                if (footnote != null) {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        footnote, fontSize = 14.sp, lineHeight = 21.sp,
                        color = PPColor.Ink40, textAlign = TextAlign.Center,
                    )
                }
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
        }
    }
}

