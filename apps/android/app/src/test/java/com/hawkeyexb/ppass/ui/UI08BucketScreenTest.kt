package com.hawkeyexb.ppass.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UI08BucketScreenTest {
    private fun bucketScreenSource(): String {
        var dir = File(System.getProperty("user.dir"))
        while (!File(dir, "apps/android").isDirectory) {
            dir = dir.parentFile ?: error("apps/android not found")
        }
        return File(
            dir,
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt",
        ).readText()
    }

    @Test
    fun album_name_is_one_line_and_ellipsized_without_changing_bucket_selection() {
        val source = bucketScreenSource()
        assertTrue("album name must have a single-line limit", source.contains("maxLines = 1"))
        assertTrue(
            "album name must show an ellipsis when the row is constrained",
            source.contains("overflow = TextOverflow.Ellipsis"),
        )
        assertTrue("album name must reserve the remaining row width", source.contains("Modifier.weight(1f)"))
        assertFalse("the old unconstrained row width must not return", source.contains("weight(1f, fill = false)"))
        assertTrue("selection semantics must still be keyed by bucket id", source.contains("selected = b.id in checked"))
        assertTrue("count semantics must still be keyed by checked bucket ids", source.contains("it.id in checked"))
    }

    @Test
    fun bucket_cover_requests_measured_display_dimensions() {
        val source = bucketScreenSource()
        assertTrue("cover size must come from the measured display bounds", source.contains("onSizeChanged"))
        assertTrue("thumbnail loading must wait for a non-zero measured size", source.contains("displaySize != IntSize.Zero"))
        assertTrue("the request must use both measured dimensions", source.contains("Size(displaySize.width, displaySize.height)"))
        assertTrue("a size change must restart the request", source.contains("key2 = displaySize"))
        assertFalse("the old fixed low-resolution request must not return", source.contains("Size(200, 200)"))
    }
}
