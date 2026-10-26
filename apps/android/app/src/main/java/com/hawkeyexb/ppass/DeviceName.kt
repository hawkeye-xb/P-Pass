// 配对时发给电脑的「这台手机叫什么」：用户在系统「设置 › 关于手机 › 设备名称」里起的名字，不是机型编号（SM-S928N）。
// 系统没有公开的单一 API：Settings.Global.DEVICE_NAME（API 25+，多数厂商把「设备名称」写在这里）→ 部分 ROM 只写蓝牙名
// （Settings.Secure "bluetooth_name"）→ 都没有才退到 Build.MODEL。读取在 MainActivity，取舍规则在这里（纯函数，可单测）。
package com.hawkeyexb.ppass

internal fun pickDeviceName(globalName: String?, bluetoothName: String?, model: String?): String =
    sequenceOf(globalName, bluetoothName, model)
        .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }
        .firstOrNull() ?: "Android"
