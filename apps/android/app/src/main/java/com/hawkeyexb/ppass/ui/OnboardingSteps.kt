// 手机 Onboarding（配对成功后）三步的后两步：「系统权限」→（相册选择，
// 复用既有 BucketScreen，不在本文件）→「备份条件」。2026-08-17 用户
// 复核实机效果后收缩：系统权限步骤只问读取照片（必需），通知与忽略
// 电池优化退回既有的契机式提醒（HomeScreen 的通知/电池白名单卡），
// 不再占 onboarding 的一步；仅充电/仅 WiFi 是 App 内策略不需权限。
// 点「进入 App」收尾，事后可在设置页重新查看这三步。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hawkeyexb.ppass.R

/** 三步小节标题——跟桌面首启向导同款「1/3」量感，不做进度条这么重。 */
@Composable
private fun StepKicker(step: Int, total: Int, title: String) {
    Text(
        stringResource(R.string.onboard_step_of, step, total),
        fontSize = 13.sp, fontWeight = FontWeight.Bold,
        letterSpacing = 1.2.sp, color = PPColor.Ink40,
    )
    Spacer(Modifier.height(8.dp))
    Text(title, fontSize = 26.sp, fontFamily = FontFamily.Serif, color = PPColor.Ink)
}

/** 权限行：说明用途 + 一个「允许」动作（照片必需，没有「跳过」）。 */
@Composable
private fun PermissionRow(
    title: String,
    body: String,
    granted: Boolean,
    actionLabel: String,
    onAction: () -> Unit,
) {
    Surface(
        color = PPColor.Paper,
        shape = RoundedCornerShape(PPSize.RadiusCard),
        border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    title, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                    color = PPColor.Ink, modifier = Modifier.weight(1f),
                )
                if (granted) {
                    Text(
                        stringResource(R.string.onboard_permission_granted),
                        fontSize = 13.sp, fontWeight = FontWeight.Bold, color = PPColor.Safe,
                    )
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(body, fontSize = 14.sp, lineHeight = 20.sp, color = PPColor.Ink60)
            if (!granted) {
                Spacer(Modifier.height(12.dp))
                Button(
                    onClick = onAction,
                    shape = RoundedCornerShape(PPSize.RadiusControl),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                    ),
                ) { Text(actionLabel, fontSize = 15.sp, fontWeight = FontWeight.Bold) }
            }
        }
    }
}

/**
 * 步骤 1/3「系统权限」。2026-08-17 用户复核实机效果后收缩：只问读取
 * 照片（必需，[onboardingCanContinue] 判定「继续」是否可点）——通知
 * 和忽略电池优化两项原来也在这一步问，占一屏换来的只是「弹窗前多一句
 * 解释」，用户拍板去掉，两项都退回既有的契机式提醒（HomeScreen 的
 * 通知/电池白名单卡，各自只看当前授权状态，跟这一步完全独立）。
 */
@Composable
fun OnboardPermissionsScreen(
    photoGranted: Boolean,
    onRequestPhoto: () -> Unit,
    onContinue: () -> Unit,
) {
    PPScreen {
        Column(Modifier.fillMaxSize().padding(28.dp)) {
            StepKicker(1, 3, stringResource(R.string.onboard_permissions_title))
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(R.string.onboard_permissions_sub),
                fontSize = 14.sp, lineHeight = 20.sp, color = PPColor.Ink40,
            )
            Spacer(Modifier.height(20.dp))
            PermissionRow(
                title = stringResource(R.string.onboard_perm_photos_title),
                body = stringResource(R.string.onboard_perm_photos_body),
                granted = photoGranted,
                actionLabel = stringResource(R.string.onboard_allow),
                onAction = onRequestPhoto,
            )
            Spacer(Modifier.weight(1f))
            Button(
                onClick = onContinue,
                enabled = com.hawkeyexb.ppass.backup.onboardingCanContinue(photoGranted),
                modifier = Modifier.fillMaxWidth().height(PPSize.TapMin),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                ),
            ) {
                Text(
                    stringResource(R.string.continue_label),
                    fontSize = 18.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

/** 步骤 3/3「备份条件」——仅充电/仅 Wi-Fi 是 App 内策略，明确说清
 *  「不需要再弹一次系统权限」，收尾按钮是「进入 App」。 */
@Composable
fun OnboardConditionsScreen(
    chargeOnly: Boolean,
    onChargeOnlyChange: (Boolean) -> Unit,
    wifiOnly: Boolean,
    onWifiOnlyChange: (Boolean) -> Unit,
    onEnterApp: () -> Unit,
) {
    PPScreen {
        Column(Modifier.fillMaxSize().padding(28.dp)) {
            StepKicker(3, 3, stringResource(R.string.onboard_conditions_title))
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(R.string.onboard_conditions_sub),
                fontSize = 14.sp, lineHeight = 20.sp, color = PPColor.Ink40,
            )
            Spacer(Modifier.height(20.dp))
            Surface(
                color = PPColor.Paper,
                shape = RoundedCornerShape(PPSize.RadiusCard),
                border = androidx.compose.foundation.BorderStroke(1.dp, PPColor.Border),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column {
                    Row(
                        Modifier.fillMaxWidth().padding(18.dp, 16.dp, 18.dp, 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            stringResource(R.string.setting_charge_only),
                            fontSize = 16.sp, color = PPColor.Ink,
                            modifier = Modifier.weight(1f),
                        )
                        Switch(checked = chargeOnly, onCheckedChange = onChargeOnlyChange)
                    }
                    HorizontalDivider(color = PPColor.Divider)
                    Row(
                        Modifier.fillMaxWidth().padding(18.dp, 16.dp, 18.dp, 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            stringResource(R.string.setting_wifi_only),
                            fontSize = 16.sp, color = PPColor.Ink,
                            modifier = Modifier.weight(1f),
                        )
                        Switch(checked = wifiOnly, onCheckedChange = onWifiOnlyChange)
                    }
                }
            }
            Spacer(Modifier.height(14.dp))
            Text(
                stringResource(R.string.onboard_conditions_no_permission_note),
                fontSize = 13.sp, lineHeight = 19.sp, color = PPColor.Ink40,
            )
            Spacer(Modifier.weight(1f))
            Button(
                onClick = onEnterApp,
                modifier = Modifier.fillMaxWidth().height(PPSize.TapMin),
                shape = RoundedCornerShape(PPSize.RadiusControl),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                ),
            ) {
                Text(
                    stringResource(R.string.onboard_enter_app),
                    fontSize = 18.sp, fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}
