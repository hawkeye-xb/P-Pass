package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 素材文件夹页的行为契约：授权状态文案/颜色、移除必须先过二次确认。 */
class FolderScreenTest {

    private val authorized = FolderUi(id = "f-ok", name = "Camera", needsPermission = false)
    private val expired = FolderUi(id = "f-exp", name = "Download", needsPermission = true)

    @Test
    fun permission_state_drives_copy_and_dot_colour() {
        assertEquals(R.string.folder_status_ok, folderStatusRes(authorized.needsPermission))
        assertEquals(R.string.folder_status_needs_permission, folderStatusRes(expired.needsPermission))
        assertEquals(PPColor.Ink60, folderStatusColor(authorized.needsPermission))
        assertEquals(PPColor.Act, folderStatusColor(expired.needsPermission))
        assertEquals(PPColor.Safe, folderDotColor(authorized.needsPermission))
        assertEquals(PPColor.Act, folderDotColor(expired.needsPermission))
    }

    @Test
    fun removal_waits_for_confirmation_before_it_fires() {
        val removed = mutableListOf<FolderUi>()
        val controller = FolderRemovalController { removed += it }

        controller.requestRemove(expired)
        assertEquals("点移除先挂起待确认", expired, controller.pending)
        assertTrue("确认前不得触发移除", removed.isEmpty())

        controller.dismiss()
        assertNull("取消后关闭确认弹窗", controller.pending)
        assertTrue("取消后不得触发移除", removed.isEmpty())
    }

    @Test
    fun confirming_removal_fires_once_for_the_pending_folder() {
        val removed = mutableListOf<FolderUi>()
        val controller = FolderRemovalController { removed += it }

        controller.requestRemove(expired)
        controller.confirm()

        assertNull("确认后关闭确认弹窗", controller.pending)
        assertEquals("确认后只触发一次、且是挂起的那一条", listOf(expired), removed)
    }

    @Test
    fun confirming_without_a_pending_folder_is_a_no_op() {
        val removed = mutableListOf<FolderUi>()
        val controller = FolderRemovalController { removed += it }

        controller.confirm()

        assertTrue("没有挂起的目录时确认不触发移除", removed.isEmpty())
    }
}
