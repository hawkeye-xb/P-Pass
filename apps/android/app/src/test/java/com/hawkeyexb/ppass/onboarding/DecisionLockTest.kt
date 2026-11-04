// 决定页「处理中」锁（#1373 评审：定案「决定开始处理后，决定页两个按钮都不可点，直到进照片页或回到决定页」）。
package com.hawkeyexb.ppass.onboarding

import com.hawkeyexb.ppass.DecisionLock
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DecisionLockTest {
    private val main by lazy { File("src/main/java/com/hawkeyexb/ppass/MainActivity.kt").readText() }

    /** 处理中再点（任一按钮）不触发第二次；取消后能再点。反证：tryLock 不看 busy 恒返回 true，第二次点击那条红。 */
    @Test
    fun second_tap_while_busy_does_nothing_and_unlock_allows_again() {
        val lock = DecisionLock()
        var started = 0
        val tap = { if (lock.tryLock()) started++ }
        tap()
        tap() // 同一按钮连点
        tap() // 另一个按钮
        assertEquals(1, started)
        assertTrue(lock.busy)
        lock.unlock() // 取消 / 没登记上 / 回到决定页
        assertFalse(lock.busy)
        tap()
        assertEquals(2, started)
    }

    /** 两个按钮都经过锁，并把锁状态交给决定页置灰。反证：任一按钮直接调处理函数（去掉 tryLock），本条红。 */
    @Test
    fun both_decision_buttons_go_through_the_lock() {
        assertTrue(main.contains("onChooseScope = { if (decisionLock.tryLock()) onDecisionChooseScope(s.pairing) }"))
        assertTrue(main.contains("onPickPhotos = { if (decisionLock.tryLock()) launchDecisionPick(s.pairing) }"))
        assertTrue(main.contains("busy = decisionLock.busy"))
        val ui = File("src/main/java/com/hawkeyexb/ppass/ui/DecisionScreen.kt").readText()
        assertTrue(ui.contains("enabled = !busy)"))
        assertTrue(ui.contains(".clickable(enabled = !busy, onClick = onPickPhotos)"))
    }

    /**
     * 每个出口都解锁，没有卡死在锁住的路径：离开决定页统一解锁；留在决定页的出口——选图取消、一张没登记上、
     * 权限结果丢了配对、系统选图 / 权限框拉不起来——各自解锁。反证：删掉其中任何一处 unlock，计数不对、本条红。
     */
    @Test
    fun every_exit_unlocks() {
        assertTrue(main.contains("LaunchedEffect(screen) { if (screen !is Screen.Decision) decisionLock.unlock() }"))
        assertEquals(5, Regex("""decisionLock\.unlock\(\)""").findAll(main).count() - 1)
    }
}
