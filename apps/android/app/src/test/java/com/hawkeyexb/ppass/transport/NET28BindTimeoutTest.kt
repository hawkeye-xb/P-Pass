// NET-28 (#454): a hung Endpoint.bind must end the pairing wait with a
// distinguishable failure instead of spinning forever.
//
// The fake bind blocks its THREAD (CountDownLatch.await), not just its
// coroutine: that is what the #454 thread dump shows (a JVM thread stuck in
// a native syscall inside uniffi's synchronous poll), and it is the case a
// plain `withTimeout { bind() }` cannot interrupt. A fake built on delay()
// or awaitCancellation() would pass against that broken fix too.
//
// @Test(timeout) keeps a regression red instead of hanging the suite.
package com.hawkeyexb.ppass.transport

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NET28BindTimeoutTest {

    private val latches = mutableListOf<CountDownLatch>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** A gate the fake bind blocks its thread on; released in @After so no
     *  test leaves a pinned thread behind. */
    private fun gate() = CountDownLatch(1).also { latches += it }

    @After
    fun release() {
        latches.forEach { it.countDown() }
        scope.cancel()
    }

    // ---- E2 contract: the pairing flow, through the real DaemonClient ----

    @Test(timeout = 10_000)
    fun `hung bind ends pairing as Failed with a bind-timeout reason`() = runBlocking {
        val hung = gate()
        val client = DaemonClient(
            bindTimeoutMs = 300,
            openEndpoint = { hung.await(); throw IllegalStateException("released") },
            bindLog = {},
        )

        val outcome = bindThenPair(
            bind = { client.bind(null) },
            pair = { fail("pairing must not start without an endpoint"); error("unreachable") },
        )

        assertTrue("got $outcome", outcome is PairOutcome.Failed)
        val reason = (outcome as PairOutcome.Failed).reason
        assertTrue(reason, reason.contains("EndpointBindTimeoutException"))
        // Distinguishable from "cannot reach the computer" (UX-11's failure).
        assertFalse(reason, reason.contains("DaemonUnreachableException"))
        // Fits the trouble screen's 160-char detail cut without losing the cause.
        assertTrue(reason, reason.take(160).contains("not the computer"))
    }

    @Test(timeout = 10_000)
    fun `bind timeout is not a CancellationException and not DaemonUnreachable`() {
        val e = EndpointBindTimeoutException(BIND_TIMEOUT_MS)
        assertFalse(e is kotlinx.coroutines.CancellationException)
        assertFalse(e is DaemonUnreachableException)
    }

    @Test(timeout = 10_000)
    fun `bind log records the duration of a bind`() = runBlocking {
        val lines = mutableListOf<String>()
        val client = DaemonClient(
            bindTimeoutMs = 300,
            openEndpoint = { throw IllegalStateException("boom") },
            bindLog = { lines += it },
        )
        runCatching { client.bind(null) }
        assertTrue(lines.toString(), lines.single().startsWith("bind failed bindMs="))
    }

    // ---- single-flight semantics behind DaemonClient.bind ----

    private fun flight(discarded: MutableList<String> = mutableListOf()) =
        BoundedSingleFlight<String>(timeoutMs = 200, scope = scope, discard = { discarded += it })

    private fun timeout(ms: Long) = EndpointBindTimeoutException(ms)

    @Test(timeout = 10_000)
    fun `retry after a timeout waits on the same attempt instead of starting another`() = runBlocking {
        val f = flight()
        val hung = gate()
        val starts = AtomicInteger()
        val start: suspend () -> String = { starts.incrementAndGet(); hung.await(); "ep" }

        repeat(2) {
            try {
                f.get(start, ::timeout)
                fail("expected timeout")
            } catch (_: EndpointBindTimeoutException) {
            }
        }
        assertEquals(1, starts.get())
    }

    @Test(timeout = 10_000)
    fun `an attempt that finishes after its caller gave up is adopted`() = runBlocking {
        val f = flight()
        val hung = gate()
        val starts = AtomicInteger()
        val start: suspend () -> String = { starts.incrementAndGet(); hung.await(); "ep" }

        runCatching { f.get(start, ::timeout) }
        hung.countDown()
        assertEquals("ep", f.get(start, ::timeout))
        assertEquals(1, starts.get())
        assertEquals("ep", f.current())
    }

    @Test(timeout = 10_000)
    fun `a late failure clears the attempt so the next call binds afresh`() = runBlocking {
        val f = flight()
        val hung = gate()
        val done = CountDownLatch(1)
        val starts = AtomicInteger()
        val first: suspend () -> String = {
            starts.incrementAndGet()
            try {
                hung.await(); throw IllegalStateException("late failure")
            } finally {
                done.countDown()
            }
        }

        runCatching { f.get(first, ::timeout) }
        hung.countDown()
        assertTrue(done.await(5, TimeUnit.SECONDS))
        // The failed attempt must not be what the next caller waits on.
        var result: String? = null
        repeat(50) {
            if (result == null) {
                result = runCatching { f.get({ starts.incrementAndGet(); "fresh" }, ::timeout) }.getOrNull()
                if (result == null) Thread.sleep(20)
            }
        }
        assertEquals("fresh", result)
        assertEquals(2, starts.get())
    }

    @Test(timeout = 10_000)
    fun `an attempt that finishes after reset is discarded, not adopted`() = runBlocking {
        val discarded = java.util.Collections.synchronizedList(mutableListOf<String>())
        val f = flight(discarded)
        val hung = gate()
        runCatching { f.get({ hung.await(); "stale" }, ::timeout) }

        f.reset()
        hung.countDown()
        repeat(100) { if (discarded.isEmpty()) Thread.sleep(20) }

        assertEquals(listOf("stale"), discarded.toList())
        assertEquals(null, f.current())
    }
}
