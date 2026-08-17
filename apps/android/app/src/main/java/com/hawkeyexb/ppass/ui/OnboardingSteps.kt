// 手机 Onboarding（配对成功后）三步的后两步：「系统权限」→（相册选择，
// 复用既有 BucketScreen，不在本文件）→「备份条件」。设计规格（用户
// 2026-08-17 原话）：读取照片必需、通知与忽略电池优化可跳过且各自说清
// 用途、点一个只弹一次系统对话框；仅充电/仅 WiFi 是 App 内策略不需
// 权限。点「进入 App」收尾，事后可在设置页重新查看这三步。
package com.hawkeyexb.ppass.ui

import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material3.TextButton
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

/** 一条权限行：说明用途 + 状态相关的一个动作（必需项没有「跳过」）。 */
@Composable
private fun PermissionRow(
    title: String,
    body: String,
    granted: Boolean,
    required: Boolean,
    actionLabel: String,
    onAction: () -> Unit,
    onSkip: (() -> Unit)? = null,
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
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = onAction,
                        shape = RoundedCornerShape(PPSize.RadiusControl),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = PPColor.Ink, contentColor = PPColor.Paper,
                        ),
                    ) { Text(actionLabel, fontSize = 15.sp, fontWeight = FontWeight.Bold) }
                    if (onSkip != null) {
                        TextButton(onClick = onSkip) {
                            Text(
                                stringResource(R.string.onboard_skip),
                                fontSize = 15.sp, color = PPColor.Ink40,
                            )
                        }
                    } else if (required) {
                        Spacer(Modifier.height(1.dp)) // 必需项没有跳过，占位对齐由按钮自身撑起
                    }
                }
            }
        }
    }
}

/**
 * 步骤 1/3「系统权限」。[photoGranted] 决定「继续」是否可点
 * （[onboardingCanContinue] 判定，读取照片必需）；通知/电池两项传
 * null action 表示已经问过或已授予，本次不再出现可点入口——由调用方
 * （MainActivity）按 [com.hawkeyexb.ppass.backup.shouldOfferNotificationPermission]
 * / [com.hawkeyexb.ppass.backup.shouldOfferBatteryWhitelist] 算好再传进来。
 */
@Composable
fun OnboardPermissionsScreen(
    photoGranted: Boolean,
    onRequestPhoto: () -> Unit,
    showNotificationRow: Boolean,
    notificationGranted: Boolean,
    onRequestNotification: () -> Unit,
    onSkipNotification: () -> Unit,
    showBatteryRow: Boolean,
    batteryWhitelisted: Boolean,
    onRequestBattery: () -> Unit,
    onSkipBattery: () -> Unit,
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
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                PermissionRow(
                    title = stringResource(R.string.onboard_perm_photos_title),
                    body = stringResource(R.string.onboard_perm_photos_body),
                    granted = photoGranted,
                    required = true,
                    actionLabel = stringResource(R.string.onboard_allow),
                    onAction = onRequestPhoto,
                    onSkip = null,
                )
                if (showNotificationRow) {
                    PermissionRow(
                        title = stringResource(R.string.onboard_perm_notif_title),
                        body = stringResource(R.string.onboard_perm_notif_body),
                        granted = notificationGranted,
                        required = false,
                        actionLabel = stringResource(R.string.onboard_allow),
                        onAction = onRequestNotification,
                        onSkip = onSkipNotification,
                    )
                }
                if (showBatteryRow) {
                    PermissionRow(
                        title = stringResource(R.string.onboard_perm_battery_title),
                        body = stringResource(R.string.onboard_perm_battery_body),
                        granted = batteryWhitelisted,
                        required = false,
                        actionLabel = stringResource(R.string.onboard_allow),
                        onAction = onRequestBattery,
                        onSkip = onSkipBattery,
                    )
                }
            }
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
