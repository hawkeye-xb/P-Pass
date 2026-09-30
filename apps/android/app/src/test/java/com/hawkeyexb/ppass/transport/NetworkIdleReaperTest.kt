package com.hawkeyexb.ppass.transport

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** #434：后台空闲才关 endpoint；前台 / 引擎在跑 / 还有东西在用都不关。 */
@OptIn(ExperimentalCoroutinesApi::class)
class NetworkIdleReaperTest {
    private val grace = 30_000L

    @Test
    fun parks_once_after_the_grace_period_in_background() = runTest {
        var parks = 0
        val reaper = NetworkIdleReaper(backgroundScope, park = { parks++; true }, graceMs = grace)
        reaper.setForeground(false)
        advanceTimeBy(grace - 1); runCurrent()
        assertEquals("not before the grace period", 0, parks)
        advanceTimeBy(1); runCurrent()
        assertEquals(1, parks)
        advanceTimeBy(grace * 10); runCurrent()
        assertEquals("parked once; nothing re-armed it", 1, parks)
    }

    @Test
    fun never_parks_while_in_foreground_or_while_the_engine_runs() = runTest {
        var parks = 0
        val reaper = NetworkIdleReaper(backgroundScope, park = { parks++; true }, graceMs = grace)
        reaper.setForeground(true)
        advanceTimeBy(grace * 5); runCurrent()
        reaper.setForeground(false)
        reaper.setEngineBusy(true)
        advanceTimeBy(grace * 5); runCurrent()
        assertEquals(0, parks)
        reaper.setEngineBusy(false)
        advanceTimeBy(grace); runCurrent()
        assertEquals("cycle over in background → parked", 1, parks)
    }

    @Test
    fun coming_back_to_foreground_cancels_a_pending_park() = runTest {
        var parks = 0
        val reaper = NetworkIdleReaper(backgroundScope, park = { parks++; true }, graceMs = grace)
        reaper.setForeground(false)
        advanceTimeBy(grace / 2); runCurrent()
        reaper.setForeground(true)
        advanceTimeBy(grace * 5); runCurrent()
        assertEquals(0, parks)
    }

    @Test
    fun a_refused_park_is_retried_until_it_succeeds() = runTest {
        var attempts = 0
        val reaper = NetworkIdleReaper(backgroundScope, park = { ++attempts >= 3 }, graceMs = grace)
        reaper.setForeground(false)
        advanceTimeBy(grace * 3); runCurrent()
        assertEquals(3, attempts)
        advanceTimeBy(grace * 5); runCurrent()
        assertEquals("stops retrying once parked", 3, attempts)
    }

    @Test
    fun a_bind_after_parking_re_arms_the_reaper() = runTest {
        var parks = 0
        val reaper = NetworkIdleReaper(backgroundScope, park = { parks++; true }, graceMs = grace)
        reaper.setForeground(false)
        advanceTimeBy(grace); runCurrent()
        assertEquals(1, parks)
        reaper.onBound() // e.g. an audit flush bound the ctrl endpoint again
        advanceTimeBy(grace); runCurrent()
        assertEquals(2, parks)
    }
}
