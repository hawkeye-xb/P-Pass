// DOG-02: ROM 电池优化白名单引导——鸿蒙/三星杀后台是 A2 case 已知咬点。
//
// 检测：PowerManager.isIgnoringBatteryOptimizations（API 23+，minSdk 26 可用）。
// 跳转回退链：标准请求对话框 → 三星智能管理器 → 鸿蒙手机管家 → 通用列表。
// 每个 intent 经 resolveActivity 过滤，全部不可用则静默返回（不崩）。
package com.hawkeyexb.ppass.battery

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings

/** 已加白（忽略电池优化）？ */
fun isIgnoringBatteryOptimizations(context: Context): Boolean {
    val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
    return pm.isIgnoringBatteryOptimizations(context.packageName)
}

/** 跳系统设置：标准请求 → 三星 → 鸿蒙 → 通用回退。全部不可用则静默。 */
fun openBatteryOptimizationSettings(context: Context) {
    val candidates = listOf(
        // 1) 标准请求对话框（系统弹窗，需 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 权限）
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:${context.packageName}")),
        // 2) 三星智能管理器电池页
        Intent().setComponent(
            ComponentName("com.samsung.android.sm", "com.samsung.android.sm.ui.battery.BatteryActivity")
        ),
        // 3) 鸿蒙手机管家·应用启动管理（后台运行白名单入口）
        Intent().setComponent(
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            )
        ),
        // 4) 通用电池优化列表
        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
    )
    val pm = context.packageManager
    for (intent in candidates) {
        if (intent.resolveActivity(pm) != null) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                return
            } catch (_: Exception) {
                // 尝试下一个
            }
        }
    }
}
