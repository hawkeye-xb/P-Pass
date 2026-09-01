package com.hawkeyexb.ppass.backup

import org.junit.Assert.assertEquals
import org.junit.Test

class MediaScannerBucketNameTest {
    @Test
    fun missing_album_name_is_preserved_as_null() {
        assertEquals(null, bucketNameOrNull(null))
        assertEquals(null, bucketNameOrNull(""))
        assertEquals(null, bucketNameOrNull("   "))
    }

    @Test
    fun present_album_name_is_preserved() {
        assertEquals("Camera", bucketNameOrNull("Camera"))
    }
}
