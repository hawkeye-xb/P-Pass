// #1801 E2：范围页相册卡（ui/components/SourceCards.kt 的 SourceCard）读屏语义回归。
//
// 语义口径 = #1801 第三轮真机报告（.evidence/1801/round3/scope/ 的 uiautomator dump）实测：
//   - 卡节点本身 checkable + checked（Role.Checkbox + selected 在 a11y 边界的体现），整卡可点；
//   - 卡子树里合并了标题、张数文本与「Album/相册」类型 desc（名称与类型一口报出）；
//   - 选中卡另有「Selected/已选择」角标 desc，stateDescription 报「Selected/已选择」，
//     未选卡 checked=false、stateDescription 报「Not selected/未选择」；
//   - 「添加文件夹」卡（AddSourceCard）是按钮（Role.Button → a11y className Button）。
//
// 反证（卡上验收「至少一条删掉语义后变红」的第一条）：把 SourceCellFrame 里
// semantics(mergeDescendants) 块（role/selected/stateDescription）删掉，本类相册卡三条全红。

package com.hawkeyexb.ppass.ui.accessibility

import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.ui.components.AddSourceCard
import com.hawkeyexb.ppass.ui.components.SourceCard
import com.hawkeyexb.ppass.ui.components.SourceKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SourceCardSemanticsTest {

    private val kindLabel get() = testContext.getString(R.string.source_kind_album)
    private val selectedLabel get() = testContext.getString(R.string.source_selected)
    private val unselectedLabel get() = testContext.getString(R.string.source_unselected)

    private val title = "Camera"
    private val count = "12"

    private fun albumCard(selected: Boolean, block: () -> Unit) {
        hostCompose(
            {
                SourceCard(
                    title = title,
                    countLabel = count,
                    kind = SourceKind.ALBUM,
                    kindLabel = kindLabel,
                    selected = selected,
                    selectedDescription = selectedLabel,
                    unselectedDescription = unselectedLabel,
                    onClick = {},
                    cover = {},
                )
            },
            block,
        )
    }

    private fun albumCardNode(): AccessibilityNodeInfo {
        // 入口找类型 desc（「相册/Album」）——它是卡内容的一部分，挂在卡子树里。
        val kind = awaitNode("相册类型 desc（kindLabel）") { it.contentDescription?.toString() == kindLabel }
        val card = kind.checkableSelfOrAncestor()
            ?: throw AssertionError("类型 desc 必须落在 checkable 的卡节点上（Role.Checkbox + selected）；树：\n${describeTree()}")
        return card
    }

    /** 选中卡：卡节点 checkable/checked=true/可点，子树带类型与标题张数，另有「已选择」角标与 stateDescription。 */
    @Test
    fun selected_album_card_reads_type_name_and_selected_state() {
        albumCard(selected = true) {
            val card = albumCardNode()
            assertTrue("卡节点必须可点（整卡一个焦点）", card.isClickable)
            assertTrue("选中卡 checked 必须 = true", card.isChecked)
            val subtree = walk(card).toList()
            assertTrue("卡上要带「相册/Album」类型 desc", subtree.any { it.contentDescription?.toString() == kindLabel })
            assertTrue("卡上要合并标题文本（名称）", subtree.any { it.text?.toString() == title })
            assertTrue("卡上要合并张数文本（名称）", subtree.any { it.text?.toString() == count })
            assertTrue("选中卡要有「已选择」角标 desc", subtree.any { it.contentDescription?.toString() == selectedLabel })
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                assertEquals("选中卡的 stateDescription 必须报「已选择」", selectedLabel, card.stateDescription?.toString())
            }
            saveTree("sourcecard-selected.txt", a11yRoot())
        }
    }

    /** 未选卡：checked=false、无「已选择」角标、stateDescription 报「未选择」。 */
    @Test
    fun unselected_album_card_reads_not_selected_state() {
        albumCard(selected = false) {
            val card = albumCardNode()
            assertTrue("卡节点必须可点", card.isClickable)
            assertFalse("未选卡 checked 必须 = false", card.isChecked)
            val subtree = walk(card).toList()
            assertTrue("卡上仍要带「相册/Album」类型 desc", subtree.any { it.contentDescription?.toString() == kindLabel })
            assertTrue("未选卡不能有「已选择」角标 desc", subtree.none { it.contentDescription?.toString() == selectedLabel })
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                assertEquals("未选卡的 stateDescription 必须报「未选择」", unselectedLabel, card.stateDescription?.toString())
            }
            saveTree("sourcecard-unselected.txt", a11yRoot())
        }
    }

    /** 「添加文件夹」卡：可点、带 Role.Button 的 a11y 体现（className Button），名称来自 label。 */
    @Test
    fun add_folder_card_reads_button_role_and_label() {
        val label = "Add folder"
        val addDesc = "Add a folder as source"
        hostCompose(
            {
                AddSourceCard(
                    label = label,
                    actionContentDescription = addDesc,
                    onClick = {},
                )
            },
        ) {
            val labelNode = awaitNode("添加文件夹卡 label") { it.text?.toString() == label }
            val row = labelNode.clickableSelfOrAncestor()
                ?: throw AssertionError("添加文件夹卡必须可点；树：\n${describeTree()}")
            val subtree = walk(row).toList()
            assertTrue(
                "可点行要带 Role.Button 的 a11y 体现（className Button，round3 dump 同款）",
                subtree.any { it.className?.toString()?.endsWith("Button") == true },
            )
            assertNotNull("卡上要有动作 desc", subtree.firstOrNull { it.contentDescription?.toString() == addDesc })
            assertFalse("添加卡不是勾选项", row.isCheckable)
            saveTree("sourcecard-add.txt", a11yRoot())
        }
    }
}
