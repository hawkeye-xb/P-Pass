// 配对核对页的主次：标题 > 电脑名 > 说明 > 指纹。原来指纹 28sp 粗体，比电脑名（22）还大，层级倒挂。
package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmDesktopTypeTest {
    @Test fun titleOutranksNameOutranksBodyOutranksFingerprint() {
        val t = ConfirmDesktopType
        assertTrue("标题 ${t.Title} > 电脑名 ${t.Name}", t.Title.value > t.Name.value)
        assertTrue("电脑名 ${t.Name} > 说明 ${t.Body}", t.Name.value > t.Body.value)
        assertTrue("说明 ${t.Body} > 指纹 ${t.Fingerprint}", t.Body.value > t.Fingerprint.value)
    }
}
