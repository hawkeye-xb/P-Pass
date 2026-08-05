// DOG-01d acceptance (counterproof): a failing MediaStore query must
// degrade to "triplet hidden" (null), never crash the app.
//
// Samsung repro: countAll's COUNT(*) projection is rejected by the
// scoped-storage provider (Invalid column count(*)), and refreshTriplet
// runs at startup with no catch -> first launch FATAL. The fix: compliant
// [_ID] projection + Throwable-level guard in the production function
// computeTripletSafe (what refreshTriplet actually calls - DOG-01c rule:
// tests go through the production call chain).
//
// JVM unit tests cannot instantiate ContentResolver (android.jar stubs
// throw on construction), so a null resolver makes countAll's query
// throw NPE - same Throwable-level contract as the Samsung
// IllegalArgumentException; both must land in the null branch.
package com.hawkeyexb.ppass.backup

import java.io.File
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MediaQueryFailureTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun mediaQueryFailureYieldsNullTripletInsteadOfCrash() {
        val store = ConfirmedStore(File(tmp.root, "backup-state/remote"))
        // refreshTriplet's production implementation; a throwing query
        // must be swallowed into null (UI hides the triplet), never
        // propagate to the caller (which would crash the app).
        val triplet = computeTripletSafe(null, store)
        assertNull(
            "media query failure must hide the triplet (null), never throw",
            triplet,
        )
    }
}
