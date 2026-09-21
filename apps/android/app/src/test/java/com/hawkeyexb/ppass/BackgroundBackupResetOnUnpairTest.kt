package com.hawkeyexb.ppass

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MOB-68 立的规矩：断开配对绝不能把后台备份**打开**。那一条不变。
 *
 * MOB-93 改的是另一半。MOB-68 当时把"不许打开"实现成了"连用户的意图
 * 一起清掉"，理由写在 `clearLocalPairing` 的注释里——「下一轮 onboarding
 * 会重新问」。#257 加了快速重连（连回以前连过的电脑直接回首页、跳过
 * onboarding）之后，那个"重新问"不再必然发生，意图有去无回，兜底对账
 * 的载体跟着一起没了（真机取证见 MOB-93）。
 *
 * 所以清意图这件事挪到了它本来该在的地方：**换一台新电脑时的 onboarding
 * 入口**。断开只负责停生产者。
 */
class BackgroundBackupResetOnUnpairTest {

    private fun mainActivity() =
        File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText()

    @Test
    fun disconnecting_stops_the_producer_and_never_turns_it_on() {
        val cleanup = mainActivity().substringAfter("private fun clearLocalPairing(")
            .substringBefore("\n}")

        assertTrue(
            "断开必须走停生产者、留意图的那条处置",
            cleanup.contains("suspendAutoBackupForPairingChange(context.filesDir)"),
        )
        // MOB-68 的红线，原样保留。
        assertFalse("断开绝不能打开后台备份", cleanup.contains("setEnabled(true)"))
        assertFalse("断开绝不能替用户要后台备份", cleanup.contains("setRequested(true)"))
    }

    @Test
    fun the_intent_is_cleared_when_a_different_desktop_starts_onboarding() {
        // MOB-68 的原意（换台电脑要重新问）没丢，只是挪了地方。
        val onboardingBranch = mainActivity()
            .substringAfter("if (hasExistingLedgerFor(outcome.pairing))")
            .substringBefore("enterBucketPicker(outcome.pairing, firstTime = true)")

        assertTrue(
            "换新电脑走 onboarding 的那条路要清掉上一台的后台备份意图",
            onboardingBranch.contains("setRequested(false)"),
        )
    }
}
