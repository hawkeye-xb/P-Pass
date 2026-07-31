package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WatermarkStoreTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun freshStoreIsZero() {
        assertEquals(0L, WatermarkStore(tmp.root).load())
    }

    @Test
    fun savedValueRoundTrips() {
        val store = WatermarkStore(tmp.root)
        store.save(42_000_123L)
        assertEquals(42_000_123L, WatermarkStore(tmp.root).load())
    }

    @Test
    fun corruptFileFallsBackToZero() {
        File(tmp.root, "backup.watermark").writeText("not a number")
        assertEquals(0L, WatermarkStore(tmp.root).load())
    }

    @Test
    fun overwriteAdvances() {
        val store = WatermarkStore(tmp.root)
        store.save(1)
        store.save(2)
        assertEquals(2L, store.load())
    }
}
