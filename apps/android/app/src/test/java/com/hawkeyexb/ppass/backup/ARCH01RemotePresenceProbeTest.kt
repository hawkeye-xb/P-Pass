package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class ARCH01RemotePresenceProbeTest {
    @Test
    fun presence_page_accepts_exactly_500_hashes_and_preserves_order() {
        val hashes = (0 until 500).map { "%064x".format(it) }

        assertEquals(hashes, presenceQueryFor(hashes).hashes)
    }

    @Test
    fun presence_page_rejects_empty_oversized_and_malformed_input() {
        assertInvalid { presenceQueryFor(emptyList()) }
        assertInvalid { presenceQueryFor((0..500).map { "%064x".format(it) }) }
        assertInvalid { presenceQueryFor(listOf("not-a-blake3-hash")) }
    }

    private fun assertInvalid(block: () -> Unit) {
        try {
            block()
            fail("presence page must reject this input")
        } catch (_: IllegalArgumentException) {
        }
    }
}
