// 配对发出去的设备名：用户起的系统设备名优先，机型编号只是最后的兜底（三星上 Build.MODEL = SM-S928N）。
package com.hawkeyexb.ppass

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceNameTest {

    @Test fun systemDeviceNameWinsOverModel() =
        assertEquals("妈妈的手机", pickDeviceName("妈妈的手机", "Galaxy S24 Ultra", "SM-S928N"))

    @Test fun blankSystemNameFallsBackToBluetoothName() =
        assertEquals("Galaxy S24 Ultra", pickDeviceName("  ", "Galaxy S24 Ultra", "SM-S928N"))

    @Test fun missingNamesFallBackToModel() =
        assertEquals("SM-S928N", pickDeviceName(null, "", "SM-S928N"))

    @Test fun nothingAtAllIsAndroid() =
        assertEquals("Android", pickDeviceName(null, null, " "))

    @Test fun surroundingWhitespaceIsTrimmed() =
        assertEquals("小王的手机", pickDeviceName(" 小王的手机\n", null, "SM-S928N"))
}
