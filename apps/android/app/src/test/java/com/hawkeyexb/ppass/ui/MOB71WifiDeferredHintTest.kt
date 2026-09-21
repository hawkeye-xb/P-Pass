package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.backup.MediaAccess

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A Wi-Fi wait recorded when the round was started is transient UI evidence, not a
 * durable condition. Once the user disables the Wi-Fi restriction, pausing the
 * current round makes it non-busy but must not make that stale evidence visible.
 */
class MOB71WifiDeferredHintTest {
    @Test
    fun pausedRoundDoesNotReviveWifiWaitAfterWifiOnlyIsDisabled() {
        assertFalse(
            "a stale deferred marker must not render after the user turned Wi-Fi-only off",
            shouldShowWifiDeferredHint(
                wifiOnly = false,
                wifiDeferred = true,
                busy = false, // paused rounds are not sending
                mediaAccess = MediaAccess.FULL,
            ),
        )
    }

    @Test
    fun enabledWifiOnlyOnMeteredNetworkStillShowsTheWait() {
        assertTrue(
            shouldShowWifiDeferredHint(
                wifiOnly = true,
                wifiDeferred = true,
                busy = false,
                mediaAccess = MediaAccess.FULL,
            ),
        )
    }

    @Test
    fun busyOrPartialAccessSuppressesTheWaitRegardlessOfADeferredMarker() {
        assertFalse(shouldShowWifiDeferredHint(true, true, busy = true, mediaAccess = MediaAccess.FULL))
        assertFalse(shouldShowWifiDeferredHint(true, true, busy = false, mediaAccess = MediaAccess.PARTIAL))
    }
}
