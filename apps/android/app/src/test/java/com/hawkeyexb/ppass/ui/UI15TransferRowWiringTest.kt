package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class UI15TransferRowWiringTest {
    @Test
    fun the_transfer_row_is_wired_from_the_projection_to_the_screen() {
        val sending = StatusLine.Working(BackupUiState.Sending(done = 2, total = 5, currentFile = "fallback.jpg"))
        val normalRow = com.hawkeyexb.ppass.backup.flow.TransferRow(
            fileName = "IMG_001.HEIC",
            bytesText = "12.3 / 189 MB",
            pace = com.hawkeyexb.ppass.backup.flow.TransferPace.MOVING,
            quietSeconds = 2,
        )
        val normalSlots = heroBusySlotsOf(sending, normalRow, 0.25f)
        assertEquals("IMG_001.HEIC", normalSlots.fileNameOverride)
        assertEquals(HeroBusySecondLine.Kind.DETAIL, normalSlots.secondLine.kind)
        assertEquals("12.3 / 189 MB", normalSlots.secondLine.bytesText)
        assertEquals(2, normalSlots.secondLine.done)
        assertEquals(5, normalSlots.secondLine.total)
        assertEquals(PPColor.Ink60, normalSlots.secondLineColor)
        assertEquals(PPColor.Safe, normalSlots.progressColor)

        val slowRow = normalRow.copy(pace = com.hawkeyexb.ppass.backup.flow.TransferPace.SLOW, quietSeconds = 18)
        val slowSlots = heroBusySlotsOf(sending, slowRow, 0.25f)
        assertEquals(HeroBusySecondLine.Kind.SLOW, slowSlots.secondLine.kind)
        assertEquals(18, slowSlots.secondLine.quietSeconds)
        assertEquals(PPColor.Waiting, slowSlots.secondLineColor)
        assertEquals(PPColor.Waiting, slowSlots.progressColor)
    }

    @Test
    fun every_line_in_the_busy_block_is_single_line_and_the_bar_slot_is_reserved() {
        val preparing = StatusLine.Working(BackupUiState.Preparing)
        val slots = heroBusySlotsOf(preparing, transferRow = null, transferProgress = null)
        assertEquals(null, slots.fileNameOverride)
        assertEquals(HeroBusySecondLine.Kind.EMPTY, slots.secondLine.kind)
        assertEquals(2, slots.singleLineCount)
        assertEquals(6, slots.progressSlotHeightDp)
    }
}
