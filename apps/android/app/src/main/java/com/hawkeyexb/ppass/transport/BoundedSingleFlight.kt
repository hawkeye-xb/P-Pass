// NET-28 (#454): one in-flight attempt at a time, and callers wait for it
// for a bounded time only.
//
// Why the caller does not just wrap the attempt in `withTimeout`: an
// iroh-ffi call is a uniffi future, and uniffi's `RustFuture::poll` runs the
// Rust future synchronously on the calling thread (uniffi_core 0.31.2,
// ffi/rustfuture/future.rs). If the Rust side blocks inside a poll — the
// #454 thread dump shows exactly that, a JVM thread parked in a native
// syscall under `ffi_iroh_ffi_rust_future_poll_u64` — the coroutine never
// reaches a suspension point, so cancellation (and therefore `withTimeout`)
// can never take effect. The attempt therefore runs in a scope the caller
// does not own, and the caller only suspends on `Deferred.await()`, which is
// always cancellable.
package com.hawkeyexb.ppass.transport

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Holds one value produced by a possibly-hanging [get] `start` action.
 *
 * - At most one attempt runs at a time. A caller that times out leaves the
 *   attempt running; the next caller waits on **the same attempt** instead of
 *   starting another one (another one would most likely hang the same way and
 *   pin one more thread, and if both finished there would be two values —
 *   for an endpoint, two endpoints with the same identity).
 * - An attempt that finishes after its callers gave up is still adopted: the
 *   next [get] returns immediately.
 * - An attempt that fails clears itself, so the next [get] starts a fresh one.
 * - [reset] forgets the current value and any in-flight attempt; an attempt
 *   that finishes after a reset is handed to `discard` instead of adopted.
 */
internal class BoundedSingleFlight<T : Any>(
    private val timeoutMs: Long,
    /** Must not be a child of any caller's job (see file header). */
    private val scope: CoroutineScope,
    private val discard: (T) -> Unit,
) {
    private val lock = Mutex()
    @Volatile private var value: T? = null
    private var inFlight: Deferred<T>? = null
    private var generation = 0L

    fun current(): T? = value

    /** Returns the held value, or waits up to [timeoutMs] for the in-flight
     *  attempt (starting one with [start] if none is running). On timeout
     *  throws what [onTimeout] builds; the attempt keeps running. */
    suspend fun get(start: suspend () -> T, onTimeout: (timeoutMs: Long) -> Throwable): T {
        value?.let { return it }
        val attempt = lock.withLock {
            value?.let { return it }
            inFlight ?: launch(start).also { inFlight = it }
        }
        return withTimeoutOrNull(timeoutMs) { attempt.await() } ?: throw onTimeout(timeoutMs)
    }

    private fun launch(start: suspend () -> T): Deferred<T> {
        val gen = generation
        return scope.async {
            val result = try {
                start()
            } catch (t: Throwable) {
                lock.withLock { if (generation == gen) inFlight = null }
                throw t
            }
            val adopted = lock.withLock {
                if (generation == gen) {
                    value = result
                    inFlight = null
                    true
                } else {
                    false
                }
            }
            if (!adopted) discard(result)
            result
        }
    }

    /** Forget the value and any in-flight attempt; returns the old value. */
    suspend fun reset(): T? = lock.withLock {
        generation++
        inFlight = null
        value.also { value = null }
    }
}
