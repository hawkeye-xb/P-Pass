package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.proto.AssetMeta
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class PhotosScreenAttributionTest {
    private fun tempDir(case: String): File =
        java.nio.file.Files.createTempDirectory("ppass-sync05-$case").toFile()

    private fun asset(hash: String, srcDevice: String?): AssetMeta =
        AssetMeta(hash = hash, srcDevice = srcDevice)

    @Test
    fun source_filters_classify_local_family_and_unknown_from_asset_metadata() {
        val local = "a".repeat(64)
        val assets = listOf(
            asset("mine", local),
            asset("family", "b".repeat(64)),
            asset("unknown", null),
            asset("blank", ""),
        )

        assertEquals(assets, filterAssetsBySource(assets, TimelineFilter.All, local))
        assertEquals(listOf(assets[0]), filterAssetsBySource(assets, TimelineFilter.LocalOnly, local))
        assertEquals(listOf(assets[1]), filterAssetsBySource(assets, TimelineFilter.Family, local))
        assertEquals(emptyList<AssetMeta>(), filterAssetsBySource(assets, TimelineFilter.LocalOnly, null))
        assertEquals(emptyList<AssetMeta>(), filterAssetsBySource(assets, TimelineFilter.Family, null))
    }

    @Test
    fun source_filters_do_not_need_backup_state_directory() {
        val root = tempDir("no-shadow-state")
        val backupState = File(root, "backup-state/remote").apply { mkdirs() }
        check(backupState.parentFile!!.deleteRecursively())

        val local = "a".repeat(64)
        val assets = listOf(asset("mine", local), asset("family", "b".repeat(64)))
        assertEquals(listOf(assets[0]), filterAssetsBySource(assets, TimelineFilter.LocalOnly, local))
        assertEquals(listOf(assets[1]), filterAssetsBySource(assets, TimelineFilter.Family, local))
    }
}
