// UI-21 (#401)：英雄卡 H-C（`confirmedRaw > n`，「正在重新清点照片」）承诺的事必须真的会发生。
//
// 新模型（#413）里 H-C 只出现在一个窗口：引擎第一次算出待办之前，首页拿到的视图是 null（visibleEngineView），
// m 退回 order 表的 CONFIRMED 数——已备份后又从相册删掉的照片还算在里面。让它消失的是引擎在手机上自己算待办，
// 不需要连着电脑；算出来之后 m = n − 待办 − 已跳过，恒 ≤ n。本文件钉住这条收敛路径，并钉住文案只说这件事。
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.backup.order.OrderState
import com.hawkeyexb.ppass.ui.HeroRender
import com.hawkeyexb.ppass.ui.heroRenderOf
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class UI21UnreconciledHeroTest {
    private val albums = setOf(7L)

    /** 与首页同一条链路：引擎视图经 visibleEngineView（EngineViewGateway 用的同一个函数）→ 账目 → 三元组。 */
    private fun Rig.heroRender(): Pair<HeroRender, Long> {
        val view = visibleEngineView(engine.view.value, engine.pendingKnown.value)
        val n = media.photos.count { media.inScope(it.bucketId) }.toLong()
        val t = flowTripletOf(FlowProjection.facts(store, control, albums, n, view), albums)!!
        return heroRenderOf(MediaAccess.FULL, t) to t.confirmedRaw
    }

    // 场景（卡面复现的新模型版）：10 张全部 CONFIRMED，之后用户在手机上删掉 3 张；进程重启，电脑不在、配对都读不到。
    // 引擎还没算待办时首页是 H-C；引擎自己启动（start → 重算待办）之后，不碰电脑就回到三元组 7 / 7。
    // 反证 1：FlowEngine.start() 去掉 refreshPending() → pendingKnown 一直是 false，settle 后仍是 Unreconciled，红。
    // 反证 2：visibleEngineView 不看 pendingKnown（恒返回 view）→ 第一段断言 Unreconciled 变 Triplet，红
    //        （那等于在待办没算出来时就说数，是 #418 要堵的另一句假话）。
    @Test
    fun `the unreconciled hero clears by itself on the phone without reaching the computer`() = runTest {
        val rig = Rig(this)
        (1L..10L).forEach { rig.order(rig.photo(it, generation = it), OrderState.CONFIRMED) }
        listOf(2L, 5L, 8L).forEach(rig.media::remove)
        rig.epoch = null
        rig.probeResult = ProbeResult.Unreachable

        assertFalse("还没算过待办", rig.engine.pendingKnown.value)
        val (before, rawBefore) = rig.heroRender()
        assertEquals(10L, rawBefore)
        assertEquals("待办没算出来时 m 退回 order 表，10 > 7 → H-C", HeroRender.Unreconciled, before)

        rig.settle() // 只让引擎自己启动：没有任何触发、没有连电脑。

        val (after, rawAfter) = rig.heroRender()
        assertEquals(7L, rawAfter)
        assertEquals("手机本地算完待办，m = n − 待办 − 已跳过 ≤ n，H-C 自己消失", HeroRender.Triplet, after)
        assertEquals("收敛不靠探测电脑", 0, rig.probes)
        assertEquals("也不靠问电脑「这些还在吗」", 0, rig.presenceCalls)
        assertTrue(rig.delivery.deliveredMediaIds.isEmpty())
        assertEquals("order 行不改写（CONFIRMED 不可否定）", OrderState.CONFIRMED, rig.state(2))
        rig.close()
    }

    // 待办算出来之后 H-C 不可达：m 被夹在 [0, n]。这是「这一格只是过渡态」的另一半证据。
    // 反证：FlowProjection.done 去掉 coerceIn / 改回 confirmed → 10 > 7，红。
    @Test
    fun `once the backlog is known the hero can no longer claim more backed up than the albums hold`() {
        val view = EngineView(GlobalState.IDLE, pending = 0)
        val p = FlowProjection(view = visibleEngineView(view, pendingKnown = true), confirmed = 10, inScopeTotal = 7, failed = 0)
        val t = flowTripletOf(p, albums)!!
        assertEquals(7L, t.confirmedRaw)
        assertEquals(HeroRender.Triplet, heroRenderOf(MediaAccess.FULL, t))
        assertNull(visibleEngineView(view, pendingKnown = false))
    }

    // 文案只能说真实会发生的事：手机本地重新清点，不需要电脑 / 插电 / Wi-Fi。
    // 反证：两份 strings.xml 的 hero_unreconciled_* 还原成「下次这台手机连上存储电脑时会自己核对」
    //      「Next time this phone reaches the storage computer…」→ 红。
    @Test
    fun `the unreconciled copy promises only the local recount that actually happens`() {
        val res = File("src/main/res")
        val zh = File(res, "values-zh/strings.xml").readText()
        val en = File(res, "values/strings.xml").readText()
        fun line(xml: String, key: String) = xml.lines().single { it.contains("name=\"$key\"") }.substringAfter(">")
        val zhText = line(zh, "hero_unreconciled_title") + line(zh, "hero_unreconciled_body")
        val enText = line(en, "hero_unreconciled_title") + line(en, "hero_unreconciled_body")

        listOf("连上", "存储电脑", "下次", "对不上").forEach {
            assertFalse("zh 不许把「连上电脑」当触发条件、也不许说账对不上：$it", zhText.contains(it))
        }
        listOf("reaches", "storage computer", "next time", "do not match").forEach {
            assertFalse("en 不许把「连上电脑」当触发条件、也不许说账对不上：$it", enText.contains(it, ignoreCase = true))
        }
        assertTrue("zh 要说是手机在清点", zhText.contains("手机正在"))
        assertTrue("zh 要说不需要电脑", zhText.contains("不用连电脑"))
        assertTrue("en 要说是手机在清点", enText.contains("this phone is recounting"))
        assertTrue("en 要说不需要电脑", enText.contains("does not need the computer"))
    }
}
