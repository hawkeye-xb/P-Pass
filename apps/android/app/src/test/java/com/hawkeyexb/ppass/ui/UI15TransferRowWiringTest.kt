package com.hawkeyexb.ppass.ui

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
        assertTrue("忙碌块默认两行都钉成单行", slots.singleLine)
        assertEquals("单行模式下文字 maxLines = 1", 1, heroBusyTextMaxLines(slots))
        assertEquals("没有进度时进度槽按 6dp 占位", 6.dp, heroBusyProgressSlotHeight(slots))
    }

    @Test
    fun the_busy_slots_are_driven_by_the_projection_not_hardcoded_in_the_screen() {
        val slots = heroBusySlotsOf(
            StatusLine.Working(BackupUiState.Sending(done = 1, total = 3)),
            transferRow = null,
            transferProgress = 0.5f,
        )
        val wrapped = slots.copy(singleLine = false, progressSlotHeightDp = 10)
        assertEquals("关掉单行约束后文字恢复多行", Int.MAX_VALUE, heroBusyTextMaxLines(wrapped))
        assertEquals("进度槽高度跟着投影里的值走", 10.dp, heroBusyProgressSlotHeight(wrapped))
    }
}
