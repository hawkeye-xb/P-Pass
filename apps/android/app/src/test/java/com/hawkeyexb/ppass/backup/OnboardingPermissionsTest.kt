// Onboarding「系统权限」步骤——纯判定函数测试（2026-08-17 收缩后只剩
// 读取照片这一项，通知/电池优化的判定函数随实现一起删掉，见
// OnboardingPermissions.kt 顶部注释）。
package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingPermissionsTest {

    // ── onboardingCanContinue：读取照片必需 ─────────────────────────
    @Test
    fun continue_requires_photo_permission_only() {
        assertFalse(onboardingCanContinue(photoGranted = false))
        assertTrue(onboardingCanContinue(photoGranted = true))
    }
}
